#!/usr/bin/env bash
# One-time macOS (Apple Silicon) setup via Homebrew, then a full test run.
# Idempotent: safe to re-run. No sudo needed (Homebrew runs as you).
#
#   scripts/setup-mac.sh            # install/start, bring up, test
#   SKIP_TEST=1 scripts/setup-mac.sh
#
# Runtime: Colima (open source, CLI-only, Apple Virtualization.framework,
# native arm64 VM). If you already run OrbStack or Docker Desktop and
# `docker info` works, the Colima steps are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == Darwin ]] || { echo "macOS only"; exit 1; }
[[ "$(uname -m)" == arm64 ]]  || echo "warning: not Apple Silicon ($(uname -m))"
command -v brew >/dev/null || { echo "Homebrew not found: https://brew.sh"; exit 1; }

if docker info >/dev/null 2>&1; then
  say "a Docker runtime is already running ($(docker context show)); not touching it"
else
  say "brew install colima docker docker-compose docker-buildx"
  brew install colima docker docker-compose docker-buildx

  # Homebrew's docker CLI finds compose/buildx only via cli-plugins.
  mkdir -p ~/.docker/cli-plugins
  ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose
  ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx"   ~/.docker/cli-plugins/docker-buildx

  say "starting colima (arm64, vz, 4 CPU / 8 GB / 40 GB)"
  colima status >/dev/null 2>&1 || \
    colima start --arch aarch64 --vm-type vz --cpu 4 --memory 8 --disk 40
  docker context use colima >/dev/null
fi

say "brew install jq (openssl ships with macOS)"
command -v jq >/dev/null || brew install jq

say "versions"
docker version --format 'docker client {{.Client.Version}} / server {{.Server.Version}} ({{.Server.Arch}})'
docker compose version

say "bring up the test world"
scripts/up.sh

say "image architecture (want arm64)"
for img in msw-node headscale/headscale:v0.29.7; do
  printf '  %-30s %s\n' "$img" "$(docker image inspect "$img" --format '{{.Architecture}}')"
done

if [[ -z "${SKIP_TEST:-}" ]]; then
  say "tests"
  scripts/test.sh
  scripts/test-policy-reload.sh
fi
