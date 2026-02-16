#!/bin/bash

set -e

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
    echo "Audits live Docker Swarm nodes for CPU core counts."
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

# --- Version Check ---
BASH_MAJOR_VERSION=${BASH_VERSINFO[0]}

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

# Fetch ALL node data once
ALL_NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")

# --- Processing Function ---
process_node_data() {
    local role=$1
    local os=$2
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"
    
    local cores_raw=$(echo "$ALL_NODES_JSON" | jq -r "$filter | .Description.Resources.NanoCPUs // 0")
    
    if [ -z "$cores_raw" ] || [ "$cores_raw" == "0" ]; then
        return
    fi

    local CPUs=""
    while read -r nano; do
        [[ -z "$nano" ]] && continue
        CPUs="${CPUs}$((nano / 1000000000))"$'\n'
    done <<< "$cores_raw"

    CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
    local count=$(echo "$CPUs" | wc -l | tr -d ' ')
    local total=$(echo "$CPUs" | paste -sd+ - | bc)
    local min=$(echo "$CPUs" | head -n1)
    local max=$(echo "$CPUs" | tail -n1)
    local avg=$(echo "scale=2; $total / $count" | bc)

    # --- Output Logic ---
    if [ "$FORMAT" == "json" ]; then
        # Building JSON fragments
        local key="${role}_${os:-all}"
        printf '"%s": {"count": %d, "total": %d, "min": %d, "max": %d, "avg": %s}' \
               "$key" "$count" "$total" "$min" "$max" "$avg"
    elif [ "$FORMAT" == "csv" ]; then
        echo "${role},${os:-all},$count,$total,$min,$max,$avg"
    else
        local title="Data for ${role} nodes"
        [[ -n "$os" ]] && title="$title running ${os}"
        echo "=========================================="
        echo "$title:"
        echo "$CPUs" | uniq -c | while read -r c s; do
            printf "%d Core x %d\n" "$s" "$c"
        done
        echo -e "\n# Nodes  - $count\nTtl Core - $total\nMin Core - $min\nMax Core - $max\nAvg Core - $avg"
    fi
}

# --- Execution ---
if [ "$FORMAT" == "json" ]; then
    echo "{"
    echo -n "  " && process_node_data all
    echo "," && echo -n "  " && process_node_data manager
    echo "," && echo -n "  " && process_node_data worker
    echo "," && echo -n "  " && process_node_data all linux
    echo "," && echo -n "  " && process_node_data all windows
    echo -e "\n}"
elif [ "$FORMAT" == "csv" ]; then
    echo "Role,OS,NodeCount,TotalCores,MinCores,MaxCores,AvgCores"
    process_node_data all
    process_node_data manager
    process_node_data worker
    process_node_data all linux
    process_node_data all windows
else
    process_node_data all
    process_node_data manager
    process_node_data worker
    process_node_data all linux
    process_node_data all windows
    echo "=========================================="
fi
