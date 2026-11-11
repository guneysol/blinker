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

```bash
curl -fsSL https://raw.githubusercontent.com/guneysol/blinker/aa9178ed54b1e8cf1c3524d6d2d53e50f65e0ff0/install.sh | bash
```

It builds the latest release from source (about a minute the first time), installs
**Blinker.app** to your Applications folder and opens it. A key icon appears in your menu bar.
Allow notifications when macOS asks, then turn on **Launch at Login** from the `⋯` menu. macOS
doesn't show an "unidentified developer" warning, because the app is built on your Mac.

**Check it works:** run `ssh -T git@github.com` (or anything that uses your key). When the key
blinks, Blinker should notify you within a second. If nothing happens, your key may not require
a touch: check `ykman openpgp info` (or `ykman piv info` for PIV keys), or see the
[FAQ](#faq).

The installer needs no sudo, touches nothing else, and prints the exact commit it builds, which
is listed in the [release notes](https://github.com/guneysol/blinker/releases). The command pins the reviewed installer to an immutable commit. It verifies release signatures against the pinned
maintainer fingerprint `9D81BD4F85757F958E1C2611897F6CFCDBEFF338` before building.
For stronger bootstrap protection, keep a reviewed installer locally or fetch it by a full
commit SHA you have independently verified; Keep the pinned URL when sharing the install command.

<details>
<summary><b>Prefer to look first?</b></summary>

Download the script, read it, then run it:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/guneysol/blinker/aa9178ed54b1e8cf1c3524d6d2d53e50f65e0ff0/install.sh
less install.sh
bash install.sh
```

Or build it yourself and check the release signature. This needs GnuPG (`brew install gnupg`).
First import the maintainer's signing key, then clone, pick the newest release and verify it:

```bash
curl -fsSL https://github.com/guneysol.gpg | gpg --import
git clone https://github.com/guneysol/blinker && cd blinker
tag=$(git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
git tag -v "$tag" && git checkout -q "$tag" && ./build.sh --install
```

Look for `Good signature from "Guney …"`. gpg also prints "This key is not certified with a
trusted signature"; that's expected for a key you just imported.
</details>

> **Blinker tells you *that* your key is waiting. *Who* asked is a best guess, which any program
> on your Mac could fake. Only touch your key for something you just started.**

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

"Your key is waiting" comes from Apple's smart-card driver, and other programs can't fake it.
Who asked and why is read from the programs connected to your key's agent, and any program
running as you can fake those details. See [SECURITY.md](SECURITY.md) for the full picture and
to report a vulnerability.

- It makes **no network connections**. The links in the `⋯` menu open in your browser.
- It runs as you, never asks for sudo, and can only stop your own processes.
- It saves two settings (notifications and sound). History stays in memory until you quit.
- Notifications name the program and repo, never the command, and are removed once you touch the
  key. Raw command arguments are hidden in the menu and history to avoid exposing credentials.
- To tell who asked, it reads the arguments and folders of your own running programs (never
  their environment variables) and the branch from `.git/HEAD`. It never looks inside Desktop,
  Documents, Downloads, iCloud Drive or network drives, so it doesn't trigger privacy prompts.
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

A downloaded app has to be notarized by Apple, or Gatekeeper blocks it. Building from source
avoids that, and the whole app is about 2,200 lines of Swift, easy to read before you run it.
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
