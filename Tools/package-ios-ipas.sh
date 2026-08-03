#!/usr/bin/env bash
# Build two unsigned IPA payloads from one complete NOOP iOS .app:
#   1. AltStore/SideStore: phone/iPad app only (no PlugIns/ or Watch/)
#   2. Full Apple bundle: iOS widgets + Watch app + Watch complication intact
set -euo pipefail

APP="${1:?usage: $0 path/to/NOOP.app lite.ipa full.ipa}"
LITE_INPUT="${2:?usage: $0 path/to/NOOP.app lite.ipa full.ipa}"
FULL_INPUT="${3:?usage: $0 path/to/NOOP.app lite.ipa full.ipa}"

[[ -d "$APP" ]] || { echo "iOS app bundle not found: $APP" >&2; exit 1; }

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

LITE_IPA="$(absolute_path "$LITE_INPUT")"
FULL_IPA="$(absolute_path "$FULL_INPUT")"
APP_NAME="$(basename "$APP")"
WATCH_APP="$APP/Watch/NOOPWatch.app"
IOS_WIDGET="$APP/PlugIns/NOOPWidgets.appex"
WATCH_WIDGET="$WATCH_APP/PlugIns/NOOPWatchComplications.appex"

[[ -d "$IOS_WIDGET" ]] || { echo "full build is missing $IOS_WIDGET" >&2; exit 1; }
[[ -d "$WATCH_APP" ]] || { echo "full build is missing $WATCH_APP" >&2; exit 1; }
[[ -d "$WATCH_WIDGET" ]] || { echo "full build is missing $WATCH_WIDGET" >&2; exit 1; }

if find "$APP" -name embedded.mobileprovision -print -quit | grep -q .; then
  echo "refusing to package a provisioned Apple bundle" >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"
}

ROOT_ID="$(plist_value "$APP" CFBundleIdentifier)"
WATCH_COMPANION_ID="$(plist_value "$WATCH_APP" WKCompanionAppBundleIdentifier)"
[[ "$WATCH_COMPANION_ID" == "$ROOT_ID" ]] || {
  echo "Watch companion id '$WATCH_COMPANION_ID' does not match iOS app id '$ROOT_ID'" >&2
  exit 1
}

ROOT_VERSION="$(plist_value "$APP" CFBundleShortVersionString)"
ROOT_BUILD="$(plist_value "$APP" CFBundleVersion)"
for nested in "$IOS_WIDGET" "$WATCH_APP" "$WATCH_WIDGET"; do
  [[ "$(plist_value "$nested" CFBundleShortVersionString)" == "$ROOT_VERSION" ]] || {
    echo "version mismatch in $nested" >&2; exit 1;
  }
  [[ "$(plist_value "$nested" CFBundleVersion)" == "$ROOT_BUILD" ]] || {
    echo "build-number mismatch in $nested" >&2; exit 1;
  }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/full/Payload" "$STAGE/lite/Payload"
cp -R "$APP" "$STAGE/full/Payload/"
cp -R "$APP" "$STAGE/lite/Payload/"

# Thin only the staged AltStore copy. The canonical build product and Full IPA stay intact.
rm -rf "$STAGE/lite/Payload/$APP_NAME/PlugIns" "$STAGE/lite/Payload/$APP_NAME/Watch"

[[ ! -e "$STAGE/lite/Payload/$APP_NAME/PlugIns" ]] || { echo "Lite IPA still has PlugIns" >&2; exit 1; }
[[ ! -e "$STAGE/lite/Payload/$APP_NAME/Watch" ]] || { echo "Lite IPA still has Watch" >&2; exit 1; }

mkdir -p "$(dirname "$LITE_IPA")" "$(dirname "$FULL_IPA")"
rm -f "$LITE_IPA" "$FULL_IPA"
(cd "$STAGE/lite" && zip -qry "$LITE_IPA" Payload)
(cd "$STAGE/full" && zip -qry "$FULL_IPA" Payload)

echo "Packaged AltStore IPA: $LITE_IPA ($(du -h "$LITE_IPA" | cut -f1))"
echo "Packaged Full IPA:     $FULL_IPA ($(du -h "$FULL_IPA" | cut -f1))"
