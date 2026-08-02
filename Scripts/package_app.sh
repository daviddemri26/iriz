#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/build"
APP_ROOT="$BUILD_ROOT/Iriz.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

mkdir -p /tmp/iriz-swift-cache "$BUILD_ROOT"
cd "$PROJECT_ROOT"

export SWIFT_MODULECACHE_PATH=/tmp/iriz-swift-cache
export CLANG_MODULE_CACHE_PATH=/tmp/iriz-swift-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/iriz-swift-cache

swift build \
  --configuration release \
  --triple arm64-apple-macosx15.0 \
  --scratch-path "$BUILD_ROOT/arm64" \
  --disable-sandbox

swift build \
  --configuration release \
  --triple x86_64-apple-macosx15.0 \
  --scratch-path "$BUILD_ROOT/x86_64" \
  --disable-sandbox

ARM_BINARY="$BUILD_ROOT/arm64/arm64-apple-macosx/release/Iriz"
INTEL_BINARY="$BUILD_ROOT/x86_64/x86_64-apple-macosx/release/Iriz"
if [[ ! -x "$ARM_BINARY" || ! -x "$INTEL_BINARY" ]]; then
  echo "One or both release binaries were not produced." >&2
  exit 1
fi

rm -rf "$APP_ROOT" "$BUILD_ROOT/Iriz.zip"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_ROOT/Contents/MacOS/Iriz"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Assets/IrizIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
xattr -cr "$APP_ROOT"

SIGN_OPTIONS=(
  --force
  --deep
  --options runtime
  --entitlements "$PROJECT_ROOT/Packaging/Iriz.entitlements"
  --sign "$IDENTITY"
)
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_OPTIONS+=(--timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "$APP_ROOT"
codesign --verify --deep --strict --verbose=2 "$APP_ROOT"
plutil -lint "$APP_ROOT/Contents/Info.plist"

ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/Iriz.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID Application identity." >&2
    exit 1
  fi
  xcrun notarytool submit "$BUILD_ROOT/Iriz.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_ROOT"
  rm -f "$BUILD_ROOT/Iriz.zip"
  ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/Iriz.zip"
fi
echo "$APP_ROOT"
echo "$BUILD_ROOT/Iriz.zip"
