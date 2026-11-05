import AppKit
import Combine
import SwiftUI

/// The menu bar item and its menu, owned through AppKit.
///
/// The icon is set straight on the status button from Store's state. SwiftUI's MenuBarExtra
/// label rebuilt itself whenever Store changed, and swapping images there twice caused runaway
/// update loops (a frozen main thread, then 100% CPU and unbounded memory), so SwiftUI is
/// only used for the menu's contents.
@MainActor
final class StatusBar: NSObject, NSWindowDelegate {
    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: NSPanel?
    private var outsideClicks: Any?
    private var watching: AnyCancellable?
    /// True while the settings menu is open, so the panel doesn't close when the menu takes focus.
    private var settingsOpen = false

    init(store: Store) {
        self.store = store
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Blinker")
        // Only the icon's inputs; nothing else in Store touches the status button.
        watching = store.$current.map { $0 != nil }
            .combineLatest(store.blink.$on, store.$problem.map { $0 != nil })
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] waiting, blinkOn, problem in
                self?.setIcon(waiting: waiting, bright: blinkOn, problem: problem)
            }
    }

    private func setIcon(waiting: Bool, bright: Bool, problem: Bool) {
        let image = waiting ? Icons.green[bright ? 1 : 0] : problem ? Icons.problem : Icons.idle
        guard item.button?.image !== image else { return }
        item.button?.image = image
        item.button?.setAccessibilityLabel(waiting ? "Blinker: your key is waiting for a touch"
                                           : problem ? "Blinker: not watching your key" : "Blinker")
    }

    // MARK: - The menu

    @objc private func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    private func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 200)
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        panel?.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    private func makePanel() -> NSPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: MenuView(
            onSizeChange: { [weak self] in self?.resize() },
            onSettings: { [weak self] anchor in self?.showSettings(under: anchor) }
        ).environmentObject(store))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// Keeps the menu's top edge under the icon when its content grows or shrinks.
    private func resize() {
        guard let panel, panel.isVisible, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !settingsOpen { close() }
    }

    // MARK: - Settings

    private func showSettings(under anchor: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, on: Bool? = nil, enabled: Bool = true, link: String? = nil) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            item.representedObject = link
            menu.addItem(item)
        }
        add("Notifications", #selector(toggleNotify), on: store.notify)
        add("Notification Sound", #selector(toggleSound), on: store.sound, enabled: store.notify)
        add("Launch at Login", #selector(toggleLogin), on: store.launchAtLogin)
        menu.addItem(.separator())
        add("Send a Test Notification", #selector(sendTest))
        add("Clear History", #selector(clearHistory), enabled: !store.history.isEmpty)
        menu.addItem(.separator())
        add("Follow @guneysol on X", #selector(openLink), link: "https://x.com/guneysol")
        // X has no link that opens a DM by username, so this opens the profile with its Message button.
        add("Send Feedback on X…", #selector(openLink), link: "https://x.com/guneysol")
        add("Star on GitHub", #selector(openLink), link: "https://github.com/guneysol/blinker")
        add("Report a Bug…", #selector(openLink), link: "https://github.com/guneysol/blinker/issues/new/choose")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blinker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        settingsOpen = true
        // Just below the button. A button's coordinates are flipped (y grows downward), so
        // "below" is its maxY there; getting this wrong opens the menu into the menu bar,
        // where macOS clips it and adds a scroll arrow.
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : anchor.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: below), in: anchor) // returns when it closes
        settingsOpen = false
        panel?.makeKey()
    }

    @objc private func toggleNotify() { store.notify.toggle() }
    @objc private func toggleSound() { store.sound.toggle() }
    @objc private func toggleLogin() { store.setLaunchAtLogin(!store.launchAtLogin) }
    @objc private func clearHistory() { store.clearHistory() }
    @objc private func sendTest() {
        close()
        store.sendTest()
    }
    @objc private func openLink(_ sender: NSMenuItem) {
        close()
        if let link = sender.representedObject as? String, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

/// A borderless panel that can take keyboard focus (for the ⋯ menu and Escape).
private final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Icons, made once. Idle and problem are templates the system tints; the waiting key is a real
/// green image (the color of the light on the key), in a bright and a dim version for the blink.
@MainActor
enum Icons {
    static let idle = symbol("key.horizontal", template: true)
    static let problem = symbol("exclamationmark.triangle", template: true)
    static let green: [NSImage] = [0.45, 1.0].map { alpha in
        symbol("key.horizontal.fill", template: false, color: NSColor.systemGreen.withAlphaComponent(alpha))
    }

    private static func symbol(_ name: String, template: Bool, color: NSColor? = nil) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = template
        return image
    }
}
