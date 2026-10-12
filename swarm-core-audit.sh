#!/bin/bash

# Removed 'set -e' to prevent silent crashes; we'll handle errors manually.
# Log messages go to stderr so --json and --csv output on stdout stays clean.

# --- Default Format ---
FORMAT="text"

# --- Logging ---
# Mirrors the logrus text format used by Mirantis tooling, e.g. "INFO[0000] message".
# Levels are colored only when stderr is a terminal and NO_COLOR is unset.
if [ -t 2 ] && [ -z "${NO_COLOR}" ]; then
    C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_FATA=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_INFO=""; C_WARN=""; C_FATA=""; C_RESET=""
fi

log()   { printf '%s%s%s[%04d] %s\n' "$1" "$2" "$C_RESET" "$SECONDS" "$3" >&2; }
info()  { log "$C_INFO" "INFO" "$*"; }
warn()  { log "$C_WARN" "WARN" "$*"; }
fatal() { log "$C_FATA" "FATA" "$*"; exit 1; }

# --- Usage Function ---
usage() {
    echo "Usage: $0 [--json | --csv]"
    echo "Audits Docker Swarm node sizing via the Docker/UCP API."
    echo ""
    echo "Options:"
    echo "  --json    Output summary in JSON format"
    echo "  --csv     Output summary in CSV format"
    echo "  --help    Display this help message"
}

# --- Parse Flags ---
case "$1" in
    --json)     FORMAT="json" ;;
    --csv)      FORMAT="csv"  ;;
    -h|--help)  usage; exit 0 ;;
    "")         FORMAT="text" ;;
    *)          fatal "Unknown option: $1. Run with --help to see the supported options." ;;
esac

# --- Dependency Check ---
for cmd in curl jq bc; do
    command -v "$cmd" > /dev/null 2>&1 || fatal "Required command '$cmd' is not installed."
done

# --- Configuration ---
if [ -n "${UCP_URL}" ]; then
    for f in /data/key.pem /data/cert.pem; do
        [ -f "$f" ] || fatal "Missing $f. You must mount an extracted client bundle with \"-v /path/to/bundle:/data:ro\""
    done
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    if [ -f /data/ca.pem ]; then
        CURL_CMD="$CURL_CMD --cacert /data/ca.pem"
    else
        warn "No ca.pem found in /data; verifying the UCP certificate against the system CA store."
    fi
    BASE_URL="https://${UCP_URL}"
    API_DESC="UCP at ${BASE_URL}"
else
    [ -S /var/run/docker.sock ] || fatal "Missing docker.sock. You must run the container with \"-v /var/run/docker.sock:/var/run/docker.sock\" or set UCP_URL with a client bundle mounted at /data"
    CURL_CMD="curl -s -m 5 --unix-socket /var/run/docker.sock"
    BASE_URL="http://v1.30"
    API_DESC="Docker API via /var/run/docker.sock"
fi

# Basic check to see if we can talk to the API
if ! $CURL_CMD "${BASE_URL}/_ping" > /dev/null; then
    fatal "Unable to connect to the ${API_DESC}."
fi
info "Connected to the ${API_DESC}"

# Fetch all node data in a single request
NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")
if ! echo "$NODES_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
    reason=$(echo "$NODES_JSON" | jq -r '.message // empty' 2>/dev/null)
    fatal "Unable to list nodes: ${reason:-this engine must be a Swarm manager}"
fi

CLUSTER_ID=$($CURL_CMD "${BASE_URL}/info" | jq -r '.Swarm.Cluster.ID // "unknown"' 2>/dev/null)
[ -z "$CLUSTER_ID" ] && CLUSTER_ID="unknown"
info "Cluster ID: ${CLUSTER_ID}"

node_total=$(echo "$NODES_JSON" | jq 'length')
no_resources=$(echo "$NODES_JSON" | jq '[.[] | select((.Description.Resources.NanoCPUs // 0) == 0)] | length')
info "Retrieved ${node_total} nodes"
[ "$no_resources" -gt 0 ] && warn "${no_resources} node(s) reported no CPU data and are excluded from the totals"

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
    border="+------------+-------+-------------+-----------------+"
    row() { printf '| %-10s | %5s | %11s | %15s |\n' "$@"; }

    echo ""
    echo "$border"
    row "Node Group" "Nodes" "Total Cores" "Total RAM (GiB)"
    echo "$border"
    for group in manager: worker: "-" all:linux all:windows "-" all:; do
        if [ "$group" == "-" ]; then
            echo "$border"
            continue
        fi
        case "$group" in
            manager:)    label="Managers" ;;
            worker:)     label="Workers"  ;;
            all:linux)   label="Linux"    ;;
            all:windows) label="Windows"  ;;
            all:)        label="Total"    ;;
        esac
        process_node_data "${group%%:*}" "${group#*:}"
        row "$label" "$NODE_COUNT" "$TOTAL_CORES" "$TOTAL_MEM_GB"
    done
    echo "$border"
fi
