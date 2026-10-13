#!/bin/bash
# Tests the audit image against a throwaway two-node Docker-in-Docker swarm and a mock MKE API.
# Requires Docker with privileged containers. Usage: tests/run-swarm-tests.sh
TESTS=$(cd "$(dirname "$0")" && pwd)
REPO="$TESTS/.."
# shellcheck source=tests/lib.sh
. "$TESTS/lib.sh"

IMAGE=mcr-cluster-config:test
DIND=docker:28-dind
PYTHON=python:3.11-slim
P=mcc-test-$$
NET=$P-net

cleanup() {
    docker rm -f "$P-mgr" "$P-wkr" "$P-mock" > /dev/null 2>&1
    docker volume rm "$P-mgr-sock" "$P-wkr-sock" "$P-mock-sock" > /dev/null 2>&1
    docker network rm "$NET" > /dev/null 2>&1
}
trap cleanup EXIT

# audit <socket volume> [args...]: runs the image; sets OUT (stdout), ERR (stderr) and RC
audit() {
    local vol=$1; shift
    local errf; errf=$(mktemp)
    OUT=$(docker run --rm ${vol:+-v "$vol":/var/run} "$IMAGE" "$@" 2> "$errf"); RC=$?
    ERR=$(cat "$errf"); rm -f "$errf"
}
mgr() { docker exec "$P-mgr" docker "$@"; }

echo "Building $IMAGE"
docker build -q -t "$IMAGE" "$REPO" > /dev/null || { echo "FAIL - image build"; exit 1; }

echo "Starting a two-node swarm"
docker network create "$NET" > /dev/null
for n in mgr wkr; do
    docker run -d --privileged --name "$P-$n" --hostname "mke-$n-01" --network "$NET" \
        -v "$P-$n-sock":/var/run -e DOCKER_TLS_CERTDIR= "$DIND" > /dev/null
done
for _ in $(seq 1 60); do
    docker exec "$P-mgr" docker info > /dev/null 2>&1 && docker exec "$P-wkr" docker info > /dev/null 2>&1 && break
    sleep 1
done

echo "# not a swarm manager"
audit "$P-mgr-sock"
assert_equals "exits 1" "$RC" "1"
assert_contains "explains the engine is not a manager" "$ERR" "Unable to list nodes: This node is not a swarm manager"

mgr swarm init --advertise-addr eth0 > /dev/null
docker exec "$P-wkr" docker swarm join --token "$(mgr swarm join-token -q worker)" "$P-mgr:2377" > /dev/null
mgr node update --availability drain mke-wkr-01 > /dev/null
mgr service create -q --detach --no-resolve-image --name dtr-api mirantis/dtr-api:2.9.19 > /dev/null
sleep 3

echo "# via docker.sock"
audit "$P-mgr-sock"
assert_equals "text exits 0" "$RC" "0"
assert_contains "table header" "$OUT" "| Hostname   | Node ID    | Role   | Avail  | State | Address"
assert_contains "Operating System column" "$OUT" "| OS/Arch"
assert_not_contains "Orchestrators column removed" "$OUT" "Orchestrators"
assert_not_contains "Status column removed" "$OUT" "| Status"
assert_contains "leader row" "$OUT" "| mke-mgr-01 |"
assert_contains "worker row is drained" "$(echo "$OUT" | grep 'mke-wkr-01')" "| worker | drain  |"
assert_contains "summary table" "$OUT" "| Node Group | Nodes | Total Cores | Total RAM (GiB) |"
assert_contains "node count wording" "$ERR" "Retrieved 2 nodes (managers: 1, workers: 1)"
assert_contains "MSR version from service image" "$ERR" "MSR version: 2.9.19"
assert_contains "drained node warning" "$ERR" "] Node mke-wkr-01: state ready, availability drain"
assert_contains "operating system only for the connected node" "$ERR" "Operating system found for 1 of 2 nodes. docker info on this engine only describes this node"

audit "$P-mgr-sock" --csv
assert_equals "--csv exits 0" "$RC" "0"
assert_equals "--csv header unchanged" "$(echo "$OUT" | head -1)" "ClusterID,Role,OS,NodeCount,TotalCores,TotalGiB"
assert_equals "--csv has 5 groups" "$(echo "$OUT" | tail -n +2 | wc -l | tr -d ' ')" "5"

audit "$P-mgr-sock" --nodes-csv
assert_equals "--nodes-csv exits 0" "$RC" "0"
assert_equals "--nodes-csv header" "$(echo "$OUT" | head -1)" '"ClusterID","Hostname","NodeID","Role","Availability","State","Address","OS","Arch","OperatingSystem","EngineVersion","vCPUs","RAM_GiB","Created","Updated"'
assert_equals "--nodes-csv has 2 nodes" "$(echo "$OUT" | tail -n +2 | wc -l | tr -d ' ')" "2"

audit "$P-mgr-sock" --json
assert_equals "--json exits 0" "$RC" "0"
assert_equals "--json is valid with 2 nodes and 5 groups" "$(echo "$OUT" | jq -c '[(.nodes | length), (.groups | length)]' 2>&1)" "[2,5]"
assert_equals "--json has the leader" "$(echo "$OUT" | jq -r '.nodes[0].role' 2>&1)" "leader"
assert_equals "--json msr_version" "$(echo "$OUT" | jq -r '.msr_version' 2>&1)" "2.9.19"

docker stop -t 1 "$P-wkr" > /dev/null
for _ in $(seq 1 30); do
    [ "$(mgr node inspect -f '{{.Status.State}}' mke-wkr-01)" == "down" ] && break
    sleep 2
done
audit "$P-mgr-sock"
assert_contains "down node warning with status message" "$ERR" "] Node mke-wkr-01: state down, availability drain (heartbeat failure)"

echo "# through a mock MKE API"
docker run -d --name "$P-mock" -v "$TESTS/mock_mke.py":/mock_mke.py:ro -v "$TESTS/fixtures/mock-mke":/fixtures:ro \
    -v "$P-mock-sock":/var/run "$PYTHON" python -I /mock_mke.py > /dev/null
for _ in $(seq 1 30); do
    docker run --rm -v "$P-mock-sock":/var/run --entrypoint test "$IMAGE" -S /var/run/docker.sock && break
    sleep 1
done
audit "$P-mock-sock"
assert_equals "text exits 0" "$RC" "0"
assert_contains "MKE version from /version" "$ERR" "MKE version: 3.8.8"
assert_not_contains "every node has an operating system" "$ERR" "Operating system found for"
assert_contains "Linux node OS from MKE SystemStatus" "$(echo "$OUT" | grep 'mke-wkr-01')" "| Ubuntu 22.04.5 LTS"
assert_contains "Windows node OS from MKE SystemStatus" "$(echo "$OUT" | grep 'mke-win-01')" "| Windows Server 2022 Datacenter"
assert_contains "leader OS" "$(echo "$OUT" | grep 'mke-mgr-01')" "| Red Hat Enterprise Linux 8.10 (Ootpa)"
audit "$P-mock-sock" --json
assert_equals "--json operating systems" "$(echo "$OUT" | jq -c '[.nodes[].operating_system]' 2>&1)" \
    '["Red Hat Enterprise Linux 8.10 (Ootpa)","Red Hat Enterprise Linux 8.10 (Ootpa)","Windows Server 2022 Datacenter Version 2009 (OS Build 20348.2700)","Ubuntu 22.04.5 LTS"]'

echo "# errors and options"
audit ""
assert_equals "no socket: exits 1" "$RC" "1"
assert_contains "no socket: FATA message" "$ERR" "] Missing docker.sock."
OUT=$(docker run --rm -e UCP_URL=ucp.example.com "$IMAGE" 2>&1); RC=$?
assert_equals "UCP_URL without bundle: exits 1" "$RC" "1"
assert_contains "UCP_URL without bundle: FATA message" "$OUT" "] Missing /data/key.pem."
audit "$P-mock-sock" --xml
assert_equals "unknown option: exits 1" "$RC" "1"
audit "$P-mock-sock" --help
assert_equals "--help exits 0" "$RC" "0"

summary
