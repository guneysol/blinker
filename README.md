<div align="center">

<img src="Resources/AppIcon.png" width="128" alt="Blinker icon">

# Blinker

**Know why your YubiKey is blinking.**

When your key waits for a touch, Blinker tells you who asked and what for, before the
request times out.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/demo-dark.png">
  <img src="docs/demo-light.png" width="900" alt="Blinker's green key icon in the menu bar, its menu showing that Claude Code is asking to fetch from acme/web on github.com with a Stop button, and the notification it posts">
</picture>

</div>

**Is it for you?** Blinker is for Macs where a YubiKey (OpenPGP or PIV) signs commits or SSH
logins through `gpg-agent`, `ssh-agent` or `yubikey-agent`, and the key is set to require a
touch. FIDO2 keys (`sk-ssh-…` keys, passkeys) aren't supported yet.

**You need** macOS 14 or later, Apple's developer tools (`xcode-select --install`), GnuPG (`brew install gnupg`), and an admin
account, because macOS only lets admins read the system log that Blinker watches.

## Install

Download the installer from **this repository**, inspect it, then run it:

```bash
curl -fsSLo blinker-install.sh https://raw.githubusercontent.com/guneysol/blinker/61b634540b79a10cebe8af7a3ee469913dbd0f4a/install.sh
less blinker-install.sh
bash blinker-install.sh
```

[View the installer](https://github.com/guneysol/blinker/blob/61b634540b79a10cebe8af7a3ee469913dbd0f4a/install.sh) ·
[Releases](https://github.com/guneysol/blinker/releases) · [Security details](SECURITY.md) ·
[Uninstall](#update-and-uninstall)

The URL pins the installer to a reviewed commit in `guneysol/blinker`. It downloads the newest
stable tag from that same repository and verifies its signature, signing fingerprint and signed
version name **before checking out or building any release code**. It rejects releases below
v0.1.3 or your installed version unless you explicitly request a rollback.

It builds Blinker locally, replaces only an existing Blinker installation with the matching app
identifier, installs to `/Applications` (or `~/Applications` if needed), and opens the app.
Temporary build files are removed afterwards. It does not use sudo, change key touch policies,
or edit your SSH/GPG configuration. Internet access is needed to download the source and public
signing key; normal app operation has no telemetry or network client.

Allow notifications if you want alerts. **Launch at Login is opt-in** in the `⋯` menu.
The locally built app has an ad-hoc signature; it is **not Developer ID signed or notarized by Apple**.
Release signatures establish who signed the source, not a guarantee that it has no bugs.

The pinned release-signing fingerprint is:
`9D81BD4F85757F958E1C2611897F6CFCDBEFF338`.
A commit-pinned URL cannot protect against a look-alike repository or altered instructions:
check that the owner and repository are exactly `guneysol/blinker`.

**Check it works:** start an SSH login using your key:

```bash
ssh -T -o ControlPath=none git@github.com
```

When the key blinks, Blinker should notify you. Only touch for the operation you just started.
An existing connection or cached touch can complete without blinking; Blinker cannot report a
wait that never happens. See the [FAQ](#faq) if nothing appears.

> Blinker reports a likely requester. It does not authenticate the requester, verify the SSH
> server, or authorize an operation. Only touch your key for something you started.

## Why

Your key signs commits and authenticates `git fetch` and `git push`, but it has no screen. It
blinks, and the request times out after about 15 seconds if you don't notice. Then whatever
asked fails or hangs. With AI agents running git in the background, you often don't know a
request is waiting, and when you do notice, you don't know what you'd be approving.

The key can't tell your Mac why it's waiting. Blinker notices the wait from macOS itself and
matches it to the program that asked.

## What it does

- You get a notification within about half a second of the key starting to blink, and the menu
  bar key blinks green. Both go away when you touch the key.
- It says who asked and what for, like "Claude Code: Fetch from org/repo on github.com" or
  "Ghostty: Sign a commit", with the folder and branch. It recognizes Claude Code, Codex,
  Gemini CLI, Cursor, Aider, opencode and more, plus the terminal or editor you started it from.
- It warns instead of guessing when something looks off: several programs asking at once (it
  names them all), a program running from `/tmp` or Downloads, or SSH options that send the
  connection elsewhere or forward your key.
- The notification and the menu have a **Stop** button that cancels the waiting request, for a
  stuck `git fetch` or something you didn't start.
- The menu keeps the last 20 requests until you quit. Idle, Blinker uses no CPU.

<details>
<summary><b>How it works</b></summary>

1. **Detecting the wait.** While a smart-card key waits for a touch, it keeps asking the USB
   reader for more time, and Apple's smart-card driver logs each request. Blinker streams only
   those log lines, and only from Apple's own driver in the system-protected `/System` folder,
   so another program can't fake one. Touching the key stops them.
2. **Finding who asked.** Your key only waits on behalf of a program connected to the agent that
   holds it, and that program is blocked until you touch. Blinker lists the programs connected
   to the agent right then, and describes each one from its executable, its arguments, the
   programs that started it, and its folder and git branch.
</details>

## Security and privacy

The wait indication comes from time-extension events emitted by Apple’s smart-card driver.
It is a detection heuristic, not a cryptographic statement about the pending operation.
Who asked and why is read from the programs connected to your key's agent, and any program
running as you can fake those details. See [SECURITY.md](SECURITY.md) for the full picture and
to report a vulnerability.

- The app has **no telemetry or network client**. Menu links open in your browser only when clicked.
- It runs as you, never asks for sudo, and can only stop your own processes.
- It saves two settings (notifications and sound). History stays in memory until you quit.
- Notifications name the program and repo, never the command, and are removed once you touch the
  key. Raw command arguments are hidden in the menu and history to avoid exposing credentials.
- To infer the requester, it reads process arguments, executable paths, folders and agent socket
  metadata for your user. It does not intentionally parse environment variables or read private-key files.
  Git context reads are limited to small `.git` and `HEAD` files; protected folders, non-local
  mounts and symlink paths are skipped. If a path cannot be checked safely, its branch is omitted.
- It's built from source on your Mac and isn't notarized by Apple.

## FAQ

<details>
<summary><b>I installed it, but nothing happens when I use my key.</b></summary>

Most likely your key doesn't require a touch for that operation, so it never waits. Check with
`ykman openpgp info` (or `ykman piv info`) and look for "Touch policy". Blinker also can't see
FIDO2 keys yet. If the menu says "Not watching your key", your account isn't an admin (see
below).
</details>

<details>
<summary><b>Can't I just make my key ask less?</b></summary>

For stronger protection, keep touch required for every operation (`on`). With the optional
`cached` touch policy, one touch covers 15 seconds
of requests, including requests from other programs with access to your agent. Those requests
may not wait for a touch, so Blinker cannot alert you to them. This trades security for
convenience. If you deliberately accept that tradeoff, for SSH:

```bash
ykman openpgp keys set-touch aut cached
```

Use `sig` instead of `aut` for signing. Check your current policies with `ykman openpgp info`.
</details>

<details>
<summary><b>It listed two programs, "one of these is asking".</b></summary>

Two programs asked your key's agent at the same moment, for example two fetches. Your touch goes
to whichever one the agent serves first, which can't be seen from outside, so Blinker names both
instead of guessing. Click the notification to open the menu, where each has a Stop button. Every connected client remains a candidate, regardless of its age.
</details>

<details>
<summary><b>Why does it need an admin account?</b></summary>

The wait is only visible in the system log, and macOS only lets admin accounts (or members of the
`_developer` group) stream it. Blinker doesn't need sudo: it runs `/usr/bin/log stream` as you.
Without admin rights it shows "Not watching your key" and says why.
</details>

<details>
<summary><b>Why is there no downloadable app or Homebrew cask?</b></summary>

We currently distribute source, not a Developer ID–signed and notarized download.
The source-build path remains inspectable, but needs developer tools and GnuPG.
Do not disable Gatekeeper or remove quarantine attributes to install Blinker.
</details>

Stop sends a termination request. “Stop requested” means cancellation is pending; a process may ignore it. The client disappears when it disconnects, but the hardware may keep blinking until its operation times out. Blinker keeps a “Cancellation requested — don’t touch” warning until that wait ends. Do not touch the key based on a pending cancellation.

## Update and uninstall

To update, run the install command again.

To uninstall, open the `⋯` menu, turn off **Launch at Login** and choose **Quit Blinker**, then:

```bash
rm -rf /Applications/Blinker.app ~/Applications/Blinker.app
defaults delete io.github.guneysol.blinker 2>/dev/null
```

macOS keeps Blinker's entry in System Settings › Notifications for a while; you can remove it
there, or it goes away on its own.

## Contributing

Feedback and ideas are welcome: DM [@guneysol](https://x.com/guneysol) on X, or use **Send
Feedback on X** in the app's `⋯` menu. Bug reports, agent names and PRs are welcome too.
[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the development loop and the debug commands.

## License

[MIT](LICENSE)

---

<div align="center">

Made by [@guneysol](https://x.com/guneysol). Follow for updates.

</div>
