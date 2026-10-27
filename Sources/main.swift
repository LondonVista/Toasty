import AppKit
import SwiftUI

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    /// Called once the user has dragged the card somewhere new.
    var onDragged: (() -> Void)?
    /// Adjusts a dragged-to origin, so the card can snap to things nearby.
    var snap: ((NSPoint) -> NSPoint)?
    private(set) var isDragging = false
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    // Dragging anywhere on the card moves it; a plain click still reaches the buttons.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStart = (NSEvent.mouseLocation, frame.origin)
        case .leftMouseDragged:
            guard let start = dragStart else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            if isDragging || hypot(dx, dy) > 3 {
                isDragging = true
                let origin = NSPoint(x: start.origin.x + dx, y: start.origin.y + dy)
                setFrameOrigin(snap?(origin) ?? origin)
                return
            }
        case .leftMouseUp:
            dragStart = nil
            if isDragging {
                isDragging = false
                onDragged?()
                // Release the press away from the card, so a drag that began on a button doesn't click it.
                if let away = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000),
                                                 modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                                 windowNumber: windowNumber, context: nil, eventNumber: event.eventNumber,
                                                 clickCount: event.clickCount, pressure: 0) {
                    super.sendEvent(away)
                }
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let warmer = Warmer()
    private let look = Look()
    private var panel: CardPanel!
    private var dockTimer: Timer?

    private let widgetBundleID = "com.londonvista.iPhoneBatteryWidget"
    private lazy var widgetDefaults = UserDefaults(suiteName: widgetBundleID)
    private let gap: CGFloat = 4
    private let defaults = UserDefaults.standard

    /// Where the card sits relative to the bottom-left of the widget's glass (top-left origin, so +y is down).
    /// Dragging the card changes it; the card then follows the widget at that distance as the widget resizes.
    private var widgetOffset: CGPoint {
        get {
            CGPoint(x: defaults.object(forKey: "widgetOffsetX") as? Double ?? 0,
                    y: defaults.object(forKey: "widgetOffsetY") as? Double ?? gap)
        }
        set {
            defaults.set(newValue.x, forKey: "widgetOffsetX")
            defaults.set(newValue.y, forKey: "widgetOffsetY")
        }
    }

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
        panel.isMovableByWindowBackground = false // CardPanel does its own dragging
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.onDragged = { [weak self] in self?.cardDragged() }
        panel.snap = { [weak self] origin in self?.snapToWidget(origin) ?? origin }
        panel.orderFrontRegardless()
    }

    private func cardDragged() {
        saveCardTopLeft()
        if let glass = widgetGlass(), let primary = NSScreen.screens.first {
            widgetOffset = CGPoint(x: panel.frame.minX - glass.minX, y: primary.frame.height - panel.frame.maxY - glass.maxY)
        }
    }

    /// Magnet: near the widget, the card lines up with its edges, beside, above or under it.
    private func snapToWidget(_ origin: NSPoint) -> NSPoint {
        guard let glass = widgetGlass(), let primary = NSScreen.screens.first else { return origin }
        let reach: CGFloat = 20
        let size = panel.frame.size
        let widget = NSRect(x: glass.minX, y: primary.frame.height - glass.maxY, width: glass.width, height: glass.height)
        guard NSRect(origin: origin, size: size).intersects(widget.insetBy(dx: -reach, dy: -reach)) else { return origin }

        func nearest(_ value: CGFloat, _ candidates: [CGFloat]) -> CGFloat {
            candidates.min { abs($0 - value) < abs($1 - value) }.flatMap { abs($0 - value) <= reach ? $0 : nil } ?? value
        }
        return NSPoint(
            x: nearest(origin.x, [widget.minX, widget.maxX - size.width, widget.maxX + gap, widget.minX - gap - size.width]),
            y: nearest(origin.y, [widget.minY - gap - size.height, widget.maxY + gap, widget.maxY - size.height, widget.minY])
        )
    }

    /// Used while the widget is hidden. The top-left corner is kept, so the card grows downwards when the scale changes.
    private func saveCardTopLeft() {
        defaults.set(panel.frame.minX, forKey: "cardX")
        defaults.set(panel.frame.maxY, forKey: "cardTop")
    }

    /// Where the user left the card, pulled back on screen if that display is gone.
    private func placeWhereLeft(size: NSSize) {
        let x = defaults.object(forKey: "cardX") as? Double ?? panel.frame.minX
        let top = defaults.object(forKey: "cardTop") as? Double ?? panel.frame.maxY
        var frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), let visible = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: visible.minX + 8, y: visible.maxY - size.height - 8)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Keeps the card glued to the widget's visible glass (at the dragged-to distance), at the widget's scale and opacity.
    private func dockUnderWidget() {
        look.scale = CGFloat(widgetNumber("ibw.widgetScale") ?? 1)
        look.opacity = widgetNumber("batteryWidget.bgOpacity") ?? 0.48
        let size = NSSize(width: CardView.baseWidth * look.scale, height: CardView.baseHeight * look.scale)
        guard !panel.isDragging else { return }

        guard let glass = widgetGlass(), let primary = NSScreen.screens.first else {
            return placeWhereLeft(size: size)
        }
        let offset = widgetOffset
        var origin = NSPoint(x: glass.minX + offset.x, y: primary.frame.height - glass.maxY - offset.y - size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: glass.midX, y: primary.frame.height - glass.midY)) })?.visibleFrame,
           origin.y < visible.minY {
            origin.y = visible.minY // no room below: sit on the Dock edge rather than slide off screen
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        saveCardTopLeft()
    }

    /// The widget's visible glass in screen coordinates with a top-left origin.
    /// Its window is taller than the glass: the content is drawn scaled from the top.
    private func widgetGlass() -> CGRect? {
        guard let widget = widgetBounds() else { return nil }
        return CGRect(x: widget.minX, y: widget.minY, width: widget.width * look.scale, height: widget.height * look.scale)
    }

    /// The widget's floating window in screen coordinates with a top-left origin.
    private func widgetBounds() -> CGRect? {
        // Found by app ID: the widget's window name has changed between versions.
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: widgetBundleID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows
            .filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.floatingWindow)) }
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
        menu.addItem(item("Move Card Back Under iPhone Widget", #selector(resetCardPosition)))
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
    @objc private func resetCardPosition() {
        defaults.removeObject(forKey: "widgetOffsetX")
        defaults.removeObject(forKey: "widgetOffsetY")
        dockUnderWidget()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
