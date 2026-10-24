import AppKit
import SwiftUI

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let warmer = Warmer()
    private let look = Look()
    private var panel: CardPanel!
    private var dockTimer: Timer?

    private let widgetOwner = "iPhoneBatteryWidget"
    private let widgetDefaults = UserDefaults(suiteName: "com.londonvista.iPhoneBatteryWidget")
    private let gap: CGFloat = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildPanel()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)

        dockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dockUnderWidget() }
        }
        dockUnderWidget()
        if CommandLine.arguments.contains("--heat-now") {
            warmer.start(now: true)
        } else if warmer.autoStart {
            warmer.start(resuming: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        warmer.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addControls(to: menu)
        return menu
    }

    // MARK: - Lid open / close

    @objc private func didWake() {
        if warmer.autoStart { warmer.start() }
    }

    @objc private func willSleep() {
        warmer.stop()
    }

    // MARK: - Card

    private func buildPanel() {
        let host = NSHostingView(rootView: CardView(warmer: warmer, look: look))
        panel = CardPanel(
            contentRect: NSRect(x: 8, y: 120, width: CardView.baseWidth, height: CardView.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.managed, .fullScreenNone]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    /// Keeps the card glued under the widget's visible glass, at the widget's scale and opacity.
    private func dockUnderWidget() {
        look.scale = CGFloat(widgetNumber("ibw.widgetScale") ?? 1)
        look.opacity = widgetNumber("batteryWidget.bgOpacity") ?? 0.48
        let size = NSSize(width: CardView.baseWidth * look.scale, height: CardView.baseHeight * look.scale)

        guard let widget = widgetBounds(), let primary = NSScreen.screens.first else {
            if panel.frame.size != size { panel.setContentSize(size) }
            return
        }
        // The widget's window is taller than its glass: the content is drawn scaled from the top.
        let glassBottom = widget.minY + widget.height * look.scale
        var origin = NSPoint(x: widget.minX, y: primary.frame.height - glassBottom - gap - size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: widget.midX, y: primary.frame.height - widget.midY)) })?.visibleFrame,
           origin.y < visible.minY {
            origin.y = visible.minY // no room below: sit on the Dock edge rather than slide off screen
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The widget's floating window in screen coordinates with a top-left origin.
    private func widgetBounds() -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows
            .filter { $0[kCGWindowOwnerName as String] as? String == widgetOwner && $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.floatingWindow)) }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// The widget stores some numbers as strings, so accept both.
    private func widgetNumber(_ key: String) -> Double? {
        let value = widgetDefaults?.object(forKey: key)
        return (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Toasty")
        appMenu.delegate = self
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addControls(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Quit Toasty", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func addControls(to menu: NSMenu) {
        menu.addItem(item(warmer.isWarming ? "Stop Warming" : "Start Warming", #selector(toggleWarming)))

        let targetMenu = NSMenu()
        for degrees in Int(Warmer.targetRange.lowerBound)...Int(Warmer.targetRange.upperBound) {
            let entry = item("\(degrees)°C", #selector(setTarget(_:)))
            entry.tag = degrees
            entry.state = Int(warmer.target) == degrees ? .on : .off
            targetMenu.addItem(entry)
        }
        menu.addItem(submenu("Target: \(Int(warmer.target))°C", targetMenu))

        let holdMenu = NSMenu()
        for minutes in [0, 15, 30, 60, 120] {
            let title = minutes == 0 ? "Until I Stop It" : minutes < 60 ? "\(minutes) Minutes" : minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours"
            let entry = item(title, #selector(setHold(_:)))
            entry.tag = minutes
            entry.state = warmer.holdMinutes == minutes ? .on : .off
            holdMenu.addItem(entry)
        }
        menu.addItem(submenu("Keep Warm For", holdMenu))
        menu.addItem(.separator())

        menu.addItem(toggle("Start When Lid Opens", warmer.autoStart, #selector(toggleAutoStart)))
        menu.addItem(toggle("Pause After \(warmer.idleMinutes) Minutes Idle", warmer.stopWhenIdle, #selector(toggleStopWhenIdle)))
        menu.addItem(toggle("Run on Battery (stops at \(warmer.minBatteryPercent)%)", warmer.runOnBattery, #selector(toggleRunOnBattery)))
        menu.addItem(toggle("Open at Login", warmer.loginItemEnabled, #selector(toggleLoginItem)))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let entry = item(title, action)
        entry.state = on ? .on : .off
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    // MARK: - Actions

    @objc private func toggleWarming() { warmer.toggle() }
    @objc private func setTarget(_ sender: NSMenuItem) { warmer.target = Double(sender.tag) }
    @objc private func setHold(_ sender: NSMenuItem) { warmer.holdMinutes = sender.tag }
    @objc private func toggleAutoStart() { warmer.autoStart.toggle() }
    @objc private func toggleStopWhenIdle() { warmer.stopWhenIdle.toggle() }
    @objc private func toggleRunOnBattery() { warmer.runOnBattery.toggle() }
    @objc private func toggleLoginItem() { warmer.toggleLoginItem() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
