#!/bin/bash

# Default format
FORMAT="text"

# Help menu
usage() {
    echo "Usage: $0 [--json | --csv]"
    echo "Checks CPU core counts from Docker Swarm ucp-nodes.txt"
    exit 1
}

# Parse flags
case "$1" in
    --json) FORMAT="json" ;;
    --csv)  FORMAT="csv"  ;;
    -h|--help) usage ;;
esac

# Check for required files
if [[ ! -f ucp-nodes.txt ]] || [[ ! -f ucp-instance-id.txt ]]; then
    echo "ERROR: Required files (ucp-nodes.txt or ucp-instance-id.txt) not found."
    exit 1
fi

# Variables
CLUSTER_ID=$(cat ucp-instance-id.txt)
# Extract NanoCPUs and convert to whole Cores immediately
CORES_LIST=$(grep NanoCPUs ucp-nodes.txt | awk -F '[: ,]+' '{print $3/1000000000}')

# Stats Calculation
total_cpu=0
count=0
min_cpu=999
max_cpu=0

# Populate an associative array for the "X Core x Y Nodes" breakdown
declare -A size_counts

for cpu in $CORES_LIST; do
    total_cpu=$(echo "$total_cpu + $cpu" | bc)
    ((count++))
    ((cpu < min_cpu)) && min_cpu=$cpu
    ((cpu > max_cpu)) && max_cpu=$cpu
    ((size_counts[$cpu]++))
done

avg_cpu=$(echo "scale=2; $total_cpu / $count" | bc)

# --- Output Logic ---

if [ "$FORMAT" == "json" ]; then
    # Constructing a simple JSON object
    echo "{"
    echo "  \"cluster_id\": \"$CLUSTER_ID\","
    echo "  \"node_count\": $count,"
    echo "  \"total_cores\": $total_cpu,"
    echo "  \"min_cores\": $min_cpu,"
    echo "  \"max_cores\": $max_cpu,"
    echo "  \"avg_cores\": $avg_cpu,"
    echo "  \"breakdown\": {"
    first=true
    for size in "${!size_counts[@]}"; do
        if [ "$first" = true ]; then first=false; else echo ","; fi
        echo -n "    \"${size}_core\": ${size_counts[$size]}"
    done
    echo -e "\n  }"
    echo "}"

elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,NodeCount,TotalCores,MinCores,MaxCores,AvgCores"
    echo "$CLUSTER_ID,$count,$total_cpu,$min_cpu,$max_cpu,$avg_cpu"

else
    # Improved Text Output
    echo "------------------------------------------"
    echo " Cluster ID: $CLUSTER_ID"
    echo "------------------------------------------"
    printf "%-15s : %s\n" "Total Nodes" "$count"
    printf "%-15s : %s\n" "Total Cores" "$total_cpu"
    printf "%-15s : %s\n" "Min/Max/Avg" "$min_cpu / $max_cpu / $avg_cpu"
    echo "------------------------------------------"
    echo " Core Distribution:"
    for size in $(echo "${!size_counts[@]}" | tr ' ' '\n' | sort -n); do
        printf "  %2d Core x %d nodes\n" "$size" "${size_counts[$size]}"
    done
    echo "------------------------------------------"
fi
