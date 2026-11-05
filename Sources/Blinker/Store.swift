import AppKit
import Darwin
import Foundation
import OSLog
import ServiceManagement
import UserNotifications

/// What the app does, in `log stream --predicate 'subsystem == "io.github.guneysol.blinker"'`.
/// Event names and counts only: never commands, paths or names of programs.
let log = Logger(subsystem: "io.github.guneysol.blinker", category: "app")

/// One touch wait, kept in memory only. Nothing is written to disk.
struct Wait: Identifiable {
    let id = UUID()
    let began: Date
    var ended: Date?
    /// Every program connected to the key's agent when the wait began, newest first.
    var requests: [Request] = []
    var looked = false
    var stopped: Set<UUID> = []

    /// A program that connected in the last minute. Older connections are usually idle or stuck
    /// (a hung `git fetch`), so they're listed but never offered as the answer.
    static let freshness: TimeInterval = 60
    var fresh: [Request] { requests.filter { began.timeIntervalSince($0.started) < Self.freshness } }
    var idle: [Request] { requests.filter { began.timeIntervalSince($0.started) >= Self.freshness } }

    /// The single best guess: exactly one program connected just now. With none, or several,
    /// Blinker says it can't tell rather than guess.
    var likely: Request? { fresh.count == 1 ? fresh[0] : nil }

    var headline: String {
        if let likely { return likely.headline }
        if !looked { return "Checking who asked…" }
        if fresh.isEmpty { return "An unknown program is asking" }
        return "\(fresh.count) programs asked at once"
    }
}

/// Flips while the key waits, so the menu bar icon blinks. Its own object, so the blink
/// redraws only the icon, never the menu.
@MainActor
final class Blink: ObservableObject {
    @Published private(set) var on = false
    private var timer: Timer?

    func start() {
        on = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.on.toggle() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps blinking while a menu is open
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        on = false
    }
}

@MainActor
final class Store: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var current: Wait?
    @Published private(set) var history: [Wait] = []
    @Published private(set) var problem: String?
    /// macOS has notifications for Blinker turned off, so nothing would appear.
    @Published private(set) var notificationsOff = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNote: String?
    @Published private(set) var stopFailed: UUID?
    @Published var notify: Bool { didSet { UserDefaults.standard.set(notify, forKey: "notify") } }
    @Published var sound: Bool { didSet { UserDefaults.standard.set(sound, forKey: "sound") } }
    let blink = Blink()

    private var watcher: TouchWatcher?
    private let center = UNUserNotificationCenter.current()
    private static let historyLimit = 20
    nonisolated private static let category = "touch"
    nonisolated private static let stopAction = "stop"

    override init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["notify": true, "sound": true])
        notify = defaults.bool(forKey: "notify")
        sound = defaults.bool(forKey: "sound")
        super.init()
    }

    func start() {
        guard watcher == nil else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            // Stopping a process from the lock screen needs the Mac unlocked first.
            actions: [UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [.destructive, .authenticationRequired])],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "YubiKey needs a touch",
            options: []
        )])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            log.info("notifications allowed: \(granted, privacy: .public)")
            Task { @MainActor in self?.refresh() }
        }
        center.removeAllDeliveredNotifications() // anything left from a previous run is stale

        let watcher = TouchWatcher { [weak self] event in self?.handle(event) }
        self.watcher = watcher
        watcher.start()
        // A burst of logd restarts (an update, a rough wake) can make the watcher give up.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.retry() } }
    }

    func stop() { watcher?.stop() }

    /// Starts watching again after it gave up. Does nothing while it's still watching.
    func retry() {
        guard problem != nil else { return }
        problem = nil
        watcher?.start()
    }

    /// Re-reads things that change outside the app: notification permission and login item.
    /// Called when the menu opens, never on a timer.
    func refresh() {
        center.getNotificationSettings { [weak self] settings in
            let off = settings.authorizationStatus == .denied
            Task { @MainActor in self?.notificationsOff = off }
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval { launchAtLoginNote = "Allow Blinker in System Settings › Login Items." }
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginNote = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginNote = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginNote = "Allow Blinker in System Settings › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openNotificationSettings() {
        let url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.guneysol.blinker"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private func handle(_ event: TouchWatcher.Event) {
        log.info("watcher event: \(String(describing: event), privacy: .public)")
        switch event {
        case .started:
            problem = nil
            let wait = Wait(began: Date())
            current = wait
            blink.start()
            // Reading the process table touches the disk (for branch names), so keep it off the
            // main thread. The asker is blocked on the key, so it'll still be there.
            Task.detached(priority: .userInitiated) {
                let requests = Requests.current()
                await MainActor.run { self.found(requests, for: wait.id) }
            }
        case .ended:
            guard var wait = current else { return }
            wait.ended = Date()
            current = nil
            stopFailed = nil
            blink.stop()
            history.insert(wait, at: 0)
            history = Array(history.prefix(Self.historyLimit))
            withdraw(wait.id)
        case .unavailable(let reason):
            problem = reason
            let content = UNMutableNotificationContent()
            content.title = "Blinker stopped watching your key"
            content.body = reason
            center.add(UNNotificationRequest(identifier: "unavailable", content: content, trigger: nil))
        }
    }

    private func found(_ requests: [Request], for id: UUID) {
        if current?.id == id {
            current?.requests = requests
            current?.looked = true
            log.info("found \(requests.count, privacy: .public) connected programs; notify=\(self.notify, privacy: .public)")
            if notify, let wait = current { post(wait) }
            keepLooking(id)
        } else if let i = history.firstIndex(where: { $0.id == id }) {
            history[i].requests = requests // the wait was over before we finished looking
            history[i].looked = true
        }
    }

    /// Back-to-back requests keep the key waiting without a pause, so they arrive as one long
    /// wait. While it lasts, look again every few seconds (about 6 ms each time) and follow a
    /// change of asker, so the menu and notification never describe a request that's gone.
    private func keepLooking(_ id: UUID) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.current?.id == id else { return }
                let requests = await Task.detached(priority: .utility) { Requests.current() }.value
                self.update(requests, for: id)
            }
        }
    }

    private func update(_ fresh: [Request], for id: UUID) {
        guard var wait = current, wait.id == id else { return }
        func key(_ r: Request) -> String { "\(r.pid)/\(r.started.timeIntervalSince1970)" }
        // Keep the same Request (and so its Stop state) for programs still connected.
        let known = Dictionary(wait.requests.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let merged = fresh.map { known[key($0)] ?? $0 }
        guard merged.map(key) != wait.requests.map(key) else { return }
        let before = wait.likely.map(key)
        wait.requests = merged
        current = wait
        log.info("connected programs changed: now \(merged.count, privacy: .public)")
        // A new, identifiable asker replaces the banner (same identifier). One that just left
        // doesn't: the menu shows the change without another sound.
        if notify, let now = wait.likely.map(key), now != before { post(wait) }
    }

    // MARK: - Stopping a request

    /// Sends SIGTERM to a program connected to the key, only while the key is still waiting.
    /// Before signaling, it checks that the pid is still the same process (same start time, so a
    /// recycled pid is never hit), still yours, and still connected to the key's agent. An agent
    /// only listens on its socket and is never connected to one, so it can't be signaled.
    @discardableResult
    func stop(_ request: Request) -> Bool {
        stopFailed = nil
        guard let wait = current, wait.requests.contains(request),
              let proc = Processes.table()[request.pid], // lists only your own processes
              abs(proc.started.timeIntervalSince(request.started)) < 0.001,
              proc.pid > 1, proc.pid != getpid(),
              Requests.isConnected(proc.pid, to: Requests.agentSocketPaths()),
              kill(proc.pid, SIGTERM) == 0
        else {
            stopFailed = request.id
            return false
        }
        current?.stopped.insert(request.id)
        return true
    }

    func clearHistory() { history.removeAll() }

    /// Made-up requests for `--snapshot --demo`, so screenshots never show real projects.
    func showDemo() {
        current = Demo.live
        history = Demo.history
    }

    // MARK: - Notifications

    /// Two short lines, readable at a glance: what's needed, then who wants what. A warning, if
    /// any, comes first so it can't be pushed out of view by a long name. The repo, branch,
    /// server and command stay in the menu: Notification Center keeps these on disk.
    nonisolated static func notificationText(_ wait: Wait) -> (title: String, body: String) {
        guard let likely = wait.likely else { return ("YubiKey needs a touch", wait.headline) }
        let ask = "\(likely.who ?? "A program"): \(likely.title)"
        guard let warning = likely.warnings.first else { return ("YubiKey needs a touch", ask) }
        return ("YubiKey needs a touch. Check first", "\(warning)\n\(ask)")
    }

    private func post(_ wait: Wait) {
        let text = Self.notificationText(wait)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        if wait.likely != nil { content.categoryIdentifier = Self.category }
        content.userInfo = ["wait": wait.id.uuidString]
        if sound { content.sound = .default }
        // .timeSensitive would break through Focus, but it needs an Apple-issued entitlement that
        // a locally built app can't have, so this is the strongest level available.
        content.interruptionLevel = .active
        let id = wait.id
        center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)) { [weak self] error in
            if let error { log.error("couldn't post notification: \(error.localizedDescription, privacy: .public)") }
            else { log.info("posted notification") }
            // If the touch came while this was being added, take it back down.
            Task { @MainActor in if self?.current?.id != id { self?.withdraw(id) } }
        }
    }

    private func withdraw(_ id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "YubiKey needs a touch (test)"
        content.body = "This is a test. Your key isn't waiting."
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: "test", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.stopAction,
              let id = response.notification.request.content.userInfo["wait"] as? String else { return }
        await MainActor.run {
            // Only the wait that is still going, and only the single program it named. A banner
            // clicked after the touch, or after a new wait began, does nothing.
            guard let wait = current, wait.id.uuidString == id, let likely = wait.likely else { return }
            stop(likely)
        }
    }
}

enum Demo {
    private static func request(_ who: String?, _ action: String, _ command: String, _ place: String?,
                                exe: String = "/usr/bin/ssh", known: Bool = true, ago: TimeInterval = 1) -> Request {
        Request(pid: 0, started: Date().addingTimeInterval(-ago), exe: exe, knownLocation: known, who: who,
                action: action, command: command, place: place,
                host: action.hasSuffix(" on github.com") ? "github.com" : nil)
    }

    static var live: Wait {
        Wait(began: Date().addingTimeInterval(-3), requests: [
            request("Claude Code", "push to acme/web on github.com", "git push origin feat/login",
                    "~/code/acme-web (feat/login)"),
        ], looked: true)
    }

    static var history: [Wait] {
        func past(_ minutes: Double, _ waited: Double, _ requests: [Request]) -> Wait {
            let began = Date().addingTimeInterval(-minutes * 60)
            return Wait(began: began, ended: began.addingTimeInterval(waited), requests: requests, looked: true)
        }
        return [
            past(4, 2, [request("Ghostty", "sign a commit", "git commit -m Add login form",
                                "~/code/acme-web (feat/login)", exe: "/opt/homebrew/Cellar/gnupg/2.4.8/bin/gpg")]),
            past(19, 6, [request("Cursor", "pull from origin", "git pull origin main", "~/code/acme-api (main)")]),
            past(52, 1, [request("Codex", "fetch from acme/docs on github.com", "git fetch --all", "~/code/acme-docs (main)")]),
        ]
    }
}

