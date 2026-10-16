#!/bin/bash
# Builds the Windows variants of the image on Linux, without a Windows build machine: crane appends
# one layer (PowerShell 7, the docker CLI and swarm-core-audit.ps1) to Microsoft's Nano Server base
# image for each Windows Server version, and pushes the result.
#
# Usage: windows/build-image.sh <repository> <tag> [--insecure] [--save <dir>]
#   Pushes <repository>:<tag>-windows-ltsc2019, -ltsc2022 and -ltsc2025, and prints their digests.
#   --insecure   the registry is plain HTTP (a local test registry)
#   --save <dir> also save each variant as a docker-load-able tarball (windows-ltsc20xx.tar)
# Needs Linux x86_64, curl, sha256sum, unzip and tar; downloads are verified against pinned checksums.
#
# The images run windows/swarm-core-audit.ps1 against the host engine through its named pipe:
#   docker run --rm -v \\.\pipe\docker_engine:\\.\pipe\docker_engine <repository>:<tag>
set -e -o pipefail
cd "$(dirname "$0")/.."

# --- Pinned downloads: update the version and checksum together ---
CRANE_VERSION=v0.22.1
CRANE_SHA256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
PWSH_VERSION=7.4.21
PWSH_SHA256=b47ee814b9fe5fe6b713a26667998cadd6bbb74cb3889fadea56c775f11953a2
DOCKER_CLI_VERSION=29.9.1
DOCKER_CLI_SHA256=5d9b66509390553fd97d590ec2ff0ce10b04c2ac653fa52f2abf2f05c4c197ca

# Windows Server version -> Nano Server base image tag (2019's is "1809")
VARIANTS="ltsc2019:1809 ltsc2022:ltsc2022 ltsc2025:ltsc2025"

repository=$1
tag=$2
shift 2 || { echo "Usage: $0 <repository> <tag> [--insecure] [--save <dir>]" >&2; exit 1; }
[ -n "$repository" ] && [ -n "$tag" ] || { echo "Usage: $0 <repository> <tag> [--insecure] [--save <dir>]" >&2; exit 1; }
insecure=()
save_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --insecure) insecure=(--insecure) ;;
        --save)     save_dir=$2; shift ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

version=$(sed -n 's/^ENV MCR_CLUSTER_CONFIG_VERSION=//p' Dockerfile)
revision=$(git rev-parse HEAD 2> /dev/null || echo unknown)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

download() { # <url> <file> <sha256>
    curl -sSfL -o "$work/$2" "$1"
    echo "$3  $work/$2" | sha256sum -c --quiet || { echo "Checksum mismatch for $1" >&2; exit 1; }
}

echo "Downloading crane $CRANE_VERSION, PowerShell $PWSH_VERSION and docker CLI $DOCKER_CLI_VERSION"
download "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz" crane.tar.gz "$CRANE_SHA256"
download "https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/PowerShell-$PWSH_VERSION-win-x64.zip" pwsh.zip "$PWSH_SHA256"
download "https://download.docker.com/win/static/stable/x86_64/docker-$DOCKER_CLI_VERSION.zip" docker.zip "$DOCKER_CLI_SHA256"
tar -xzf "$work/crane.tar.gz" -C "$work" crane
crane="$work/crane"

# One layer: C:\pwsh, C:\docker\docker.exe and C:\mcr-cluster-config\swarm-core-audit.ps1
mkdir -p "$work/root/pwsh" "$work/root/mcr-cluster-config"
unzip -q "$work/pwsh.zip" -d "$work/root/pwsh"
unzip -q "$work/docker.zip" -d "$work/root"
cp windows/swarm-core-audit.ps1 "$work/root/mcr-cluster-config/"
tar -C "$work/root" -cf "$work/layer.tar" pwsh docker mcr-cluster-config

[ -n "$save_dir" ] && mkdir -p "$save_dir"
for variant in $VARIANTS; do
    name=${variant%%:*}
    base=mcr.microsoft.com/windows/nanoserver:${variant#*:}
    ref="$repository:$tag-windows-$name"
    # crane converts the layer to Windows layer format because the base image is Windows
    "$crane" --platform windows/amd64 append "${insecure[@]}" -b "$base" -f "$work/layer.tar" -t "$ref" > /dev/null
    "$crane" mutate "${insecure[@]}" "$ref" \
        --entrypoint 'C:\pwsh\pwsh.exe,-NoLogo,-NoProfile,-ExecutionPolicy,Bypass,-File,C:\mcr-cluster-config\swarm-core-audit.ps1' \
        --env 'PATH=C:\Windows\system32;C:\Windows;C:\pwsh;C:\docker' \
        --env "MCR_CLUSTER_CONFIG_VERSION=$version" \
        --env 'POWERSHELL_TELEMETRY_OPTOUT=1' \
        --user ContainerAdministrator \
        --workdir 'C:\mcr-cluster-config' \
        --label "version=$version" \
        --label "org.opencontainers.image.revision=$revision" \
        --label "description=Docker Swarm / MKE cluster audit for Windows Server (PowerShell)" \
        -t "$ref" > /dev/null
    digest=$("$crane" digest "${insecure[@]}" "$ref")
    os_version=$("$crane" config "${insecure[@]}" "$ref" | sed -n 's/.*"os.version":"\([^"]*\)".*/\1/p')
    echo "$ref@$digest (Windows $os_version)"
    if [ -n "$save_dir" ]; then
        # "legacy" is the docker save layout; the default layout has file names with ":" that Windows rejects
        "$crane" pull "${insecure[@]}" --format legacy "$ref" "$save_dir/windows-$name.tar"
    fi
done
