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
    echo "Audits Docker Swarm node sizing from a ucp-nodes.txt file."
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

# Verify necessary files exist
if [ ! -f ucp-nodes.txt ] || [ ! -f ucp-instance-id.txt ]; then
  echo "ERROR: Unable to find ucp-nodes.txt or ucp-instance-id.txt"
  echo "  Hint: Are you in the directory where the support dump was extracted?"
  exit 1
fi

CLUSTER_ID=$(cat ucp-instance-id.txt)

# Extract CPUs and Memory
# We clean the output to ensure only raw numbers remain
nano_list=$(grep "NanoCPUs" ucp-nodes.txt | awk -F: '{print $2}' | tr -d ' ,"' )
mem_list=$(grep "MemoryBytes" ucp-nodes.txt | awk -F: '{print $2}' | tr -d ' ,"' )

# Initialize stats
CPUs=""
total_cpu=0
total_mem_bytes=0
count=0

# Process CPU list
for nano in $nano_list; do
    [[ -z "$nano" || "$nano" -eq 0 ]] && continue
    cpu=$((nano / 1000000000))
    CPUs="${CPUs}${cpu}"$'\n'
    total_cpu=$((total_cpu + cpu))
    ((count++))
done

# Process Memory list
for mem in $mem_list; do
    [[ -z "$mem" || "$mem" -eq 0 ]] && continue
    total_mem_bytes=$(echo "$total_mem_bytes + $mem" | bc)
done

if [ "$count" -eq 0 ]; then
    echo "ERROR: No valid node data found in ucp-nodes.txt"
    exit 1
fi

# Final Calculations
CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
min_cpu=$(echo "$CPUs" | head -n1)
max_cpu=$(echo "$CPUs" | tail -n1)
avg_cpu=$(echo "scale=2; $total_cpu / $count" | bc)

total_mem_gb=$(echo "scale=2; $total_mem_bytes / 1073741824" | bc)
avg_mem_gb=$(echo "scale=2; $total_mem_gb / $count" | bc)

# --- Output Logic ---
if [ "$FORMAT" == "json" ]; then
    printf '{"cluster_id": "%s", "nodes": %d, "cpu": {"total": %d, "avg": %s}, "mem_gib": {"total": %s, "avg": %s}}\n' \
           "$CLUSTER_ID" "$count" "$total_cpu" "$avg_cpu" "$total_mem_gb" "$avg_mem_gb"
elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,NodeCount,TotalCores,AvgCores,TotalGiB,AvgGiB"
    echo "$CLUSTER_ID,$count,$total_cpu,$avg_cpu,$total_mem_gb,$avg_mem_gb"
else
    echo "------------------------------------------"
    echo " Cluster ID: $CLUSTER_ID"
    echo "------------------------------------------"
    echo " Core Distribution:"
    echo "$CPUs" | uniq -c | while read -r c s; do
        printf "  %2d Core x %d nodes\n" "$s" "$c"
    done
    echo "
# Nodes    - $count
Ttl Cores  - $total_cpu
Ttl RAM    - ${total_mem_gb} GiB
Avg Cores  - $avg_cpu
Avg RAM    - ${avg_mem_gb} GiB"
    echo "------------------------------------------"
fi
