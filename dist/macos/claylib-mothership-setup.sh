#!/bin/bash
# One-time Mothership setup for .github/workflows/claylib-release.yml, run there by hand: the
# Sparkle key, the Developer ID and notarytool credentials, and the self-hosted runner as a
# LaunchAgent. Rerunnable: each step skips once done.
# Usage: dist/macos/claylib-mothership-setup.sh DeveloperID.p12  (exported from Automatron's Keychain Access)
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

# Its own keychain, unlocked by the workflow with a password from a file: the login keychain is
# locked over ssh and to the runner.
kc=~/Library/Keychains/claylib-signing.keychain-db
pw=~/.config/claylib/signing-keychain.pass
if [ ! -f "$kc" ]; then
    (umask 077 && /opt/homebrew/bin/openssl rand -hex 24 > "$pw")
    security create-keychain -p "$(cat "$pw")" "$kc"
    security set-keychain-settings "$kc" # no auto-lock
fi
security unlock-keychain -p "$(cat "$pw")" "$kc"

if ! security find-identity -v -p codesigning "$kc" | grep -q "$identity"; then
    security import "${1:?pass the Developer ID .p12 exported from Automatron}" -k "$kc" -T /usr/bin/codesign
    # Lets codesign use the key without a prompt, which a headless runner can't answer.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$pw")" "$kc" >/dev/null
fi

if ! xcrun notarytool history --keychain-profile claylib-notary --keychain "$kc" >/dev/null 2>&1; then
    # Prompts for the Apple ID and an app-specific password (appleid.apple.com).
    xcrun notarytool store-credentials claylib-notary --team-id GMLPGJ9UVD --keychain "$kc"
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
