#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool keychain profile.}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archive_dir=".build/release-artifacts"
app="$archive_dir/MacKeySwitcher.app"
submission_zip="$archive_dir/MacKeySwitcher-${version}-arm64-submission.zip"
final_zip="$archive_dir/MacKeySwitcher-${version}-arm64.zip"
verify_dir="$archive_dir/verify"
verify_app="$verify_dir/MacKeySwitcher.app"

rm -rf "$archive_dir"
mkdir -p "$archive_dir"

# 1. Build the release .app bundle.
Scripts/package-app.sh
mv .build/MacKeySwitcher.app "$app"
mkdir -p "$app/Contents/Resources/Licenses"
cp Resources/LanguageDetector/source/ATTRIBUTION.md "$app/Contents/Resources/Licenses/LanguageDetector-ATTRIBUTION.md"
cp Resources/LanguageDetector/source/LICENSE.md "$app/Contents/Resources/Licenses/LanguageDetector-LICENSE.md"

# 2. Sign with Hardened Runtime (no App Sandbox — see ADR-0001) and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
codesign --verify --strict --verbose=2 "$app"

# 3. Submit a throwaway ZIP for notarization and wait for the verdict.
ditto -c -k --keepParent "$app" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$NOTARY_PROFILE" --wait

# 4. Staple the ticket onto the .app, then build the FINAL ZIP from the stapled bundle.
#    The submission ZIP is discarded so only a stapled artifact can be shipped.
xcrun stapler staple "$app"
rm -f "$submission_zip"
ditto -c -k --keepParent "$app" "$final_zip"

# 5. Verify Gatekeeper acceptance on the .app extracted from the FINAL ZIP, not the build tree.
rm -rf "$verify_dir"
mkdir -p "$verify_dir"
ditto -x -k "$final_zip" "$verify_dir"
xcrun stapler validate "$verify_app"
spctl --assess --type execute --verbose "$verify_app"
rm -rf "$verify_dir"

echo "$root/$final_zip"
