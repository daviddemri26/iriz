#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')"
  IDENTITY_COUNT="$(print -r -- "$IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$IDENTITY_COUNT" == "1" ]]; then
    IDENTITY="$(print -r -- "$IDENTITIES" | sed '/^$/d')"
  else
    echo "Set CODE_SIGN_IDENTITY to exactly one Developer ID Application identity." >&2
    security find-identity -v -p codesigning >&2
    exit 1
  fi
fi

if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Release candidates require Developer ID Application, not '$IDENTITY'." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "The requested Developer ID identity is not available in the user Keychain." >&2
  exit 1
fi

CODE_SIGN_IDENTITY="$IDENTITY" \
CODE_SIGN_TIMESTAMP="automatic" \
IRIZ_BUILD_CHANNEL="ReleaseCandidate" \
"$PROJECT_ROOT/Scripts/package_app.sh"

"$PROJECT_ROOT/Scripts/verify_release_candidate.sh" "$PROJECT_ROOT/build/iriz.app"
