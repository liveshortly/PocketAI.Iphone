#!/usr/bin/env bash
# App Store sign -> IPA -> TestFlight upload, for an UNSIGNED PocketAI.app
# archived elsewhere (the MBP archives with CODE_SIGNING_ALLOWED=NO; signing
# material never leaves this machine).
#
#   scripts/sign-upload-local.sh /path/to/PocketAI.app /path/to/libswiftCompatibilitySpan.dylib [out-dir]
#
# The Span dylib comes from the building Xcode's toolchain
# (XcodeDefault.xctoolchain/usr/lib/swift-6.2/iphoneos/) and goes in
# SwiftSupport/, which App Store validation requires.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: $0 PocketAI.app libswiftCompatibilitySpan.dylib [out-dir]}"
SPAN="${2:?missing libswiftCompatibilitySpan.dylib}"
OUT="${3:-build/upload}"
ID="${SIGN_ID:-Apple Distribution: Rohit Sehgal (4RK6YA795V)}"
PROFILE_UUID="${PROFILE_UUID:-19927ee6-5ee0-4555-83bf-8594b89d6c6e}"
KEY_ID="${ASC_KEY_ID:-784C9X9KK5}"
ISSUER="${ASC_ISSUER:-4ac4d69c-918c-4e45-a0a3-d84f1b8c8338}"

PROFILE=""
for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  [[ -f "$d/$PROFILE_UUID.mobileprovision" ]] && PROFILE="$d/$PROFILE_UUID.mobileprovision" && break
done
[[ -n "$PROFILE" ]] || { echo "error: profile $PROFILE_UUID not found" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/Payload" "$OUT/SwiftSupport/iphoneos"
APP="$OUT/Payload/PocketAI.app"
ditto "$SRC" "$APP"
cp "$SPAN" "$OUT/SwiftSupport/iphoneos/"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# Xcode-managed profile, so entitlements are spelled out rather than taken
# from a manual-signing archive. Keep in step with Entitlements/*.entitlements.
ENT="$OUT/dist.entitlements"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>4RK6YA795V.com.getpocketai.app</string>
  <key>com.apple.developer.team-identifier</key><string>4RK6YA795V</string>
  <key>get-task-allow</key><false/>
  <key>beta-reports-active</key><true/>
  <key>keychain-access-groups</key><array><string>4RK6YA795V.com.getpocketai.app</string></array>
  <key>com.apple.developer.kernel.increased-memory-limit</key><true/>
  <key>com.apple.developer.kernel.extended-virtual-addressing</key><true/>
</dict></plist>
PLIST

echo "==> sign"
find "$APP" -depth \( -name "*.framework" -o -name "*.dylib" \) -print0 |
  while IFS= read -r -d '' f; do codesign --force --timestamp --sign "$ID" "$f"; done
codesign --force --timestamp --sign "$ID" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
IPA="$OUT/PocketAI-$BUILD.ipa"
(cd "$OUT" && zip -qry "$(basename "$IPA")" Payload SwiftSupport)

echo "==> upload build $BUILD"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 |
  grep -E "UPLOAD|Delivery UUID|ITMS-|error:" | grep -v "GET APP SETTINGS\|Download task\|KPI"
