#!/bin/bash

REMOTE_NAME="$1"
REMOTE_URL="$2"

if [ -z "$REMOTE_URL" ]; then
  REMOTE_URL=$(git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")
fi

# --- Config ---
WHITELIST_FILE="$(dirname "$0")/whitelist.txt"
SENTRY_URL="https://sentry.gem-corp.tech/api/7/store/"
SENTRY_KEY="c04662ba996ca859544095fa54b7d05b"
DEBUG=true   # Enable debug output

# --- Metadata ---
USER_OS=$(whoami)
GIT_USER=$(git config user.name)
GIT_EMAIL=$(git config user.email)
EXPECTED_REPO_URL=$(git remote get-url origin 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")

# ======================================================
# Send Sentry notification
# ======================================================
send_sentry_notification() {
  local payload=$(cat <<EOF
{
  "message": "❌ Unauthorized Git push attempt detected",
  "level": "error",
  "logger": "global.pre-push.hook",
  "platform": "bash",
  "extra": {
    "os_user": "$USER_OS",
    "git_user": "$GIT_USER",
    "git_email": "$GIT_EMAIL",
    "unauthorized_repo": "$REMOTE_URL",
    "expected_repo": "$EXPECTED_REPO_URL",
    "timestamp": "$TIMESTAMP"
  }
}
EOF
  )
  # curl -s -X POST "$SENTRY_URL" \
  #   -H "Content-Type: application/json" \
  #   -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=curl/1.0, sentry_key=$SENTRY_KEY" \
  #   -d "$payload" >/dev/null 2>&1
}

# ======================================================
# Normalize Git URL to "domain/org/repo"
# ======================================================
normalize_url() {
  local url="$1"
  echo "$url" | sed -E '
    s#(ssh://|git@|https://|http://)##;  # strip protocols
    s#:#/#;                              # convert : to /
    s#^[^@]+@##;                         # drop username@
    s#//#/#g;                            # collapse double slashes
    s#\.git$##;                          # remove .git
  ' | tr -d '\r' | xargs
}

# ======================================================
# Check whitelist existence
# ======================================================
if [ ! -f "$WHITELIST_FILE" ]; then
  echo "⚠️ Whitelist not found at $WHITELIST_FILE"
  exit 1
fi

# ======================================================
# Normalize remote
# ======================================================
NORMALIZED_REMOTE=$(normalize_url "$REMOTE_URL")

if [ "$DEBUG" = true ]; then
  echo "=== DEBUG INFO ==="
  echo "Remote name: $REMOTE_NAME"
  echo "Original remote URL: $REMOTE_URL"
  echo "Normalized remote: $NORMALIZED_REMOTE"
  echo "Whitelist file: $WHITELIST_FILE"
  echo "=================="
fi

AUTHORIZED=0

# ======================================================
# Check whitelist
# ======================================================
while IFS= read -r line || [ -n "$line" ]; do
  line=$(echo "$line" | tr -d '\r' | xargs)
  [[ -z "$line" || "$line" == \#* ]] && continue

  NORMALIZED_LINE=$(normalize_url "$line")

  if [ "$DEBUG" = true ]; then
    echo "Checking whitelist entry: '$line' -> '$NORMALIZED_LINE'"
  fi

  # Wildcard support
  if [[ "$NORMALIZED_LINE" == *"*"* ]]; then
    PATTERN="^${NORMALIZED_LINE//\*/.*}$"
    if [[ "$NORMALIZED_REMOTE" =~ $PATTERN ]]; then
      AUTHORIZED=1
      $DEBUG && echo "MATCH via wildcard: $PATTERN"
      break
    fi
  # Exact or fuzzy match
  elif [[ "$NORMALIZED_REMOTE" == "$NORMALIZED_LINE" ]] || \
       [[ "$NORMALIZED_REMOTE" == */"$NORMALIZED_LINE" ]] || \
       [[ "$NORMALIZED_REMOTE" == "$NORMALIZED_LINE"/* ]]; then
    AUTHORIZED=1
    $DEBUG && echo "MATCH via exact/fuzzy: $NORMALIZED_LINE"
    break
  fi
done < "$WHITELIST_FILE"

if [ "$DEBUG" = true ]; then
  echo "AUTHORIZED = $AUTHORIZED"
fi

# ======================================================
# Block unauthorized pushes
# ======================================================
if [ $AUTHORIZED -ne 1 ]; then
  echo "❌ Push to unauthorized repo '$REMOTE_NAME' blocked!"
  echo "   URL: $REMOTE_URL"
  echo "   Normalized: $NORMALIZED_REMOTE"
  echo ""
  echo "🔒 Allowed repositories (whitelist):"
  cat "$WHITELIST_FILE"
  # send_sentry_notification
  exit 1
fi

# ======================================================
# Run local pre-push if exists
# ======================================================
LOCAL_HOOK=".git/hooks/pre-push.local"

if [ -x "$LOCAL_HOOK" ]; then
  echo "[Global Hook] Running local pre-push hook from $LOCAL_HOOK..."
  "$LOCAL_HOOK" "$@"
  LOCAL_STATUS=$?
  if [ $LOCAL_STATUS -ne 0 ]; then
    echo "[Global Hook] Local pre-push hook failed (exit code $LOCAL_STATUS)."
    exit $LOCAL_STATUS
  fi
else
  echo "[Global Hook] No local pre-push hook found — continuing."
fi

exit 0
