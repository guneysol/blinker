import AppKit
import Foundation
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        switch args.first {
        case "--who": CLI.who()
        case "--watch": CLI.watch()
        case "--version": print(CLI.version)
        case "--snapshot": MainActor.assumeIsolated { Snapshot.run(Array(args)) }
        case "--help", "-h": CLI.help()
        case nil: MainActor.assumeIsolated { AppDelegate.run() }
        default: CLI.help(); exit(2)
        }
    }
}

/// The menu bar app. Plain AppKit at the top: the status item is ours (see StatusBar), and
/// SwiftUI draws only the menu's contents.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var statusBar: StatusBar?

    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `build.sh` and `kill` send TERM: quit normally, so the log helper is stopped too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminateSignal = source
        TouchWatcher.endLeftovers()
        statusBar = StatusBar(store: store)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}

/// `Blinker --snapshot out.png [--dark] [--demo] [--scene]` renders the menu to a PNG, then quits.
/// `--scene` places it on a mock desktop with the notification, for the README.
/// `--demo` uses made-up requests, so screenshots never leak real projects.
@MainActor
enum Snapshot {
    static func run(_ args: [String]) {
        guard args.count > 1 else { CLI.help(); exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await write(to: args[1], dark: args.contains("--dark"), demo: args.contains("--demo"),
                        several: args.contains("--several"), scene: args.contains("--scene"))
            exit(0)
        }
        app.run()
    }

    private static func write(to path: String, dark: Bool, demo: Bool, several: Bool, scene: Bool) async {
        let store = Store()
        if demo { store.showDemo(several: several) }
        let root = scene
            ? AnyView(DemoScene(dark: dark, tweet: CommandLine.arguments.contains("--tweet")).environmentObject(store))
            : AnyView(MenuView().environmentObject(store).background(.windowBackground))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        try? await Task.sleep(for: .milliseconds(400))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Debug commands. They print to stdout and never send anything anywhere.
enum CLI {
    static let version = "0.1.0"

    static func help() {
        print("""
        Blinker \(version): shows who wants your YubiKey touched, and why.

        Usage: Blinker [--who | --watch | --snapshot out.png [--demo] [--dark] [--scene] | --version]
          (no flags)  run the menu bar app
          --who       list programs connected to your key's agent right now
          --watch     print touch waits as they happen, with who asked (Ctrl-C to quit)
          --snapshot  render the menu to a PNG. It shows an empty menu (this is a new process,
                      not the running app) unless you add --demo for made-up data. --dark for
                      dark mode, --scene for the README image (desktop, menu and notification),
                      --several for two programs asking at once, --tweet for a 16:9 scene
        """)
    }

    static func who() {
        let wait = Wait(began: Date(), requests: Requests.current(), looked: true)
        if wait.requests.isEmpty { print("Nothing is connected to gpg-agent, ssh-agent or yubikey-agent right now.") }
        for r in wait.requests { print(format(r, idle: wait.idle.contains(r))) }
    }

    static func watch() {
        setvbuf(stdout, nil, _IOLBF, 0) // one line at a time, even into a pipe or file
        print("Watching for touch requests. Ctrl-C to quit.")
        let watcher = TouchWatcher { event in
            switch event {
            case .started:
                let wait = Wait(began: Date(), requests: Requests.current(), looked: true)
                print("\(time.string(from: Date())) KEY WAITING FOR TOUCH")
                if wait.likely == nil { print("  \(wait.headline)") }
                for r in wait.requests { print(format(r, idle: wait.idle.contains(r))) }
            case .ended: print("\(time.string(from: Date())) done")
            case .unavailable(let why): print("\(time.string(from: Date())) can't watch: \(why)"); exit(1)
            }
        }
        watcher.start()
        dispatchMain()
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func format(_ r: Request, idle: Bool) -> String {
        var lines = ["  \(idle ? "(idle connection) " : "")\(r.headline)",
                     "    pid \(r.pid), connected since \(time.string(from: r.started))",
                     "    exe \(r.exe)", "    \(r.command)"]
        if let place = r.place { lines.append("    in \(place)") }
        for warning in r.warnings { lines.append("    WARNING: \(warning)") }
        return lines.joined(separator: "\n")
    }
}
