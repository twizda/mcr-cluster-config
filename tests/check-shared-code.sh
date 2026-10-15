#!/bin/bash
# Checks that every "# >>> shared:<name>" region is identical in both audit scripts.
cd "$(dirname "$0")/.." || exit 1

A=swarm-core-audit.sh
B=support-dump-count-cores.sh
status=0

regions=$(grep -ho '^# >>> shared:[a-z-]*' "$A" "$B" | sed 's/^# >>> shared://' | sort -u)
[ -z "$regions" ] && { echo "FAIL: no shared regions found"; exit 1; }

extract() { awk -v r="$2" '$0 ~ "^# >>> shared:" r "( |$)" {on=1} on {print} $0 == "# <<< shared:" r {on=0}' "$1"; }

for r in $regions; do
    a=$(extract "$A" "$r"); b=$(extract "$B" "$r")
    if [ -z "$a" ] || [ -z "$b" ]; then
        echo "FAIL: shared region '$r' is missing from one of the scripts"; status=1
    elif [ "$a" != "$b" ]; then
        echo "FAIL: shared region '$r' differs between $A and $B:"
        diff <(echo "$a") <(echo "$b")
        status=1
    else
        echo "ok: shared region '$r' is identical ($(echo "$a" | wc -l | tr -d ' ') lines)"
    fi
done
# The Windows PowerShell audit carries its own copy of the release version
docker_version=$(sed -n 's/^ENV MCR_CLUSTER_CONFIG_VERSION=//p' Dockerfile)
ps_version=$(sed -n "s/^\\\$ScriptVersion = '\\(.*\\)'/\\1/p" windows/swarm-core-audit.ps1)
if [ "$ps_version" != "$docker_version" ]; then
    echo "FAIL: windows/swarm-core-audit.ps1 version ($ps_version) differs from the Dockerfile ($docker_version)"; status=1
else
    echo "ok: windows/swarm-core-audit.ps1 version matches the Dockerfile ($docker_version)"
fi
exit $status
