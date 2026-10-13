#!/bin/bash
# Tests support-dump-count-cores.sh against the dumps in tests/fixtures.
# Usage: tests/run-dump-tests.sh [--update]   (--update rewrites tests/expected after a deliberate change)
TESTS=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$TESTS/../support-dump-count-cores.sh"
EXPECTED="$TESTS/expected"
# shellcheck source=tests/lib.sh
. "$TESTS/lib.sh"
[ "$1" == "--update" ] && UPDATE_GOLDEN=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# run <dir> [args...]: runs the script in <dir>; sets OUT (stdout), ERR (stderr) and RC
run() {
    local dir=$1; shift
    OUT=$(cd "$dir" && "$SHELL_BIN" "$SCRIPT" "$@" 2> "$WORK/stderr"); RC=$?
    ERR=$(cat "$WORK/stderr")
}

# Run the script with the same bash that runs the tests (CI uses /bin/bash on macOS for bash 3.2)
SHELL_BIN=${BASH:-bash}
echo "Support dump tests ($("$SHELL_BIN" --version | head -1))"

for fixture in dump-mke dump-partial dump-legacy; do
    echo "# $fixture"
    for mode in text csv nodes-csv json; do
        if [ "$mode" == "text" ]; then run "$TESTS/fixtures/$fixture"; else run "$TESTS/fixtures/$fixture" "--$mode"; fi
        assert_equals "$mode exits 0" "$RC" "0"
        assert_golden "$mode output matches tests/expected/$fixture.$mode.out" "$OUT" "$EXPECTED/$fixture.$mode.out"
    done
done

echo "# operating system coverage and node warnings"
run "$TESTS/fixtures/dump-mke"
assert_not_contains "dump-mke: every node has an operating system" "$ERR" "Operating system found for"
assert_contains "dump-mke: down node is reported" "$ERR" "] Node mke-wkr-01: state down, availability active (Calico CNI"
assert_contains "dump-mke: drained node is reported" "$ERR" "Node mke-win-01: state ready, availability drain"
assert_contains "dump-mke: singular/plural wording" "$ERR" "Found 4 nodes"
run "$TESTS/fixtures/dump-partial"
assert_contains "dump-partial: text docker info covers one node" "$ERR" "Operating system found for 1 of 4 nodes."
run "$TESTS/fixtures/dump-legacy"
assert_contains "dump-legacy: no docker info in the dump" "$ERR" "Operating system found for 0 of 4 nodes."
assert_not_contains "dump-legacy: no false warnings for missing state fields" "$ERR" "state null"

echo "# without jq"
mkdir -p "$WORK/bin"
for cmd in bc awk grep tr sed sort uniq head tail cat paste wc mktemp; do
    ln -sf "$(command -v "$cmd")" "$WORK/bin/$cmd"
done
OUT=$(cd "$TESTS/fixtures/dump-mke" && PATH="$WORK/bin" "$SHELL_BIN" "$SCRIPT" 2> "$WORK/stderr"); RC=$?; ERR=$(cat "$WORK/stderr")
assert_equals "no jq: text exits 0" "$RC" "0"
assert_contains "no jq: warns that per-node details are skipped" "$ERR" "jq is not installed; per-node details are skipped"
assert_contains "no jq: summary is still printed" "$OUT" "| Nodes | Total Cores |"
assert_not_contains "no jq: no per-node table" "$OUT" "Operating System"
OUT=$(cd "$TESTS/fixtures/dump-mke" && PATH="$WORK/bin" "$SHELL_BIN" "$SCRIPT" --nodes-csv 2> "$WORK/stderr"); RC=$?; ERR=$(cat "$WORK/stderr")
assert_equals "no jq: --nodes-csv exits 1" "$RC" "1"
assert_contains "no jq: --nodes-csv explains why" "$ERR" "] --nodes-csv requires jq"

echo "# errors and options"
mkdir -p "$WORK/empty"
run "$WORK/empty"
assert_equals "missing dump files: exits 1" "$RC" "1"
assert_contains "missing dump files: FATA message" "$ERR" "] Unable to find ucp-nodes.txt"
mkdir -p "$WORK/textdump"
printf 'Node 1\n    "NanoCPUs": 4000000000,\n    "MemoryBytes": 17179869184,\n' > "$WORK/textdump/ucp-nodes.txt"
echo "TEXT" > "$WORK/textdump/ucp-instance-id.txt"
run "$WORK/textdump"
assert_equals "non-JSON ucp-nodes.txt: exits 0" "$RC" "0"
assert_contains "non-JSON ucp-nodes.txt: warns" "$ERR" "ucp-nodes.txt is not a JSON node list; per-node details are skipped"
assert_contains "non-JSON ucp-nodes.txt: summary from grep parser" "$OUT" "|     1 |           4 |           16.00 |"
assert_contains "singular wording for one node" "$ERR" "Found 1 node"
assert_not_contains "no \"1 nodes\"" "$ERR" "1 nodes"
run "$TESTS/fixtures/dump-mke" --xml
assert_equals "unknown option: exits 1" "$RC" "1"
assert_contains "unknown option: FATA message" "$ERR" "] Unknown option: --xml"
run "$TESTS/fixtures/dump-mke" --help
assert_equals "--help exits 0" "$RC" "0"
assert_contains "--help lists --nodes-csv" "$OUT" "--nodes-csv"

summary
