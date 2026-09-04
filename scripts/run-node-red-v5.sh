#!/bin/sh
# Create the Node-Red-V5 container next to the legacy nucleus-node-red one.
# Safe to re-run: it refuses to touch an existing container of the same name.
# Written as single-line commands: the Cockpit web terminal breaks "\" continuations.
set -eu

IMAGE="${IMAGE:-node-red:5.0.6-tyrion-armv7}"
NAME="${NAME:-Node-Red-V5}"
PORT="${PORT:-1885}"
VOLUME="${VOLUME:-node-red-v5}"
MEM="${MEM:-400m}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE not present. Load it first: docker load -i nrv5.tar" >&2
  exit 1
fi

if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "container $NAME already exists (state: $(docker inspect -f '{{.State.Status}}' "$NAME")). Remove it first or pick another NAME." >&2
  exit 1
fi

if netstat -tln 2>/dev/null | grep -q ":$PORT "; then
  echo "port $PORT is already in use on the host" >&2
  exit 1
fi

docker volume create "$VOLUME" >/dev/null

docker run -d --name "$NAME" --restart unless-stopped --network host -e PORT="$PORT" -e NODE_OPTIONS=--max-old-space-size=256 --memory "$MEM" --memory-swap "$MEM" --log-driver journald -v "$VOLUME":/data "$IMAGE"

echo "started $NAME on port $PORT (image $IMAGE, volume $VOLUME)"
