#!/bin/sh
# Runs the bb app and tsproxy in one container. If either dies, the container
# exits (and compose restarts it), so a node is never half-up.
set -e
bb /app/server.clj &
APP=$!
tsproxy &
PROXY=$!
# Wait for whichever exits first, then take the other down with it.
while kill -0 "$APP" 2>/dev/null && kill -0 "$PROXY" 2>/dev/null; do sleep 1; done
kill "$APP" "$PROXY" 2>/dev/null || true
exit 1
