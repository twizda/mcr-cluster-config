#!/bin/bash

# Removed 'set -e' to prevent silent crashes; we'll handle errors manually.
# Removed 'exec 1>&2' to ensure output stays on the standard channel.

# --- Default Format ---
FORMAT="text"

# --- Usage Function ---
usage() {
    echo "Usage: $0 [--json | --csv]"
    echo "Audits Docker Swarm node sizing via the Docker/UCP API."
    echo ""
    echo "Options:"
    echo "  --json    Output summary in JSON format"
    echo "  --csv     Output summary in CSV format"
    echo "  --help    Display this help message"
    exit 1
}

# --- Parse Flags ---
case "$1" in
    --json)     FORMAT="json" ;;
    --csv)      FORMAT="csv"  ;;
    -h|--help)  usage ;;
    "")         FORMAT="text" ;;
    *)          echo "Unknown option: $1"; usage ;;
esac

# --- Configuration ---
if [ -n "${UCP_URL}" ]; then
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    BASE_URL="https://${UCP_URL}"
else
    CURL_CMD="curl -s -m 5 --unix-socket /var/run/docker.sock"
    BASE_URL="http://v1.30"
fi

# Basic check to see if we can talk to the API
if ! $CURL_CMD "${BASE_URL}/_ping" > /dev/null; then
    echo "ERROR: Cannot connect to Docker API." >&2
    exit 1
fi

# Fetch all node data in a single request
NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")
if ! echo "$NODES_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
    echo "ERROR: Unable to list nodes. Is this engine a Swarm manager?" >&2
    echo "$NODES_JSON" | jq -r '.message // empty' 2>/dev/null >&2
    exit 1
fi

CLUSTER_ID=$($CURL_CMD "${BASE_URL}/info" | jq -r '.Swarm.Cluster.ID // "unknown"' 2>/dev/null)
[ -z "$CLUSTER_ID" ] && CLUSTER_ID="unknown"

# --- Processing Function ---
# Sets NODE_COUNT, TOTAL_CORES and TOTAL_MEM_GB for the given role/OS filter
process_node_data() {
    local role=$1
    local os=$2

    # Filter strings
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"

    local stats
    stats=$(echo "$NODES_JSON" | jq -r "[$filter | select((.Description.Resources.NanoCPUs // 0) > 0)]
        | \"\(length) \(map(.Description.Resources.NanoCPUs / 1000000000 | floor) | add // 0) \(map(.Description.Resources.MemoryBytes // 0) | add // 0)\"")
    read -r NODE_COUNT TOTAL_CORES total_mem_bytes <<< "$stats"

    TOTAL_MEM_GB=$(printf '%.2f' "$(echo "scale=2; $total_mem_bytes / 1073741824" | bc)")
}

# --- Execution ---
GROUPS_LIST="all: manager: worker: all:linux all:windows"

if [ "$FORMAT" == "json" ]; then
    entries=""
    for group in $GROUPS_LIST; do
        process_node_data "${group%%:*}" "${group#*:}"
        entries="${entries:+$entries, }{\"role\": \"${group%%:*}\", \"os\": \"${group#*:}\", \"nodes\": $NODE_COUNT, \"cores\": $TOTAL_CORES, \"mem_gib\": $TOTAL_MEM_GB}"
    done
    printf '{"cluster_id": "%s", "groups": [%s]}\n' "$CLUSTER_ID" "$entries"
elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,Role,OS,NodeCount,TotalCores,TotalGiB"
    for group in $GROUPS_LIST; do
        process_node_data "${group%%:*}" "${group#*:}"
        echo "$CLUSTER_ID,${group%%:*},${group#*:},$NODE_COUNT,$TOTAL_CORES,$TOTAL_MEM_GB"
    done
else
    for group in $GROUPS_LIST; do
        role=${group%%:*}
        os=${group#*:}
        process_node_data "$role" "$os"
        [ "$NODE_COUNT" -eq 0 ] && continue

        # Simple Output
        echo "=========================================="
        echo "Data for $role nodes ${os:+($os)}:"
        echo "# Nodes    - $NODE_COUNT"
        echo "Ttl Cores  - $TOTAL_CORES"
        echo "Ttl RAM    - $TOTAL_MEM_GB GiB"
    done
    echo "=========================================="
fi
