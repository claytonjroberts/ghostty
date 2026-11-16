#!/bin/bash
# One-time Mothership setup for .github/workflows/claylib-release.yml, run there by hand:
# the Developer ID cert, notarytool credentials and Sparkle key into the login keychain, and
# the self-hosted runner as a LaunchAgent. Each step skips itself once done.
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
# Creates the key on first run, then just prints the public half.
"$sparkle/bin/generate_keys" --account claylib-ghostty

if ! security find-identity -v -p codesigning | grep -q "$identity"; then
    p12=${1:?"pass the Developer ID .p12 exported from the laptop's Keychain Access"}
    # -T: codesign may use the key without a prompt, which a headless runner can't answer.
    security import "$p12" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
fi

if ! xcrun notarytool history --keychain-profile claylib-notary >/dev/null 2>&1; then
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
