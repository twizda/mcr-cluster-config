#!/bin/bash
# Prepares a release: bumps the Dockerfile version and updates DOCKERHUB.md and HARBOR.md
# (new tags-table row marked latest, support-dump script link, HARBOR.md pull example). Commit the result in a
# pull request; after it merges, push an annotated tag to publish:
#   git tag -a v<version> -m "Release v<version>: <title>" && git push origin v<version>
#
# Usage: scripts/prepare-release.sh <version> "<tags-table note>"
#   e.g. scripts/prepare-release.sh 0.5.2 "Singular wording fix; OS/Arch display fix"
set -e
cd "$(dirname "$0")/.."

version=$1
note=$2
if ! echo "$version" | grep -qE '^0\.[0-9]+\.[0-9]+$' || [ -z "$note" ]; then
    echo "Usage: $0 <version> \"<tags-table note>\"   (version must be 0.x.y, for example 0.5.2)" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$version" > /dev/null; then
    echo "Tag v$version already exists." >&2
    exit 1
fi

current=$(sed -n 's/^ENV MCR_CLUSTER_CONFIG_VERSION=//p' Dockerfile)
if [ "$current" = "$version" ]; then
    echo "Dockerfile is already at $version." >&2
    exit 1
fi
newest=$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ "$newest" != "$version" ]; then
    echo "Version $version is not newer than the current $current." >&2
    exit 1
fi

# Dockerfile version (ENV line; the image label is filled from it)
sed -i.bak "s/^ENV MCR_CLUSTER_CONFIG_VERSION=.*/ENV MCR_CLUSTER_CONFIG_VERSION=$version/" Dockerfile && rm -f Dockerfile.bak
# Windows PowerShell audit carries its own copy of the version
sed -i.bak "s/^\$ScriptVersion = '.*'/\$ScriptVersion = '$version'/" windows/swarm-core-audit.ps1 && rm -f windows/swarm-core-audit.ps1.bak

# DOCKERHUB.md and HARBOR.md: move "latest" to a new row in the tags table, and point the
# support-dump link and HARBOR.md's pull example at the new version
for f in DOCKERHUB.md HARBOR.md; do
    awk -v v="$version" -v note="$note" '
        /^\| `[0-9.]+`, `latest` \|/ { sub(/, `latest`/, "") }
        { print }
        /^\| Tag \| Notes \|$/ { header = 1; next }
        header && /^\|---\|---\|$/ { printf "| `%s`, `latest` | %s |\n", v, note; header = 0 }
    ' "$f" > "$f.new"
    sed -e "s|/blob/v[0-9.]*/support-dump-count-cores.sh|/blob/v$version/support-dump-count-cores.sh|" \
        -e "s|\(docker pull registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config:\)[0-9.]*|\1$version|" \
        -e "s|\(mcr-cluster-config version \)[0-9.]*|\1$version|" \
        -e "s|/releases/download/v[0-9.]*/|/releases/download/v$version/|g" \
        "$f.new" > "$f"
    rm -f "$f.new"
    grep -q "^| \`$version\`, \`latest\` |" "$f" || { echo "Failed to update the $f tags table." >&2; exit 1; }
done

# README: the version line in the example output
sed -i.bak "s|\(mcr-cluster-config version \)[0-9.]*|\1$version|" README.md && rm -f README.md.bak

echo "Prepared release $version (was $current):"
git --no-pager diff --stat -- Dockerfile DOCKERHUB.md HARBOR.md README.md windows/swarm-core-audit.ps1
echo ""
echo "Next: open a pull request with these changes. After it merges, publish with:"
echo "  git checkout main && git pull"
echo "  git tag -a v$version -m \"Release v$version: <title>\" -m \"<summary for the release notes>\""
echo "  scripts/release-notes.sh v$version   # optional preview"
echo "  git push origin v$version"
echo ""
echo "When the release workflow finishes, copy the image to the Mirantis registry:"
echo "  scripts/push-mirantis-registry.sh $version"
