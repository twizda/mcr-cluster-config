# mcr-cluster-config

Audits a Docker Swarm / Mirantis Kubernetes Engine (UCP) cluster and reports node counts, CPU cores and RAM. Results are broken down by role (managers and workers) and OS (Linux and Windows). Use it for license sizing and capacity reviews.

Source code, issues and release notes: **https://github.com/twizda/mcr-cluster-config**

> This image replaces `mirantis/audit-cluster`, which is no longer updated.

## Tags

| Tag | Notes |
|---|---|
| `0.5.2`, `latest` | Singular wording ("1 node") and OS/Arch display fixes; first automated release |
| `0.5.1` | Operating System column (from `docker info`); Orchestrators, Collection and Status columns removed from the table |
| `0.5.0` | Per-node details: role, state, address, engine, MKE orchestrators and status; new `--nodes-csv` option |
| `0.4.1` | Security update: zlib CVE-2026-85091 fixed; Alpine 3.24 base pinned by digest |
| `0.4.0` | Table output and Mirantis-style log messages |
| `0.3.2` | Working `--json` / `--csv` flags |

All tags are built for `linux/amd64` and `linux/arm64`, with build provenance and an SBOM attached.

## Quick start

**On a Swarm manager** (or with a client bundle loaded):

```bash
docker run -t --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e affinity:container==ucp-controller \
  twizda/mcr-cluster-config
```

**From any machine, using a UCP/MKE client bundle:**

```bash
docker run -t --rm \
  -e UCP_URL="ucp.example.com" \
  -v /path/to/your/client/bundle:/data:ro \
  twizda/mcr-cluster-config
```

The bundle's `key.pem` and `cert.pem` are used to authenticate, and `ca.pem` is used to verify the UCP certificate.

## Example output

```text
INFO[0000] Connected to UCP at https://mke.example.com
INFO[0000] Cluster ID: 4ysfudgvpfagt1yy0gwf9viqi
INFO[0000] Connected node: mke-mgr-01, Red Hat Enterprise Linux 8.10 (Ootpa), kernel 4.18.0-553.el8_10.x86_64, engine ucp/3.8.8
INFO[0000] MKE version: 3.8.8
INFO[0000] Retrieved 2 nodes (managers: 1, workers: 1)
WARN[0000] Node mke-wkr-01: state down, availability active (heartbeat failure)

+------------+------------+--------+--------+-------+-----------+--------------+---------------------------------------+-----------+-------+-----------+
| Hostname   | Node ID    | Role   | Avail  | State | Address   | OS/Arch      | Operating System                      | Engine    | vCPUs | RAM (GiB) |
+------------+------------+--------+--------+-------+-----------+--------------+---------------------------------------+-----------+-------+-----------+
| mke-mgr-01 | p8ntfkxhex | leader | active | ready | 10.0.0.11 | linux/x86_64 | Red Hat Enterprise Linux 8.10 (Ootpa) | 25.0.14m1 |     8 |     31.13 |
| mke-wkr-01 | i7bni64o55 | worker | active | down  | 10.0.0.21 | linux/x86_64 | Red Hat Enterprise Linux 8.10 (Ootpa) | 25.0.14m1 |    12 |     62.38 |
+------------+------------+--------+--------+-------+-----------+--------------+---------------------------------------+-----------+-------+-----------+

+------------+-------+-------------+-----------------+
| Node Group | Nodes | Total Cores | Total RAM (GiB) |
+------------+-------+-------------+-----------------+
| Managers   |     1 |           8 |           31.13 |
| Workers    |     1 |          12 |           62.38 |
+------------+-------+-------------+-----------------+
| Linux      |     2 |          20 |           93.52 |
| Windows    |     0 |           0 |            0.00 |
+------------+-------+-------------+-----------------+
| Total      |     2 |          20 |           93.52 |
+------------+-------+-------------+-----------------+
```

The per-node table uses the same information as `docker node ls` and `docker info`: role (including the leader), availability, state, address, OS/architecture, operating system, engine version, vCPUs and RAM. Nodes that aren't `ready` and `active` are also reported as warnings.

**Operating System** comes from each node's `docker info`. Run through MKE (`UCP_URL` with a client bundle) to get it for every node; when run via `docker.sock`, only the node the container runs on is covered, and a warning says so.

Log messages use the standard Mirantis format (`INFO`, `WARN`, `FATA`) and go to stderr. With `-t`, they're colored cyan, yellow and red. Set `NO_COLOR=1` to turn colors off.

## Options

Add an option after the image name:

| Option | Output |
|---|---|
| *(none)* | Per-node table and summary table |
| `--csv` | Summary CSV, one row per node group |
| `--nodes-csv` | Per-node CSV, one row per node |
| `--json` | JSON with the summary and per-node details |
| `--help` | Usage |

To save a report, drop `-t`, otherwise the file gets Windows-style (CRLF) line endings:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  twizda/mcr-cluster-config --nodes-csv > nodes.csv
```

## Environment variables

| Variable | Description |
|---|---|
| `UCP_URL` | UCP/MKE host (no `https://`). If set, the API is reached using the client bundle mounted at `/data`. Otherwise, `/var/run/docker.sock` is used. |
| `NO_COLOR` | Set to any value to turn off colored log output. |

## No API access?

If you only have a UCP support dump, use [`support-dump-count-cores.sh`](https://github.com/twizda/mcr-cluster-config/blob/v0.5.2/support-dump-count-cores.sh) from the GitHub repository. Run it in the extracted dump directory. It produces the same per-node table and totals, without Docker. Per-node details need `jq`.

## Security

- Every release is scanned with Docker Scout and is published only if it has **no fixable critical or high vulnerabilities**. See the Tags tab for each tag's current scan results.
- The container runs as root, because it needs to read `/var/run/docker.sock`. It only sends read-only `GET` requests (`/_ping`, `/info`, `/version`, `/nodes`, `/services`).
- Report security issues through [GitHub](https://github.com/twizda/mcr-cluster-config/issues).
