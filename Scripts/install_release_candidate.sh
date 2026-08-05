#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_ROOT/build/Iriz.app}"
DESTINATION_APP="${IRIZ_INSTALL_PATH:-/Applications/Iriz.app}"

if [[ "$DESTINATION_APP" != */Iriz.app ]]; then
  echo "Refusing unexpected installation target: $DESTINATION_APP" >&2
  exit 1
fi

"$PROJECT_ROOT/Scripts/verify_release_candidate.sh" "$SOURCE_APP"

if pgrep -x Iriz >/dev/null; then
  echo "Quit every running Iriz copy before installing the release candidate." >&2
  exit 1
fi

if [[ -e "$DESTINATION_APP" ]]; then
  PREVIOUS_REQUIREMENT="$(codesign -d -r- "$DESTINATION_APP" 2>&1 | sed -n '/^designated =>/p')"
  NEXT_REQUIREMENT="$(codesign -d -r- "$SOURCE_APP" 2>&1 | sed -n '/^designated =>/p')"
  if [[ -z "$PREVIOUS_REQUIREMENT" || -z "$NEXT_REQUIREMENT" ]]; then
    echo "Refusing update: unable to read the designated code requirement." >&2
    exit 1
  fi
  if [[ "$PREVIOUS_REQUIREMENT" != "$NEXT_REQUIREMENT" ]]; then
    echo "Refusing update: the designated code requirement changed." >&2
    echo "Previous: $PREVIOUS_REQUIREMENT" >&2
    echo "Next: $NEXT_REQUIREMENT" >&2
    exit 1
  fi
  rm -rf "$DESTINATION_APP"
  echo "Previous installation removed before replacement."
fi

ditto --norsrc "$SOURCE_APP" "$DESTINATION_APP"
codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DESTINATION_APP"
fi

echo "Installed stable Local Release Candidate at $DESTINATION_APP"
echo "Launch only this copy when testing permissions."
