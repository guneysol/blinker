# Contributing

Thanks for helping! Blinker is small on purpose: plain SwiftUI with Swift Package Manager, no
dependencies, and about 2,200 lines.

## Development loop

```bash
git clone https://github.com/guneysol/blinker && cd blinker
./build.sh --open      # build build/Blinker.app and relaunch it
swift test             # parsing, spoofing and redaction tests
```

You need macOS 14 or later and Xcode 16 (or its Command Line Tools). The build must stay free of
warnings: check locally with `swift build -c release -Xswiftc -warnings-as-errors`.

### Debug commands

```bash
B=build/Blinker.app/Contents/MacOS/Blinker
$B --who      # programs connected to your key's agent right now, and how Blinker describes them
$B --watch    # print each touch wait as it happens, with everything Blinker found
$B --snapshot out.png --demo [--dark]           # render the menu with made-up data
$B --snapshot out.png --demo --scene [--dark]   # the README image: desktop, menu and notification
```

To trigger a real wait, run something that needs your key, such as `ssh -T git@github.com`
(with your SSH key's touch policy on: `ykman openpgp info`), and watch `--watch`. The app logs
its own events, without any commands or paths:
`log stream --level info --predicate 'subsystem == "io.github.guneysol.blinker"'`.

Never paste real `--who`, `--watch` or non-demo `--snapshot` output into issues or PRs without checking it first. It
includes commands, project paths and branch names.

## Where things live

| File | What it does |
|---|---|
| `Sources/Blinker/TouchWatcher.swift` | Streams the system log and turns time-extension lines into "waiting" and "done" |
| `Sources/Blinker/Processes.swift` | Reads processes, argv, working directories and sockets from the kernel |
| `Sources/Blinker/Requests.swift` | Finds the agent's clients and describes them. **Add an agent or tool here** |
| `Sources/Blinker/Store.swift` | App state, notifications and Stop |
| `Sources/Blinker/StatusBar.swift` | The menu bar item, its icon and the menu panel (AppKit) |
| `Sources/Blinker/Views.swift` | The menu's contents (SwiftUI) |
| `Sources/Blinker/DemoScene.swift` | Mock desktop for README images (`--scene`) |
| `Sources/Blinker/BlinkerApp.swift` | App entry point and debug commands |
| `Tests/BlinkerTests` | Unit tests |
| `scripts/make-icon.swift` | Draws the app icon: `swift scripts/make-icon.swift` |

## Ground rules

- **Untrusted text stays untrusted.** Anything read from a process (argv, names, paths, branch
  names) goes through `Sanitize` before it's shown. Don't present it as verified, and never put
  the full command in a notification.
- **Identify by path, never by name.** A process can call itself anything. Changes to how
  requesters are recognized need a test in `Tests/BlinkerTests` showing that the spoofed version
  is caught.
- **Stop must never hit the wrong process.** Keep the checks in `Store.stop`.
- **Idle cost is a feature.** No timers or polling while the key isn't waiting.
- **Keep SwiftUI out of the menu bar icon.** It's set from AppKit on purpose: a SwiftUI
  MenuBarExtra label caused runaway update loops twice.
- **Keep it native, dependency-free, and offline.** No network code.
