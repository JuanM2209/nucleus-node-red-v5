# Device diagnostic — NFBM-440 (2026-09-04)

Collected through the Cockpit terminal before installing the second Node-RED.
Re-run on any device with [`scripts/diagnose.sh`](../scripts/diagnose.sh).

## Hardware / OS

| Item | Value |
|---|---|
| SoC | NXP i.MX7D, ARMv7 rev 5 (armv7l, 32-bit), 2 cores |
| Kernel | 4.9.88-tn-imx (Toradex/NXP BSP, 2021 build) |
| Distro | NXP i.MX Release Distro 4.9.88-2.0.0 (Yocto rocko) |
| RAM | 998 MB total, ~730 MB available at idle |
| Root FS | 938 MB, read-only, 65 % used |
| `/data` | 13 GB eMMC partition, 7.9 GB free. Docker root (`/var/lib/docker`) lives here |
| Seccomp | **not compiled into the kernel** (`Seccomp: 0`) |
| Timezone | Universal (UTC) |

The missing seccomp is actually good news here: the well-known failure of
modern Alpine/musl images on old Docker (`faccessat2` / `clock_gettime64`
returning `EPERM`) is a seccomp-profile problem, so it cannot happen on this
kernel.

## Docker engine

| Item | Value |
|---|---|
| Version | 18.03.0 (build 0f1bb35), arm |
| Storage driver | overlay2 |
| Cgroup driver | cgroupfs, memory cgroup available (limits work) |
| Security options | apparmor only |
| Registry | `registry-1.docker.io` reachable (HTTP 401 on `/v2/`, expected) |

### Pull limitation

```
$ docker pull nodered/node-red:4.1.14-22
Error response from daemon: missing signature key
$ docker pull nodered/node-red@sha256:e2196cf4...   # arm/v7 manifest digest
Error response from daemon: missing signature key
```

Docker 18.03 does not understand OCI image indexes or OCI manifests. When the
registry answers with one, the daemon falls back to the schema-1 code path and
fails on the (absent) signature. Fix: build a classic docker-archive with
`tools/pull-docker-archive.py` and `docker load` it.

### Image availability on Docker Hub (checked 2026-09-04)

| Tag | Platforms |
|---|---|
| `latest` | amd64, arm64 (**no arm/v7**) |
| `4.2.0` | does not exist |
| `4.1.14` / `4.1.14-22` / `4.1.14-20` / `4.1.14-22-minimal` | amd64, arm64, **arm/v7** |
| `4.1.0` | amd64, arm64, arm/v7 |
| `3.1.15` | amd64, arm64, arm/v7, arm/v6 |

**No 5.x tag publishes arm/v7** — `5.0.6`, `5.0.6-24`, `5.0.6-minimal` and
`5.0.6-debian` are all `amd64` + `arm64` only, because Node-RED 5 defaults to a
`node:24` base and `node:24-alpine` has no arm/v7 build (`node:22-alpine` still
does). Node-RED 5.0.6 itself only requires `node >= 22.9`.

So the image running on the device is **built from the project's own
`Dockerfile.custom`**, unmodified, with `ARCH=arm32v7` and `NODE_VERSION=22`
(see `image/build-armv7.sh`). Result: `node-red:5.0.6-22-armv7`, 552 MB on disk,
196 MB as a compressed archive.

## Existing containers

| Container | Image | Network | Restart | User | Extras |
|---|---|---|---|---|---|
| `nucleus-node-red` | `tyrionintegration/nucleus-node-red` (Node-RED 0.20.8 / Node 8.17.0) | host | always | node-red | groups 7,20; `/dev/ttymxc5`; `/dev/usb`; volume `node-red:/data`; env-file `/data/nr.env`; journald logs |
| `nucleus-agent` | `nucleus-agent:vr43` | host | — | — | 22.5 MB image |
| `remote-support` | `remote-support` | host | — | — | 79.4 MB image |

Everything runs on the host network, which is why the new instance also uses
`--network host` with `PORT=1885` instead of a bridge port mapping.

## Listening ports before the change

| Port | Process |
|---|---|
| 1880 | node-red (legacy) |
| 22 | sshd |
| 9090 | cockpit |
| 1885 | free |

## Network

| Interface | Address | Role |
|---|---|---|
| eth0 | 10.10.1.1/24 | field / PLC side |
| wlan0 | 192.168.1.138/24 (DHCP) | default route (uplink) |
| docker0 | 172.17.0.1/16 | unused bridge |

The image download (~196 MB) goes through wlan0.
