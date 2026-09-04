# Nucleus Node-RED V5 sidecar

Run **the newest Node-RED (5.0.6, Node.js 22)** side by side with the legacy
`nucleus-node-red` container (Node-RED 0.20.8 / Node.js 8) on a Nucleus edge
device, without touching the production instance.

| Instance | Container | Image | Port | Data |
|---|---|---|---|---|
| Legacy (production) | `nucleus-node-red` | `tyrionintegration/nucleus-node-red` | 1880 | volume `node-red` |
| New | `Node-Red-V5` | `node-red:5.0.6-tyrion3-armv7` (built here) | **1885** | volume `node-red-v5` |

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
docker save node-red:5.0.6-tyrion3-armv7 -o nodered.tar
```

A pre-built archive is attached to the GitHub release
`nodered-5.0.6-tyrion3-armv7` of this repo.

On the device (Cockpit terminal or SSH, run as a user in the `docker` group):

```bash
cd /data
curl -L -o nrv5.tar https://github.com/JuanM2209/nucleus-node-red-v5/releases/download/nodered-5.0.6-tyrion3-armv7/nodered-5.0.6-tyrion3-armv7.tar
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
  -v node-red-v5:/data node-red:5.0.6-tyrion3-armv7
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

## Bundled palette

The image ships with the Tyrion Integration palette and the rest of the fleet's
node set already installed, so a device needs no `npm install` and no Manage
Palette round trip.

| Purpose | Module |
|---|---|
| Cloud | `@tyrion-integration/cumulus-convection-cloud` |
| Diagnostics | `nucleus-convection-diagnostics`, `node-red-contrib-nucleus-services-diagnostics` |
| Analog / digital IN & OUT | `nucleus-convection-io`, `node-red-contrib-nucleus-services-io` |
| Nucleus editor plugin | `node-red-contrib-tyrion` |
| RS-485 / Modbus | `node-red-contrib-modbus` 5.60.2 |
| MQTT broker | `node-red-contrib-aedes` 1.3.0 |
| Sparkplug B | `node-red-contrib-mqtt-sparkplug-plus` 3.1.1 |
| EtherNet/IP | `node-red-contrib-cip-ethernet-ip` |
| CAN bus | `node-red-contrib-socketcan` |
| Dashboard | `node-red-dashboard`, `node-red-node-ui-table`, `node-red-contrib-ui-led` |
| Misc | `node-red-contrib-counter`, `node-red-contrib-fs`, `node-red-contrib-unsafe-function` |

Several of these are versions the legacy Node 8 instance could never run:
Modbus 4.1 to 5.60, Sparkplug 1.2 to 3.1 (birth-immediately, UDT templates,
TCK conformance), aedes 0.3.1 to 1.3.0.

### Serial passthrough

The container gets `--device=/dev/ttymxc5 --group-add=20`, mirroring the fleet
`run.sh`. The group matters: the container runs as uid 1000 `node-red` and the
device is `root:dialout crw-rw----`, so without gid 20 every `open()` returns
EACCES. Both flags are conditional in the run script, so the same script works
on a Nucleus with no serial line.

**A serial line is exclusive.** Only one process at a time can hold
`/dev/ttymxc5`: this instance, the legacy Node-RED, or the portal's Modbus
Bridge (mbusd on TCP 2202). Starting the bridge while a flow here is polling
will take the port away. The run script warns when another process already
holds it.

### The musl trap on 32-bit ARM

Alpine uses **musl**; most prebuilt native addons are built against **glibc**.
`node-gyp-build` picks a prebuild by platform+arch and, on Linux, by libc — but
only when the package actually ships a musl variant. When it doesn't, the glibc
binary gets loaded anyway and the process dies with SIGSEGV. There is no
exception, no stack trace, and nothing in the Node-RED log: the whole runtime
disappears mid-flow-start, and a `--restart` policy turns it into a crash loop.

The three native modules in this image are a clean natural experiment:

| Module | linux-arm prebuilds | Result on this device |
|---|---|---|
| `@serialport/bindings-cpp` | armv6.glibc, armv7.glibc, **armv7.musl** | works |
| `bcrypt` | glibc, **musl** | works |
| `classic-level` | armv6, armv7 — **glibc only** | **SIGSEGV** |
| `socketcan` | none — compiled at install | works |

`classic-level` arrives via `level@^9`, which
`@tyrion-integration/cumulus-convection-cloud` depends on, so the crash fires
the moment a flow contains a **Tyrion Cloud** node. DELTA 4 in the Dockerfile
runs `npm rebuild --build-from-source classic-level` in the build stage, which
links it against musl; `node-gyp-build` then prefers `build/Release` over
`prebuilds/`. Verified under emulation: open, put, get and close all succeed.

If you add a palette with a native addon, check this first:

```bash
docker run --rm --platform linux/arm/v7 --entrypoint sh <image> -c   'ls node_modules/<pkg>/prebuilds/linux-arm/'
```

No `.musl` in those filenames means you must add the package to DELTA 4.

### Guard rails that keep it from coming back

* **Build gate** — `image/scripts/elf-gate.sh` runs in the build stage after
  every `npm rebuild`. It fails the build if any native addon that would load on
  linux/arm/musl is a glibc-only prebuild with no local `build/Release`. That is
  the exact shape of the classic-level crash, so any recurrence is a build error
  rather than a field crash loop.
* **Release gate** — `tools/verify-image.sh <image>` runs four checks under
  emulation before an image is published: classic-level open/put/get/close from
  `build/Release`; the Modbus override resolves to upstream and
  `connectRTUBuffered` returns on a PTY; serialport plus `udevadm`; and a full
  Node-RED boot to 18 modules, 0 errors, Tyrion plugin loaded. Every check maps
  to a crash that actually happened.
* **Recovery** — if a flow ever crash-loops the runtime again, restart the
  container with `-e NODE_RED_ENABLE_SAFE_MODE=true`. The editor comes up with
  flows stopped, you fix or remove the offending node, deploy, then recreate the
  container without the variable. No surgery in `/data` is needed.

### The one remaining brick vector

Manage Palette is still enabled. The image deliberately has no compiler, so a
native addon installed from the editor will use its prebuild — and if that
prebuild is glibc-only for arm (as classic-level's is), it will segfault on
first use exactly like the crash above. Two ways to close this, both the
operator's call:

* `externalModules.palette.allowInstall: false` in `/data/settings.js` (no
  installs from the editor; palettes are added via `image/package.json` and a
  rebuild, which is where the build gate protects you), or
* keep installs enabled and run the check in the previous section on any new
  module before deploying a flow that uses it.

A note for future hardware: the audit found every glibc arm prebuild in this
tree targets ARMv7VE with VFPv4, NEON and hardware divide. Fine on the
Cortex-A7 in the i.MX7D; would `SIGILL` on a Cortex-A8/A9 even with a musl
build. All musl binaries that actually load here are built conservatively
(ARMv5TE/VFPv2, no NEON).

### Two deliberate overrides

`@openp4nr/modbus-serial` is **overridden to upstream `modbus-serial@8.0.25`**.
`node-red-contrib-modbus` 5.27+ swapped its upstream dependency for this fork,
pulled from a cloudsmith.io tarball rather than npm, and on armv7 the fork
**segfaults inside `connectRTUBuffered()`** — it kills the Node-RED process the
instant flows start, so `--restart` turns it into a crash loop rather than an
error you can see in the debug pane.

Isolation, for anyone who hits this again: raw `serialport` 13 opens, writes and
closes `/dev/ttymxc5` fine, and the crash reproduces with **no serial device
attached at all**, so neither the passthrough nor the hardware is implicated.
Upstream `modbus-serial@8.0.25` pulls the very same `serialport` 13 and returns
a normal `Timed out` instead of dying. The override keeps the NR5-aware
`node-red-contrib-modbus` 5.60.2 while dropping the fork.

### One deliberate omission

`@tyrion-integration/node-red-contrib-nucleus-services-cloud` is **not**
included. All eight published versions pin `level@^4`, whose `leveldown@4`
native addon calls V8 APIs removed in Node 18 (`v8::AccessorSignature`), so it
cannot compile on Node 22 — the build fails in `node-gyp`. Its successor
`cumulus-convection-cloud` uses `level@^9` / `classic-level` (N-API, version
stable) and registers all five of the old node types plus four more
(`-file`, `-file-publish`, `broker-publish`, `broker-subscribe`).

A flow using the old `nucleus-services-cloud*` node types needs those nodes
swapped for their `cumulus-convection-cloud*` equivalents. To restore the old
package instead, Tyrion would have to republish it against a modern `level`.

## Size

| Archive | Contents | Size |
|---|---|---|
| `nodered-4.1.14-22-armv7` | stock image, no palette | 187 MB |
| `nodered-5.0.6-22-armv7` | stock image, no palette | 187 MB |
| `nodered-5.0.6-tyrion-armv7` | **18 palettes included** | **105 MB** |

Smaller *and* fully loaded, from two changes in
[`image/Dockerfile.nucleus`](image/Dockerfile.nucleus):

* **No devtools in the release stage** (~200 MB). Upstream installs
  `build-base`, `linux-headers`, `udev` and `python3` into the final image so
  Manage Palette can compile native addons on the device. Everything this fleet
  needs is compiled in the build stage, so the toolchain is dead weight at
  runtime. The trade: adding a module with a native addon now means editing
  `image/package.json` and rebuilding, not clicking Install on the device.
* **`COPY --chown` instead of a later `RUN chown -R`** (~116 MB). The upstream
  Dockerfile copies `node_modules` and *then* chowns it, which rewrites every
  file into a second layer — the tree is stored twice.

`udev` is added back to the base packages (~1 MB), because upstream ships it
only inside `install_devtools.sh`. Without `udevadm`, `SerialPort.list()`
rejects with `spawn udevadm ENOENT` and the port-scan button in every serial
node's config dialog stops working.

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
docker rmi node-red:5.0.6-tyrion3-armv7               # frees ~330 MB in /var/lib/docker
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
