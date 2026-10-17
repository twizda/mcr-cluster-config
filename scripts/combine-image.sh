#!/bin/bash
# Creates one multi-platform tag from the Linux image index and the Windows variant indexes, then
# checks the result: Linux amd64 and arm64 present, and every Windows entry recording its Windows
# build (os.version), which Windows hosts need to pick the variant that matches their build.
#
# Usage: scripts/combine-image.sh <target> <linux-index> <windows-variant>...
#   e.g. scripts/combine-image.sh docker.io/twizda/mcr-cluster-config:0.7.0 \
#            docker.io/twizda/mcr-cluster-config@sha256:... \
#            docker.io/twizda/mcr-cluster-config:0.7.0-windows-ltsc2019 ...
set -e -o pipefail

target=$1
linux=$2
[ -n "$target" ] && [ -n "$linux" ] && [ $# -ge 3 ] || { echo "Usage: $0 <target> <linux-index> <windows-variant>..." >&2; exit 1; }
shift 2
windows_count=$#

if ! output=$(docker buildx imagetools create --tag "$target" "$linux" "$@" 2>&1); then
    echo "$output" >&2
    exit 1
fi

raw=$(docker buildx imagetools inspect "$target" --raw)
platforms=$(echo "$raw" | jq -r '.manifests[] | select(.platform.os != "unknown")
    | "\(.platform.os)/\(.platform.architecture)\(if .platform.variant then "/" + .platform.variant else "" end)\(if .platform["os.version"] then " " + .platform["os.version"] else "" end)"')
echo "$target:"
echo "$platforms" | sed 's/^/  /'

status=0
for platform in linux/amd64 linux/arm64; do
    echo "$platforms" | grep -qE "^$platform(/v8)?$" || { echo "Missing $platform" >&2; status=1; }
done
found=$(echo "$raw" | jq '[.manifests[] | select(.platform.os == "windows")] | length')
missing=$(echo "$raw" | jq '[.manifests[] | select(.platform.os == "windows" and (.platform["os.version"] // "") == "")] | length')
[ "$found" -eq "$windows_count" ] || { echo "Expected $windows_count Windows entries, found $found" >&2; status=1; }
[ "$missing" -eq 0 ] || { echo "$missing Windows entries have no os.version" >&2; status=1; }
exit $status
