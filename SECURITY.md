# Security

Blinker sits next to your hardware key, so security reports are taken seriously.

## Reporting a problem

Please **don't open a public issue** for a vulnerability. Report it privately through
[GitHub's security advisories](https://github.com/guneysol/blinker/security/advisories/new)
instead. You'll get a reply within a few days, and a fix will be released as soon as possible.
You'll be credited unless you'd rather not be.

## What you can rely on

- **The "key is waiting" signal.** Blinker only accepts log lines written by Apple's smart-card
  driver (`/System/Library/CryptoTokenKit/usbsmartcardreaderd.slotd/…`). That path is protected
  by System Integrity Protection, so no other program can produce them.
- **No network.** Blinker makes no network connections.
- **No privileges.** It runs as you, never asks for sudo, requests no accessibility, screen
  recording or disk access, and can only signal your own processes.
- **Stop never hits the wrong process.** Stop works only while the key is still waiting. It
  checks that the process has the same pid and start time, is yours, and is still connected to
  your key's agent before sending SIGTERM. It never signals the agent itself.

## What you can't rely on

**Who asked, and why, is a best guess.** Blinker reads it from the process connected to your
key's agent: its name, arguments, parent processes, folder and git branch. A program running as
your user controls all of those, and can make a request look like something you'd approve.
Blinker makes this harder, but can't make it impossible:

- It identifies tools by executable path, not by the name a process gives itself, and lists every
  program connected to your key's agent, whatever it calls itself.
- It flags executables in unusual locations, and names that don't match the file.
- It uses git's label ("sign a commit") only for the exact signing command git runs, so a hook
  inside `git commit` can't borrow it, and won't let an SSH command chained after
  `git-upload-pack` pass for a fetch. It flags SSH options that change the real destination or
  forward your key.
- It names a program only when exactly one connected just before the wait; otherwise it says it
  can't tell. Warnings come first in the notification, so a long name can't push them out of view.
- It strips invisible and bidirectional characters, so text can't be made to read differently.

If something already runs as you, it can do far worse than fool Blinker. Still, **don't touch
your key for an action you didn't start**, whatever the notification says.

## Out of scope

- Malware running as your user or as root. Blinker isn't a security boundary.
- FIDO2 requests, which Blinker doesn't detect yet.

## Releases

- Release tags are signed with the maintainer's hardware key; check one with `git tag -v <tag>`
  (the one-line installer doesn't check signatures; the README's "build it yourself" steps do).
- The installer builds the newest `vX.Y.Z` tag from source and never downloads a prebuilt binary.
- Only the latest release is supported. To update, run the install command again.
