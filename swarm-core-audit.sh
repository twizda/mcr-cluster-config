#!/bin/bash

set -e
# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is not installed. This script requires it for parsing API data."
    exit 1
fi

# --- Version Check ---
BASH_MAJOR_VERSION=${BASH_VERSINFO[0]}
if [ "$BASH_MAJOR_VERSION" -lt 4 ]; then
    # Optional: Log that we are running in legacy compatibility mode
    COMPAT_MODE=true
fi

# --- Default Format ---
FORMAT="text"

# --- Usage Function ---
usage() {
    echo "Usage: $0 [--json | --csv]"
    echo "Audits live Docker Swarm nodes for CPU and Memory stats."
    echo ""
    echo "Options:"
    echo "  --json    Output full cluster data in JSON format"
    echo "  --csv     Output summary data in CSV format"
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

# --- Dependency Check ---
for cmd in jq bc curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: '$cmd' is not installed."
        exit 1
    fi
done

# --- Configuration & Connection Logic ---
if [ -n "${UCP_URL}" ]; then
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    if ! curl -s --cacert /data/ca.pem "https://${UCP_URL}/_ping" | grep -q "OK"; then
        if ! curl -s "https://${UCP_URL}/_ping" | grep -q "OK"; then
            echo "ERROR: UCP unavailable at https://${UCP_URL}/_ping"
            exit 1
        fi
        BASE_URL="https://${UCP_URL}"
    else
        CURL_CMD="$CURL_CMD --cacert /data/ca.pem"
        BASE_URL="https://${UCP_URL}"
    fi
else
    CURL_CMD="curl -s -m 5 --unix-socket /var/run/docker.sock"
    BASE_URL="http://v1.30"
fi

# Check Swarm Status
if [ "$($CURL_CMD "${BASE_URL}/swarm" | jq -r .ID)" == "null" ]; then
    echo "ERROR: This node is not a Swarm manager."
    exit 1
fi

# Fetch ALL node data
ALL_NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")

# --- Processing Function ---
process_node_data() {
    local role=$1
    local os=$2
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"
    
    # Extract NanoCPUs and MemoryBytes
    local raw_data=$(echo "$ALL_NODES_JSON" | jq -r "$filter | \"\(.Description.Resources.NanoCPUs // 0) \(.Description.Resources.MemoryBytes // 0)\"")
    
    if [ -z "$raw_data" ]; then return; fi

    local CPUs=""
    local total_mem_bytes=0
    local count=0

    while read -r nano mem; do
        [[ -z "$nano" || "$nano" -eq 0 ]] && continue
        CPUs="${CPUs}$((nano / 1000000000))"$'\n'
        total_mem_bytes=$(echo "$total_mem_bytes + $mem" | bc)
        ((count++))
    done <<< "$raw_data"

    if [ "$count" -eq 0 ]; then return; fi

    CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
    local total_cpu=$(echo "$CPUs" | paste -sd+ - | bc)
    local min_cpu=$(echo "$CPUs" | head -n1)
    local max_cpu=$(echo "$CPUs" | tail -n1)
    local avg_cpu=$(echo "scale=2; $total_cpu / $count" | bc)

    # Convert memory to GiB (Bytes / 1024^3)
    local total_mem_gb=$(echo "scale=2; $total_mem_bytes / 1073741824" | bc)
    local avg_mem_gb=$(echo "scale=2; $total_mem_gb / $count" | bc)

    # --- Output Logic ---
    if [ "$FORMAT" == "json" ]; then
        local key="${role}_${os:-all}"
        printf '"%s": {"nodes": %d, "cpu": {"total": %d, "avg": %s}, "mem_gib": {"total": %s, "avg": %s}}' \
               "$key" "$count" "$total_cpu" "$avg_cpu" "$total_mem_gb" "$avg_mem_gb"
    elif [ "$FORMAT" == "csv" ]; then
        echo "${role},${os:-all},$count,$total_cpu,$avg_cpu,$total_mem_gb,$avg_mem_gb"
    else
        local title="Data for ${role} nodes"
        [[ -n "$os" ]] && title="$title running ${os}"
        echo "=========================================="
        echo "$title:"
        echo "$CPUs" | uniq -c | while read -r c s; do
            printf "%d Core x %d\n" "$s" "$c"
        done
        echo -e "\n# Nodes    - $count"
        echo "Ttl Cores  - $total_cpu"
        echo "Ttl RAM    - ${total_mem_gb} GiB"
        echo "Avg Cores  - $avg_cpu"
        echo "Avg RAM    - ${avg_mem_gb} GiB"
    fi
}

# --- Execution ---
if [ "$FORMAT" == "json" ]; then
    echo "{"
    echo -n "  " && process_node_data all
    echo "," && echo -n "  " && process_node_data manager
    echo "," && echo -n "  " && process_node_data worker
    echo -e "\n}"
elif [ "$FORMAT" == "csv" ]; then
    echo "Role,OS,NodeCount,TotalCores,AvgCores,TotalGiB,AvgGiB"
    process_node_data all; process_node_data manager; process_node_data worker
else
    process_node_data all; process_node_data manager; process_node_data worker
    process_node_data all linux; process_node_data all windows
    echo "=========================================="
fi
