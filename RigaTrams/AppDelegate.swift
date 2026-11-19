import AppKit
import SwiftUI
import ServiceManagement

/// Creates the always-on desktop board and the menu bar icon that controls it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var feed: TramFeed!
    private var host: DraggableHostingView<BoardView>!
    private var blur: NSVisualEffectView!
    private var style: BoardStyle!
    private let defaults = UserDefaults.standard

    /// What the board shows. Each mode has its own network file in the app bundle.
    private enum Mode: String, CaseIterable {
        case trams, buses
        var resource: String { self == .trams ? "riga_trams" : "riga_buses" }
        var menuTitle: String { self == .trams ? "Show Trams" : "Show My Buses" }
    }

    private var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .trams }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    private var networks: [Mode: TramNetwork] = [:]
    private func network(for mode: Mode) -> TramNetwork {
        if let cached = networks[mode] { return cached }
        let loaded = TramNetwork.load(mode.resource)
        networks[mode] = loaded
        return loaded
    }

    private enum BoardSize: Int, CaseIterable {
        case small = 342, medium = 420, large = 540   // Small = width of two small macOS widgets side by side
        var title: String {
            switch self {
            case .small: "Small (two widgets wide)"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
    }

    private var size: BoardSize {
        get { BoardSize(rawValue: defaults.integer(forKey: "boardSize")) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "boardSize") }
    }

    private var floats: Bool {
        get { defaults.bool(forKey: "floatAboveWindows") }
        set { defaults.set(newValue, forKey: "floatAboveWindows") }
    }

    /// 0 = solid board, 1 = fully transparent.
    private var transparency: Double {
        get { defaults.double(forKey: "transparency") }
        set { defaults.set(newValue, forKey: "transparency") }
    }

    /// Locked: the board ignores drags and only responds to right-click.
    private var locked: Bool {
        get { defaults.bool(forKey: "positionLocked") }
        set { defaults.set(newValue, forKey: "positionLocked") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        feed = TramFeed(network: network(for: mode))
        makeWindow()
        makeStatusItem()
        feed.start()

        // Stop polling while the displays sleep; resume when they wake.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed.stop() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window.isVisible else { return }
                self.feed.start()
            }
        }
    }

    // MARK: Board window

    private func makeWindow() {
        let side = CGFloat(size.rawValue)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        // Frosted glass behind the board (blurs the wallpaper); shown when transparency > 0.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .popover            // follows light/dark mode
        blur.blendingMode = .behindWindow
        blur.state = .active
        container.addSubview(blur)

        style = BoardStyle(transparency: transparency)
        host = DraggableHostingView(rootView: BoardView(feed: feed, style: style))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        host.locked = locked
        host.menuProvider = { [weak self] in self?.makeMenu() }
        host.onHover = { [weak self] point in self?.style.hover = point }
        container.addSubview(host)
        window.contentView = container
        applyTransparency()

        window.ignoresMouseEvents = false   // drag the board anywhere with the mouse
        window.acceptsMouseMovedEvents = true   // hover shows stop names
        applyLevel()
        placeWindow()
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOrigin() }
        }
    }

    /// Sits on the desktop (above the icons so it can be dragged, behind every
    /// window), or floats on top if chosen.
    private func applyLevel() {
        window.level = floats
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func placeWindow() {
        let side = CGFloat(size.rawValue)
        window.setContentSize(NSSize(width: side, height: side))
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: visible.maxX - side - 24, y: visible.minY + 24)   // default: bottom right
        if let x = defaults.object(forKey: "originX") as? Double,
           let y = defaults.object(forKey: "originY") as? Double {
            origin = NSPoint(x: x, y: y)
        }
        // Keep it fully on screen (e.g. after switching to a larger size).
        origin.x = min(max(origin.x, visible.minX), visible.maxX - side)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - side)
        window.setFrameOrigin(origin)
    }

    private func applyTransparency() {
        style.transparency = transparency
        blur.alphaValue = transparency > 0 ? style.glassOpacity : 0
        blur.maskImage = Self.roundedMask(radius: CGFloat(size.rawValue) * 0.05)
        window.hasShadow = transparency < 0.75     // a shadow around floating text looks odd
        window.invalidateShadow()
    }

    /// Stretchable rounded-rectangle mask so the blur has the board's corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func saveOrigin() {
        defaults.set(Double(window.frame.origin.x), forKey: "originX")
        defaults.set(Double(window.frame.origin.y), forKey: "originY")
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Riga Trams")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Refresh the tram-icon menu each time it opens, so it always shows current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let items = makeMenu().items
        menu.removeAllItems()
        for item in items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    /// The same menu appears from the tram icon and when right-clicking the board.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(locked ? "Unlock Widget" : "Lock Widget", #selector(toggleLock)))
        menu.addItem(.separator())
        for m in Mode.allCases {
            let it = item(m.menuTitle, #selector(chooseMode(_:)))
            it.representedObject = m.rawValue
            it.state = m == mode ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshNow)))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for s in BoardSize.allCases {
            let it = item(s.title, #selector(chooseSize(_:)))
            it.tag = s.rawValue
            it.state = s == size ? .on : .off
            sizeMenu.addItem(it)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(transparencyItem())

        let floatItem = item("Float Above Windows", #selector(toggleFloat))
        floatItem.state = floats ? .on : .off
        menu.addItem(floatItem)
        menu.addItem(item(window.isVisible ? "Hide Board" : "Show Board", #selector(toggleVisible)))
        menu.addItem(.separator())

        let loginItem = item("Open at Login", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Riga Trams", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    /// "Transparency" label, current percentage, and a 0–100 % slider.
    private func transparencyItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        let title = NSTextField(labelWithString: "Transparency")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 20, y: 26, width: 140, height: 18)
        let value = NSTextField(labelWithString: "\(Int((transparency * 100).rounded()))%")
        value.font = .menuFont(ofSize: 0)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.tag = 7
        value.frame = NSRect(x: 160, y: 26, width: 62, height: 18)
        let slider = NSSlider(value: transparency * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(transparencyChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: 206, height: 20)
        view.addSubview(title)
        view.addSubview(value)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func transparencyChanged(_ sender: NSSlider) {
        transparency = sender.doubleValue / 100
        (sender.superview?.viewWithTag(7) as? NSTextField)?.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        applyTransparency()
    }

    @objc private func refreshNow() { feed.refresh() }

    /// Swap the board between trams and buses: new feed, new map, same window.
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let newMode = Mode(rawValue: raw),
              newMode != mode else { return }
        mode = newMode
        feed.stop()
        feed = TramFeed(network: network(for: newMode))
        host.rootView = BoardView(feed: feed, style: style)
        if window.isVisible { feed.start() }
        rebuildMenu()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        size = BoardSize(rawValue: sender.tag) ?? .medium
        placeWindow()
        applyTransparency()   // the blur's corner radius depends on size
        rebuildMenu()
    }

    @objc private func toggleLock() {
        locked.toggle()
        host.locked = locked
        rebuildMenu()
    }

    @objc private func toggleFloat() {
        floats.toggle()
        applyLevel()
        rebuildMenu()
    }

    @objc private func toggleVisible() {
        if window.isVisible {
            window.orderOut(nil)
            feed.stop()
        } else {
            window.orderFrontRegardless()
            feed.start()
        }
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        rebuildMenu()
    }
}

/// Drag anywhere on the board to move it (unless locked); right-click or
/// Control-click opens the board's menu; hovering reports the pointer position.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var locked = false
    var menuProvider: (() -> NSMenu?)?
    var onHover: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    /// .activeAlways: hover works even though this app is never the active one.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        onHover?(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))   // SwiftUI measures from the top
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override var mouseDownCanMoveWindow: Bool { !locked }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        if !locked { window?.performDrag(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
