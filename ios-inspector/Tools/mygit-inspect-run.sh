#!/bin/bash
# Build and run an iOS app with every SwiftUI view tagged with its source
# location, so MyGit's UI Inspector can jump from a view to the exact line.
#
# The repo itself is never modified: sources are mirrored into
# <repo>/.mygit/inspect/src (non-Swift files by rsync, Swift files by
# mygit-source-tagger, both incremental), built from there with their own
# DerivedData, and installed like a normal run. Tags record the original
# repo-relative paths, and line numbers are unchanged.
#
# usage: mygit-inspect-run.sh --repo DIR --tagger BIN --scheme NAME --device ID
#                             [--workspace REL | --project REL] [--physical]
set -euo pipefail

REPO="" TAGGER="" SCHEME="" DEVICE="" CONTAINER_FLAG="" CONTAINER="" PHYSICAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tagger) TAGGER="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --workspace) CONTAINER_FLAG="-workspace"; CONTAINER="$2"; shift 2 ;;
    --project) CONTAINER_FLAG="-project"; CONTAINER="$2"; shift 2 ;;
    --physical) PHYSICAL=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$TAGGER" ] && [ -n "$SCHEME" ] && [ -n "$DEVICE" ] && [ -n "$CONTAINER" ] || {
  echo "usage: $0 --repo DIR --tagger BIN --scheme NAME --device ID (--workspace REL | --project REL) [--physical]" >&2
  exit 2
}

cd "$REPO"
REPO="$(pwd -P)"
INSPECT="$REPO/.mygit/inspect"
SRC="$INSPECT/src"
DERIVED="$INSPECT/DerivedData"
LOG="$INSPECT/build.log"
mkdir -p "$SRC"

# Keep .mygit/ out of `git status` without touching the repo's .gitignore.
EXCLUDE="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
if [ -n "$EXCLUDE" ] && ! grep -qxF '.mygit/' "$EXCLUDE" 2>/dev/null; then
  mkdir -p "$(dirname "$EXCLUDE")"
  printf '.mygit/\n' >> "$EXCLUDE"
fi

START=$(date +%s)
echo "▶ mirroring sources → .mygit/inspect/src"
# Everything but Swift sources (the tagger owns those) and build output.
# -a keeps mtimes, so unchanged files stay unchanged for Xcode.
rsync -a --delete \
  --exclude '/.git' --exclude '/.mygit' --exclude 'DerivedData' --exclude '.build' \
  --exclude 'xcuserdata' --exclude '*.swift' \
  "$REPO/" "$SRC/"

# Debug-only modifiers removed from the inspected build (their overlays
# clutter the tree). Space-separated; set to "" to keep everything.
STRIP_MODIFIERS="${MYGIT_INSPECT_STRIP_MODIFIERS-debugLayoutBounds}"
STRIP_FLAGS=()
for m in $STRIP_MODIFIERS; do STRIP_FLAGS+=(--strip-modifier "$m"); done

tag() {
  "$TAGGER" --source "$REPO" --dest "$SRC" --manifest "$INSPECT/tagger-manifest.json" --map "$INSPECT/map" \
    ${STRIP_FLAGS[@]+"${STRIP_FLAGS[@]}"} "$@"
}
tag

if [ "$PHYSICAL" = 1 ]; then
  SDK_FLAGS=(-allowProvisioningUpdates)
  PRODUCTS="Debug-iphoneos"
else
  SDK_FLAGS=(-sdk iphonesimulator)
  PRODUCTS="Debug-iphonesimulator"
fi

# A project that leaves DEVELOPMENT_TEAM unset can't be signed for a device.
# Borrow the team of an installed, unexpired provisioning profile that covers
# this device (a wildcard one first, since it fits any bundle ID).
# MYGIT_DEVELOPMENT_TEAM overrides the guess.
pick_team() {
  if [ -n "${MYGIT_DEVELOPMENT_TEAM:-}" ]; then echo "$MYGIT_DEVELOPMENT_TEAM"; return; fi
  local now fallback="" dir p d team
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for p in "$dir"/*.mobileprovision; do
      [ -f "$p" ] || continue
      d="$(security cms -D -i "$p" 2>/dev/null)" || continue
      grep -qF "<string>$DEVICE</string>" <<< "$d" || continue
      [[ "$(plutil -extract ExpirationDate raw -o - - <<< "$d" 2>/dev/null)" > "$now" ]] || continue
      team="$(plutil -extract TeamIdentifier.0 raw -o - - <<< "$d" 2>/dev/null)" || continue
      if [ "$(plutil -extract Entitlements.application-identifier raw -o - - <<< "$d" 2>/dev/null)" = "$team.*" ]; then
        echo "$team"; return
      fi
      fallback="${fallback:-$team}"
    done
  done
  echo "$fallback"
}
# Signing overrides found by an earlier run (one xcodebuild setting per line),
# so later runs skip the failed first attempt.
SIGNING="$INSPECT/signing"
TEAM_FLAGS=()
if [ "$PHYSICAL" = 1 ] && [ -z "${MYGIT_DEVELOPMENT_TEAM:-}" ] && [ -f "$SIGNING" ]; then
  while IFS= read -r line; do [ -n "$line" ] && TEAM_FLAGS+=("$line"); done < "$SIGNING"
fi

DEST="id=$DEVICE"
build() {
  (cd "$SRC" && xcrun xcodebuild "$CONTAINER_FLAG" "$CONTAINER" -scheme "$SCHEME" -configuration Debug \
     "${SDK_FLAGS[@]}" -destination "$DEST" -derivedDataPath "$DERIVED" \
     ${TEAM_FLAGS[@]+"${TEAM_FLAGS[@]}"} build) 2>&1 | tee "$LOG" \
     | grep -E --line-buffered '(: error:|\*\* BUILD)' || true
  grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"
}

# A tag the compiler rejects (a custom API the tagger misread) shouldn't
# block the run: first build those files without token probes (an argument
# that won't pass through `__mT`), then, if they still fail, untagged.
ATTEMPT=1
UNPROBED=" "
until build; do
  # The iPhone isn't reachable right now (unplugged, and not found over
  # Wi-Fi): the build doesn't need it — only the install does.
  if [ "$PHYSICAL" = 1 ] && [ "$DEST" != "generic/platform=iOS" ] && grep -q 'Unable to find a destination matching' "$LOG"; then
    echo "▶ xcodebuild can't see the iPhone right now — building for any iOS device"
    DEST="generic/platform=iOS"
    continue
  fi
  if [ "$PHYSICAL" = 1 ] && [ ${#TEAM_FLAGS[@]} -eq 0 ] && grep -q 'requires a development team' "$LOG"; then
    TEAM="$(pick_team)"
    if [ -n "$TEAM" ]; then
      echo "▶ project has no development team — signing with team $TEAM (set MYGIT_DEVELOPMENT_TEAM to override)"
      TEAM_FLAGS=("DEVELOPMENT_TEAM=$TEAM")
      printf '%s\n' "${TEAM_FLAGS[@]}" > "$SIGNING"
      continue
    fi
    echo "✘ project has no development team and no provisioning profile covers this device —" >&2
    echo "  set one in Xcode (Signing & Capabilities) or export MYGIT_DEVELOPMENT_TEAM=<team id>" >&2
    exit 1
  fi
  FAILED=$(grep -oE "^$SRC/[^:]+\.swift:[0-9]+:[0-9]+: error:" "$LOG" | sed -E "s#^$SRC/##; s#:[0-9]+:[0-9]+: error:##" | sort -u || true)
  if [ -z "$FAILED" ] || [ "$ATTEMPT" -ge 5 ] || ! grep -q '__MyGitSourceKey' $(printf "$SRC/%s " $FAILED) 2>/dev/null; then
    echo "✘ build failed — full log: $LOG" >&2
    exit 1
  fi
  FLAGS=()
  while IFS= read -r f; do
    if grep -q '__mT(' "$SRC/$f" 2>/dev/null && [ "${UNPROBED#* $f }" = "$UNPROBED" ]; then
      echo "▶ building without token probes: $f"
      FLAGS+=(--unprobed "$f"); UNPROBED="$UNPROBED$f "
    else
      echo "▶ building without source tags: $f"
      FLAGS+=(--plain "$f")
    fi
  done <<< "$FAILED"
  tag "${FLAGS[@]}"
  ATTEMPT=$((ATTEMPT + 1))
done

APP="$(ls -d "$DERIVED/Build/Products/$PRODUCTS/"*.app | head -1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "▶ built in $(( $(date +%s) - START ))s"

if [ "$PHYSICAL" = 1 ]; then
  echo "▶ installing on device ..."
  INSTALLED=0
  # An app embedding MyGitInspector must declare its Bonjour service and a
  # local-network reason, or iOS silently refuses to advertise it on a device
  # (the simulator doesn't check). Add both to the built app when missing and
  # re-sign it with the identity it was signed with.
  patch_inspector_plist() {
    local app="$1" plist="$1/Info.plist" auth sha
    LC_ALL=C grep -aqs 'mygitinspect' "$app"/* || return 0
    if /usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$plist" 2>/dev/null | grep -q '_mygitinspect._tcp' \
       && /usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$plist" >/dev/null 2>&1; then
      return 0
    fi
    echo "▶ adding the UI Inspector's Bonjour service to Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Add :NSBonjourServices array' "$plist"
    /usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$plist" | grep -q '_mygitinspect._tcp' \
      || /usr/libexec/PlistBuddy -c 'Add :NSBonjourServices: string _mygitinspect._tcp' "$plist"
    /usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$plist" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string MyGit UI Inspector connects to this debug build over the local network.' "$plist"
    auth="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [ -n "$auth" ] || return 0   # unsigned (simulator): nothing to re-sign
    sha="$(security find-identity -v -p codesigning | grep -F "\"$auth\"" | awk '{print $2}' | head -1)"
    codesign -f -s "${sha:-$auth}" --preserve-metadata=identifier,entitlements,flags "$app"
  }
  # CoreDevice's tunnel state for a UDID: "connected" / "disconnected" are
  # reachable; "unavailable" means unplugged and not found over Wi-Fi — busy or
  # client-isolated networks (offices, cafés) block that discovery.
  device_state() {
    local json n i
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" --quiet >/dev/null 2>&1 || { rm -f "$json"; return 0; }
    n="$(plutil -extract result.devices raw -o - "$json" 2>/dev/null || echo 0)"
    for ((i = 0; i < n; i++)); do
      if [ "$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$json" 2>/dev/null)" = "$1" ]; then
        plutil -extract "result.devices.$i.connectionProperties.tunnelState" raw -o - "$json" 2>/dev/null || true
        break
      fi
    done
    rm -f "$json"
  }
  # Wait for an unreachable iPhone instead of failing the install.
  wait_for_device() {
    local device="$1" waited=0
    while [ "$(device_state "$device")" = "unavailable" ]; do
      if [ "$waited" -ge 180 ]; then
        echo "✘ the iPhone still isn't reachable — connect it with a USB cable and run again" >&2
        exit 1
      fi
      [ "$waited" -eq 0 ] && echo "▶ the iPhone isn't reachable — connect it with a USB cable (busy Wi-Fi networks often hide it); waiting up to 3 min ..."
      sleep 3
      waited=$((waited + 3))
    done
  }
  wait_for_device "$DEVICE"
  install() {
    patch_inspector_plist "$APP"
    INSTALL_OUT="$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1)" && INSTALLED=1
  }
  if ! install; then
    # The device already has this bundle ID from a team this Mac can't sign
    # for. When we picked the team ourselves, install side by side under
    # "<bundle id>.mygit" instead of asking the user to delete their app.
    if grep -q 'MismatchedApplicationIdentifierEntitlement' <<< "$INSTALL_OUT" \
       && [ ${#TEAM_FLAGS[@]} -gt 0 ] && [ "${BUNDLE_ID%.mygit}" = "$BUNDLE_ID" ]; then
      echo "▶ $BUNDLE_ID is already on the device from another team — installing alongside it as $BUNDLE_ID.mygit"
      TEAM_FLAGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID.mygit")
      printf '%s\n' "${TEAM_FLAGS[@]}" > "$SIGNING"
      build || { echo "✘ build failed — full log: $LOG" >&2; exit 1; }
      BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
      install || true
    fi
  fi
  if [ "$INSTALLED" = 0 ]; then
    echo "$INSTALL_OUT" >&2
    if grep -q 'MismatchedApplicationIdentifierEntitlement' <<< "$INSTALL_OUT"; then
      echo "✘ $BUNDLE_ID is already on the device, signed by another team — delete it from the device" >&2
      echo "  or export MYGIT_DEVELOPMENT_TEAM=<that team id> if this Mac can sign for it" >&2
    fi
    exit 1
  fi
  # A locked iPhone refuses the launch: wait for it to be unlocked instead of failing.
  launch_on_device() {
    local device="$1" bundle="$2" out waited=0
    while :; do
      if out="$(xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle" 2>&1)"; then
        echo "$out" | tail -1
        return 0
      fi
      if grep -q 'could not be, unlocked\|BSErrorCodeDescription = Locked' <<< "$out" && [ "$waited" -lt 120 ]; then
        [ "$waited" -eq 0 ] && echo "▶ the iPhone is locked — unlock it to launch the app (waiting up to 2 min) ..."
        sleep 3
        waited=$((waited + 3))
        continue
      fi
      echo "$out" >&2
      return 1
    done
  }
  launch_on_device "$DEVICE" "$BUNDLE_ID"
else
  echo "▶ booting simulator ..."
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  open -a Simulator
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
fi
echo "✔ running with source tags — open View ▸ UI Inspector in MyGit"
