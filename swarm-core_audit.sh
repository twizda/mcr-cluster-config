#!/bin/bash

set -e

# --- Version Check ---
BASH_MAJOR_VERSION=${BASH_VERSINFO[0]}
if [ "$BASH_MAJOR_VERSION" -lt 4 ]; then
    # Optional: Log that we are running in legacy compatibility mode
    COMPAT_MODE=true
fi

# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is not installed. This script requires it for parsing API data."
    exit 1
fi

# --- Configuration & Connection Logic ---
# This section determines if we use the local socket or a UCP URL
if [ -n "${UCP_URL}" ]; then
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    # Verify connection and CA requirement
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

# Check Swarm Manager Status
# We check .ID to ensure we are talking to a live manager
if [ "$($CURL_CMD "${BASE_URL}/swarm" | jq -r .ID)" == "null" ]; then
    echo "ERROR: This node is not a Swarm manager."
    exit 1
fi

# Fetch ALL node data once into a variable to avoid repeated API calls
ALL_NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")

# --- Processing Function ---
process_node_data() {
    local role=$1    # all, manager, worker
    local os=$2      # linux, windows, or empty

    # Filter JSON: .[] iterates through the node array
    local filter=".[]"
    [[ "$role" != "all" ]] && filter="$filter | select(.Spec.Role == \"$role\")"
    [[ -n "$os" ]]         && filter="$filter | select(.Description.Platform.OS == \"$os\")"
    
    # Extract NanoCPUs and convert to Cores
    local cores_raw
    cores_raw=$(echo "$ALL_NODES_JSON" | jq -r "$filter | .Description.Resources.NanoCPUs // 0")
    
    # Check if any nodes were found
    if [ -z "$cores_raw" ] || [ "$cores_raw" == "0" ]; then
        return
    fi

    # Convert nano to whole numbers and store in a simple list
    local CPUs=""
    while read -r nano; do
        [[ -z "$nano" ]] && continue
        CPUs="${CPUs}$((nano / 1000000000))"$'\n'
    done <<< "$cores_raw"

    # Clean up trailing newline and sort
    CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
    
    # Stats Calculation using basic tools
    local count=$(echo "$CPUs" | wc -l | tr -d ' ')
    local total=$(echo "$CPUs" | paste -sd+ - | bc)
    local min=$(echo "$CPUs" | head -n1)
    local max=$(echo "$CPUs" | tail -n1)
    local avg=$(echo "scale=2; $total / $count" | bc)

    # --- Print Output ---
    local title="Data for ${role} nodes"
    [[ -n "$os" ]] && title="$title running ${os}"
    
    echo "$title:"

    # Distribution: Using uniq -c to count occurrences (Bash 3.2 friendly)
    echo "$CPUs" | uniq -c | while read -r c s; do
        printf "%d Core x %d\n" "$s" "$c"
    done

    echo "
# Nodes  - $count
Ttl Core - $total
Min Core - $min
Max Core - $max
Avg Core - $avg"
}

# --- Main Execution ---
echo "=========================================="
process_node_data all
echo "=========================================="
process_node_data manager
echo "=========================================="
process_node_data worker
echo "=========================================="
process_node_data all linux
echo "=========================================="
process_node_data all windows
echo "=========================================="
