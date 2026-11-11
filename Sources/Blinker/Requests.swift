import Darwin
import Foundation

/// A program connected to your key's agent while the key waits: the best guess at who asked.
///
/// Everything here except `exe` comes from things the program itself controls (its name,
/// argv, working directory), so it is a hint, never proof. `knownLocation` says whether the
/// executable lives where real tools are installed, and is the one signal argv can't fake.
struct Request: Identifiable, Equatable {
    var id = UUID()
    let pid: pid_t
    let started: Date
    /// Full path of the executable, from the kernel.
    let exe: String
    let knownLocation: Bool
    /// "Claude Code", "Ghostty", or nil when nothing recognizable started it.
    let who: String?
    /// "push to guneysol/portside on github.com", "sign a commit", "connect to example.com".
    let action: String
    /// The command that asked, redacted and cleaned for display: "git push origin feat".
    let command: String
    /// "~/code/orb (feat-x)"
    let place: String?
    /// The requested command-line SSH destination (configuration may override it), as shown: "github.com".
    var host: String? = nil
    /// A program that started the asker from a temporary or download folder, if any.
    var launcher: String? = nil

    var headline: String { "\(who ?? "A program") wants to \(action)" }

    /// "Fetch from guneysol/portside on github.com". The server always stays in: a repo name is
    /// easy to fake, and where the connection goes is what matters.
    var title: String { action.prefix(1).uppercased() + action.dropFirst() }

    /// The title without the server, for history rows, unless the server carries a warning.
    var compactTitle: String {
        guard let host, !host.hasSuffix(")"), title.hasSuffix(" on \(host)") else { return title }
        return String(title.dropLast(host.count + 4))
    }

    static func == (a: Request, b: Request) -> Bool { a.id == b.id }
}

/// Finds the programs that could be waiting on the key right now.
///
/// The key only ever waits on behalf of a client of an agent that holds it (`gpg-agent`,
/// `ssh-agent`, `yubikey-agent`). While it waits, that client is blocked on the agent's socket,
/// so it is alive and connected: we list the agents' socket paths and every process connected
/// to one. No client is ever skipped because of its name, since a name is free to choose.
enum Requests {
    static let agents: Set<String> = ["gpg-agent", "ssh-agent", "yubikey-agent", "piv-agent"]

    /// Newest first. Reads only process metadata, plus two small files per git checkout.
    static func current() -> [Request] {
        let procs = Processes.table()
        // Agents are found by name only to learn their socket paths. A client is anything
        // connected to one of those paths, whatever it calls itself: an agent only listens on
        // its own socket, so a program named "gpg-agent" that connects to one is still listed.
        let paths = socketPaths(of: Set(procs.values.filter { agents.contains($0.name) }.map(\.pid)))
        guard !paths.isEmpty else { return [] }
        let me = getpid()
        return procs.values
            .filter { $0.pid != me && isConnected($0.pid, to: paths) }
            .sorted { $0.started > $1.started }
            .map { describe($0, procs: procs) }
    }

    static func agentSocketPaths() -> Set<String> {
        socketPaths(of: Set(Processes.table().values.filter { agents.contains($0.name) }.map(\.pid)))
    }

    private static func socketPaths(of pids: Set<pid_t>) -> Set<String> {
        var paths: Set<String> = []
        for pid in pids {
            for s in Processes.unixSockets(pid) where !s.bound.isEmpty { paths.insert(s.bound) }
        }
        return paths
    }

    static func isConnected(_ pid: pid_t, to paths: Set<String>) -> Bool {
        Processes.unixSockets(pid).contains { paths.contains($0.peer) }
    }

    // MARK: - Describing a request

    static func describe(_ client: Proc, procs: [pid_t: Proc]) -> Request {
        let chain = ancestry(of: client, procs: procs)
        let requester = chain[0]
        let tool = Tool(requester)

        // git's label is used only when the requester is the helper git itself runs for that
        // command, started by git directly. A hook or script running inside `git commit`
        // keeps its own description, so it can't borrow "sign a commit".
        var git: (proc: Proc, sub: [String])?
        if let parent = gitParent(of: chain), let sub = Git.subcommand(parent.argv), tool.isHelper(for: sub[0]) {
            git = (parent, sub)
        }
        let shown = git?.proc ?? requester
        // A real agent or terminal never runs from a temporary or download folder. Anything in
        // the chain that does (a fake "claude" in /tmp starting a real ssh) gets flagged.
        let launcher = chain.dropFirst().first { Tool.isTemporaryLocation($0.exe) }

        return Request(
            pid: requester.pid,
            started: requester.started,
            exe: Sanitize.clean(requester.exe, limit: 200, keepEnd: true),
            knownLocation: Tool.isKnownLocation(requester.exe) && tool.nameMatchesExecutable,
            who: origin(chain),
            // Over SSH, ssh's own remote command says exactly what happens on the server
            // ("git-receive-pack 'org/repo'"), so it beats git's subcommand.
            action: (tool.kind == .ssh ? tool.action : nil)
                ?? git.map { Git.action($0.sub) }
                ?? tool.action
                ?? "use your key (\(Sanitize.clean(requester.exe.basename, limit: 40)))",
            command: Sanitize.clean(Sanitize.redact(shown.argv).joined(separator: " "), limit: 120),
            place: Place.describe(cwd: shown.cwd.isEmpty ? requester.cwd : shown.cwd),
            host: tool.kind == .ssh ? SSH.parse(requester.argv)?.displayHost : nil,
            launcher: launcher.map { Sanitize.clean($0.exe, limit: 120, keepEnd: true) }
        )
    }

    /// The process and its parents, up to launchd, with argv, executable and cwd filled in.
    static func ancestry(of proc: Proc, procs: [pid_t: Proc]) -> [Proc] {
        var chain: [Proc] = [Processes.detailed(proc)]
        var seen: Set<pid_t> = [proc.pid]
        var next = proc.ppid
        while next > 1, chain.count < 32, !seen.contains(next), let parent = procs[next] {
            seen.insert(next)
            chain.append(Processes.detailed(parent))
            next = parent.ppid
        }
        return chain
    }

    /// git that started the requester directly, or through the `sh -c` it uses for
    /// `core.sshCommand` and `gpg.program`.
    private static func gitParent(of chain: [Proc]) -> Proc? {
        guard chain.count > 1 else { return nil }
        var candidate: Proc?
        if Tool(chain[1]).kind == .git { candidate = chain[1] }
        else if chain.count > 2, Tool(chain[1]).kind == .shell, chain[1].argv.dropFirst().first == "-c",
                Tool(chain[2]).kind == .git { candidate = chain[2] }
        // A binary named "git" in /tmp can't lend its label.
        guard let git = candidate, Tool.isKnownLocation(git.exe), Tool(git).nameMatchesExecutable else { return nil }
        return git
    }

    // MARK: - Who started it

    static let agentNames: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "opencode": "opencode",
        "aider": "Aider", "amp": "Amp", "cursor-agent": "Cursor Agent", "droid": "Droid", "goose": "Goose",
    ]
    /// Agents written in a scripting language run as `node /path/to/claude …`.
    private static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// The nearest AI agent above the request, else the app it runs in (Ghostty, Cursor…).
    static func origin(_ chain: [Proc]) -> String? {
        for p in chain {
            let exe = p.exe.basename.lowercased()
            if let name = agentNames[exe] { return name }
            if runtimes.contains(exe), p.argv.count > 1, let name = agentNames[p.argv[1].basename.lowercased()] {
                return name
            }
        }
        for p in chain {
            if let app = appName(p.exe) { return Sanitize.clean(app, limit: 40) }
        }
        return nil
    }

    /// "/Applications/Ghostty.app/Contents/MacOS/ghostty" → "Ghostty". Only apps installed in the
    /// system Applications folders count, so a bundle named "Ghostty.app" elsewhere doesn't.
    static func appName(_ exe: String) -> String? {
        // Not ~/Applications: anything running as you can write there.
        let folders = ["/Applications/", "/System/Applications/"]
        guard let folder = folders.first(where: exe.hasPrefix) else { return nil }
        guard let first = exe.dropFirst(folder.count).split(separator: "/").first, first.hasSuffix(".app") else { return nil }
        return String(first.dropLast(4))
    }
}

// MARK: - Recognizing tools

/// What kind of program a process is, judged by its executable path, not its chosen name.
struct Tool {
    enum Kind { case ssh, sshKeygen, gpg, git, shell, other }

    let proc: Proc
    let kind: Kind

    init(_ proc: Proc) {
        self.proc = proc
        switch proc.exe.basename {
        case "ssh": kind = .ssh
        case "ssh-keygen": kind = .sshKeygen
        case "gpg", "gpg2": kind = .gpg
        case "git": kind = .git
        case "sh", "bash", "zsh", "dash": kind = .shell
        default: kind = .other
        }
    }

    /// The kernel's short name and argv[0] agree with the executable: no disguise attempted.
    var nameMatchesExecutable: Bool {
        let exe = proc.exe.basename
        let argv0 = proc.argv.first?.basename ?? exe
        return proc.name == String(exe.prefix(Int(MAXCOMLEN))) && (argv0 == exe || argv0 == "-" + exe)
    }

    /// Where Apple and package managers install real tools. Homebrew's prefix is writable by
    /// you, so this means "not somewhere odd like /tmp", not "untampered".
    static func isKnownLocation(_ exe: String) -> Bool {
        let prefixes = [
            "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/System/",
            "/Library/Developer/CommandLineTools/", "/Applications/Xcode.app/",
            "/opt/homebrew/Cellar/", "/opt/homebrew/opt/", "/opt/homebrew/bin/",
            "/usr/local/Cellar/", "/usr/local/opt/", "/usr/local/bin/", "/usr/local/MacGPG2/",
            "/nix/store/", "/run/current-system/sw/", "/opt/local/bin/",
        ]
        return prefixes.contains(where: exe.hasPrefix)
    }

    /// Whether this is the program git runs for `sub`: ssh for remotes, gpg or ssh-keygen for signing.
    /// Temporary and download folders: where something dropped by a script or a browser lives.
    static func isTemporaryLocation(_ exe: String) -> Bool {
        let home = NSHomeDirectory()
        let prefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/",
                        "/private/var/folders/", home + "/Downloads/", home + "/.Trash/"]
        let path = exe.lowercased()
        return prefixes.contains { path.hasPrefix($0.lowercased()) }
    }

    /// Whether this is exactly the helper git runs for `sub`: ssh for remotes, and for signing
    /// `gpg --status-fd=2 -bsau <key>` or `ssh-keygen -Y sign -n git`. A hook that runs, say,
    /// `gpg -d secrets.gpg` inside `git commit` doesn't match, so it can't pass as "sign a commit".
    func isHelper(for sub: String) -> Bool {
        let args = proc.argv.dropFirst()
        switch sub {
        case "push", "fetch", "pull", "clone", "ls-remote", "remote", "submodule": return kind == .ssh
        case "commit", "merge", "cherry-pick", "revert", "rebase", "am", "tag":
            if kind == .gpg { return args.contains("--status-fd=2") && args.contains("-bsau") }
            if kind == .sshKeygen { return Array(args.prefix(4)) == ["-Y", "sign", "-n", "git"] }
            return false
        default: return false
        }
    }

    /// What the program says it's doing, from its own argv.
    var action: String? {
        switch kind {
        case .ssh: return SSH.parse(proc.argv)?.action
        case .sshKeygen: return proc.argv.contains("-Y") ? "sign with your SSH key" : nil
        case .gpg: return GPG.action(proc.argv)
        default: return nil
        }
    }
}

extension String {
    var basename: String { (self as NSString).lastPathComponent }
}

// MARK: - Reading commands

enum Git {
    /// Global options that take their value as the next argument.
    private static let valued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"]

    /// `git -C x -c a=b push origin main` → ["push", "origin", "main"]
    static func subcommand(_ argv: [String]) -> [String]? {
        var i = 1
        while i < argv.count, argv[i].hasPrefix("-") {
            i += valued.contains(argv[i]) ? 2 : 1
        }
        guard i < argv.count else { return nil }
        return Array(argv[i...])
    }

    static func action(_ sub: [String]) -> String {
        let operands = sub.dropFirst().filter { !$0.hasPrefix("-") }
        let remote = operands.first.map { Sanitize.clean(Sanitize.redact([$0])[0], limit: 60) }
        switch sub[0] {
        case "push": return "push" + (remote.map { " to \($0)" } ?? "")
        case "fetch": return "fetch" + (remote.map { " from \($0)" } ?? "")
        case "pull": return "pull" + (remote.map { " from \($0)" } ?? "")
        case "clone": return "clone" + (remote.map { " \($0)" } ?? " a repository")
        case "ls-remote", "remote", "submodule": return "talk to a git remote"
        case "commit", "merge", "cherry-pick", "revert", "rebase", "am": return "sign a commit"
        case "tag": return "sign a tag"
        default: return "run git \(Sanitize.clean(sub[0], limit: 30))"
        }
    }
}

enum SSH {
    /// ssh options that take a value, from ssh(1).
    private static let valued = Set("BbcDEeFIiJLlmOoPpQRSWw")
    /// `-o` options that make the real destination differ from the one on the command line.
    private static let rerouting: Set<String> = [
        "hostname", "proxycommand", "proxyjump", "localcommand", "remotecommand", "include",
        "canonicaldomains", "canonicalizehostname", "hostkeyalias", "knownhostscommand",
    ]

    /// Splits an `-o` value the way ssh's own config reader does: leading spaces and tabs are
    /// skipped, the keyword ends at the first space, tab or "=", and keywords ignore case. So
    /// "\tHostName evil" and "ForwardAgent\tyes" are recognized like their plain spellings.
    static func option(_ raw: String) -> (key: String, value: String) {
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let trimmed = raw.drop(while: blank)
        let key = trimmed.prefix { !blank($0) && $0 != "=" }
        var rest = trimmed.dropFirst(key.count).drop(while: blank)
        if rest.first == "=" { rest = rest.dropFirst().drop(while: blank) }
        return (key.lowercased(), String(rest).lowercased())
    }

    struct Call {
        let host: String
        let remoteCommand: [String]
        /// -J, -F, or -o HostName/ProxyCommand/…: the host shown may not be where it connects.
        let rerouted: Bool
        /// -A or -o ForwardAgent: the server could use your key while you're connected.
        var forwardsAgent = false
    }

    static func parse(_ argv: [String]) -> Call? {
        var i = 1, rerouted = false, forwards = false
        var destination: String?
        while i < argv.count {
            let a = argv[i]
            if a == "--" { i += 1; break }
            guard a.hasPrefix("-"), a.count > 1 else {
                if destination == nil { destination = a; i += 1; continue }
                break
            }
            // "-p22" carries its value; "-p" takes the next argument; "-vT" are flags.
            let flags = a.dropFirst()
            let valuedAt = flags.firstIndex(where: { valued.contains($0) })
            if flags[..<(valuedAt ?? flags.endIndex)].contains("A") { forwards = true }
            if let at = valuedAt {
                let after = flags.index(after: at)
                let attached = after == flags.endIndex ? nil : String(flags[after...])
                let value = attached ?? (i + 1 < argv.count ? argv[i + 1] : "")
                switch flags[at] {
                case "J", "F": rerouted = true
                case "R" where value.contains("/"), "L" where value.contains("/"):
                    forwards = true // a forwarded socket can carry your key
                case "o":
                    let o = option(value)
                    if rerouting.contains(o.key) { rerouted = true }
                    if o.key == "forwardagent", o.value != "no" { forwards = true }
                    if ["remoteforward", "localforward"].contains(o.key), o.value.contains("/") { forwards = true }
                default: break
                }
                i += attached == nil ? 2 : 1
            } else {
                i += 1
            }
        }
        if destination == nil {
            guard i < argv.count else { return nil }
            destination = argv[i]
            i += 1
        }
        guard i <= argv.count, let destination else { return nil }
        let host = destination.split(separator: "@").last.map(String.init) ?? destination
        return Call(host: host, remoteCommand: Array(argv[i...]), rerouted: rerouted, forwardsAgent: forwards)
    }
}

extension SSH.Call {
    /// git over SSH runs exactly `git-receive-pack 'owner/repo.git'` (push) or `git-upload-pack`
    /// (fetch). Anything more is shown as a remote command, so `git-upload-pack x; curl …`
    /// can't pass for a fetch.
    /// The host as shown, with a warning attached when it may not be where ssh really goes.
    var displayHost: String {
        var host = Sanitize.clean(self.host, limit: 60)
        if host.unicodeScalars.contains(where: { !$0.isASCII }) { host += " (non-ASCII name)" }
        if rerouted { host += " (via custom ssh options)" }
        if forwardsAgent { host += " (forwards your key)" }
        return host
    }

    var action: String {
        let host = displayHost
        let joined = remoteCommand.joined(separator: " ")
        let words = joined.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = words.first else { return "connect to \(host)" }
        // Plain ASCII only: a no-break space or look-alike could otherwise smuggle extra words
        // ("acme/web on github.com") into what looks like the repo name.
        let plain = words.count <= 2 && joined.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 }
            && !joined.contains(where: { ";|&$`<>(){}\\".contains($0) })
        let repo = words.dropFirst().first.map { Sanitize.clean(Self.repoName($0), limit: 60) }
        let target = repo.map { "\($0) on \(host)" } ?? host
        switch (plain, verb) {
        case (true, "git-receive-pack"): return "push to \(target)"
        case (true, "git-upload-pack"): return "fetch from \(target)"
        case (true, "git-upload-archive"): return "download from \(target)"
        default: return "run a command on \(host)"
        }
    }

    /// "'/guneysol/portside.git'" → "guneysol/portside"
    static func repoName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if s.hasPrefix("/") { s.removeFirst() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }
}

enum GPG {
    static func action(_ argv: [String]) -> String {
        let args = argv.dropFirst()
        let short = args.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.joined()
        if args.contains(where: { ["--sign", "--detach-sign", "--clearsign", "--clear-sign"].contains($0) }) || short.contains("s") {
            return "sign with your GPG key"
        }
        if args.contains("--decrypt") || short.contains("d") { return "decrypt with your GPG key" }
        return "use your GPG key"
    }
}

// MARK: - Where it runs

enum Place {
    /// "~/code/orb (feat-x)" from a working directory inside a git checkout, or the folder itself.
    static func describe(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        func tilde(_ path: String) -> String {
            path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        guard canRead(cwd), let (root, branch) = gitCheckout(containing: cwd) else {
            return Sanitize.clean(tilde(cwd), limit: 80, keepEnd: true)
        }
        let folder = Sanitize.clean(tilde(root), limit: 80, keepEnd: true)
        return branch.map { "\(folder) (\(Sanitize.clean($0, limit: 50)))" } ?? folder
    }

    /// Folders macOS guards with a privacy prompt. Looking inside would make Blinker ask for
    /// access it doesn't need, so it shows the path without reading anything there.
    private static let protected = [
        "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages",
    ].map { (NSHomeDirectory() + "/" + $0).lowercased() }

    /// Local disks only (a network share can hang, and reading it causes network traffic), and
    /// never a folder macOS guards with a privacy prompt. Decided without touching the path:
    /// the mount table comes from the kernel's cached copy (MNT_NOWAIT), so a dead mount
    /// can't block here.
    static func canRead(_ path: String) -> Bool {
        // The file system is case-insensitive, and /System/Volumes/Data is another name for /.
        var p = path.lowercased()
        if p.hasPrefix("/system/volumes/data/") { p = String(p.dropFirst("/system/volumes/data".count)) }
        if protected.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
        if ["/volumes/", "/net/", "/network/"].contains(where: p.hasPrefix) { return false }
        return isOnLocalMount(path)
    }

    private static func isOnLocalMount(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
        guard count > 0, let mounts else { return false }
        var best: (length: Int, local: Bool) = (-1, false)
        for i in 0..<count {
            var m = mounts[i]
            let point = withUnsafeBytes(of: &m.f_mntonname) { Processes.cString($0) }
            let prefix = point == "/" ? "/" : point + "/"
            guard path == point || path.hasPrefix(prefix), point.count > best.length else { continue }
            best = (point.count, (m.f_flags & UInt32(MNT_LOCAL)) != 0)
        }
        return best.local
    }

    /// The checkout root and current branch. Reads at most two small files, no `git` process.
    static func gitCheckout(containing path: String) -> (String, String?)? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = dir.appendingPathComponent(".git")
            var st = stat()
            if lstat(dotGit.path, &st) == 0 {
                var gitDir = dotGit
                switch st.st_mode & S_IFMT {
                case S_IFDIR: break
                case S_IFREG: // a worktree or submodule: ".git" holds "gitdir: <path>"
                    guard let line = readSmall(dotGit.path), line.hasPrefix("gitdir: ") else { return (dir.path, nil) }
                    let target = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL.resolvingSymlinksInPath()
                    guard canRead(gitDir.path) else { return (dir.path, nil) }
                default: return (dir.path, nil)
                }
                let head = readSmall(gitDir.appendingPathComponent("HEAD").path)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)) : nil }
                return (dir.path, branch)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    /// First 4 KB of a regular file. Checked before opening, so a device node or FIFO is never
    /// opened, and again after, in case it was swapped in between.
    private static func readSmall(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[..<n], as: UTF8.self) : nil
    }
}

// MARK: - Making untrusted text safe to show

enum Sanitize {
    /// Characters that render as nothing but aren't in Unicode's format category.
    private static let invisibles: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x034F, 0x17B4, 0x17B5]

    /// Anything from a command line, a branch name or a path is attacker-shapeable. Before it
    /// reaches the screen: drop control and invisible formatting characters (bidi overrides
    /// could make "evil" read as "live"), cap stacked combining marks, collapse whitespace, and
    /// cap the length in Unicode scalars, so a "character" made of 500 marks counts as 500.
    static func clean(_ s: String, limit: Int, keepEnd: Bool = false) -> String {
        var out: [Unicode.Scalar] = []
        var lastWasSpace = false, marks = 0
        for scalar in s.unicodeScalars {
            let category = scalar.properties.generalCategory
            // Invisible: zero-width spaces and bidi overrides (format), plus blank look-alikes.
            if category == .format || invisibles.contains(scalar.value) { continue }
            if [.control, .lineSeparator, .paragraphSeparator].contains(category) || scalar.properties.isWhitespace {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            if [.nonspacingMark, .enclosingMark].contains(category) {
                marks += 1
                if marks > 2 { continue }
            } else {
                marks = 0
            }
            out.append(scalar)
            lastWasSpace = false
        }
        while out.last == " " { out.removeLast() }
        if out.count > limit {
            out = keepEnd ? ["…"] + out.suffix(limit - 1) : out.prefix(limit - 1) + ["…"]
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        return String(view)
    }

    private static let secretWords = ["pass", "token", "secret", "auth", "key", "cookie", "bearer", "credential", "session", "header"]
    /// Flags whose next argument is often a credential.
    private static let secretFlags: Set<String> = ["-H", "--header", "-u", "--user", "-p", "-P", "--password"]
    private static let tokenPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "sk-", "xox", "AKIA", "eyJ", "ya29."]

    /// Best-effort removal of secrets from argv: values after secret-looking flags, `k=v` pairs
    /// with a secret-looking key, URL credentials and query strings, and token-shaped strings.
    /// It can't catch everything, which is why notifications never include the command.
    static func redact(_ argv: [String]) -> [String] {
        var out: [String] = []
        var hideNext = false
        for arg in argv.prefix(24) {
            if hideNext { out.append("•••"); hideNext = false; continue }
            let isFlag = arg.hasPrefix("-")
            let name = arg.firstIndex(of: "=").map { String(arg[..<$0]) } ?? arg
            // First, anything that carries its value inside this same argument.
            // Values attached to short flags: mysql -pS3cret, curl -HAuthorization:…, -uuser:pass
            if isFlag, !arg.hasPrefix("--"), arg.count > 2, let flag = ["-p", "-P", "-H", "-u"].first(where: arg.hasPrefix) {
                out.append(flag + "•••"); continue
            }
            // An Authorization header anywhere, e.g. -c "http.extraHeader=Authorization: Basic …"
            if arg.lowercased().contains("authorization") { out.append("•••"); continue }
            if isFlag, secretFlags.contains(name) || secretWords.contains(where: name.lowercased().contains) {
                if name != arg { out.append(name + "=•••") } else { out.append(arg); hideNext = true }
                continue
            }
            if name != arg, secretWords.contains(where: name.lowercased().contains) { out.append(name + "=•••"); continue }
            out.append(redactTokens(redactURL(arg)))
        }
        if argv.count > 24 { out.append("…") }
        return out
    }

    /// "https://user:token@host/x?sig=abc" → "https://host/x?•••"
    static func redactURL(_ s: String) -> String {
        guard let scheme = s.range(of: "://") else { return s }
        var rest = String(s[scheme.upperBound...])
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        if let at = rest[..<hostEnd].lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if let q = rest.firstIndex(of: "?") { rest = String(rest[...q]) + "•••" }
        return String(s[..<scheme.upperBound]) + rest
    }

    /// Words that look like API tokens, or long random strings, become "•••".
    static func redactTokens(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            if tokenPrefixes.contains(where: w.hasPrefix), w.count >= 12 { return "•••" }
            if w.count >= 32, w.allSatisfy({ $0.isLetter || $0.isNumber || "-_+/=".contains($0) }),
               w.contains(where: \.isNumber), w.contains(where: \.isLetter) { return "•••" }
            return w
        }.joined(separator: " ")
    }
}

// MARK: - Presentation

extension Request {
    /// Reasons to look twice, shown before anything else in the menu and the notification.
    var warnings: [String] {
        var out: [String] = []
        if !knownLocation { out.append("Unusual program: \(exe)") }
        if let host, host.hasSuffix(")") { out.append("Requested host: \(host)") }
        if let launcher { out.append("Started from a temporary folder: \(launcher)") }
        return out
    }

    /// What kind of operation, for the icon. Read from the start of `action`, which Blinker
    /// writes itself; any attacker-shaped text only ever comes after the verb.
    enum Kind { case push, fetch, sign, decrypt, connect, unknown }

    var kind: Kind {
        switch action.split(separator: " ").first {
        case "push": .push
        case "fetch", "pull", "clone", "download", "talk": .fetch
        case "sign": .sign
        case "decrypt": .decrypt
        case "connect", "run": .connect
        default: .unknown
        }
    }

}
