#!/bin/bash
# Prints the GitHub release notes for a tag:
#   1. Summary: the annotated tag message after its first line (the first line is the release title)
#   2. Docker image and pull command, the Docker Scout result, and the Windows PowerShell audit download
#   3. Pull requests merged since the previous v0.x tag (GitHub's generated notes)
#
# Usage: scripts/release-notes.sh v0.5.3
# Environment: IMAGE (default docker.io/twizda/mcr-cluster-config), PLATFORMS (default linux/amd64,linux/arm64),
#              GITHUB_REPOSITORY (default twizda/mcr-cluster-config); needs git and an authenticated gh.
set -e -o pipefail
cd "$(dirname "$0")/.."

tag=$1
[ -n "$tag" ] || { echo "Usage: $0 <tag>" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" > /dev/null || { echo "Tag $tag not found" >&2; exit 1; }

image=${IMAGE:-docker.io/twizda/mcr-cluster-config}
platforms=${PLATFORMS:-linux/amd64,linux/arm64}
repo=${GITHUB_REPOSITORY:-twizda/mcr-cluster-config}
version=${tag#v}

# Tag message body: everything after the subject line (empty for lightweight tags)
summary=""
if [ "$(git cat-file -t "refs/tags/$tag")" = "tag" ]; then
    # Only annotated tags have their own message; for a lightweight tag, git would return the commit's
    summary=$(git for-each-ref "refs/tags/$tag" --format='%(contents:body)' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
fi
previous=$(git tag --list 'v0.*' --sort=-version:refname | grep -vx "$tag" | head -1 || true)

if [ -n "$summary" ]; then
    printf '%s\n\n' "$summary"
fi
windows_image=false
git cat-file -e "$tag:windows/build-image.sh" 2> /dev/null && windows_image=true
if $windows_image; then
    echo "**Docker image:** \`$image:$version\` (also \`latest\`), for ${platforms//,/, } and Windows Server 2019, 2022 and 2025."
else
    echo "**Docker image:** \`$image:$version\` (also \`latest\`), for ${platforms//,/ and }."
fi
echo '```bash'
echo "docker pull ${image#docker.io/}:$version"
echo '```'
echo ""
if $windows_image; then
    echo "Docker Scout found no fixable critical or high vulnerabilities in the Linux variants (Docker Scout doesn't scan Windows images)."
else
    echo "Docker Scout found no fixable critical or high vulnerabilities in this image."
fi
echo ""
# Windows container: the same tag runs on Windows Server, with the engine's named pipe mounted
if $windows_image; then
    echo "**Windows Server (container):** the same image runs on Windows Server 2019, 2022 and 2025, and Docker Desktop on Windows 10/11. On a Swarm manager:"
    echo '```powershell'
    echo "docker run --rm -v \\\\.\\pipe\\docker_engine:\\\\.\\pipe\\docker_engine ${image#docker.io/}:$version"
    echo '```'
    echo ""
fi
# Windows PowerShell audit, attached to releases that include it
if git cat-file -e "$tag:windows/swarm-core-audit.ps1" 2> /dev/null; then
    url="https://github.com/$repo/releases/download/$tag"
    echo "**Windows Server (no container):** \`swarm-core-audit.ps1\` is attached below. In PowerShell on a Swarm manager:"
    echo '```powershell'
    echo "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'"
    echo "Invoke-WebRequest -UseBasicParsing $url/swarm-core-audit.ps1 -OutFile swarm-core-audit.ps1"
    echo "Invoke-WebRequest -UseBasicParsing $url/swarm-core-audit.ps1.sha256 -OutFile swarm-core-audit.ps1.sha256"
    echo "(Get-FileHash swarm-core-audit.ps1 -Algorithm SHA256).Hash -eq (Get-Content swarm-core-audit.ps1.sha256).Split(' ')[0].ToUpper()"
    echo "powershell -ExecutionPolicy Bypass -File .\\swarm-core-audit.ps1"
    echo '```'
    echo ""
fi
gh api "repos/$repo/releases/generate-notes" -f tag_name="$tag" ${previous:+-f previous_tag_name="$previous"} -q .body
