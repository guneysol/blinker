import Foundation

/// Tells when a smart-card key (OpenPGP or PIV on a YubiKey) is waiting for a touch.
///
/// While the key waits, the card asks the reader for more time every ~290 ms, and Apple's
/// CCID driver logs "Time extension received" for each request. The requests stop the moment
/// the key is touched, or when the key gives up. We read only those lines, using a predicate
/// that `logd` applies before anything reaches us, and only from Apple's own driver: its
/// image path is under SIP-protected /System, so no other process can fake it.
/// All mutable state lives on `queue`, which is why it's safe to send across threads.
final class TouchWatcher: @unchecked Sendable {
    enum Event: Sendable { case started, ended, unavailable(String) }

    static let driver = "/System/Library/CryptoTokenKit/usbsmartcardreaderd.slotd/Contents/MacOS/usbsmartcardreaderd"
    static let message = "Time extension received"
    static let predicate = """
        processImagePath == "\(driver)" AND subsystem == "com.apple.CryptoTokenKit" \
        AND category == "ccid" AND eventMessage == "\(message)"
        """

    /// Two extensions in a row before we call it a touch wait: one alone can be a slow but
    /// touch-free operation (an RSA signature on an older key, say).
    private let pulsesToStart = 2
    /// Extensions arrive every ~290 ms, so a second of silence means the wait is over.
    private let quietToEnd: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "blinker.watcher")
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private var process: Process?
    private var buffer = Data()
    private var errors = Data()
    private var pulses: [Date] = []
    private var waiting = false
    private var quietTimer: DispatchWorkItem?
    private var restarts: [Date] = []
    /// True from start() until we give up; covers the backoff gap between restarts too.
    private var active = false

    /// `onEvent` is called on the main actor.
    init(onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// Starts watching, or starts again after giving up (Try Again, or the Mac waking up).
    func start() {
        queue.async {
            guard !self.active else { return }
            self.active = true
            self.restarts.removeAll()
            self.launch()
        }
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        Task { @MainActor in onEvent(event) }
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--level", "debug", "--style", "ndjson", "--predicate", Self.predicate]
        p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"] // nothing inherited
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer.removeAll() // half a line from a previous `log` would corrupt the first new one
        errors.removeAll()

        // Restart only once the process has exited AND both pipes are drained, so a last
        // error message ("Must be admin") is never lost to the race between them.
        let done = DispatchGroup()
        done.enter(); done.enter(); done.enter()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; done.leave(); return }
            self?.queue.async { self?.consume(chunk) }
        }
        // Drained as it arrives: a full stderr pipe would block `log` and silently stop detection.
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; done.leave(); return }
            self?.queue.async {
                guard let self, self.errors.count < 2048 else { return }
                self.errors.append(chunk.prefix(2048 - self.errors.count))
            }
        }
        p.terminationHandler = { _ in done.leave() }
        done.notify(queue: queue) { [weak self] in
            guard let self else { return }
            self.relaunch(after: p.terminationStatus, reason: String(decoding: self.errors, as: UTF8.self))
        }
        do {
            try p.run()
            process = p
            log.info("log stream started, pid \(p.processIdentifier, privacy: .public)")
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            active = false
            emit(.unavailable("Couldn't start /usr/bin/log: \(error.localizedDescription)"))
        }
    }

    /// `log stream` exits when logd restarts. Restart it, but if it keeps dying (no permission
    /// to read the log, say), stop and say why instead of spinning. `start()` tries again.
    private func relaunch(after status: Int32, reason: String) {
        process = nil
        if waiting { finish() }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        // macOS lets only admin accounts stream the log; there's no point retrying that.
        if reason.contains("Must be admin") {
            active = false
            emit(.unavailable("macOS only lets admin accounts read the system log, which Blinker needs. Use an admin account, or ask your admin to add you to the _developer group."))
            return
        }
        if restarts.count > 5 {
            active = false
            let detail = Sanitize.clean(reason, limit: 300)
            emit(.unavailable(detail.isEmpty ? "The system log stream keeps exiting (status \(status))." : detail))
            return
        }
        log.info("log stream exited (status \(status, privacy: .public)), restarting")
        queue.asyncAfter(deadline: .now() + Double(restarts.count)) { self.launch() }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        if buffer.count > 1 << 20 { buffer.removeAll() } // a runaway line can't grow us without bound
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if Self.isTimeExtension(line) { pulse() } else if line.count > 1 { log.debug("ignored a log line") }
        }
    }

    /// The predicate already filtered the stream; this re-checks the two fields that matter so
    /// that a change in `log`'s output can only make us miss events, never invent them.
    static func isTimeExtension(_ line: Data) -> Bool {
        guard line.first == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["eventMessage"] as? String == message && object["processImagePath"] as? String == driver
    }

    private func pulse() {
        let now = Date()
        pulses = pulses.filter { now.timeIntervalSince($0) < quietToEnd } + [now]
        if !waiting, pulses.count >= pulsesToStart {
            waiting = true
            emit(.started)
        }
        quietTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.finish() }
        quietTimer = timer
        queue.asyncAfter(deadline: .now() + quietToEnd, execute: timer)
    }

    private func finish() {
        quietTimer?.cancel()
        quietTimer = nil
        pulses.removeAll()
        guard waiting else { return }
        waiting = false
        emit(.ended)
    }
}
