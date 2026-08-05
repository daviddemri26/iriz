#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "CODE_SIGN_IDENTITY must be a Developer ID Application identity." >&2
  exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "NOTARY_PROFILE must name credentials stored with notarytool." >&2
  exit 1
fi

IRIZ_BUILD_CHANNEL="Standalone" \
CODE_SIGN_TIMESTAMP="automatic" \
"$PROJECT_ROOT/Scripts/package_app.sh"

APP_PATH="$PROJECT_ROOT/build/iriz.app"
if /usr/libexec/PlistBuddy -c 'Print :IrizAdHocBuild' "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Public release unexpectedly contains the ad hoc build marker." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "Developer ID signature, notarization ticket and Gatekeeper assessment verified."
