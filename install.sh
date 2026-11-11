#!/bin/bash
# One-line install: builds the latest Blinker release from source and puts it in Applications.
# See README.md for the reviewed, commit-pinned installer URL.
#
# What this does: checks for Apple's developer tools, clones the latest release tag into a
# temporary folder, builds it, and copies Blinker.app to /Applications (or ~/Applications when
# /Applications isn't writable without sudo). SSH/GPG settings and key policies are unchanged;
# the temporary source and verification keyring are deleted afterwards.
#
# Set BLINKER_REF=vX.Y.Z to select another signed release.
set -euo pipefail

# This code belongs to the reviewed installer, never to the unverified checkout.
verify_release() {
    local checkout="$1" ref="$2" keyring="$3" fingerprint="$4" payload signature
    [[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]] || return 1
    [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$(git -C "$checkout" cat-file -t "refs/tags/$ref")" == tag ]] || {
        echo "Release must be an annotated, signed tag."; return 1;
    }
    payload=$(git -C "$checkout" cat-file tag "refs/tags/$ref") || return 1
    # Check headers only; a message containing a matching tag name must not count.
    [[ "$(printf '%s\n' "$payload" | sed -n '3p')" == "tag $ref" &&
       "$(printf '%s\n' "$payload" | sed -n '2p')" == "type commit" ]] || {
        echo "Signed release name does not match the requested version."; return 1;
    }
    signature=$(GNUPGHOME="$keyring" git -C "$checkout" -c gpg.format=openpgp -c gpg.program=gpg verify-tag --raw "refs/tags/$ref" 2>&1) || {
        echo "Release signature verification failed. Nothing was built or installed."; return 1;
    }
    printf '%s\n' "$signature" | grep -Eq "^\[GNUPG:\] VALIDSIG $fingerprint " || {
        echo "Release was not signed by the pinned maintainer key."; return 1;
    }
}

version_older() {
    [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

check_version() {
    local requested="$1" minimum="$2"
    if version_older "$requested" "$minimum" && [[ "${BLINKER_ALLOW_DOWNGRADE:-0}" != 1 ]]; then
        echo "Refusing $requested: minimum accepted version is $minimum."
        echo "For an intentional rollback only, set BLINKER_ALLOW_DOWNGRADE=1."
        return 1
    fi
}

# Everything lives in main(), which only runs on the last line, so a download that is cut off
# halfway runs nothing at all.
main() {
    local repo=https://github.com/guneysol/blinker

    # Blinker runs as you. Under sudo it would install a root-owned app and could start it as root.
    if [[ $EUID -eq 0 ]]; then
        echo "Please run this without sudo. Blinker installs and runs as your own user."
        exit 1
    fi

    # /usr/bin/swift exists even without the tools (it is an installer stub), so ask xcode-select.
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Blinker builds from source and needs Apple's developer tools."
        echo "Install them with:  xcode-select --install   (then run this again)"
        exit 1
    fi

    command -v gpg >/dev/null 2>&1 || {
        echo "Release verification requires GnuPG. Install it with: brew install gnupg"
        exit 1
    }
    local ref="${BLINKER_REF:-}"
    if [[ -z "$ref" ]]; then
        # Releases only (vX.Y.Z): a pre-release tag like v1.0-rc1 is never picked as "latest".
        ref=$(git ls-remote --tags --refs "$repo" 'v*' | sed 's#.*refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
        [[ -n "$ref" ]] || { echo "Couldn't find a Blinker release on GitHub."; exit 1; }
    fi
    [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Only signed release tags (vX.Y.Z) may be installed. Build development branches manually."
        exit 1
    }
    # Never silently go below this installer's security baseline or an installed version.
    check_version "$ref" v0.1.3 || exit 1
    local installed app
    for app in /Applications/Blinker.app "$HOME/Applications/Blinker.app"; do
        [[ "$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)" == io.github.guneysol.blinker ]] || continue
        installed=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
        [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot verify installed version."; exit 1; }
        check_version "$ref" "v$installed" || exit 1
    done
    echo "Installing Blinker ${ref}..."

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    # Fetch just that tag (or branch) and check it out. `git clone --branch <signed tag>` works
    # too, but prints a scary-looking "is not a commit" warning for signed tags.
    git -C "$dir" init --quiet
    git -C "$dir" fetch --quiet --depth 1 "$repo" "refs/tags/$ref:refs/tags/$ref"
    # A fresh keyring prevents local trust configuration from changing acceptance.
    local keyring="$dir/verify-keyring"
    mkdir -m 700 "$keyring"
    # Public-key verification does not need an agent or access to private keys.
    echo no-autostart > "$keyring/gpg.conf"
    curl -fsSL https://github.com/guneysol.gpg -o "$dir/maintainer.asc"
    GNUPGHOME="$keyring" gpg --batch --quiet --import "$dir/maintainer.asc"
    verify_release "$dir" "$ref" "$keyring" "9D81BD4F85757F958E1C2611897F6CFCDBEFF338" || exit 1
    git -C "$dir" -c advice.detachedHead=false checkout --quiet "$ref"
    # The exact code being built. Each release's notes list its commit, so you can compare.
    echo "Building commit $(git -C "$dir" rev-parse HEAD)"
    "$dir/build.sh" --install
    echo
    echo "Like it? A star helps others find it: https://github.com/guneysol/blinker"
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
