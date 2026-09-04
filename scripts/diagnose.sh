#!/bin/sh
# Read-only diagnostic for a Nucleus edge device before installing a second Node-RED.
# Prints hardware, Docker engine, existing containers, ports and free space.
# Usage: sh diagnose.sh   (run on the device; no root needed if in the docker group)

section() { printf '\n== %s ==\n' "$1"; }

section "Host"
uname -m; uname -r
grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null
nproc; free -m | head -2

section "Docker engine"
docker version --format 'server {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'
docker info 2>/dev/null | grep -E 'Storage Driver|Cgroup Driver|Docker Root Dir'
docker info 2>/dev/null | grep -A3 'Security Options'
grep -i seccomp /proc/self/status

section "Disk"
df -h /var/lib/docker /data 2>/dev/null

section "Containers"
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'
for c in $(docker ps -aq); do
  docker inspect "$c" --format '{{.Name}} net={{.HostConfig.NetworkMode}} restart={{.HostConfig.RestartPolicy.Name}} user={{.Config.User}} groups={{.HostConfig.GroupAdd}} devices={{range .HostConfig.Devices}}{{.PathOnHost}} {{end}} binds={{.HostConfig.Binds}}'
done

section "Node-RED versions in running containers"
for c in $(docker ps --format '{{.Names}}' | grep -i node-red); do
  printf '%s: ' "$c"; docker logs "$c" 2>&1 | grep -m1 -E 'Node-RED version' || echo '(no banner in logs)'
done

section "Listening TCP ports"
netstat -tlnp 2>/dev/null | awk 'NR>2{print $4, $7}' | sort

section "Network"
ip -4 -brief addr 2>/dev/null || ip -4 addr | grep inet
ip route | head -5

section "Registry reachability"
timeout 15 curl -sS -o /dev/null -w 'registry-1.docker.io -> HTTP %{http_code} in %{time_total}s (401 is expected)\n' https://registry-1.docker.io/v2/ || echo 'registry unreachable'
