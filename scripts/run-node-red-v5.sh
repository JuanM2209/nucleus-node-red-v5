#!/bin/sh
# Create the Node-Red-V5 container next to the legacy nucleus-node-red one.
# Safe to re-run: it refuses to touch an existing container of the same name.
# Written as single-line docker commands: the Cockpit web terminal breaks "\" continuations.
set -eu

IMAGE="${IMAGE:-node-red:5.0.6-tyrion2-armv7}"
NAME="${NAME:-Node-Red-V5}"
PORT="${PORT:-1885}"
VOLUME="${VOLUME:-node-red-v5}"
MEM="${MEM:-400m}"

# RS-485 / Modbus serial line. Set SERIAL_PORT=none for a container with no
# serial access. The device is passed through only when it actually exists, so
# the same script works on a Nucleus without one.
SERIAL_PORT="${SERIAL_PORT:-/dev/ttymxc5}"
# gid of the group owning the serial device (dialout = 20 on the Nucleus BSP).
# The container runs as uid 1000 `node-red` and /dev/ttymxc5 is root:dialout
# crw-rw----, so without this the open() fails with EACCES.
SERIAL_GID="${SERIAL_GID:-20}"

FACTORY_SERIAL="/data/nucleus/factory/nucleus_serial_number"

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

# --- optional serial passthrough -------------------------------------------
SERIAL_ARGS=""
if [ "$SERIAL_PORT" != "none" ]; then
  if [ -c "$SERIAL_PORT" ]; then
    SERIAL_ARGS="--device=$SERIAL_PORT --group-add=$SERIAL_GID"
    echo "serial: passing through $SERIAL_PORT (group $SERIAL_GID)"
    # A serial line is exclusive. Warn rather than fail: the holder may be about
    # to release it, and the container can start before the port is needed.
    for p in /proc/[0-9]*; do
      if ls -l "$p/fd" 2>/dev/null | grep -q "$(basename "$SERIAL_PORT")"; then
        echo "WARNING: $SERIAL_PORT is open by PID ${p#/proc/} ($(cat "$p/comm" 2>/dev/null)). Only one process at a time can use it." >&2
      fi
    done
  else
    echo "serial: $SERIAL_PORT not present, skipping passthrough"
  fi
fi

# --- optional Nucleus identity ---------------------------------------------
# Mirrors the fleet run.sh: the Tyrion nodes read NUCLEUS_ID to identify the box.
ID_ARGS=""
if [ -r "$FACTORY_SERIAL" ]; then
  ID_ARGS="-e NUCLEUS_ID=$(cat "$FACTORY_SERIAL")"
  echo "identity: NUCLEUS_ID=$(cat "$FACTORY_SERIAL")"
fi

docker volume create "$VOLUME" >/dev/null

# shellcheck disable=SC2086  # SERIAL_ARGS / ID_ARGS are intentionally word-split
docker run -d --name "$NAME" --restart unless-stopped --network host -e PORT="$PORT" -e NODE_OPTIONS=--max-old-space-size=256 $ID_ARGS $SERIAL_ARGS --memory "$MEM" --memory-swap "$MEM" --log-driver journald -v "$VOLUME":/data "$IMAGE"

echo "started $NAME on port $PORT (image $IMAGE, volume $VOLUME)"
