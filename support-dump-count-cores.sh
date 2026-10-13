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
    echo "Usage: $0 [--json | --csv | --nodes-csv]"
    echo "Audits Docker Swarm node sizing from a ucp-nodes.txt file."
    echo "Run it from the directory where the support dump was extracted."
    echo ""
    echo "Options:"
    echo "  --json       Output summary (and per-node details, if jq is installed) in JSON format"
    echo "  --csv        Output summary in CSV format"
    echo "  --nodes-csv  Output per-node details in CSV format (requires jq)"
    echo "  --help       Display this help message"
}

# --- Parse Flags ---
case "$1" in
    --json)     FORMAT="json" ;;
    --csv)      FORMAT="csv"  ;;
    --nodes-csv) FORMAT="nodes-csv" ;;
    -h|--help)  usage; exit 0 ;;
    "")         FORMAT="text" ;;
    *)          fatal "Unknown option: $1. Run with --help to see the supported options." ;;
esac

# --- Dependency Check ---
for cmd in bc awk; do
    command -v "$cmd" > /dev/null 2>&1 || fatal "Required command '$cmd' is not installed."
done

# --- Per-node details ---
# Shared with the other audit script (keep in sync): turns a node list into one object per node.
# OS_MAP maps hostnames to the "Operating System" reported by docker info for that node.
OS_MAP='{}'

# Through MKE, docker info (/info) lists every node in SystemStatus, with the node's
# docker info details in a "Labels" entry, e.g. "kernelversion=..., operatingsystem=..., ostype=linux"
SYSTEMSTATUS_OS_JQ='
reduce ((.SystemStatus // [])[] | select(type == "array" and length >= 2)) as $kv ({node: null, map: {}};
    if ($kv[0] | test("^ [^ ]")) then .node = ($kv[0] | ltrimstr(" "))
    elif (.node != null and ($kv[0] | test("Labels$"))) then
        ([($kv[1] // "") | split(", ")[] | select(startswith("operatingsystem=")) | ltrimstr("operatingsystem=")] | first) as $os
        | if $os then .map[.node] = $os else . end
    else . end) | .map'

NODE_JQ='
def two: ((. // 0) * 100 | floor) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length == 1 then "0" + . else . end)";
def lbl($k): (.Spec.Labels // {})[$k];
[ .[] | {
    hostname:         (.Description.Hostname // ""),
    id:               .ID,
    role:             (if .ManagerStatus.Leader == true then "leader" else (.Spec.Role // "") end),
    availability:     (.Spec.Availability // ""),
    state:            (.Status.State // ""),
    addr:             (.Status.Addr // ""),
    os:               (.Description.Platform.OS // ""),
    arch:             (.Description.Platform.Architecture // ""),
    operating_system: ($osmap[.Description.Hostname // ""] // ""),
    engine:           (.Description.Engine.EngineVersion // ""),
    cpus:             ((.Description.Resources.NanoCPUs // 0) / 1000000000 | floor),
    mem_gib:          ((.Description.Resources.MemoryBytes // 0) / 1073741824 | two),
    orchestrators:    [ (if lbl("com.docker.ucp.orchestrator.swarm") == "true" then "swarm" else empty end),
                        (if lbl("com.docker.ucp.orchestrator.kubernetes") == "true" then "kube" else empty end) ],
    collection:       (lbl("com.docker.ucp.access.label") // ""),
    created:          ((.CreatedAt // "")[0:19]),
    updated:          ((.UpdatedAt // "")[0:19]),
    status_message:   (.Status.Message // "")
} ] | sort_by((if .role == "leader" then 0 elif .role == "manager" then 1 else 2 end), .hostname)'

# Empty values are shown as "-" in the table only; CSV and JSON keep them empty
node_table_tsv() {
    printf 'Hostname\tNode ID\tRole\tAvail\tState\tAddress\tOS/Arch\tOperating System\tEngine\tvCPUs\tRAM (GiB)\n'
    echo "$1" | jq -r --argjson osmap "$OS_MAP" "$NODE_JQ"' | .[] | [.hostname, .id[0:10], .role, .availability,
        .state, .addr, (.os + "/" + .arch), .operating_system, .engine, (.cpus | tostring), .mem_gib]
        | map(if . == "" or . == "/" then "-" else . end) | @tsv'
}

node_csv() {
    echo "$1" | jq -r --argjson osmap "$OS_MAP" --arg cid "$2" '["ClusterID","Hostname","NodeID","Role","Availability",
        "State","Address","OS","Arch","OperatingSystem","EngineVersion","vCPUs","RAM_GiB","Created","Updated"],
        ('"$NODE_JQ"' | .[] | [$cid, .hostname, .id, .role, .availability, .state, .addr, .os, .arch,
        .operating_system, .engine, .cpus, (.mem_gib | tonumber), .created, .updated]) | @csv'
}

node_json() {
    echo "$1" | jq -c --argjson osmap "$OS_MAP" "$NODE_JQ"' | map(.mem_gib |= tonumber)'
}

# Logs how many nodes have an operating system, and why any are missing
report_os_coverage() {
    local total found
    total=$(echo "$1" | jq 'length')
    found=$(echo "$1" | jq --argjson osmap "$OS_MAP" '[.[] | select($osmap[.Description.Hostname // ""] != null)] | length')
    if [ "$found" -lt "$total" ]; then
        warn "Operating system found for ${found} of ${total} nodes. $2"
    fi
}

# Prints tab-separated rows (first row is the header) as a bordered table.
# $1 is a comma-separated list of right-aligned column numbers. Long cells are truncated.
print_table() {
    awk -F'\t' -v right="$1" -v maxw=60 '
        BEGIN { n = split(right, r, ","); for (i = 1; i <= n; i++) ra[r[i]] = 1 }
        {
            for (i = 1; i <= NF; i++) {
                v = $i
                if (length(v) > maxw) v = substr(v, 1, maxw - 3) "..."
                cell[NR, i] = v
                if (length(v) > w[i]) w[i] = length(v)
            }
            if (NF > nf) nf = NF
        }
        END {
            sep = "+"
            for (i = 1; i <= nf; i++) { s = ""; for (j = 0; j < w[i] + 2; j++) s = s "-"; sep = sep s "+" }
            print sep
            for (row = 1; row <= NR; row++) {
                line = "|"
                for (i = 1; i <= nf; i++) line = line " " sprintf((ra[i] ? "%" : "%-") w[i] "s", cell[row, i]) " |"
                print line
                if (row == 1) print sep
            }
            print sep
        }'
}

# Builds OS_MAP from any docker info output in the dump, matched to nodes by name:
# text output (" Name:" and " Operating System:" lines) and JSON output (including MKE's SystemStatus)
build_dump_os_map() {
    local map='{}' f name os found
    while IFS= read -r f; do
        name=$(awk '/^ ?Name: /{ print substr($0, index($0, ": ") + 2); exit }' "$f")
        os=$(awk '/^ ?Operating System: /{ print substr($0, index($0, ": ") + 2); exit }' "$f")
        if [ -n "$name" ] && [ -n "$os" ]; then
            map=$(echo "$map" | jq -c --arg n "$name" --arg o "$os" '.[$n] //= $o')
        fi
    done < <(grep -rlIE '^ ?Operating System: ' . 2>/dev/null)
    while IFS= read -r f; do
        found=$(jq -c "[.. | objects | select(has(\"OperatingSystem\") or has(\"SystemStatus\"))
            | ($SYSTEMSTATUS_OS_JQ) + (if (.Name // \"\") != \"\" and (.OperatingSystem // \"\") != \"\" then {(.Name): .OperatingSystem} else {} end)]
            | add // {}" "$f" 2>/dev/null) || continue
        [ -n "$found" ] && map=$(echo "$map" | jq -c --argjson f "$found" '$f + .')
    done < <(grep -rlIE '"(OperatingSystem|SystemStatus)"' . 2>/dev/null)
    echo "$map"
}

# Verify necessary files exist
for f in ucp-nodes.txt ucp-instance-id.txt; do
    [ -f "$f" ] || fatal "Unable to find $f in $(pwd). Run this script from the directory where the support dump was extracted."
done

CLUSTER_ID=$(tr -d '[:space:]' < ucp-instance-id.txt)
info "Reading support dump from $(pwd)"
info "Cluster ID: ${CLUSTER_ID}"

# Per-node details need jq and a JSON node list; the summary works without them
NODES_JSON=""
if ! command -v jq > /dev/null 2>&1; then
    [ "$FORMAT" == "nodes-csv" ] && fatal "--nodes-csv requires jq. Install jq and try again."
    warn "jq is not installed; per-node details are skipped"
elif jq -e 'type == "array"' ucp-nodes.txt > /dev/null 2>&1; then
    NODES_JSON=$(cat ucp-nodes.txt)
    OS_MAP=$(build_dump_os_map)
    report_os_coverage "$NODES_JSON" "The support dump has no docker info output for the other nodes."
    # Flag nodes that are not ready or not active, as "docker node ls" would show them
    echo "$NODES_JSON" | jq -r '.[] | select((.Status.State // "ready") != "ready" or (.Spec.Availability // "active") != "active")
        | "\(.Description.Hostname // .ID): state \(.Status.State), availability \(.Spec.Availability)\(if (.Status.Message // "") != "" then " (" + .Status.Message + ")" else "" end)"' \
        | while read -r line; do warn "Node ${line}"; done
else
    [ "$FORMAT" == "nodes-csv" ] && fatal "ucp-nodes.txt is not a JSON node list; per-node details are unavailable."
    warn "ucp-nodes.txt is not a JSON node list; per-node details are skipped"
fi

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
    node_details=""
    [ -n "$NODES_JSON" ] && node_details=", \"node_details\": $(node_json "$NODES_JSON")"
    printf '{"cluster_id": "%s", "nodes": %d, "cpu": {"total": %d, "avg": %s}, "mem_gib": {"total": %s, "avg": %s}%s}\n' \
           "$CLUSTER_ID" "$count" "$total_cpu" "$avg_cpu" "$total_mem_gb" "$avg_mem_gb" "$node_details"
elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,NodeCount,TotalCores,AvgCores,TotalGiB,AvgGiB"
    echo "$CLUSTER_ID,$count,$total_cpu,$avg_cpu,$total_mem_gb,$avg_mem_gb"
elif [ "$FORMAT" == "nodes-csv" ]; then
    node_csv "$NODES_JSON" "$CLUSTER_ID"
else
    # Per-node details
    if [ -n "$NODES_JSON" ]; then
        echo ""
        node_table_tsv "$NODES_JSON" | print_table 10,11
    fi

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
