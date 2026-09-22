#!/usr/bin/env bash
# Diagnose and repair MyGit's keychain access.
#
# MyGit stores PATs / AI keys as generic-password items in the DEFAULT (login)
# keychain under the service "com.thienpham.MyGit", one item per host account.
# Reads are gated by the item's ACL (trusted apps) + partition list; a changed
# code-signing identity, a re-created login keychain, or a macOS password reset
# all break that and surface as "MyGit wants to access key …" prompts, endless
# password dialogs, or a silently missing token (PR list won't load).
#
# Usage:
#   ./fix-keychain.sh                 # diagnose only (no changes)
#   ./fix-keychain.sh --fix           # unlock login keychain + re-authorize items for the app
#   ./fix-keychain.sh --add HOST      # (re)store a token for HOST, pre-authorized for the app
#   ./fix-keychain.sh --reset         # delete every MyGit item (sign in again in-app afterwards)
set -euo pipefail

SERVICE="com.thienpham.MyGit"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/MyGit.app"
BIN="$APP/Contents/MacOS/MyGit"
LOGIN_KC="$(security default-keychain | tr -d ' "')"

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
head_() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# Accounts (hosts) that currently have an item stored.
list_accounts() {
  security dump-keychain "$LOGIN_KC" 2>/dev/null \
    | awk -v svc="$SERVICE" '
        /"acct"<blob>=/ { acct = $0; sub(/.*"acct"<blob>="/, "", acct); sub(/".*/, "", acct) }
        /"svce"<blob>=/ { svce = $0; sub(/.*"svce"<blob>="/, "", svce); sub(/".*/, "", svce)
                          if (svce == svc && acct != "") print acct }' \
    | sort -u
}

diagnose() {
  head_ "Keychain"
  echo "  default: $LOGIN_KC"
  if security show-keychain-info "$LOGIN_KC" >/dev/null 2>&1; then
    ok "unlocked"
  else
    bad "locked — run: security unlock-keychain \"$LOGIN_KC\""
  fi
  # A login keychain macOS renamed away after a password reset still holds the
  # old secrets, encrypted with the OLD account password.
  for stale in "$HOME"/Library/Keychains/login_renamed_*.keychain-db; do
    [ -e "$stale" ] && warn "stale keychain from a password reset: $(basename "$stale") (needs the OLD password)"
  done

  head_ "Stored items (service $SERVICE)"
  local accts
  accts="$(list_accounts || true)"
  if [ -z "$accts" ]; then
    bad "none — MyGit has no token, so pull requests can't load. Fix: ./fix-keychain.sh --add <host>"
  else
    while read -r a; do [ -n "$a" ] && ok "$a"; done <<< "$accts"
  fi

  head_ "App signature"
  if [ ! -x "$BIN" ]; then
    warn "$APP not built yet — run ./run.sh"
  else
    local info auth
    info="$(codesign -dvvv "$APP" 2>&1 || true)"
    auth="$(printf '%s\n' "$info" | awk -F= '/^Authority=/ {print $2}' | head -1)"
    if [ "$auth" = "MyGit Dev" ]; then
      ok "signed as \"MyGit Dev\" (stable designated requirement)"
    else
      warn "signed as \"${auth:-<adhoc/unsigned>}\" — the ACL is bound to the signing identity, so"
      warn "the keychain will re-prompt on every rebuild. Always launch via ./run.sh"
    fi
  fi
}

# Re-authorize existing items for the current app binary and clear the partition
# gate, so reads stop prompting.
fix() {
  security unlock-keychain "$LOGIN_KC"
  local accts
  accts="$(list_accounts || true)"
  [ -z "$accts" ] && { bad "no $SERVICE items to fix — use --add <host>"; return 1; }
  head_ "Re-authorizing"
  while read -r a; do
    [ -z "$a" ] && continue
    # -S ''  → any partition may read; the ACL still restricts which apps.
    if security set-generic-password-partition-list \
         -s "$SERVICE" -a "$a" -S "apple:,apple-tool:,codesign:" "$LOGIN_KC" >/dev/null 2>&1; then
      ok "$a — partition list updated"
    else
      warn "$a — partition update failed (wrong keychain password?)"
    fi
  done <<< "$accts"
  echo
  echo "Launch MyGit (./run.sh). If it still prompts once, click \"Always Allow\"."
}

# Store a token with the app pre-trusted, so the very first read is silent.
add() {
  local host="$1"
  [ -z "$host" ] && { bad "usage: ./fix-keychain.sh --add <host>   e.g. bitbucket.org"; return 1; }
  [ -x "$BIN" ] || { bad "$APP not built — run ./run.sh first"; return 1; }
  printf "Token for %s (input hidden): " "$host"
  local token; read -rs token; echo
  [ -z "$token" ] && { bad "empty token"; return 1; }
  security unlock-keychain "$LOGIN_KC"
  security delete-generic-password -s "$SERVICE" -a "$host" "$LOGIN_KC" >/dev/null 2>&1 || true
  security add-generic-password -s "$SERVICE" -a "$host" -w "$token" \
      -T "$BIN" -T /usr/bin/security -U "$LOGIN_KC"
  security set-generic-password-partition-list \
      -s "$SERVICE" -a "$host" -S "apple:,apple-tool:,codesign:" "$LOGIN_KC" >/dev/null 2>&1 || true
  ok "stored for $host, pre-authorized for $BIN"
}

reset() {
  security unlock-keychain "$LOGIN_KC"
  local accts; accts="$(list_accounts || true)"
  [ -z "$accts" ] && { warn "nothing to delete"; return 0; }
  head_ "Deleting"
  while read -r a; do
    [ -z "$a" ] && continue
    security delete-generic-password -s "$SERVICE" -a "$a" "$LOGIN_KC" >/dev/null 2>&1 \
      && ok "$a deleted" || warn "$a not deleted"
  done <<< "$accts"
  echo
  echo "Sign in again inside MyGit (avatar in the toolbar → Sign in… / Add token…)."
}

case "${1:-}" in
  ""|--check|--diagnose) diagnose ;;
  --fix)   diagnose; fix ;;
  --add)   add "${2:-}" ;;
  --reset) reset ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
