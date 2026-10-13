#!/bin/bash
# Copies a published release from Docker Hub to the Mirantis registry, without rebuilding,
# so both platforms and the provenance/SBOM attestations are kept. Tags <version> and latest.
# Run it after the release workflow finishes; needs "docker login registry.ci.mirantis.com".
#
# Usage: scripts/push-mirantis-registry.sh 0.5.3
set -e -o pipefail

SRC=docker.io/twizda/mcr-cluster-config
DST=registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config

version=$1
if ! echo "$version" | grep -qE '^0\.[0-9]+\.[0-9]+$'; then
    echo "Usage: $0 <version>   (for example 0.5.3)" >&2
    exit 1
fi

digest() { docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'; }

src_digest=$(digest "${SRC}:${version}") || { echo "${SRC}:${version} not found; has the release workflow finished?" >&2; exit 1; }
echo "Copying ${SRC}:${version} (${src_digest}) to ${DST}:${version} and ${DST}:latest"
docker buildx imagetools create --tag "${DST}:${version}" --tag "${DST}:latest" "${SRC}:${version}"

for tag in "${version}" latest; do
    dst_digest=$(digest "${DST}:${tag}")
    if [ "$dst_digest" != "$src_digest" ]; then
        echo "${DST}:${tag} is ${dst_digest}, expected ${src_digest}" >&2
        exit 1
    fi
    echo "ok: ${DST}:${tag} = ${src_digest}"
done
