#!/bin/bash

# Force stdout/stderr to be unbuffered
exec 1>&2

set -eo pipefail #Exit on error AND catch errors in pipes
# --- Version Check ---
BASH_MAJOR_VERSION=${BASH_VERSINFO[0]}
echo "DEBUG: Starting script in Bash version $BASH_MAJOR_VERSION"

# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is not installed. This script requires it for parsing API data."
    exit 1
fi

# --- Version Check ---
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
# --- Improved Configuration & Connection Logic ---
if [ -n "${UCP_URL}" ]; then
    echo "DEBUG: Attempting to connect to UCP at ${UCP_URL}..."
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    
    if ! curl -s --cacert /data/ca.pem "https://${UCP_URL}/_ping" | grep -q "OK"; then
        echo "DEBUG: Ping with CA cert failed, trying without..."
        if ! curl -s "https://${UCP_URL}/_ping" | grep -q "OK"; then
            echo "ERROR: UCP endpoint unreachable at https://${UCP_URL}/_ping"
            exit 1
        fi
        BASE_URL="https://${UCP_URL}"
    else
        CURL_CMD="$CURL_CMD --cacert /data/ca.pem"
        BASE_URL="https://${UCP_URL}"
    fi
else
    echo "DEBUG: No UCP_URL set. Attempting to use local Docker socket..."
    CURL_CMD="curl -s -m 5 --unix-socket /var/run/docker.sock"
    BASE_URL="http://v1.30"
    
    if [ ! -S /var/run/docker.sock ]; then
        echo "ERROR: Docker socket not found at /var/run/docker.sock. Did you mount the volume?"
        exit 1
    fi
fi

# Check Swarm Manager Status
SWARM_ID=$($CURL_CMD "${BASE_URL}/swarm" | jq -r .ID 2>/dev/null || echo "null")
if [ "$SWARM_ID" == "null" ]; then
    echo "ERROR: API returned null or connection failed. This node may not be a Swarm manager."
    exit 1
fi
echo "DEBUG: Successfully connected to Swarm ID: $SWARM_ID"

# Check Swarm Status
if [ "$($CURL_CMD "${BASE_URL}/swarm" | jq -r .ID)" == "null" ]; then
    echo "ERROR: This node is not a Swarm manager."
    exit 1
fi

# Fetch ALL node data
ALL_NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")

# --- Processing Function ---
# --- Processing Function (v0.3.1) ---
process_node_data() {
    local role=$1
    local os=$2
    
    # Filter JSON: .[] iterates through the node array
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"
    
    # Extract NanoCPUs and MemoryBytes
    local raw_data
    raw_data=$(echo "$ALL_NODES_JSON" | jq -r "$filter | \"\(.Description.Resources.NanoCPUs // 0) \(.Description.Resources.MemoryBytes // 0)\"" 2>/dev/null)
    
    # Skip if no nodes match the filter
    if [[ -z "${raw_data// }" ]]; then 
        return 
    fi

    # Initialize stats for each run
    local CPUs=""
    local total_cpu=0
    local total_mem_bytes=0
    local count=0

    # Process the raw data line by line
    while read -r nano mem; do
        [[ -z "$nano" || "$nano" -eq 0 ]] && continue
        
        # Convert NanoCPUs to whole Cores
        local cpu=$((nano / 1000000000))
        CPUs="${CPUs}${cpu}"$'\n'
        total_cpu=$((total_cpu + cpu))
        
        # Accumulate total RAM bytes
        total_mem_bytes=$(echo "$total_mem_bytes + $mem" | bc)
        ((count++))
    done <<< "$raw_data"

    # Exit function if no valid nodes were processed
    if [ "$count" -eq 0 ]; then return; fi

    # Sort and calculate CPU stats
    CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
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
        
        # Print Core Distribution
        echo "$CPUs" | uniq -c | while read -r c s; do
            printf "  %2d Core x %d nodes\n" "$s" "$c"
        done
        
        # Print Summary Stats
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
