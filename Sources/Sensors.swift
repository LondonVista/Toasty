import Foundation
import IOKit.ps

// Private IOHIDEventSystem calls. They read Apple Silicon temperature sensors without root.
typealias HIDClient = OpaquePointer
typealias HIDService = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> HIDClient?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: HIDClient, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: HIDClient) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: HIDService, _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: HIDService, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

private let temperatureEventType: Int64 = 15

struct Reading {
    /// Hottest battery sensor. The battery sits under the palm rest, so this tracks what your hands feel.
    var battery: Double?
    /// Hottest chip sensor, used only as a safety limit.
    var chip: Double?
}

final class Sensors {
    private let client: HIDClient?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        }
    }

    func read() -> Reading {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) as [AnyObject]? else {
            return Reading()
        }
        var reading = Reading()
        for object in services {
            let service = unsafeBitCast(object, to: HIDService.self)
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  // A "Copy" call hands us ownership; taking it releases the event after use.
                  let event = IOHIDServiceClientCopyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(temperatureEventType << 16))
            guard value > 0, value < 150 else { continue } // unused sensors report negative values
            if name.hasPrefix("gas gauge battery") {
                reading.battery = max(reading.battery ?? value, value)
            } else if name.contains("tdie") || name.contains("ACC MTR") {
                reading.chip = max(reading.chip ?? value, value)
            }
        }
        return reading
    }
}

/// How many cores other apps are using, measured between calls (whole system minus Toasty itself).
final class CPUMeter {
    private var lastTicks: (busy: Double, total: Double)?
    private var lastOwn: Double?
    private var lastWall: Double?

    func otherAppsCores() -> Double? {
        let ticks = systemTicks()
        let own = ownCPUSeconds()
        let wall = ProcessInfo.processInfo.systemUptime
        defer { lastTicks = ticks; lastOwn = own; lastWall = wall }
        guard let ticks, let lastTicks, let lastOwn, let lastWall, ticks.total > lastTicks.total, wall > lastWall else {
            return nil
        }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let systemCores = (ticks.busy - lastTicks.busy) / (ticks.total - lastTicks.total) * cores
        let ownCores = (own - lastOwn) / (wall - lastWall)
        return max(0, systemCores - ownCores)
    }

    private func systemTicks() -> (busy: Double, total: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0), system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private func ownCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// Busy fraction (0...1) of each core between calls. On Apple Silicon the efficiency cores come first.
final class CoreMeter {
    private var last: [(busy: Double, total: Double)] = []

    let efficiencyCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 0
    }()

    func loads() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        var now: [(busy: Double, total: Double)] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)]), system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)]), idle = Double(info[base + Int(CPU_STATE_IDLE)])
            now.append((user + system + nice, user + system + nice + idle))
        }
        defer { last = now }
        guard last.count == now.count else { return now.map { _ in 0 } }
        return zip(now, last).map { current, previous in
            let total = current.total - previous.total
            return total > 0 ? min(max((current.busy - previous.busy) / total, 0), 1) : 0
        }
    }
}

struct PowerState {
    var onBattery: Bool
    var percent: Int?

    static func current() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as [CFTypeRef]? else {
            return PowerState(onBattery: false, percent: nil)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return PowerState(onBattery: onBattery, percent: description[kIOPSCurrentCapacityKey] as? Int)
        }
        return PowerState(onBattery: false, percent: nil)
    }
}
