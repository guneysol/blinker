import AppKit
import SwiftUI

/// Laid out like the system's own menu bar menus (Wi-Fi, Bluetooth): the system font in two
/// weights, gray symbol circles, hairline dividers, and one colored element: the circle of a
/// request that is waiting on your key right now.
private enum Metrics {
    static let width: CGFloat = 300
    static let inset: CGFloat = 14
    static let circle: CGFloat = 26
}

struct MenuView: View {
    @EnvironmentObject var store: Store
    @State private var showAll = false
    /// Lets the panel follow the content's height (the menu is not a SwiftUI window).
    var onSizeChange: () -> Void = {}
    /// Opens the settings menu. A native NSMenu, owned by StatusBar: a SwiftUI Menu inside the
    /// panel closed the panel as it opened, so its items never ran.
    var onSettings: (NSView) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let wait = store.current {
                // Says plainly what this section is, in the same words as the notification.
                Text("Your key is waiting for a touch")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, 3)
                    .accessibilityAddTraits(.isHeader)
                Waiting(wait: wait)
                separator
            } else if let problem = store.problem {
                Row(symbol: "exclamationmark.triangle", title: "Not watching your key", detail: problem, wraps: true,
                    action: ("Try Again", { store.retry() }))
                separator
            }
            if store.notificationsOff {
                Row(symbol: "bell.slash", title: "Notifications are off",
                    detail: "Blinker can't alert you until they're on.", wraps: true,
                    action: ("Turn On", { store.openNotificationSettings() }))
                separator
            }
            if let note = store.launchAtLoginNote {
                Row(symbol: "power", title: "Launch at Login", detail: note, wraps: true)
                separator
            }
            history
        }
        .padding(.vertical, 6)
        .frame(width: Metrics.width)
        .onAppear { store.refresh() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in onSizeChange() }
    }

    private var separator: some View {
        Divider().padding(.horizontal, Metrics.inset).padding(.vertical, 5)
    }

    @ViewBuilder private var history: some View {
        HStack {
            Text("Recent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            SettingsButton(action: onSettings)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 1)
        if store.history.isEmpty {
            Text("No requests yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.inset)
                .padding(.vertical, 3)
        } else {
            let shown = showAll ? store.history : Array(store.history.prefix(5))
            // Scrolls once it's taller than about eight rows, so it always fits on screen.
            ScrollView {
                VStack(spacing: 0) { ForEach(shown) { HistoryRow(wait: $0) } }
            }
            .scrollIndicators(.never)
            .frame(height: CGFloat(min(shown.count, 8)) * 42)
            if store.history.count > 5 {
                Button(showAll ? "Show Less" : "Show All (\(store.history.count))") { showAll.toggle() }
                    .buttonStyle(RowButtonStyle())
            }
        }
    }
}

// MARK: - The key is waiting

private struct Waiting: View {
    @EnvironmentObject var store: Store
    let wait: Wait

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let likely = wait.likely {
                asker(likely, highlighted: true)
            } else if !wait.looked {
                Row(symbol: "key.horizontal.fill", active: true, title: "Checking who asked…", detail: "")
            } else if wait.fresh.isEmpty {
                Row(symbol: "key.horizontal.fill", active: true, title: "No program Blinker can see is asking",
                    detail: "Don't touch your key unless you started something.", wraps: true)
            } else {
                // Several asked at once. The touch goes to whichever one your key's agent is
                // serving, which can't be seen from outside, so list them all as candidates.
                Text("One of these is asking")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, 2)
                ForEach(wait.fresh) { asker($0, highlighted: false) }
            }
            ForEach(wait.idle) { request in
                Connected(request: request, idle: true, stopped: wait.stopped.contains(request.id))
            }
        }
    }

    /// One program that may be asking: what it wants, who it is, where it runs, and Stop.
    private func asker(_ request: Request, highlighted: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle_(symbol: highlighted ? "key.horizontal.fill" : request.symbol, active: highlighted)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(highlighted ? "\(request.who ?? "An unrecognized program") is asking" : request.who ?? "An unrecognized program")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let place = request.place {
                    Text(place).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let host = request.host, !host.hasSuffix(")") {
                    Text("Requested host: \(host)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Destination from the SSH command. SSH configuration may override it.")
                }
                ForEach(request.warnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(request.headline)\n\(request.command)")
            stop(request, stopped: wait.stopped.contains(request.id))
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func stop(_ request: Request, stopped: Bool) -> some View {
        if stopped {
            Text("Stopped").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if store.stopFailed == request.id {
            Text("Couldn't stop").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Button("Stop", role: .destructive) { store.stop(request) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cancel this request (sends SIGTERM to pid \(request.pid))")
        }
    }
}

/// Another program connected to the agent while the key waits.
private struct Connected: View {
    @EnvironmentObject var store: Store
    let request: Request
    let idle: Bool
    let stopped: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle_(symbol: request.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.title).font(.system(size: 13)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(request.headline)\n\(request.command)")
            if !stopped {
                // Quieter than the main Stop: one prominent action per menu.
                Button("Stop") { store.stop(request) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Cancel this connection (sends SIGTERM to pid \(request.pid))")
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = [request.who ?? "Unrecognized program"]
        parts.append(idle ? "idle since \(request.started.formatted(date: .omitted, time: .shortened))" : "also connected")
        if stopped { parts.append("stopped") }
        if !request.warnings.isEmpty { parts.append("check this") }
        if store.stopFailed == request.id { parts.append("couldn't stop") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - History

private struct HistoryRow: View {
    let wait: Wait

    var body: some View {
        HStack(spacing: 10) {
            Circle_(symbol: wait.likely?.symbol ?? "questionmark")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.everyMinute) { _ in
                Text(wait.began, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .modifier(RowChrome())
        .help(wait.likely.map { "\($0.headline)\n\($0.command)" } ?? wait.requests.map(\.headline).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private var title: String { wait.summary }

    private var detail: String {
        var parts: [String] = []
        if let likely = wait.likely {
            parts.append(likely.who ?? "Unrecognized program")
            if let repo = likely.shortPlace { parts.append(repo) }
        } else if !wait.fresh.isEmpty {
            var whos: [String] = []
            for r in wait.fresh where !whos.contains(r.who ?? "A program") { whos.append(r.who ?? "A program") }
            parts.append("one of " + whos.joined(separator: ", "))
        }
        if !wait.stopped.isEmpty { parts.append("stopped") }
        return parts.isEmpty ? "Couldn't tell who asked" : parts.joined(separator: " · ")
    }
}

// MARK: - Shared pieces

/// A symbol in a circle, as in the Wi-Fi menu: gray at rest, filled with color when active.
private struct Circle_: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: Metrics.circle, height: Metrics.circle)
            .background(Circle().fill(active ? Color.green : Color.primary.opacity(0.09)))
            .accessibilityHidden(true)
    }
}

private struct Row: View {
    let symbol: String
    var active = false
    let title: String
    let detail: String
    var wraps = false
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: wraps ? .top : .center, spacing: 10) {
            Circle_(symbol: symbol, active: active)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: active ? .semibold : .regular))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: wraps)
                }
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension Request {
    /// "~/code/acme-web (feat/login)" → "acme-web (feat/login)", for one-line rows.
    var shortPlace: String? {
        guard let place else { return nil }
        let (folder, branch) = place.firstRange(of: " (").map { (String(place[..<$0.lowerBound]), String(place[$0.lowerBound...])) }
            ?? (place, "")
        return folder.basename + branch
    }

    var symbol: String {
        switch kind {
        case .push: "arrow.up"
        case .fetch: "arrow.down"
        case .sign: "signature"
        case .decrypt: "lock.open"
        case .connect: "terminal"
        case .unknown: "questionmark"
        }
    }
}

/// Rows highlight on hover like system menu items.
private struct RowChrome: ViewModifier {
    var pressed = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(pressed ? 0.14 : hovering ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(RowChrome(pressed: configuration.isPressed))
    }
}

// MARK: - Settings

/// The ⋯ button. It hands its own view to StatusBar, which pops the menu up right under it.
private struct SettingsButton: View {
    let action: (NSView) -> Void

    var body: some View {
        AnchorButton(action: action)
            .frame(width: 18, height: 18)
            .help("Settings")
            .accessibilityLabel("Settings")
    }
}

private struct AnchorButton: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func click(_ sender: NSButton) { action(sender) }
    }
}
