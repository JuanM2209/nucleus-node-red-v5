# Nucleus Node-RED V5 sidecar

Run **the newest Node-RED (5.0.6, Node.js 22)** side by side with the legacy
`nucleus-node-red` container (Node-RED 0.20.8 / Node.js 8) on a Nucleus edge
device, without touching the production instance.

| Instance | Container | Image | Port | Data |
|---|---|---|---|---|
| Legacy (production) | `nucleus-node-red` | `tyrionintegration/nucleus-node-red` | 1880 | volume `node-red` |
| New | `Node-Red-V5` | `node-red:5.0.6-22-armv7` (built here) | **1885** | volume `node-red-v5` |

Both use `--network host`, so the new instance is reachable on the device at
`http://<device-ip>:1885` and can be exposed through the Nucleus portal like
any other port.

## Why it is not a plain `docker pull`

The Nucleus i.MX7 devices run **Docker 18.03 on a 32-bit ARM (armv7l)** with
kernel 4.9. Two things get in the way:

1. **No official Node-RED 5.x image ships an `arm/v7` build.** Every `5.0.x`
   tag is `amd64` + `arm64` only, because 5.x defaults to a `node:24` base and
   Node 24 dropped 32-bit ARM. The last official arm/v7 image is the `4.1.x`
   line. So the 5.0.6 image here is **built locally** with
   [`image/build-armv7.sh`](image/build-armv7.sh), using the project's own
   unmodified `Dockerfile.custom` on a `node:22-alpine` base (Node-RED 5
   requires `node >= 22.9`, which node 22 satisfies).
2. **Docker 18.03 cannot pull OCI-format images.** Node-RED images are now
   published as OCI image indexes; the old daemon fails with
   `Error response from daemon: missing signature key` (pulling by digest
   fails the same way). `docker load` of a classic docker-archive tar still
   works, so the image is repacked with
   [`tools/pull-docker-archive.py`](tools/pull-docker-archive.py) and loaded
   on the device.

See [docs/DIAGNOSTIC.md](docs/DIAGNOSTIC.md) for the full device diagnostic.

## Quick start

On any machine with Python 3 (no Docker needed):

```bash
# repack an image that already exists on Docker Hub for arm/v7 (e.g. the 4.1.x line)
python3 tools/pull-docker-archive.py nodered/node-red 4.1.14-22 arm v7 out.tar
```

To build Node-RED 5.x for arm/v7 yourself you need Docker with buildx and QEMU
(Docker Desktop has both):

```bash
cd image && sh build-armv7.sh
docker save node-red:5.0.6-22-armv7 -o nodered-5.0.6-22-armv7.tar
```

A pre-built archive is attached to the GitHub release
`nodered-5.0.6-22-armv7` of this repo.

On the device (Cockpit terminal or SSH, run as a user in the `docker` group):

```bash
cd /data
curl -L -o nrv5.tar https://github.com/JuanM2209/nucleus-node-red-v5/releases/download/nodered-5.0.6-22-armv7/nodered-5.0.6-22-armv7.tar
sha256sum nrv5.tar          # compare with the release notes
docker load -i nrv5.tar
sh scripts/run-node-red-v5.sh
rm nrv5.tar
```

`scripts/run-node-red-v5.sh` is a one-liner-safe script (the Cockpit terminal
breaks `\` line continuations, so it is written on one line inside the file).

## What the run command does

```bash
docker run -d --name Node-Red-V5 --restart unless-stopped --network host \
  -e PORT=1885 -e NODE_OPTIONS=--max-old-space-size=256 \
  --memory 400m --memory-swap 400m --log-driver journald \
  -v node-red-v5:/data node-red:5.0.6-22-armv7
```

* `--network host` + `PORT=1885`: the official image's `settings.js` reads
  `uiPort` from `PORT`. Host networking mirrors the legacy container and keeps
  serial / localhost services reachable.
* `--memory 400m`: the device has 1 GB RAM. The cap protects the production
  Node-RED from a runaway flow in the new instance.
* `--restart unless-stopped`: comes back after a reboot, but a deliberate
  `docker stop Node-Red-V5` sticks (unlike the `always` policy used by the
  production container).
* `-v node-red-v5:/data`: separate named volume; nothing is shared with the
  legacy instance.
* No `--device` / `--group-add`: the new instance does not get the serial
  port or USB printer by default. Add `--device /dev/ttymxc5 --group-add 20`
  only if the flow needs it, and never let both instances open the same
  serial port at the same time.

## Verify

```bash
docker ps --format '{{.Names}} {{.Status}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:1885/
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:1880/
docker logs Node-Red-V5 2>&1 | grep -E 'Node-RED version|Node.js  version|Server now running'
docker stats --no-stream
```

## Verified result (NFBM-440, 2026-09-04)

```
Node-Red-V5      | Up (healthy)   Node-RED v5.0.6  / Node.js v22.23.2   :1885 -> 200
nucleus-node-red | Up 18 hours    Node-RED v0.20.8 / Node.js v8.17.0    :1880 -> 200
```

* Memory after start: new instance 37 MiB of its 400 MiB cap, legacy 85 MiB,
  ~680 MB still free on the device.
* The image takes 553 MB in `/var/lib/docker`; `/data` kept 7.3 GB free.
* The container health check (`/healthcheck.js`) reads `settings.uiPort`, so it
  genuinely probes 1885 and not the legacy 1880.
* Download of the 196 MB release asset over the device wlan0 took ~30 s;
  `docker load` on the i.MX7 took about 6 minutes (CPU-bound decompression).
* Cockpit web terminal timing: run `docker load` with `nohup ... &` and poll,
  otherwise the terminal session may time out mid-load.

## Next steps for the flow developer

* Open `http://<device-ip>:1885` (or expose port 1885 through the Nucleus
  portal). The editor has **no adminAuth yet**: set `adminAuth` in
  `/data/settings.js` inside the `node-red-v5` volume before leaving it on a
  shared network.
* Modern palettes (Sparkplug B 3.x, aedes, dashboard 2) install normally here;
  they do not on the Node 8 legacy instance.
* Import flows from the legacy instance with Export/Import JSON. Do not point
  both instances at the same serial port or printer at the same time.

## Rollback

```bash
docker stop Node-Red-V5 && docker rm Node-Red-V5      # container only
docker volume rm node-red-v5                          # flows of the new instance
docker rmi node-red:5.0.6-22-armv7                    # frees ~550 MB in /var/lib/docker
```

The legacy container is never modified by any of the above.

## Repo layout

```
README.md                   this file
docs/DIAGNOSTIC.md          device diagnostic (hardware, Docker, network, containers)
scripts/diagnose.sh         re-runs the diagnostic on any Nucleus device
scripts/run-node-red-v5.sh  creates the Node-Red-V5 container
image/                      official node-red-docker files + build-armv7.sh
tools/pull-docker-archive.py builds a docker-archive tar from a registry
```
