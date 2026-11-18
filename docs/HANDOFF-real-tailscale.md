# Handoff: fidelity run against the real tailnet

**Goal:** run `web`, `api` and `db` against Frank's real Tailscale tailnet
instead of the local Headscale, and get the same results from
`scripts/test.sh`. That tells us Headscale's tag-ACL and WhoIs behavior
matches production Tailscale, so the faster offline loop can be trusted.

**Status:** done (2026-11-17). On the real tailnet, 9/9 pass and the manual
negative control passes. That needed an egress fix in tsproxy (README
gotcha 8). Headscale is green again with the fix (9/9 plus policy reload).
Frank revoked the three auth keys the same day.

## Why this moved to Claude Code

The earlier work happened in a Claude chat session running in a cloud
sandbox. It could write files on the Mac but couldn't run Docker or `brew`
there, so Frank had to run every command himself. Claude Code runs on the
Mac directly.

## Plan

### 0. Preflight (read-only)
- `colima status` and `docker info` work.
- Show Frank his current tailnet policy (he pastes it from the admin
  console's Access controls page, or exports it) and check two things:
  - **Allow-all rule** (`src ["*"] → dst ["*:*"]`, or the equivalent
    grant): with one, the four deny checks will (correctly) fail. Discuss
    with him before changing anything.
  - **Device names** `web`, `api`, `db` already in use: the test nodes would
    register as `web-1` etc. and the tests would hit the wrong devices.
    If so, rename via `TS_HOSTNAME` in `compose.yaml` and the peer names in
    `scripts/test.sh`, or have Frank rename his devices.
  - **MagicDNS** must be on (tsproxy expands bare names with the MagicDNS
    suffix).

### 1. Policy (Frank applies it, or OKs the exact diff)
Merge, don't replace:
```hujson
"tagOwners": {
  "tag:web": ["autogroup:admin"],
  "tag:api": ["autogroup:admin"],
  "tag:db":  ["autogroup:admin"],
},
// acls form:
{"action": "accept", "src": ["tag:web"], "dst": ["tag:api:80"]},
{"action": "accept", "src": ["tag:api"], "dst": ["tag:db:80"]},
// or, if the policy uses grants:
{"src": ["tag:web"], "dst": ["tag:api"], "ip": ["80"]},
{"src": ["tag:api"], "dst": ["tag:db"], "ip": ["80"]},
```

### 2. Auth keys (Frank creates them)
Settings → Keys: three keys, one per tag (`tag:web`, `tag:api`, `tag:db`),
each **reusable**, **ephemeral** and **pre-approved**, expiring in 1 day.

### 3. Switch the stack
```sh
scripts/down.sh          # REQUIRED: per-node volumes still hold headscale state
```
Do **not** run `scripts/up.sh` afterwards; it overwrites `.env` with
Headscale keys. Write `.env` instead (the empty values matter):
```sh
COMPOSE_PROFILES=
TS_CONTROL_URL=
MSW_CA_FILE=
TS_AUTHKEY_WEB=tskey-auth-...
TS_AUTHKEY_API=tskey-auth-...
TS_AUTHKEY_DB=tskey-auth-...
```
- `TS_CONTROL_URL=` (empty) makes tsnet use Tailscale's control server
  (compose uses `${VAR-default}`, so empty is respected).
- `MSW_CA_FILE=` (empty) makes Go use the normal system roots instead of the
  test CA.
- `COMPOSE_PROFILES=` (empty) means no headscale container
  (`depends_on ... required: false`).

### 4. Run
```sh
docker compose up -d --build web api db
docker compose logs web | tail      # expect "joined tailnet as web [100.x...]"
scripts/test.sh
```
**Negative control:** `test-policy-reload.sh` only works with Headscale.
Instead, have Frank add a temporary `tag:web → tag:db:80` rule in the admin
console, then check that
`docker compose exec web curl -s localhost:8080/call/db` changes from 502 to
200. Then remove the rule. Without this, passing deny checks prove nothing.

### 5. Clean up
```sh
docker compose down -v && rm .env
```
Frank revokes the three keys and removes the temporary rules. The ephemeral
nodes disappear on their own once offline.

### 6. Back to the offline loop
`scripts/up.sh && scripts/test.sh`

## What to report back

- The `scripts/test.sh` output, plus the negative-control result.
- Any difference from Headscale: what `X-Tailnet-User` shows for tagged
  nodes (Headscale: `tagged-devices`), node naming, how long the first
  connection takes, and whether connections are direct or relayed (DERP)
  (`TS_VERBOSE=1`).
- If something differs, add it to the README's Gotchas list.

## Likely failure modes

| Symptom | Likely cause |
|---|---|
| node never prints "joined tailnet" | key not pre-approved while device approval is on; tag missing from `tagOwners`; key expired |
| x509 errors | `MSW_CA_FILE` not empty, so it still trusts only the test CA |
| nodes try `https://headscale:8443` | `TS_CONTROL_URL` not set to empty in `.env`, or old volumes (skipped `down.sh`) |
| deny checks fail (200) | broad allow rule in the tailnet policy |
| allow checks fail | ACL rule not saved or wrong port; MagicDNS off; name clash (`api-1`) |

## Later ideas (not started)

- NAT and DERP fallback: nodes on separate networks behind NAT routers
  (containerlab).
- Fault injection: netem, Pumba or Toxiproxy for latency, packet loss and
  partitions (watch how the proxy's timeouts behave on revoked connections).
- gVisor (`runtime: runsc`) for nodes that run untrusted or agent-written
  code.
- Replace the toy `app/server.clj` with Frank's real bb services.
- OAuth run on the real tailnet: one OAuth client per role (`auth_keys`
  scope, one tag each), `TS_CLIENT_SECRET_*` in `.env`, no hand-made keys.
  The tsproxy side is done but untested.
- Control-outage test (`test-control-outage.sh`). Steps: stop headscale,
  confirm `web → api` still works, remove the rule and confirm it does *not*
  take effect, restart one node and see whether it recovers without
  control, then restart headscale and measure how long revocation takes.
- Fail-closed tsproxy: refuse ingress (or only sensitive operations) after
  N minutes without contact with control.
- Scale test: `SCALE=200`+ `api-pool` replicas. Measure netmap size,
  Headscale memory and policy-reload time to every node.
- App capabilities: tsproxy forwards `WhoIs` `CapMap` as a header
  (e.g. `X-Tailnet-Caps`). Test a grant with an `app` section on Headscale
  (is it supported?) and on the real tailnet.
- Role proxy with audit (`docs/tailnet-map.html` section 8): an
  `admin-proxy` service, `X-Tailnet-On-Behalf-Of`, and a
  `TRUSTED_FORWARDERS` tag list on the receiving tsproxy.
- Self-asserted key bindings (`docs/tailnet-map.html` sections 9 and 10):
  tsproxy makes a keypair and sends a self-signed `{id, key, t}` binding on
  first contact. The receiving tsproxy accepts it only if the WhoIs identity
  of the connection matches `id`, then caches key → identity with a TTL.
  Delegation assertions signed with that key (`sub`, `act`, `aud`, `exp`)
  can then travel through `staff-proxy`. Test the HR case: staff see only
  their own record, and a compromised proxy can't switch `sub`. Also try a
  relayed binding (SDSI-style, vouched for by a party that saw it
  first-hand), and compare with tsidp token exchange (`TSIDP_ENABLE_STS=1`).
  Wire format (HTTP headers; deliberately not `X-Tailnet-*`, which
  ingress strips as spoofable):
  - `Tailnet-Key-Binding`: the client's self-signed JWS `{id, key, t}`
    (Ed25519), sent on every request. Ingress verifies it, checks `id`
    against WhoIs and caches thumbprint → identity.
  - `X-Tailnet-Key`: ingress → its own app over loopback, the verified key
    thumbprint. A plain header is fine inside that trust boundary.
  - `Tailnet-Assertion`: the delegation JWS `{sub, act, aud, exp}` signed
    with the client's key. `act` must match the WhoIs caller at the
    receiving hop.
  - `Tailnet-Binding-Witness`: a forwarding proxy's signed observation
    `{binding: hash, observed: <WhoIs id>, t}`, signed with the proxy's own
    key, for receivers that never met the client. They learn the proxy's
    key from their own direct connection to it and decide whether to trust
    it as a witness.
