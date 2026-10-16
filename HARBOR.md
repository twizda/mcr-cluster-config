# mcr-cluster-config

Audits a Docker Swarm / Mirantis Kubernetes Engine (MKE, formerly UCP) cluster and reports every node's role, state, operating system, engine version, vCPUs and RAM, with totals by role and OS. Use it for license sizing and capacity reviews.

Source code, issues and release notes: **https://github.com/twizda/mcr-cluster-config**

> This repository holds copies of the releases published on Docker Hub as [`twizda/mcr-cluster-config`](https://hub.docker.com/r/twizda/mcr-cluster-config). Each tag here is the same image (same digest) as the matching Docker Hub tag.

## Tags

| Tag | Notes |
|---|---|
| `0.6.0`, `latest` | PowerShell audit for Windows Server, attached to each release |
| `0.5.4` | Support-dump script included in the image (--entrypoint support-dump-count-cores.sh) |
| `0.5.3` | Clearer MKE connection messages; hints for client-bundle and SELinux setup errors |
| `0.5.2` | Singular wording ("1 node") and OS/Arch display fixes |

Tags are built for `linux/amd64` and `linux/arm64`, with build provenance and an SBOM attached. Older releases are available on [Docker Hub](https://hub.docker.com/r/twizda/mcr-cluster-config/tags).

## Pulling the image

This is a private project. Log in first:

```bash
docker login registry.ci.mirantis.com
docker pull registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config:0.6.0
```

## Quick start

**Through MKE with a client bundle (recommended).** Every node's operating system is reported:

```bash
docker run -t --rm \
  -e UCP_URL="mke.example.com" \
  -v /path/to/your/client/bundle:/data:ro \
  registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config
```

The bundle's `key.pem` and `cert.pem` are used to authenticate, and `ca.pem` is used to verify MKE's certificate.

Run this with your local Docker, in a shell where the client bundle is **not** loaded (no `source env.sh`). With the bundle loaded, `docker run` starts the container on the cluster, so the `-v` path refers to a cluster node and `/data` is empty.

**On a Swarm manager.** The operating system is reported only for the node the container runs on:

```bash
docker run -t --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config
```

With an MKE client bundle loaded in your shell, add `-e affinity:container==ucp-controller` so MKE schedules the container on a manager. On SELinux-enforcing hosts such as RHEL, also add `--security-opt label=disable`, otherwise the container can't access the socket.

## Example output

```text
INFO[0000] mcr-cluster-config version 0.6.0
INFO[0000] Connected to MKE at https://mke.example.com
INFO[0000] Cluster ID: 4ysfudgvpfagt1yy0gwf9viqi
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

The per-node table uses the same information as `docker node ls` and `docker info`. Nodes that aren't `ready` and `active` are also reported as warnings. Log messages use the standard Mirantis format (`INFO`, `WARN`, `FATA`) and go to stderr; with `-t`, they're colored. Set `NO_COLOR=1` to turn colors off.

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
docker run --rm -e UCP_URL="mke.example.com" -v /path/to/bundle:/data:ro \
  registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config --nodes-csv > nodes.csv
```

## Environment variables

| Variable | Description |
|---|---|
| `UCP_URL` | MKE host (no `https://`). If set, the API is reached using the client bundle mounted at `/data`. Otherwise, `/var/run/docker.sock` is used. |
| `NO_COLOR` | Set to any value to turn off colored log output. |

## Windows Server (no container)

This image is a Linux container, so it can't run on Windows Server. For clusters that run MCR on Windows Server, each release also includes a PowerShell version of the audit with the same output: [`swarm-core-audit.ps1`](https://github.com/twizda/mcr-cluster-config/releases/download/v0.6.0/swarm-core-audit.ps1), with its [SHA-256](https://github.com/twizda/mcr-cluster-config/releases/download/v0.6.0/swarm-core-audit.ps1.sha256). It needs only the `docker` CLI and Windows PowerShell 5.1 or later. On a Swarm manager, as Administrator:

```powershell
powershell -ExecutionPolicy Bypass -File .\swarm-core-audit.ps1
```

See the [README](https://github.com/twizda/mcr-cluster-config#on-windows-server) for download and verification steps.

## No API access?

If you only have an MKE support dump, the image can audit it too. Extract the dump, then run this in its top-level directory:

```bash
docker run --rm -v "$PWD":/dump:ro -w /dump --entrypoint support-dump-count-cores.sh registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config
```

It prints the same per-node table and totals as the live audit, with each node's operating system taken from the `docker info` output in the dump. Add `--csv`, `--nodes-csv` or `--json` for other formats. On SELinux-enforcing hosts such as RHEL, also add `--security-opt label=disable`.

The same script, [`support-dump-count-cores.sh`](https://github.com/twizda/mcr-cluster-config/blob/v0.6.0/support-dump-count-cores.sh), can also be run directly from the GitHub repository; it needs `bash`, `awk`, `bc` and `jq`.

## Security

- Every release is scanned with Docker Scout before publishing, and is released only if it has **no fixable critical or high vulnerabilities**. The images here are copied from Docker Hub without rebuilding, so they're identical to the scanned images.
- The container runs as root, because it needs to read `/var/run/docker.sock`. It only sends read-only `GET` requests (`/_ping`, `/info`, `/version`, `/nodes`, `/services`).
- Report security issues through [GitHub](https://github.com/twizda/mcr-cluster-config/issues).
