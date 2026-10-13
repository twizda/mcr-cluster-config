#!/bin/bash

# Removed 'set -e' to prevent silent crashes; we'll handle errors manually.
# Log messages go to stderr so --json and --csv output on stdout stays clean.

# --- Default Format ---
FORMAT="text"

# >>> shared:logging (keep identical in both scripts; checked by tests/check-shared-code.sh)
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

# Logs the release version when running from the image (the Dockerfile sets it)
log_version() { [ -n "${MCR_CLUSTER_CONFIG_VERSION}" ] && info "mcr-cluster-config version ${MCR_CLUSTER_CONFIG_VERSION}"; return 0; }

# Prints a count with a singular or plural noun, e.g. "1 node", "2 nodes"
plural() { if [ "$1" -eq 1 ]; then echo "$1 $2"; else echo "$1 ${2}s"; fi; }

# <<< shared:logging

# --- Usage Function ---
usage() {
    echo "Usage: $0 [--json | --csv | --nodes-csv]"
    echo "Audits Docker Swarm node sizing via the Docker/UCP API."
    echo ""
    echo "Options:"
    echo "  --json       Output cluster summary and per-node details in JSON format"
    echo "  --csv        Output the summary by node group in CSV format"
    echo "  --nodes-csv  Output per-node details in CSV format"
    echo "  --help       Display this help message"
}

# --- Parse Flags ---
case "$1" in
    --json)       FORMAT="json" ;;
    --csv)        FORMAT="csv"  ;;
    --nodes-csv)  FORMAT="nodes-csv" ;;
    -h|--help)    usage; exit 0 ;;
    "")           FORMAT="text" ;;
    *)            fatal "Unknown option: $1. Run with --help to see the supported options." ;;
esac

log_version

# --- Dependency Check ---
for cmd in curl jq bc awk; do
    command -v "$cmd" > /dev/null 2>&1 || fatal "Required command '$cmd' is not installed."
done

# >>> shared:node-details (keep identical in both scripts; checked by tests/check-shared-code.sh)
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
        .state, .addr, ([.os, .arch] | map(select(. != "")) | join("/")), .operating_system, .engine,
        (.cpus | tostring), .mem_gib] | map(if . == "" then "-" else . end) | @tsv'
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
        warn "Operating system found for ${found} of $(plural "$total" node). $2"
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
# <<< shared:node-details

# --- Configuration ---
if [ -n "${UCP_URL}" ]; then
    for f in /data/key.pem /data/cert.pem; do
        [ -f "$f" ] || fatal "Missing $f. You must mount an extracted client bundle with \"-v /path/to/bundle:/data:ro\". If the client bundle is loaded in your shell (DOCKER_HOST is set), the container runs on the cluster and the -v path refers to a cluster node: run it from a shell without the bundle loaded."
    done
    CURL_CMD="curl -s -m 15 --key /data/key.pem --cert /data/cert.pem"
    if [ -f /data/ca.pem ]; then
        CURL_CMD="$CURL_CMD --cacert /data/ca.pem"
    else
        warn "No ca.pem found in /data; verifying the UCP certificate against the system CA store."
    fi
    BASE_URL="https://${UCP_URL}"
    API_DESC="MKE at ${BASE_URL}"
else
    [ -S /var/run/docker.sock ] || fatal "Missing docker.sock. You must run the container with \"-v /var/run/docker.sock:/var/run/docker.sock\" (on SELinux hosts such as RHEL, also add \"--security-opt label=disable\"), or set UCP_URL with a client bundle mounted at /data"
    CURL_CMD="curl -s -m 5 --unix-socket /var/run/docker.sock"
    BASE_URL="http://v1.30"
    API_DESC="the Docker API via /var/run/docker.sock"
fi

# Basic check to see if we can talk to the API
if ! $CURL_CMD "${BASE_URL}/_ping" > /dev/null; then
    fatal "Unable to connect to ${API_DESC}."
fi
info "Connected to ${API_DESC}"

# Fetch all node data in a single request (equivalent to "docker node ls")
NODES_JSON=$($CURL_CMD "${BASE_URL}/nodes")
if ! echo "$NODES_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
    reason=$(echo "$NODES_JSON" | jq -r '.message // empty' 2>/dev/null)
    fatal "Unable to list nodes: ${reason:-this engine must be a Swarm manager}"
fi

# Cluster details (equivalent to "docker info" and "docker version")
INFO_JSON=$($CURL_CMD "${BASE_URL}/info")
CLUSTER_ID=$(echo "$INFO_JSON" | jq -r '.Swarm.Cluster.ID // "unknown"' 2>/dev/null)
[ -z "$CLUSTER_ID" ] && CLUSTER_ID="unknown"
info "Cluster ID: ${CLUSTER_ID}"

# Through MKE, /info describes MKE's controller rather than a node, so only describe a real engine
if ! echo "$INFO_JSON" | jq -e '(.ServerVersion // "") | startswith("ucp/")' > /dev/null 2>&1; then
    info "Connected node: $(echo "$INFO_JSON" | jq -r '"\(.Name // "unknown"), \(.OperatingSystem // "unknown OS"), kernel \(.KernelVersion // "unknown"), engine \(.ServerVersion // "unknown")"' 2>/dev/null)"
fi

# Operating system per node: MKE lists every node in SystemStatus; a plain engine only describes itself
OS_MAP=$(echo "$INFO_JSON" | jq -c "($SYSTEMSTATUS_OS_JQ) + (if (.Name // \"\") != \"\" and (.OperatingSystem // \"\") != \"\" then {(.Name): .OperatingSystem} else {} end)" 2>/dev/null)
[ -z "$OS_MAP" ] && OS_MAP='{}'

# Through MKE, /version reports the MKE version as "ucp/<version>"
MKE_VERSION=$($CURL_CMD "${BASE_URL}/version" | jq -r '.Version // empty | select(startswith("ucp/")) | ltrimstr("ucp/")' 2>/dev/null)
# MSR (formerly DTR) runs as Swarm services; take the version from the image tag
MSR_VERSION=$($CURL_CMD "${BASE_URL}/services" | jq -r 'if type == "array" then [.[].Spec.TaskTemplate.ContainerSpec.Image // ""
    | select(test("(mirantis|docker)/dtr")) | split("@")[0] | split(":")[1] // empty] | first // empty else empty end' 2>/dev/null)
[ -n "$MKE_VERSION" ] && info "MKE version: ${MKE_VERSION}"
[ -n "$MSR_VERSION" ] && info "MSR version: ${MSR_VERSION}"

node_total=$(echo "$NODES_JSON" | jq 'length')
manager_total=$(echo "$NODES_JSON" | jq '[.[] | select(.Spec.Role == "manager")] | length')
no_resources=$(echo "$NODES_JSON" | jq '[.[] | select((.Description.Resources.NanoCPUs // 0) == 0)] | length')
info "Retrieved $(plural "$node_total" node) (managers: ${manager_total}, workers: $((node_total - manager_total)))"
[ "$no_resources" -gt 0 ] && warn "$(plural "$no_resources" node) reported no CPU data (excluded from the totals)"
if [ -n "${UCP_URL}" ]; then
    report_os_coverage "$NODES_JSON" "MKE's docker info did not list the other nodes."
else
    report_os_coverage "$NODES_JSON" "docker info on this engine only describes this node; set UCP_URL with an MKE client bundle to get every node's operating system."
fi

# Flag nodes that are not ready or not active, as "docker node ls" would show them
echo "$NODES_JSON" | jq -r '.[] | select((.Status.State // "ready") != "ready" or (.Spec.Availability // "active") != "active")
    | "\(.Description.Hostname // .ID): state \(.Status.State), availability \(.Spec.Availability)\(if (.Status.Message // "") != "" then " (" + .Status.Message + ")" else "" end)"' \
    | while read -r line; do warn "Node ${line}"; done

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
    printf '{"cluster_id": "%s", "mke_version": "%s", "msr_version": "%s", "groups": [%s], "nodes": %s}\n' \
        "$CLUSTER_ID" "$MKE_VERSION" "$MSR_VERSION" "$entries" "$(node_json "$NODES_JSON")"
elif [ "$FORMAT" == "csv" ]; then
    echo "ClusterID,Role,OS,NodeCount,TotalCores,TotalGiB"
    for group in $GROUPS_LIST; do
        process_node_data "${group%%:*}" "${group#*:}"
        echo "$CLUSTER_ID,${group%%:*},${group#*:},$NODE_COUNT,$TOTAL_CORES,$TOTAL_MEM_GB"
    done
elif [ "$FORMAT" == "nodes-csv" ]; then
    node_csv "$NODES_JSON" "$CLUSTER_ID"
else
    # Per-node details
    echo ""
    node_table_tsv "$NODES_JSON" | print_table 10,11

    # Summary by node group
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
