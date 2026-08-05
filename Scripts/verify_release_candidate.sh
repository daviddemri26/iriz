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
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"

[[ "$CHANNEL" == "ReleaseCandidate" ]] || {
  echo "Expected ReleaseCandidate build channel, found '$CHANNEL'." >&2
  exit 1
}
[[ "$BUNDLE_ID" == "com.iriz.memory" ]] || {
  echo "Unexpected bundle identifier '$BUNDLE_ID'." >&2
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
[[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]] || {
  echo "Release candidate is not Universal: $ARCHITECTURES" >&2
  exit 1
}

echo "Verified Local Release Candidate"
echo "Bundle: $BUNDLE_ID"
echo "Architectures: $ARCHITECTURES"
codesign -d -r- "$APP_PATH" 2>&1
