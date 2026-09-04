#!/bin/sh
# Build Node-RED 5.x for linux/arm/v7 (Nucleus i.MX7) on a laptop with Docker Desktop.
# Uses the official node-red-docker Dockerfile.custom unchanged; only the base image
# namespace (arm32v7) and Node major (22 — node:24 has no arm/v7 build) differ.
# Requires: docker buildx with QEMU emulation for linux/arm/v7 (Docker Desktop ships it).
set -eu
NODE_RED_VERSION="${NODE_RED_VERSION:-$(grep -oE '"node-red": "[0-9.]+' package.json | cut -d'"' -f4)}"
NODE_VERSION="${NODE_VERSION:-22}"
TAG="${TAG:-nucleus/node-red:${NODE_RED_VERSION}-${NODE_VERSION}-armv7}"

docker buildx build --platform linux/arm/v7 \
  --build-arg ARCH=arm32v7 \
  --build-arg NODE_VERSION="$NODE_VERSION" \
  --build-arg NODE_RED_VERSION="$NODE_RED_VERSION" \
  --build-arg OS=alpine \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg BUILD_VERSION="$NODE_RED_VERSION" \
  --build-arg TAG_SUFFIX="$NODE_VERSION" \
  --file Dockerfile.custom --tag "$TAG" --load .

echo "built $TAG"
echo "export for Docker 18.03:  docker save $TAG -o nodered-${NODE_RED_VERSION}-${NODE_VERSION}-armv7.tar"
