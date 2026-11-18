#!/usr/bin/env bash
# Checks the tag ACL matrix and identity propagation.
# Each check asks node A's app to call node B through A's tsproxy.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
call() { docker compose exec -T "$1" curl -s -o /tmp/out -w '%{http_code}' \
           "http://127.0.0.1:8080/call/$2"; }

expect() {  # expect <from> <to> allow|deny
  # "allow" gets up to 3 tries: the very first packet to a peer may wait on
  # path discovery. "deny" gets one try (a deny is a silent drop => timeout).
  local code tries=1; code=$(call "$1" "$2")
  while [[ "$3" == allow && "$code" != 200 && $tries -lt 3 ]]; do
    tries=$((tries+1)); code=$(call "$1" "$2"); done
  local ok=0
  [[ "$3" == allow && "$code" == 200 ]] && ok=1
  [[ "$3" == deny  && "$code" != 200 ]] && ok=1
  if (( ok )); then pass=$((pass+1)); printf '  ok    %-4s -> %-4s %-5s (%s, tries=%s)\n' "$1" "$2" "$3" "$code" "$tries"
  else fail=$((fail+1)); printf '  FAIL  %-4s -> %-4s want %-5s got %s\n' "$1" "$2" "$3" "$code"
       docker compose exec -T "$1" cat /tmp/out; echo; fi
}

echo "ACL matrix (policy: web->api, api->db)"
expect web api allow
expect api db  allow
expect web db  deny
expect db  api deny
expect api web deny
expect db  web deny

echo "Identity propagation"
body=$(docker compose exec -T web curl -s http://127.0.0.1:8080/call/api)
tags=$(jq -r '.["peer-body"].caller.tags | join(",")' <<<"$body")
if [[ "$tags" == "tag:web" ]]; then pass=$((pass+1)); echo "  ok    api saw caller tags = $tags"
else fail=$((fail+1)); echo "  FAIL  api saw caller tags = '$tags'"; echo "$body"; fi

echo "Header spoofing"
# A caller-supplied X-Tailnet-Tags must be overwritten by tsproxy.
spoof=$(docker compose exec -T web sh -c \
  'curl -s -H "X-Tailnet-Tags: tag:db" http://127.0.0.1:9000/api/' | jq -r '.caller.tags | join(",")')
if [[ "$spoof" == "tag:web" ]]; then pass=$((pass+1)); echo "  ok    spoofed header replaced (saw $spoof)"
else fail=$((fail+1)); echo "  FAIL  spoofed header leaked: '$spoof'"; fi

echo "Bypass"
# The app listens on loopback only; other containers can't reach it directly.
if docker compose exec -T web curl -s -m 3 http://api:8080/ >/dev/null 2>&1; then
  fail=$((fail+1)); echo "  FAIL  web reached api:8080 without the tailnet"
else pass=$((pass+1)); echo "  ok    api app not reachable off-tailnet"; fi

echo; echo "passed=$pass failed=$fail"
(( fail == 0 ))
