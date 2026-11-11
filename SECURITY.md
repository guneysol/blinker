# Security

Blinker sits next to your hardware key, so security reports are taken seriously.

## Reporting a problem

Please **don't open a public issue** for a vulnerability. Report it privately through
[GitHub's security advisories](https://github.com/guneysol/blinker/security/advisories/new)
instead. You'll get a reply within a few days, and a fix will be released as soon as possible.
You'll be credited unless you'd rather not be.

## What you can rely on

- **Driver-origin detection.** Blinker filters log lines to Apple’s smart-card driver under
  SIP-protected `/System`. Time extensions are a heuristic for a touch wait; they do not
  authenticate the pending operation, requester, or particular key.
- **No telemetry or network client in the app.** The installer downloads source and a public
  signing key. App menu links open in the browser when clicked.
- **No privileges.** It runs as you, never asks for sudo, requests no accessibility, screen
  recording or disk access, and can only signal your own processes.
- **Stop requests termination of the selected process.** Stop works only while the key is still waiting. It
  checks that the process has the same pid and start time, is yours, and is still connected to
  your key's agent before sending SIGTERM. It never signals the agent itself. A successful signal does not prove cancellation: a client can ignore SIGTERM. The UI shows “Stop requested” until the client disconnects.

## What you can't rely on

**Who asked, and why, is a best guess.** Blinker reads it from the process connected to your
key's agent: its name, arguments, parent processes, folder and git branch. A program running as
your user controls all of those, and can make a request look like something you'd approve.
Blinker makes this harder, but can't make it impossible:

- It identifies tools by executable path, not by the name a process gives itself, and lists every
  program connected to your key's agent, whatever it calls itself.
- It flags executables in unusual locations, names that don't match the file, and any program in
  the chain that started the request from a temporary or download folder.
- It labels the command-line SSH destination as "Requested host" in the menu. This is ordinary
  information, not a verification of the actual server: SSH configuration may override it.
  It parses options before and after the destination and warns when it detects custom routing,
  agent forwarding, or a non-ASCII host name.
- If a new program asks during a wait (your next touch may go to it), the notification is replaced
  and plays its sound again.
- It uses git's label ("sign a commit") only for the exact signing command git runs, so a hook
  inside `git commit` can't borrow it, and won't let an SSH command chained after
  `git-upload-pack` pass for a fetch. It flags SSH options that change the real destination or
  forward your key.
- It names a single program only when exactly one is connected; with several,
  it lists them all as candidates. Warnings come first in the notification, so a long name can't push them out of view.
- It strips invisible and bidirectional characters, so text can't be made to read differently.

If something already runs as you, it can do far worse than fool Blinker. Still, **don't touch
your key for an action you didn't start**, whatever the notification says.

## Out of scope

- Malware running as your user or as root. Blinker isn't a security boundary.
- FIDO2 requests, which Blinker doesn't detect yet.

## Releases

- Release tags are signed with the maintainer's hardware key; check one with `git tag -v <tag>`
  (the installer checks the signature against a pinned signing fingerprint before building).
  The installer itself is a bootstrap trust dependency: review and pin its full commit SHA
  through a trusted channel. A compromised mutable installer can bypass its own checks.
- The installer builds the newest `vX.Y.Z` tag from source and never downloads a prebuilt binary.
- Only the latest release is supported. To update, run the install command again.

## Filesystem and release checks

Git metadata access checks the path before filesystem operations, opens each component relative
to a directory descriptor, rejects symlinks, and checks the opened filesystem is local. Unsafe
or unavailable paths simply have no branch label. OS permissions still apply; a privileged
attacker changing mounts or the filesystem is outside this threat model.

The installer rejects unsigned/lightweight tags, mismatched signed tag names, non-commit tag
targets and signatures from any other key. It refuses versions below its security baseline or
an installed Blinker version. `BLINKER_ALLOW_DOWNGRADE=1` deliberately permits a rollback;
signature and tag-name checks still apply. A pinned installer does not prove that instructions
copied from a look-alike repository are authentic, nor independently prove release freshness.

Validation runs locally with `bash scripts/check-release.sh`; no paid CI is configured.
