#!/usr/bin/env bash
#
# Build MyGit and run it as a bundled app signed with a STABLE local
# identity. A persistent self-signed cert keeps the designated requirement
# constant so granted system permissions survive rebuilds.
#
# Usage:
#   ./run.sh            # debug build
#   ./run.sh release    # release build
#
set -euo pipefail

APP_NAME="MyGit"
CONFIG="${1:-debug}"
CERT_NAME="MyGit Dev"
CERT_PW="mygit-dev"
KEYCHAIN_NAME="mygit.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ensure_keychain_and_cert() {
  # Self-heal: if a keychain file already exists but its password isn't our
  # known CERT_PW (e.g. a stale one left by another setup, or a fresh checkout
  # on a second machine), unlocking it non-interactively fails and macOS pops a
  # GUI password prompt you can't answer. Detect that and recreate it fresh.
  # The dev keychain only holds the signing cert — the app's PAT/API keys live
  # in the default login keychain — so recreating it loses nothing important.
  if [[ -f "$KEYCHAIN_PATH" ]] \
     && ! security unlock-keychain -p "$CERT_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    echo "▶︎ Existing $KEYCHAIN_NAME has an unknown password — recreating it…"
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -f "$KEYCHAIN_PATH"
  fi

  if [[ ! -f "$KEYCHAIN_PATH" ]]; then
    echo "▶︎ Creating dedicated keychain ($KEYCHAIN_NAME)…"
    security create-keychain -p "$CERT_PW" "$KEYCHAIN_NAME" >/dev/null
  fi

  security set-keychain-settings "$KEYCHAIN_PATH"
  security unlock-keychain -p "$CERT_PW" "$KEYCHAIN_PATH"

  if ! security list-keychains -d user | grep -q "$KEYCHAIN_NAME"; then
    local current
    current=$(security list-keychains -d user \
              | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
              | tr '\n' ' ')
    # shellcheck disable=SC2086
    security list-keychains -d user -s $current "$KEYCHAIN_PATH" >/dev/null
  fi

  if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    echo "▶︎ Creating self-signed cert \"$CERT_NAME\" in $KEYCHAIN_NAME (one-off)…"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CERT_NAME
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -days 3650 -config "$tmp/cfg" >/dev/null 2>&1
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/cert.p12" -passout "pass:$CERT_PW" >/dev/null 2>&1
    security import "$tmp/cert.p12" -k "$KEYCHAIN_PATH" -P "$CERT_PW" \
        -T /usr/bin/codesign -A >/dev/null 2>&1
    rm -rf "$tmp"
    echo "  ✓ Cert ready."
  fi

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$CERT_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
}

ensure_keychain_and_cert

SIGN_IDENTITY=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN_PATH" \
                | awk '/SHA-1 hash/ {print $NF}')
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "  ⚠︎ Falling back to ad-hoc signing."
  SIGN_IDENTITY="-"
fi

echo "▶︎ Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "✗ Binary not found at $BIN" >&2; exit 1; }

APP="$ROOT/build/$APP_NAME.app"
echo "▶︎ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# SPM resource bundles (e.g. Highlightr's highlight.js + themes) live next to the
# binary; Bundle.module finds them in Contents/Resources at runtime. Without this the
# diff viewer's syntax highlighting silently no-ops (engine fails to load its JS).
BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob
# UI Inspector's "Run with Inspector": the source tagger (SwiftSyntax,
# built once in release, then incrementally) and its run script ship in
# Resources.
TAGGER_PKG="$ROOT/../ios-inspector/Tools/SourceTagger"
if [[ -d "$TAGGER_PKG" ]]; then
  echo "▶︎ Building source tagger…"
  swift build -c release --package-path "$TAGGER_PKG" --product mygit-source-tagger 2>&1 | grep -E "error|warning: unable" || true
  TAGGER_BIN="$(swift build -c release --package-path "$TAGGER_PKG" --show-bin-path)/mygit-source-tagger"
  if [[ -x "$TAGGER_BIN" ]]; then
    cp "$TAGGER_BIN" "$APP/Contents/Resources/mygit-source-tagger"
    cp "$ROOT/../ios-inspector/Tools/mygit-inspect-run.sh" "$APP/Contents/Resources/mygit-inspect-run.sh"
  else
    echo "⚠︎ source tagger didn't build — Run with Inspector will be unavailable" >&2
  fi
fi
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Packaging/AppIcon.icns" ]]; then
  cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

security unlock-keychain -p "$CERT_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

echo "▶︎ Code signing as: $CERT_NAME ($SIGN_IDENTITY)"
# --deep doesn't reach executables in Resources; sign the tagger itself.
if [[ -f "$APP/Contents/Resources/mygit-source-tagger" ]]; then
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
    "$APP/Contents/Resources/mygit-source-tagger" 2>/dev/null \
    || codesign --force --sign - "$APP/Contents/Resources/mygit-source-tagger"
fi
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
  --keychain "$KEYCHAIN_PATH" \
  --entitlements "$ROOT/Packaging/MyGit.entitlements" \
  "$APP" 2>/dev/null \
  || codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" "$APP"

echo "▶︎ Killing old instance (if any)…"
killall "$APP_NAME" 2>/dev/null || true
# The app quits cleanly on SIGTERM (saves tabs, drops its Claude Code lock
# file, frees its IDE port). Wait for that so the new instance can reclaim the
# same port and running Claude sessions reconnect; force it after 5s.
for _ in $(seq 1 50); do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.1
done
killall -9 "$APP_NAME" 2>/dev/null || true

echo "▶︎ Launching $APP"
open "$APP"

cat <<EOF

✓ Done.
  • File → Add Local Repository… (⌘O) to add a repo
  • Log: log stream --predicate 'process == "$APP_NAME"' --level debug
EOF
