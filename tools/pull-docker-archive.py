#!/usr/bin/env python3
"""Build a legacy `docker load`-compatible archive from an OCI image on Docker Hub.

Why this exists
---------------
Old Docker engines (e.g. 18.03 on the Nucleus i.MX7 devices) cannot `docker pull`
images that are published as OCI manifests / image indexes: the daemon fails with
`missing signature key`. `docker load` of a plain docker-archive tar still works,
so we download the platform-specific layers + config straight from the registry
API and pack them in the classic archive layout (manifest.json + config + layers).

Usage
-----
    python3 pull-docker-archive.py nodered/node-red 4.1.14-22 arm v7 out.tar

The resulting tar is loaded on the target with:
    docker load -i out.tar
"""
import hashlib
import json
import os
import sys
import tarfile
import tempfile
import urllib.request

REGISTRY = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
ACCEPT_INDEX = ", ".join([
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
])


class DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Blob downloads redirect to a CDN with a pre-signed URL; forwarding the
    registry bearer token there makes the CDN reject the request."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return urllib.request.Request(newurl, method="GET")


OPENER = urllib.request.build_opener(DropAuthOnRedirect())


def get(url, token=None, accept=None, stream_to=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if accept:
        headers["Accept"] = accept
    req = urllib.request.Request(url, headers=headers)
    with OPENER.open(req, timeout=120) as resp:
        if stream_to is None:
            return resp.read()
        digest = hashlib.sha256()
        with open(stream_to, "wb") as fh:
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                fh.write(chunk)
                digest.update(chunk)
        return "sha256:" + digest.hexdigest()


def pick_platform_manifest(index, arch, variant):
    if "manifests" not in index:
        return None  # already a single-platform manifest
    for m in index["manifests"]:
        p = m.get("platform", {})
        if p.get("os") == "linux" and p.get("architecture") == arch and p.get("variant", "") == (variant or ""):
            return m["digest"]
    raise SystemExit(f"no manifest for linux/{arch}/{variant} in index")


def main(repo, tag, arch, variant, out_path):
    token = json.loads(get(AUTH.format(repo=repo)))["token"]
    index = json.loads(get(f"{REGISTRY}/v2/{repo}/manifests/{tag}", token, ACCEPT_INDEX))
    digest = pick_platform_manifest(index, arch, variant)
    manifest = index if digest is None else json.loads(
        get(f"{REGISTRY}/v2/{repo}/manifests/{digest}", token, ACCEPT_INDEX))

    config_raw = get(f"{REGISTRY}/v2/{repo}/blobs/{manifest['config']['digest']}", token)
    config_sha = hashlib.sha256(config_raw).hexdigest()
    if "sha256:" + config_sha != manifest["config"]["digest"]:
        raise SystemExit("config digest mismatch")
    diff_ids = json.loads(config_raw)["rootfs"]["diff_ids"]
    layers = manifest["layers"]
    if len(diff_ids) != len(layers):
        raise SystemExit("layer/diff_id count mismatch")

    workdir = tempfile.mkdtemp(prefix="docker-archive-")
    layer_paths = []
    with tarfile.open(out_path, "w") as tar:
        cfg_name = f"{config_sha}.json"
        cfg_file = os.path.join(workdir, cfg_name)
        with open(cfg_file, "wb") as fh:
            fh.write(config_raw)
        tar.add(cfg_file, arcname=cfg_name)

        for i, (layer, diff_id) in enumerate(zip(layers, diff_ids), 1):
            print(f"[{i}/{len(layers)}] {layer['digest'][:19]} {layer['size'] / 1e6:.1f} MB", flush=True)
            local = os.path.join(workdir, f"layer{i}.tar.gz")
            got = get(f"{REGISTRY}/v2/{repo}/blobs/{layer['digest']}", token, stream_to=local)
            if got != layer["digest"]:
                raise SystemExit(f"layer {i} digest mismatch: {got}")
            arc = f"{diff_id.split(':')[1]}/layer.tar"
            tar.add(local, arcname=arc)
            layer_paths.append(arc)
            os.remove(local)

        manifest_json = json.dumps([{
            "Config": cfg_name,
            "RepoTags": [f"{repo}:{tag}"],
            "Layers": layer_paths,
        }]).encode()
        mf = os.path.join(workdir, "manifest.json")
        with open(mf, "wb") as fh:
            fh.write(manifest_json)
        tar.add(mf, arcname="manifest.json")

    print(f"done: {out_path} ({os.path.getsize(out_path) / 1e6:.1f} MB), image id sha256:{config_sha}")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
