#!/bin/zsh
set -euo pipefail

# Package an unsigned / ad-hoc release artifact for distribution WITHOUT the
# Apple Developer Program (no Developer ID, no notarization). Produces both a
# ZIP and a DMG in .build/release-artifacts/. See docs/release-unsigned.md.

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archive_dir=".build/release-artifacts"
app="$archive_dir/MacKeySwitcher.app"
zip="$archive_dir/MacKeySwitcher-${version}-arm64.zip"
dmg="$archive_dir/MacKeySwitcher-${version}-arm64.dmg"
staging="$archive_dir/dmg"

rm -rf "$archive_dir"
mkdir -p "$archive_dir"

# 1. Build the release .app bundle (reuse the shared packaging script).
Scripts/package-app.sh
mv .build/MacKeySwitcher.app "$app"

# 2. Copy bundled language-resource licenses (as in the notarized release script).
mkdir -p "$app/Contents/Resources/Licenses"
cp Resources/LanguageDetector/source/ATTRIBUTION.md "$app/Contents/Resources/Licenses/LanguageDetector-ATTRIBUTION.md"
cp Resources/LanguageDetector/source/LICENSE.md "$app/Contents/Resources/Licenses/LanguageDetector-LICENSE.md"

# 3. Ad-hoc sign. Stable, free, no account required. Hardened Runtime is not
#    needed here because there is no notarization step.
codesign --force --deep --sign - "$app"
codesign --verify --strict --verbose=2 "$app"

# 4. Build the ZIP straight from the signed bundle.
ditto -c -k --keepParent "$app" "$zip"

# 5. Build the DMG (simple, dependency-free) with an /Applications symlink so the
#    user can drag-and-drop install. `hdiutil create -srcfolder` is the classic
#    path but needs to attach a disk device, which is unavailable in restricted
#    sandboxes; `makehybrid` + `convert` produces an equivalent compressed UDZO
#    image without attaching a device.
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

if hdiutil create -volname "Mac Key Switcher" \
        -srcfolder "$staging" -ov -format UDZO "$dmg" 2>/dev/null; then
    :
else
    echo "note: 'hdiutil create' unavailable (sandbox?); using makehybrid + convert." >&2
    raw_dmg="$archive_dir/.raw.dmg"
    rm -f "$raw_dmg"
    hdiutil makehybrid -hfs -hfs-volume-name "Mac Key Switcher" -o "$raw_dmg" "$staging"
    hdiutil convert "$raw_dmg" -format UDZO -ov -o "$dmg"
    rm -f "$raw_dmg"
fi
rm -rf "$staging"

# 6. Print both artifact paths.
echo "$root/$zip"
echo "$root/$dmg"
