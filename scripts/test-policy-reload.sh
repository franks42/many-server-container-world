#!/usr/bin/env bash
# Negative control for test.sh: proves the "deny" results come from the ACL,
# not from broken connectivity. Temporarily allows web->db, reloads headscale
# (SIGHUP), expects web->db to flip to 200, then restores the policy.
set -uo pipefail
cd "$(dirname "$0")/.."

policy=headscale/policy.hujson
backup=$(mktemp)
cp "$policy" "$backup"
restore() { cp "$backup" "$policy"; docker compose kill -s SIGHUP headscale >/dev/null 2>&1; rm -f "$backup"; }
trap restore EXIT

code() { docker compose exec -T web curl -s -m 12 -o /dev/null -w '%{http_code}' \
           http://127.0.0.1:8080/call/db; }

before=$(code); echo "before: web->db $before (want != 200)"

# Insert a rule allowing tag:web -> tag:db:80 right after the "acls" opener.
sed -i 's#"acls": \[#"acls": [\n    {"action": "accept", "src": ["tag:web"], "dst": ["tag:db:80"]},  // TEMP#' "$policy"
docker compose kill -s SIGHUP headscale >/dev/null

after=000
for i in $(seq 1 10); do sleep 2; after=$(code); [[ "$after" == 200 ]] && break; done
echo "after reload: web->db $after (want 200, took ~$((i*2))s)"

[[ "$before" != 200 && "$after" == 200 ]] && echo "ok" || { echo "FAIL"; exit 1; }
# Note: after restore, an already-open keep-alive connection is not reset —
# packets are just dropped, so the next call times out rather than erroring fast.
