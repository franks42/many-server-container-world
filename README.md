# many-server-container-world

A throwaway, fully offline tailnet on one machine: a **Headscale** control
server plus N "servers", each a container running a **babashka app behind its
own Go `tsnet` proxy** with a Tailscale tag identity. Built to test tag-to-tag
ACLs and identity propagation before touching a real tailnet.

```
             ┌──────────── docker network (one Linux VM / host) ────────────┐
             │                                                              │
             │   headscale  (control plane + embedded DERP/STUN, TLS via    │
             │               a local throwaway CA, policy.hujson)           │
             │                                                              │
             │   ┌─ web (tag:web) ─┐   ┌─ api (tag:api) ─┐   ┌─ db (tag:db) ─┐
             │   │ bb app :8080 lo │   │ bb app :8080 lo │   │ bb app        │
             │   │ tsproxy         │──▶│ tsproxy         │──▶│ tsproxy       │
             │   └─────────────────┘   └─────────────────┘   └───────────────┘
             │        + api-pool-* replicas (tag:api), `--scale` as many as you like
             └──────────────────────────────────────────────────────────────┘
```

Each node container runs two processes:

- **app/server.clj**: babashka/http-kit, listening on **loopback only**.
  `GET /` returns its role plus who called it. `GET /call/<peer>` calls a
  peer through the egress proxy.
- **tsproxy** (Go, `tailscale.com/tsnet`), fully userspace, so no TUN device,
  no `NET_ADMIN`, and the container runs with `cap_drop: ALL`.
  - *Ingress:* tailnet `:80` forwards to the app. The caller's identity comes
    from `WhoIs` and is injected as `X-Tailnet-Node`, `X-Tailnet-Tags` and
    `X-Tailnet-User`. Client-supplied `X-Tailnet-*` headers are stripped first.
  - *Egress:* `127.0.0.1:9000/<peer>/<path>` goes to `http://<peer>/<path>` over
    the tailnet. Bare names are expanded to the MagicDNS FQDN (see Gotchas).

## Run

**macOS quick start:** `scripts/setup-mac.sh` installs Colima, the Docker CLI,
Compose and `jq` with Homebrew (no sudo), starts an arm64 VM, brings up the
world and runs the tests. It skips the runtime setup if `docker info`
already works, e.g. with OrbStack.

Needs Docker with Compose v2, `jq` and `openssl`. On a Mac, use OrbStack,
Colima or Docker Desktop; everything runs in their one Linux VM, with no
nested virtualization.

**Native on Apple Silicon.** All three base images publish `linux/arm64`
builds (checked 2026-11: `headscale/headscale:v0.29.7`, `golang:1.27-alpine`,
`babashka/babashka:latest`), and tsproxy is compiled in the build stage for
the building platform. Nothing pins `--platform`, so on an M-series Mac
everything runs as arm64 with no Rosetta or QEMU emulation. Verify with
`docker image inspect msw-node --format '{{.Architecture}}'`, which should
print `arm64`.

```sh
scripts/up.sh                       # CA + headscale + tagged keys + web/api/db
scripts/test.sh                     # ACL matrix, identity, spoofing, bypass
scripts/test-policy-reload.sh       # negative control: flip a rule live
SCALE=20 scripts/up.sh              # ...plus 20 api-pool replicas
scripts/down.sh                     # wipe everything (fresh tailnet next time)

docker compose exec web curl -s localhost:8080/call/api | jq   # poke around
docker compose --profile headscale exec headscale headscale nodes list
TS_VERBOSE=1 docker compose up -d web                          # tailscaled-level logs
```

Expected `scripts/test.sh` output:

```
ACL matrix (policy: web->api, api->db)
  ok    web  -> api  allow (200, tries=1)
  ok    api  -> db   allow (200, tries=1)
  ok    web  -> db   deny  (502, tries=1)
  ok    db   -> api  deny  (502, tries=1)
  ok    api  -> web  deny  (502, tries=1)
  ok    db   -> web  deny  (502, tries=1)
Identity propagation
  ok    api saw caller tags = tag:web
Header spoofing
  ok    spoofed header replaced (saw tag:web)
Bypass
  ok    api app not reachable off-tailnet
passed=9 failed=0
```

## Policy

`headscale/policy.hujson` defines a three-tier chain: `web → api:80 → db:80`.
Edit it, then `docker compose kill -s SIGHUP headscale`. The change reaches
nodes within about 2 s; `test-policy-reload.sh` measures this.

## Against real Tailscale (fidelity check)

Headscale isn't Tailscale. Tag ACLs and `WhoIs` behave the same here, but
newer features (grants, app capabilities) may differ. To run the same nodes
against your real tailnet, create **ephemeral, pre-approved, tagged** auth keys
in the admin console and add the tags to your tailnet policy's `tagOwners`.
Then:

```sh
cat > .env <<EOF
COMPOSE_PROFILES=
TS_CONTROL_URL=
MSW_CA_FILE=
TS_AUTHKEY_WEB=tskey-auth-...
TS_AUTHKEY_API=tskey-auth-...
TS_AUTHKEY_DB=tskey-auth-...
EOF
docker compose up -d --build web api db && scripts/test.sh
```

**Result (2026-11-17, Frank's tailnet):** 9/9 after the egress fix (gotcha 8),
plus a manual negative control: adding a `tag:web → tag:db` grant made
`web → db` return 200 as `tag:web`, and removing it brought back the deny. Same
as Headscale:
- `X-Tailnet-User` is `tagged-devices` for tagged nodes.
- Node names are clean (`web`, `api`, `db`).
- Connections are direct.

Differences:
- Nodes joined in about 3 s.
- The first `web → api` call succeeded on the first try.
- Policy changes reached nodes within seconds.

## Gotchas found while building this (each one cost a debugging round)

1. **No reachable DERP means about a minute before the first packet.** Peers
   know each other's direct endpoints, but the disco handshake bootstraps via
   DERP. With an unreachable relay, nodes on the same LAN still took around 60 s
   to connect. Hence the embedded DERP, and TLS is required for it.
2. **Short names can resolve to the wrong network.** In Compose, `api` is also
   the container's Docker DNS name, so a bare name can reach the container
   directly instead of going over the tailnet. tsproxy always expands names to
   `api.world.test`.
3. **Restarting with fresh state renames the node.** The old ephemeral entry
   keeps `api` for the inactivity timeout (2 m here), so the restarted node
   becomes `api-1`. Fixed nodes keep tsnet state in named volumes. Replicas use
   tmpfs, since their names are unique anyway.
4. **Host `SSL_CERT_FILE` leaks in.** Interpolating `${SSL_CERT_FILE}` in
   Compose picks up the host's value. The project uses `MSW_CA_FILE` instead.
5. **Single-file bind mounts go stale.** `sed -i` and most editors replace the
   file with a new inode, so a mounted `policy.hujson` would never change in the
   container. The whole `headscale/` directory is mounted instead.
6. **Revoking access drops traffic silently.** After a rule is removed, an
   already-open keep-alive connection isn't reset; it just hangs until a
   timeout. Your proxy and app timeouts are what bound this.
7. **A deny looks like a timeout.** Tailscale drops denied packets, so a deny
   shows up as a dial timeout (5 s in tsproxy), not "connection refused". That's
   why the negative-control test exists: without it, a broken tailnet would pass
   every deny check. Since the fix in gotcha 8, a target that isn't a peer at all
   (no rule in either direction) is refused at once instead.
8. **tsnet's `Dial` falls back to the host network.** Control only tells a node
   about peers it shares a rule with. For any other target, `tsnet.Server.Dial`
   quietly uses the host's network stack. If the host is itself on the tailnet,
   as Frank's Mac is, the call goes out through the host's Tailscale and arrives
   as the *host's* identity. Here that let `web → db` through as `fs-mbp14`. On
   Headscale the fallback failed fast instead (the OS resolver can't resolve
   `*.world.test`), so it looked like a correct deny. tsproxy now resolves the
   target against its own peer list (`LocalClient.Status`) and dials only that peer's Tailscale IP.
9. **The Tailscale admin console rejected a `tests` block.** A valid HuJSON
   `"tests": [...]` (tag sources, `accept`/`deny` with `tag:x:80`) was rejected
   with `invalid literal` at the first `"deny"`. The policy saved fine without
   it. The reason is unknown, so the real-tailnet policy has no `tests`.
10. **Copying long lines from a terminal can insert hard line breaks.** That
    breaks JSON strings. To move policy text, use `pbcopy < file` instead.

## What's deliberately not here (yet)

- **NAT and topology:** all nodes share one Docker network, so connections are
  always direct. For NAT traversal and DERP fallback, put nodes on separate
  networks behind NAT router containers, e.g. with containerlab.
- **Faults:** `tc netem` needs `NET_ADMIN` in the node, or use Pumba or Toxiproxy.
- **Untrusted code:** set `runtime: runsc` (gVisor) on a service.
- **TLS between nodes:** traffic runs over WireGuard, but node-to-node HTTP is
  plain. Headscale can't issue `ListenTLS` certificates the way Tailscale's
  HTTPS feature does.

Tested with Headscale v0.29.7, tailscale.com v1.104.7, Go 1.27 and
Babashka 1.13. Bringing up 23 nodes took about 10 s and roughly 1.4 GB of RAM in
total on a 2-vCPU Linux VM.

## License

Eclipse Public License 2.0 — see [LICENSE](LICENSE).
