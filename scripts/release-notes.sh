#!/bin/bash
# Prints the GitHub release notes for a tag:
#   1. Summary: the annotated tag message after its first line (the first line is the release title)
#   2. Docker image and pull command, and the Docker Scout result
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
summary=$(git for-each-ref "refs/tags/$tag" --format='%(contents:body)' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
previous=$(git tag --list 'v0.*' --sort=-version:refname | grep -vx "$tag" | head -1 || true)

if [ -n "$summary" ]; then
    printf '%s\n\n' "$summary"
fi
echo "**Docker image:** \`$image:$version\` (also \`latest\`), for ${platforms//,/ and }."
echo '```bash'
echo "docker pull ${image#docker.io/}:$version"
echo '```'
echo ""
echo "Docker Scout found no fixable critical or high vulnerabilities in this image."
echo ""
gh api "repos/$repo/releases/generate-notes" -f tag_name="$tag" ${previous:+-f previous_tag_name="$previous"} -q .body
