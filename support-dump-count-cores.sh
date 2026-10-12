#!/bin/bash

# Errors are handled explicitly; log messages go to stderr so --json and --csv
# output on stdout stays clean.

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
    echo "Audits Docker Swarm node sizing from a ucp-nodes.txt file."
    echo "Run it from the directory where the support dump was extracted."
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
for cmd in bc awk; do
    command -v "$cmd" > /dev/null 2>&1 || fatal "Required command '$cmd' is not installed."
done

# Verify necessary files exist
for f in ucp-nodes.txt ucp-instance-id.txt; do
    [ -f "$f" ] || fatal "Unable to find $f in $(pwd). Run this script from the directory where the support dump was extracted."
done

CLUSTER_ID=$(tr -d '[:space:]' < ucp-instance-id.txt)
info "Reading support dump from $(pwd)"
info "Cluster ID: ${CLUSTER_ID}"

# Extract CPUs and Memory
# We clean the output to ensure only raw numbers remain
nano_list=$(grep "NanoCPUs" ucp-nodes.txt | awk -F: '{print $2}' | tr -d ' ,"' )
mem_list=$(grep "MemoryBytes" ucp-nodes.txt | awk -F: '{print $2}' | tr -d ' ,"' )

# Initialize stats
CPUs=""
total_cpu=0
total_mem_bytes=0
count=0
skipped=0

nano_count=$(echo "$nano_list" | grep -c .)
mem_count=$(echo "$mem_list" | grep -c .)
if [ "$nano_count" -eq "$mem_count" ]; then
    # Pair each node's CPU and memory so excluded nodes drop out of both totals
    node_list=$(paste -d' ' <(echo "$nano_list") <(echo "$mem_list"))
else
    warn "ucp-nodes.txt has ${nano_count} NanoCPUs and ${mem_count} MemoryBytes entries; RAM totals may include excluded nodes"
    node_list=$(echo "$nano_list" | awk '{print $1, 0}')
    for mem in $mem_list; do
        total_mem_bytes=$(echo "$total_mem_bytes + $mem" | bc)
    done
fi

# Process each node
while read -r nano mem; do
    [ -z "$nano" ] && continue
    if [ "$nano" -eq 0 ]; then
        skipped=$((skipped + 1))
        continue
    fi
    cpu=$((nano / 1000000000))
    CPUs="${CPUs}${cpu}"$'\n'
    total_cpu=$((total_cpu + cpu))
    total_mem_bytes=$(echo "$total_mem_bytes + ${mem:-0}" | bc)
    count=$((count + 1))
done <<< "$node_list"

[ "$count" -eq 0 ] && fatal "No valid node data found in ucp-nodes.txt"
info "Found ${count} nodes"
[ "$skipped" -gt 0 ] && warn "${skipped} node(s) reported no CPU data and are excluded from the totals"

# Final Calculations (printf adds the leading zero bc omits for values below 1)
CPUs=$(echo "$CPUs" | sed '/^$/d' | sort -n)
avg_cpu=$(printf '%.2f' "$(echo "scale=2; $total_cpu / $count" | bc)")
total_mem_gb=$(printf '%.2f' "$(echo "scale=2; $total_mem_bytes / 1073741824" | bc)")
avg_mem_gb=$(printf '%.2f' "$(echo "scale=2; $total_mem_gb / $count" | bc)")

# --- Output Logic ---
if [ "$FORMAT" == "json" ]; then
    printf '{"cluster_id": "%s", "nodes": %d, "cpu": {"total": %d, "avg": %s}, "mem_gib": {"total": %s, "avg": %s}}\n' \
           "$CLUSTER_ID" "$count" "$total_cpu" "$avg_cpu" "$total_mem_gb" "$avg_mem_gb"
elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,NodeCount,TotalCores,AvgCores,TotalGiB,AvgGiB"
    echo "$CLUSTER_ID,$count,$total_cpu,$avg_cpu,$total_mem_gb,$avg_mem_gb"
else
    # Core distribution
    dist_border="+-------------+-------+"
    echo ""
    echo "$dist_border"
    printf '| %-11s | %5s |\n' "Cores/Node" "Nodes"
    echo "$dist_border"
    echo "$CPUs" | uniq -c | while read -r c s; do
        printf '| %11s | %5s |\n' "$s" "$c"
    done
    echo "$dist_border"

    # Summary
    sum_border="+-------+-------------+-----------------+-----------+---------------+"
    echo ""
    echo "$sum_border"
    printf '| %5s | %11s | %15s | %9s | %13s |\n' "Nodes" "Total Cores" "Total RAM (GiB)" "Avg Cores" "Avg RAM (GiB)"
    echo "$sum_border"
    printf '| %5s | %11s | %15s | %9s | %13s |\n' "$count" "$total_cpu" "$total_mem_gb" "$avg_cpu" "$avg_mem_gb"
    echo "$sum_border"
fi
