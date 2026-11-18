#!/usr/bin/env bash
# Tear everything down, including the headscale database (fresh tailnet next time).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose --profile headscale --profile scale down -v --remove-orphans
rm -f .env
