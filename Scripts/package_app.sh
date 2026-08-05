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
if [[ -n "${IRIZ_OPTIMIZATION_PHASE:-}" ]]; then
  OPTIMIZATION_PHASE="${IRIZ_OPTIMIZATION_PHASE:l}"
elif [[ "$BUILD_CHANNEL" == "Development" || "$BUILD_CHANNEL" == "ReleaseCandidate" ]]; then
  OPTIMIZATION_PHASE="legacy"
else
  OPTIMIZATION_PHASE="adaptive"
fi
if [[ "$OPTIMIZATION_PHASE" != "legacy" && "$OPTIMIZATION_PHASE" != "shadow" && "$OPTIMIZATION_PHASE" != "adaptive" ]]; then
  echo "IRIZ_OPTIMIZATION_PHASE must be legacy, shadow, or adaptive." >&2
  exit 1
fi
if [[ -n "${IRIZ_TERRA_OPTIMIZATION:-}" ]]; then
  case "${IRIZ_TERRA_OPTIMIZATION:l}" in
    1|true|yes) DEFERRED_TERRA_REFINEMENT=true ;;
    0|false|no) DEFERRED_TERRA_REFINEMENT=false ;;
    *)
      echo "IRIZ_TERRA_OPTIMIZATION must be true or false." >&2
      exit 1
      ;;
  esac
elif [[ "$BUILD_CHANNEL" == "Standalone" || "$BUILD_CHANNEL" == "Setapp" ]]; then
  DEFERRED_TERRA_REFINEMENT=true
else
  DEFERRED_TERRA_REFINEMENT=false
fi
if [[ -n "${IRIZ_OPTIMIZATION_STAGE:-}" ]]; then
  OPTIMIZATION_STAGE="${IRIZ_OPTIMIZATION_STAGE:l}"
elif [[ "$BUILD_CHANNEL" == "Standalone" || "$BUILD_CHANNEL" == "Setapp" ]]; then
  OPTIMIZATION_STAGE="production"
elif [[ "$OPTIMIZATION_PHASE" == "legacy" ]]; then
  OPTIMIZATION_STAGE="baseline"
elif [[ "$OPTIMIZATION_PHASE" == "shadow" ]]; then
  OPTIMIZATION_STAGE="apple-shadow"
elif [[ "$DEFERRED_TERRA_REFINEMENT" == true ]]; then
  OPTIMIZATION_STAGE="terra"
else
  OPTIMIZATION_STAGE="adaptive"
fi
case "$OPTIMIZATION_STAGE" in
  baseline)
    [[ "$OPTIMIZATION_PHASE" == "legacy" && "$DEFERRED_TERRA_REFINEMENT" == false ]] || {
      echo "baseline requires legacy with deferred Terra disabled." >&2
      exit 1
    }
    ;;
  process|adaptive)
    [[ "$OPTIMIZATION_PHASE" == "adaptive" && "$DEFERRED_TERRA_REFINEMENT" == false ]] || {
      echo "$OPTIMIZATION_STAGE requires adaptive with deferred Terra disabled." >&2
      exit 1
    }
    ;;
  apple-shadow)
    [[ "$OPTIMIZATION_PHASE" == "shadow" && "$DEFERRED_TERRA_REFINEMENT" == false ]] || {
      echo "apple-shadow requires shadow with deferred Terra disabled." >&2
      exit 1
    }
    ;;
  terra|local-events|speech|production)
    [[ "$OPTIMIZATION_PHASE" == "adaptive" && "$DEFERRED_TERRA_REFINEMENT" == true ]] || {
      echo "$OPTIMIZATION_STAGE requires adaptive with deferred Terra enabled." >&2
      exit 1
    }
    ;;
  *)
    echo "IRIZ_OPTIMIZATION_STAGE must be baseline, process, apple-shadow, adaptive, terra, local-events, speech, or production." >&2
    exit 1
    ;;
esac

mkdir -p /tmp/iriz-swift-cache "$BUILD_ROOT"
cd "$PROJECT_ROOT"

export SWIFT_MODULECACHE_PATH=/tmp/iriz-swift-cache
export CLANG_MODULE_CACHE_PATH=/tmp/iriz-swift-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/iriz-swift-cache

swift build \
  --configuration release \
  --triple arm64-apple-macosx26.0 \
  --scratch-path "$BUILD_ROOT/arm64" \
  --disable-sandbox

ARM_BINARY="$BUILD_ROOT/arm64/arm64-apple-macosx/release/iriz"
if [[ ! -x "$ARM_BINARY" ]]; then
  echo "The Apple silicon release binary was not produced." >&2
  exit 1
fi

rm -rf "$APP_ROOT" "$BUILD_ROOT/Iriz.app" "$BUILD_ROOT/iriz.zip" "$BUILD_ROOT/Iriz.zip"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$ARM_BINARY" "$APP_ROOT/Contents/MacOS/iriz"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Assets/IrizIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :IrizBuildChannel string $BUILD_CHANNEL" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :IrizOptimizationPhase string $OPTIMIZATION_PHASE" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :IrizOptimizationStage string $OPTIMIZATION_STAGE" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :IrizDeferredTerraRefinement bool $DEFERRED_TERRA_REFINEMENT" "$APP_ROOT/Contents/Info.plist"
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

ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/Iriz.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "NOTARY_PROFILE requires a Developer ID Application identity, not '$IDENTITY'." >&2
    exit 1
  fi
  if [[ "$SIGNING_TIMESTAMP" == "none" ]]; then
    echo "Notarization requires a secure timestamp." >&2
    exit 1
  fi
  xcrun notarytool submit "$BUILD_ROOT/Iriz.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_ROOT"
  rm -f "$BUILD_ROOT/Iriz.zip"
  ditto --norsrc -c -k --keepParent "$APP_ROOT" "$BUILD_ROOT/Iriz.zip"
fi
echo "$APP_ROOT"
echo "$BUILD_ROOT/Iriz.zip"
