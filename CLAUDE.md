# many-server-container-world: notes for Claude Code

Throwaway, offline tailnet for testing **Tailscale tag ACLs and identity
propagation** between many "servers" on one machine. Headscale is the control
server, and each node is a container running a babashka app behind its own Go
`tsnet` proxy. Read `README.md` for the architecture and the full list of
gotchas; this file covers how to work in the repo.

Owner: Frank (franks42). This is the test bed for his "bb apps as their own
tailnet nodes via a tsnet reverse proxy" design: TLS and identity at the
proxy, identity forwarded in HTTP headers, tag identities on both client and
server.

## Environment (Frank's Mac)

- Apple Silicon, macOS, **Homebrew is the preferred installer**. No sudo is
  needed for anything here; ask Frank if something truly needs it.
- Docker runtime: **Colima** (installed by `scripts/setup-mac.sh`), arm64 VM
  on the `vz` backend. Docker context is `colima`. After a reboot, run
  `colima start`.
- All images are native arm64. Never add `--platform linux/amd64`.
- macOS userland is BSD: use `perl -pi`, not `sed -i` (that already broke one
  script). Avoid `readlink -f`, `date -d` and `grep -P`.

## Commands

```sh
scripts/setup-mac.sh          # one-time: brew + colima, then up + tests
scripts/up.sh                 # CA, headscale, tagged keys -> .env, web/api/db
SCALE=20 scripts/up.sh        # plus 20 api-pool replicas
scripts/test.sh               # 9 checks: ACL matrix, identity, spoofing, bypass
scripts/test-policy-reload.sh # negative control (edits headscale/policy.hujson, restores it)
scripts/down.sh               # wipe containers, volumes, .env
TS_VERBOSE=1 docker compose up -d web   # tailscaled-level logs
docker compose --profile headscale exec headscale headscale nodes list
```

## Layout

- `tsproxy/main.go`: ingress (tailnet :80 to app, WhoIs headers, strips any
  spoofed `X-Tailnet-*`) and egress (`127.0.0.1:9000/<peer>/<path>`)
- `app/server.clj`: bb http-kit app on loopback only
- `headscale/`: `config.yaml` (TLS, embedded DERP) and `policy.hujson`. The
  whole directory is bind-mounted; keep it that way (single-file mounts go
  stale)
- `compose.yaml`: node anchor, per-node state volumes, `api-pool` scale
  profile
- `.env` and `certs/` are generated and git-ignored. **Never commit them.**

## Verified state (2026-11-17)

- Cloud Linux x86 sandbox: 9/9 checks plus the policy-reload check pass;
  23 nodes come up in about 10 s.
- Frank's Mac (arm64, Colima): 9/9 plus the policy-reload check pass
  (reload takes about 2 s). The first `web -> api` call needs 2 tries
  (first-packet path discovery); that's expected.

## Rules for working here

- Run the tests after any change to `tsproxy/`, `compose.yaml`, `headscale/`
  or `scripts/`. "Deny" results only mean something if the negative control
  (`test-policy-reload.sh`) also passes.
- **Real tailnet:** never change Frank's Tailscale policy, keys or devices
  without first showing the exact diff and getting his OK. Auth keys go only
  in `.env`, never in git, the chat, or logs you print.
- Commit and push only when Frank asks.

## Current task

See `docs/HANDOFF-real-tailscale.md`: run the same nodes against Frank's real
tailnet as a fidelity check of Headscale's behavior.
