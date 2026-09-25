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

build() {
  (cd "$SRC" && xcrun xcodebuild "$CONTAINER_FLAG" "$CONTAINER" -scheme "$SCHEME" -configuration Debug \
     "${SDK_FLAGS[@]}" -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
     ${TEAM_FLAGS[@]+"${TEAM_FLAGS[@]}"} build) 2>&1 | tee "$LOG" \
     | grep -E --line-buffered '(: error:|\*\* BUILD)' || true
  grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"
}

# A tag the compiler rejects (a custom API the tagger misread) shouldn't
# block the run: mirror those files untagged and build again.
ATTEMPT=1
until build; do
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
  if [ -z "$FAILED" ] || [ "$ATTEMPT" -ge 3 ] || ! grep -q '__MyGitSourceKey' $(printf "$SRC/%s " $FAILED) 2>/dev/null; then
    echo "✘ build failed — full log: $LOG" >&2
    exit 1
  fi
  echo "▶ building without source tags in:"
  PLAIN=()
  while IFS= read -r f; do echo "    $f"; PLAIN+=(--plain "$f"); done <<< "$FAILED"
  tag "${PLAIN[@]}"
  ATTEMPT=$((ATTEMPT + 1))
done

APP="$(ls -d "$DERIVED/Build/Products/$PRODUCTS/"*.app | head -1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "▶ built in $(( $(date +%s) - START ))s"

if [ "$PHYSICAL" = 1 ]; then
  echo "▶ installing on device ..."
  INSTALLED=0
  install() { INSTALL_OUT="$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1)" && INSTALLED=1; }
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
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
else
  echo "▶ booting simulator ..."
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  open -a Simulator
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
fi
echo "✔ running with source tags — open View ▸ UI Inspector in MyGit"
