#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --configuration release --arch arm64

bundle=".build/MacKeySwitcher.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
bin_path="$(swift build --configuration release --arch arm64 --show-bin-path)"
cp "$bin_path/MacKeySwitcher" "$bundle/Contents/MacOS/MacKeySwitcher"
cp -R "$bin_path"/*.bundle "$bundle/Contents/Resources/"

identity="${DEVELOPMENT_IDENTITY:-$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)}"
if [[ -z "$identity" ]]; then
    echo "warning: Apple Development certificate not found; using ad-hoc signing (macOS may ask for permissions again after rebuilding)." >&2
    identity="-"
fi
codesign --force --sign "$identity" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
echo "$PWD/$bundle"
