#!/bin/bash
# One-time Mothership setup for .github/workflows/claylib-release.yml, run there by hand: the
# Sparkle key, optionally the Developer ID and notarytool credentials (else builds are ad-hoc
# signed), and the self-hosted runner as a LaunchAgent. Rerunnable: each step skips once done.
# Usage: dist/macos/claylib-mothership-setup.sh [DeveloperID.p12]
set -euo pipefail
repo=claytonjroberts/ghostty
identity="Developer ID Application: Clayton Roberts (GMLPGJ9UVD)"

sparkle=~/.local/share/sparkle
if [ ! -x "$sparkle/bin/sign_update" ]; then
    mkdir -p "$sparkle"
    curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip -o "$sparkle/s.zip"
    unzip -qo "$sparkle/s.zip" -d "$sparkle" && rm "$sparkle/s.zip"
fi

# A file, not the keychain (generate_keys): the keychain is locked over ssh and to the runner.
key=~/.config/claylib/sparkle-ed25519.pem
if [ ! -f "$key" ]; then
    mkdir -p "$(dirname "$key")"
    (umask 077 && /opt/homebrew/bin/openssl genpkey -algorithm ed25519 -out "$key")
fi

if ! security find-identity -v -p codesigning | grep -q "$identity"; then
    if [ -n "${1:-}" ]; then
        security unlock-keychain ~/Library/Keychains/login.keychain-db
        # -T: codesign may use the key without a prompt, which a headless runner can't answer.
        security import "$1" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
    else
        echo "No Developer ID: builds will be ad-hoc signed. Rerun with its .p12 to notarize."
    fi
fi

if security find-identity -v -p codesigning | grep -q "$identity" \
    && ! xcrun notarytool history --keychain-profile claylib-notary >/dev/null 2>&1; then
    security unlock-keychain ~/Library/Keychains/login.keychain-db
    # Prompts for the Apple ID and an app-specific password (appleid.apple.com).
    xcrun notarytool store-credentials claylib-notary --team-id GMLPGJ9UVD
fi

runner=~/actions-runner
if [ ! -f "$runner/.runner" ]; then
    mkdir -p "$runner" && cd "$runner"
    version=$(gh api repos/actions/runner/releases/latest -q .tag_name | tr -d v)
    curl -sL "https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-arm64-$version.tar.gz" | tar xz
    token=$(gh api -X POST "repos/$repo/actions/runners/registration-token" -q .token)
    # Run from this shell so the service's PATH has Homebrew's zig and gh.
    ./config.sh --unattended --url "https://github.com/$repo" --token "$token" --name mothership --labels mothership
    ./svc.sh install && ./svc.sh start
fi

# .gitattributes' merge=ours (the fork's update feed) needs its driver in each clone.
git -C ~/repos/ghostty config merge.ours.driver true
echo "Mothership is ready to build claylib releases."
