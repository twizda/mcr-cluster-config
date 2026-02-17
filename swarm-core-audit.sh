#!/bin/bash

# Removed 'set -e' to prevent silent crashes; we'll handle errors manually.
# Removed 'exec 1>&2' to ensure output stays on the standard channel.

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
    echo "ERROR: Cannot connect to Docker API."
    exit 1
fi

# --- Processing Function (Original Style) ---
process_node_data() {
    local role=$1
    local os=$2
    
    # Filter strings
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"

    # 1. Get CPU Cores directly
    local cores_raw=$($CURL_CMD "${BASE_URL}/nodes" | jq -r "$filter | .Description.Resources.NanoCPUs // 0")
    
    # 2. Get Memory Bytes directly
    local mem_raw=$($CURL_CMD "${BASE_URL}/nodes" | jq -r "$filter | .Description.Resources.MemoryBytes // 0")

    if [ -z "$cores_raw" ] || [ "$cores_raw" = "0" ]; then
        return
    fi

    # Math for Cores
    local total_cores=0
    local node_count=0
    for nano in $cores_raw; do
        total_cores=$((total_cores + (nano / 1000000000)))
        ((node_count++))
    done

    # Math for Memory
    local total_mem_bytes=0
    for bytes in $mem_raw; do
        total_mem_bytes=$(echo "$total_mem_bytes + $bytes" | bc)
    done
    local total_mem_gb=$(echo "scale=2; $total_mem_bytes / 1073741824" | bc)

    # Simple Output
    echo "=========================================="
    echo "Data for $role nodes ${os:+($os)}:"
    echo "# Nodes    - $node_count"
    echo "Ttl Cores  - $total_cores"
    echo "Ttl RAM    - $total_mem_gb GiB"
}

# --- Execution ---
process_node_data all
process_node_data manager
process_node_data worker
process_node_data all linux
process_node_data all windows
echo "=========================================="
