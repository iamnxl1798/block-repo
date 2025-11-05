#!/bin/bash

REMOTE_NAME="$1"
REMOTE_URL="$2"

if [ -z "$REMOTE_URL" ]; then
  REMOTE_URL=$(git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")
fi
# --- Configurable paths ---
WHITELIST_FILE="$HOME/.git/hooks/whitelist.txt"
SENTRY_URL="https://sentry.gem-corp.tech/api/7/store/"
SENTRY_KEY="c04662ba996ca859544095fa54b7d05b"

# --- Collect environment info ---
USER_OS=$(whoami)
GIT_USER=$(git config user.name)
GIT_EMAIL=$(git config user.email)
EXPECTED_REPO_URL=$(git remote get-url origin 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")

# --- Helper: Send notification to Sentry ---
send_sentry_notification() {
  local payload=$(cat <<EOF
{
  "message": "❌ Unauthorized Git push attempt detected",
  "level": "error",
  "logger": ".prepush.hook",
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

  curl -s -X POST "$SENTRY_URL" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=curl/1.0, sentry_key=$SENTRY_KEY" \
    -d "$payload" >/dev/null 2>&1
}

# --- Check whitelist existence ---
if [ ! -f "$WHITELIST_FILE" ]; then
  echo "⚠️  Whitelist file not found at $WHITELIST_FILE"
  echo "   Create it with one allowed GitHub repo per line."
  exit 1
fi

# --- Check if remote URL is in whitelist ---
NORMALIZED_URL=$(echo "$REMOTE_URL" | sed -E 's#(git@|ssh://git@|https://|http://)##; s#:#/#')
AUTHORIZED=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue  # skip empty or comment lines
  if [[ "$NORMALIZED_URL" == *"$line"* ]]; then
    AUTHORIZED=1
    break
  fi
done < "$WHITELIST_FILE"

if [ $AUTHORIZED -ne 1 ]; then
  echo "❌ Push to unauthorized repo '$REMOTE_NAME' blocked!"
  echo "   URL: $REMOTE_URL"
  echo "   Expected: $EXPECTED_REPO_URL"

  send_sentry_notification
  exit 1
fi

# --- Run local repo pre-push hook if exists ---
LOCAL_HOOK=".git/hooks/pre-push"

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
