#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="${IRIZ_BUILD_ROOT:-$PROJECT_ROOT/build}"
APP_ROOT="$BUILD_ROOT/iriz.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGNING_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-}"
SIGNING_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-automatic}"
if [[ -n "${IRIZ_BUILD_CHANNEL:-}" ]]; then
  BUILD_CHANNEL="$IRIZ_BUILD_CHANNEL"
elif [[ "$IDENTITY" == "-" ]]; then
  BUILD_CHANNEL="Development"
else
  BUILD_CHANNEL="Standalone"
fi

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

ARM_BINARY="$BUILD_ROOT/arm64/arm64-apple-macosx/release/iriz"
INTEL_BINARY="$BUILD_ROOT/x86_64/x86_64-apple-macosx/release/iriz"
if [[ ! -x "$ARM_BINARY" || ! -x "$INTEL_BINARY" ]]; then
  echo "One or both release binaries were not produced." >&2
  exit 1
fi

rm -rf "$APP_ROOT" "$BUILD_ROOT/Iriz.app" "$BUILD_ROOT/iriz.zip" "$BUILD_ROOT/Iriz.zip"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_ROOT/Contents/MacOS/iriz"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Assets/IrizIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :IrizBuildChannel string $BUILD_CHANNEL" "$APP_ROOT/Contents/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
  /usr/libexec/PlistBuddy -c "Add :IrizAdHocBuild bool true" "$APP_ROOT/Contents/Info.plist"
fi
xattr -cr "$APP_ROOT"

SIGN_OPTIONS=(
  --force
  --deep
  --options runtime
  --entitlements "$PROJECT_ROOT/Packaging/Iriz.entitlements"
  --sign "$IDENTITY"
)
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  SIGN_OPTIONS+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ "$IDENTITY" != "-" && "$SIGNING_TIMESTAMP" != "none" ]]; then
  SIGN_OPTIONS+=(--timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "$APP_ROOT"
codesign --verify --deep --strict --verbose=2 "$APP_ROOT"
plutil -lint "$APP_ROOT/Contents/Info.plist"

ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/iriz.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "NOTARY_PROFILE requires a Developer ID Application identity, not '$IDENTITY'." >&2
    exit 1
  fi
  if [[ "$SIGNING_TIMESTAMP" == "none" ]]; then
    echo "Notarization requires a secure timestamp." >&2
    exit 1
  fi
  xcrun notarytool submit "$BUILD_ROOT/iriz.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_ROOT"
  rm -f "$BUILD_ROOT/iriz.zip"
  ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/iriz.zip"
fi
echo "$APP_ROOT"
echo "$BUILD_ROOT/iriz.zip"
