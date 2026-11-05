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
        let host = NSHostingView(rootView: MenuView(onSizeChange: { [weak self] in self?.resize() }).environmentObject(store))
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

    func windowDidResignKey(_ notification: Notification) { close() }
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
