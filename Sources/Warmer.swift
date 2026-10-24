import CoreGraphics
import Foundation
import ServiceManagement

/// The thermostat: reads the palm rest temperature every few seconds and sets the heater power.
@MainActor
final class Warmer: ObservableObject {
    @Published private(set) var reading = Reading()
    @Published private(set) var isWarming = false
    @Published private(set) var duty = 0.0
    @Published private(set) var note = "" { didSet { if note != oldValue { log(note.isEmpty ? "resumed" : note) } } }
    @Published private(set) var warmingUntil: Date?
    @Published private(set) var coreLoads: [Double] = []
    let coreMeter = CoreMeter()

    @Published var target: Double { didSet { defaults.set(target, forKey: "target"); update() } }
    @Published var reheatAt: Double { didSet { defaults.set(reheatAt, forKey: "reheatAt"); update() } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "autoStart") } }
    @Published var runOnBattery: Bool { didSet { defaults.set(runOnBattery, forKey: "runOnBattery"); update() } }
    @Published var holdMinutes: Int { didSet { defaults.set(holdMinutes, forKey: "holdMinutes"); if isWarming { start() } } }
    @Published var stopWhenIdle: Bool { didSet { defaults.set(stopWhenIdle, forKey: "stopWhenIdle") } }

    let idleMinutes = 2

    static let targetRange = 30.0...38.0
    let minBatteryPercent = 20

    private let sensors = Sensors()
    private let heater = Heater()
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    /// Heat to the target at full power, then rest until the palm rest cools to `reheatAt`.
    private enum Phase { case warmingUp, resting, reheating }
    private var phase = Phase.warmingUp {
        didSet {
            // Remembered so a restart or update carries on with an unfinished warm-up.
            defaults.set(phase != .resting, forKey: "midWarmUp")
            if phase != oldValue { log("\(phase)") }
        }
    }

    /// One line per state change in ~/Library/Logs/Toasty.log, to see later why it heated or not.
    private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Toasty.log")

    private func log(_ event: String) {
        let temp = reading.battery.map { String(format: "%.1f°C", $0) } ?? "?"
        let chip = reading.chip.map { String(format: "%.0f°C", $0) } ?? "?"
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(event)  palm \(temp)  chip \(chip)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private let tick = 2.0              // seconds between control updates
    private let batteryLimit = 40.0     // never let the palm rest go above this
    // The user is fine with 100 °C on the chip; this is only a last-resort failsafe.
    private let chipLimit = 105.0
    // Toasty leaves 4 cores free; background work alone uses about 2, so above 3 the apps want ours too.
    private let busyCores = 3.0
    private let cpuMeter = CPUMeter()

    init() {
        defaults.register(defaults: ["target": 35.0, "reheatAt": 30.0, "autoStart": true, "holdMinutes": 0,
                                     "runOnBattery": true, "stopWhenIdle": true])
        stopWhenIdle = defaults.bool(forKey: "stopWhenIdle")
        target = defaults.double(forKey: "target")
        reheatAt = defaults.double(forKey: "reheatAt")
        autoStart = defaults.bool(forKey: "autoStart")
        runOnBattery = defaults.bool(forKey: "runOnBattery")
        holdMinutes = defaults.integer(forKey: "holdMinutes")

        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    var status: String {
        if !note.isEmpty { return note }
        guard isWarming else { return "Off" }
        switch phase {
        case .warmingUp: return "Warming up"
        case .resting: return "Resting"
        case .reheating: return "Reheating"
        }
    }

    /// Always at least a degree under the target, so the swing never gets stuck.
    var effectiveReheatAt: Double { min(reheatAt, target - 1) }

    var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// `now` heats straight away (the ⏻ button); otherwise a warm Mac waits for the reheat point.
    func start(now: Bool = false, resuming: Bool = false) {
        let now = now || (resuming && defaults.bool(forKey: "midWarmUp"))
        warmingUntil = holdMinutes > 0 ? Date().addingTimeInterval(Double(holdMinutes) * 60) : nil
        isWarming = true
        // Already warm from earlier use: wait until it cools to the reheat point.
        reading = sensors.read()
        log(now ? "start now" : "start")
        phase = now || (reading.battery ?? 0) <= effectiveReheatAt ? .warmingUp : .resting
        note = ""
        heater.start()
        update()
    }

    func stop() {
        defaults.set(false, forKey: "midWarmUp")
        if isWarming { log("stop") }
        isWarming = false
        warmingUntil = nil
        heater.stop()
        update()
    }

    func toggle() { isWarming ? stop() : start(now: true) }

    func nudgeTarget(by step: Double) {
        target = min(max(target + step, Self.targetRange.lowerBound), Self.targetRange.upperBound)
    }

    func nudgeReheat(by step: Double) {
        reheatAt = min(max(effectiveReheatAt + step, Self.targetRange.lowerBound - 5), target - 1)
    }

    func toggleLoginItem() {
        do {
            if loginItemEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            note = "Login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func shutdown() { heater.stop() }

    private func update() {
        reading = sensors.read()
        coreLoads = coreMeter.loads()
        let others = cpuMeter.otherAppsCores()
        if isWarming {
            heater.duty = nextDuty(otherCores: others)
        } else if note.hasPrefix("Paused") || note.hasPrefix("Safety") || note.hasPrefix("Mac") {
            note = ""
        }
        duty = heater.isRunning ? heater.duty : 0
    }

    /// Share the Mac while warming: half power when apps are busy or macOS is getting hot,
    /// so they lose at most about half their speed and the Mac still warms up.
    private func sharedPower(otherCores: Double?) -> (note: String, duty: Double)? {
        // Serious is where macOS starts slowing apps down; fair is just "warm" and fine.
        let state = ProcessInfo.processInfo.thermalState
        if state == .critical || (reading.chip ?? 0) >= chipLimit { return ("Mac hot, paused", 0) }
        if state == .serious { return ("Mac warm, half power", 0.5) }
        if let otherCores, otherCores > busyCores { return ("Mac busy, half power", 0.5) }
        return nil
    }

    private func nextDuty(otherCores: Double?) -> Double {
        if let until = warmingUntil, Date() >= until {
            stop()
            return 0
        }
        // Nobody at the Mac: no mouse move, click or key press for a while. Pause the heater but
        // keep the cycle, so a warm-up carries on to the target once they are back.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if stopWhenIdle, idle >= Double(idleMinutes * 60) {
            note = "Idle, paused"
            return 0
        }
        let power = PowerState.current()
        if power.onBattery {
            if !runOnBattery { note = "Paused on battery"; return 0 }
            if let percent = power.percent, percent < minBatteryPercent {
                stop()
                note = "Battery below \(minBatteryPercent)%"
                return 0
            }
        }
        guard let temp = reading.battery else { note = "No sensor"; return 0 }
        if temp >= batteryLimit {
            note = "Safety pause"
            phase = .resting
            return 0
        }
        switch phase {
        case .warmingUp, .reheating:
            if temp >= target { phase = .resting }
        case .resting:
            if temp <= effectiveReheatAt { phase = .reheating }
        }
        guard phase != .resting else { note = ""; return 0 }

        let shared = sharedPower(otherCores: otherCores)
        note = shared?.note ?? ""
        return shared?.duty ?? 1
    }
}
