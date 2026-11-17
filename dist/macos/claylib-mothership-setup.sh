#!/bin/bash
# One-time Mothership setup for .github/workflows/claylib-release.yml, run there by hand: the
# Sparkle key, the Developer ID and notarytool credentials, and the self-hosted runner as a
# LaunchAgent. Rerunnable: each step skips once done. Needs `op` signed in (1Password app unlocked).
set -euo pipefail
repo=claytonjroberts/ghostty
identity="Developer ID Application: Clayton Roberts (GMLPGJ9UVD)"
cert=op://Shnipper/rcsi27tzk3wlcgzctf3jxv674u # "Apple Developer Cert", shared with Shnipper's CI

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
    # On the search list so trust evaluation finds the Developer ID intermediate, or find-identity -v hides it.
    security list-keychains -d user -s "$kc" $(security list-keychains -d user | xargs)
fi
security unlock-keychain -p "$(cat "$pw")" "$kc"

# The .p12 holds only the leaf: without its issuer find-identity -v hides the identity.
if ! security find-certificate -c "Developer ID Certification Authority" >/dev/null 2>&1; then
    ca=$(mktemp)
    curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$ca"
    security import "$ca" -k "$kc" && rm "$ca"
fi

if ! security find-certificate -c "$identity" "$kc" >/dev/null 2>&1; then
    p12=$(mktemp) && trap 'rm -f "$p12"' EXIT
    op read "$cert/MACOS_CERTIFICATE" | base64 -d > "$p12"
    security import "$p12" -f pkcs12 -k "$kc" -P "$(op read "$cert/MACOS_CERTIFICATE_PWD")" -T /usr/bin/codesign
    # Lets codesign use the key without a prompt, which a headless runner can't answer.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$pw")" "$kc" >/dev/null
fi

if ! xcrun notarytool history --keychain-profile claylib-notary --keychain "$kc" >/dev/null 2>&1; then
    xcrun notarytool store-credentials claylib-notary --keychain "$kc" --team-id GMLPGJ9UVD \
        --apple-id "$(op read "$cert/MACOS_NOTARY_APPLE_ID")" --password "$(op read "$cert/MACOS_NOTARY_PASSWORD")"
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
