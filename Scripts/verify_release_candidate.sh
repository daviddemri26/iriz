#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_ROOT/build/iriz.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "iriz app not found at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
BINARY="$APP_PATH/Contents/MacOS/iriz"
CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :IrizBuildChannel' "$INFO_PLIST")"
OPTIMIZATION_PHASE="$(/usr/libexec/PlistBuddy -c 'Print :IrizOptimizationPhase' "$INFO_PLIST")"
OPTIMIZATION_STAGE="$(/usr/libexec/PlistBuddy -c 'Print :IrizOptimizationStage' "$INFO_PLIST")"
DEFERRED_TERRA_REFINEMENT="$(/usr/libexec/PlistBuddy -c 'Print :IrizDeferredTerraRefinement' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"

[[ "$CHANNEL" == "ReleaseCandidate" ]] || {
  echo "Expected ReleaseCandidate build channel, found '$CHANNEL'." >&2
  exit 1
}
[[ "$OPTIMIZATION_PHASE" == "legacy" || "$OPTIMIZATION_PHASE" == "shadow" || "$OPTIMIZATION_PHASE" == "adaptive" ]] || {
  echo "Unexpected optimization phase '$OPTIMIZATION_PHASE'." >&2
  exit 1
}
[[ "$DEFERRED_TERRA_REFINEMENT" == "true" || "$DEFERRED_TERRA_REFINEMENT" == "false" ]] || {
  echo "Unexpected deferred Terra setting '$DEFERRED_TERRA_REFINEMENT'." >&2
  exit 1
}
case "$OPTIMIZATION_STAGE" in
  baseline)
    [[ "$OPTIMIZATION_PHASE" == "legacy" && "$DEFERRED_TERRA_REFINEMENT" == "false" ]] || exit 1
    ;;
  process|adaptive)
    [[ "$OPTIMIZATION_PHASE" == "adaptive" && "$DEFERRED_TERRA_REFINEMENT" == "false" ]] || exit 1
    ;;
  apple-shadow)
    [[ "$OPTIMIZATION_PHASE" == "shadow" && "$DEFERRED_TERRA_REFINEMENT" == "false" ]] || exit 1
    ;;
  terra|local-events|speech|production)
    [[ "$OPTIMIZATION_PHASE" == "adaptive" && "$DEFERRED_TERRA_REFINEMENT" == "true" ]] || exit 1
    ;;
  *)
    echo "Unexpected optimization stage '$OPTIMIZATION_STAGE'." >&2
    exit 1
    ;;
esac
[[ "$BUNDLE_ID" == "com.iriz.memory" ]] || {
  echo "Unexpected bundle identifier '$BUNDLE_ID'." >&2
  exit 1
}
[[ "$MINIMUM_SYSTEM_VERSION" == "26.0" ]] || {
  echo "Expected macOS 26.0 minimum, found '$MINIMUM_SYSTEM_VERSION'." >&2
  exit 1
}
if grep -Fq "Signature=adhoc" <<< "$SIGNATURE_DETAILS" || grep -Eq 'flags=.*\(.*adhoc' <<< "$SIGNATURE_DETAILS"; then
  echo "Release candidate must not use an ad hoc signature." >&2
  exit 1
fi
if ! grep -Fq "Authority=Developer ID Application:" <<< "$SIGNATURE_DETAILS"; then
  echo "Release candidate is not signed by a Developer ID Application certificate." >&2
  exit 1
fi
if grep -Fq "TeamIdentifier=not set" <<< "$SIGNATURE_DETAILS"; then
  echo "Release candidate has no Apple Team Identifier." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$INFO_PLIST"
ARCHITECTURES="$(lipo -archs "$BINARY")"
[[ "$ARCHITECTURES" == "arm64" ]] || {
  echo "Release candidate must be Apple silicon-only: $ARCHITECTURES" >&2
  exit 1
}

echo "Verified Local Release Candidate"
echo "Bundle: $BUNDLE_ID"
echo "Minimum system: macOS $MINIMUM_SYSTEM_VERSION"
echo "Architectures: $ARCHITECTURES"
echo "Optimization: $OPTIMIZATION_STAGE / $OPTIMIZATION_PHASE (deferred Terra: $DEFERRED_TERRA_REFINEMENT)"
codesign -d -r- "$APP_PATH" 2>&1
