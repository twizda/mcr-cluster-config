# mcr-cluster-config

Audits a Docker Swarm / Mirantis Kubernetes Engine (UCP) cluster and reports node counts, CPU cores and RAM. Results are broken down by role (managers and workers) and OS (Linux and Windows). Use it for license sizing and capacity reviews.

Source code, issues and release notes: **https://github.com/twizda/mcr-cluster-config**

> This image replaces `mirantis/audit-cluster`, which is no longer updated.

## Tags

| Tag | Notes |
|---|---|
| `0.4.1`, `latest` | Security update: zlib CVE-2026-85091 fixed; Alpine 3.24 base pinned by digest |
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
INFO[0000] Connected to the Docker API via /var/run/docker.sock
INFO[0000] Cluster ID: ym2kpp6s655tvztn3yblhr12t
INFO[0000] Retrieved 2 nodes

+------------+-------+-------------+-----------------+
| Node Group | Nodes | Total Cores | Total RAM (GiB) |
+------------+-------+-------------+-----------------+
| Managers   |     1 |          14 |            7.74 |
| Workers    |     1 |          14 |            7.74 |
+------------+-------+-------------+-----------------+
| Linux      |     2 |          28 |           15.49 |
| Windows    |     0 |           0 |            0.00 |
+------------+-------+-------------+-----------------+
| Total      |     2 |          28 |           15.49 |
+------------+-------+-------------+-----------------+
```

Log messages use the standard Mirantis format (`INFO`, `WARN`, `FATA`) and go to stderr. With `-t`, they're colored cyan, yellow and red. Set `NO_COLOR=1` to turn colors off.

## Options

Add an option after the image name:

| Option | Output |
|---|---|
| *(none)* | Text table |
| `--csv` | CSV, one row per node group |
| `--json` | JSON |
| `--help` | Usage |

To save a report, drop `-t`, otherwise the file gets Windows-style (CRLF) line endings:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  twizda/mcr-cluster-config --csv > cluster_report.csv
```

## Environment variables

| Variable | Description |
|---|---|
| `UCP_URL` | UCP/MKE host (no `https://`). If set, the API is reached using the client bundle mounted at `/data`. Otherwise, `/var/run/docker.sock` is used. |
| `NO_COLOR` | Set to any value to turn off colored log output. |

## No API access?

If you only have a UCP support dump, use [`support-dump-count-cores.sh`](https://github.com/twizda/mcr-cluster-config/blob/v0.4.1/support-dump-count-cores.sh) from the GitHub repository. Run it in the extracted dump directory. It produces the same totals, without Docker.

## Security

- Docker Scout reports **0 known vulnerabilities** for `0.4.1` (amd64 and arm64).
- The container runs as root, because it needs to read `/var/run/docker.sock`. It only sends read-only `GET` requests (`/_ping`, `/nodes`, `/info`).
- Report security issues through [GitHub](https://github.com/twizda/mcr-cluster-config/issues).
