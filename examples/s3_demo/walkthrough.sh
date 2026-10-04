#!/usr/bin/env bash
# Runs the README walkthrough against a fresh prefix and verifies the restore.
set -euo pipefail
cd "$(dirname "$0")"
export S3_PREFIX="${S3_PREFIX:-walkthrough-$(date +%s)}"
export DATABASE_ENCRYPTION_KEY="${DATABASE_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

mix deps.get >/dev/null
mix setup >/dev/null

mix demo.write 100000 >"$log" 2>&1 &
writer=$!
sleep "${WRITE_SECONDS:-5}"
kill -9 "$writer"
wait "$writer" 2>/dev/null || true

acked=$(grep -c '^committed ' "$log" || true)
durable=$(sed -n 's/^committed \([0-9]*\) (durable)$/\1/p' "$log" | tail -1)
durable=${durable:-0}
echo "acknowledged commits before kill -9: $acked (the last durable one: $durable)"

mix demo.wipe
show="$(mix demo.show)"
restored=$(echo "$show" | sed -n 's/^\([0-9]*\) notes in the database$/\1/p')
echo "notes after restoring from S3: $restored"

# Async durability: every durable commit is restored, a few later ones may be
# lost, and at most one unacknowledged commit (in flight at the kill) shows up
if [ "$durable" -gt 0 ] && [ "$restored" -ge "$durable" ] &&
   [ "$restored" -le $((acked + 1)) ] && echo "$show" | grep -q '^no gaps$'; then
  echo "OK: every durable commit was restored, with no gaps ($((acked - restored > 0 ? acked - restored : 0)) acknowledged but not yet durable commits lost)"
else
  echo "FAILED"; exit 1
fi
