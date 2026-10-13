# mirantis/mcr-cluster-config

Docker image for auditing a Swarm/UCP cluster to return the core counts and other sizing stats based on `alpine:latest`.

To pull this image:
`docker pull twizda/mcr-cluster-config`

> **Note:** This project was previously published as `mirantis/audit-cluster`. That image is no longer updated; use `twizda/mcr-cluster-config` instead.

The Docker Hub description is maintained in [DOCKERHUB.md](DOCKERHUB.md). Update it with each release, and paste it into the repository settings on Docker Hub.

## v0.2 Enhancements
* **Performance Optimization**: API calls are now bundled, fetching all node data in a single request to reduce network overhead.
* **Output Formats**: Added support for `--json` and `--csv` flags for both live audit and support dump scripts.
* **Cross-Platform Support**: Optimized for both modern Linux (Bash 4+) and legacy macOS (Bash 3.2).
* **CLI Options**: Integrated a usage menu and flag parsing for better usability.
* **Memory**: Adds output for node memory

## Example Usage

There are three methods to run this audit:

1. [**On the cluster**](#on-the-cluster) - Run it directly on a manager via the Docker socket.
2. [**On a local engine**](#on-a-local-engine) - Communicate to UCP APIs using a client bundle.
3. [**From a UCP support dump**](#from-a-ucp-support-dump) - Analyze static files locally using the provided script.

### CLI Flags
Both `swarm-core-audit.sh` (the container's entrypoint) and `support-dump-count-cores.sh` support the following:
* `--json`: Output the summary and per-node details in JSON format.
* `--csv`: Output the summary by node group in CSV format.
* `--nodes-csv`: Output per-node details in CSV format, one row per node.
* `--help`: Display the usage menu.

When running the container, add the flag after the image name. Drop `-t` when redirecting output to a file, otherwise the file gets Windows-style (CRLF) line endings:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock twizda/mcr-cluster-config --nodes-csv > nodes.csv
```

In `--csv` and `--json` output, every group (all, manager, worker, linux, windows) is included, even when it has zero nodes, so the columns stay consistent between clusters.

### Collected data
The audit uses the same information as `docker info`, `docker version` and `docker node ls`.

**Cluster:** cluster ID; the connected node's OS, kernel and engine version; MKE version (when connected through MKE) and MSR version (when MSR runs on the cluster).

**Per node:**

| Column | Source |
|---|---|
| Hostname, Node ID | Node description and ID |
| Role | `leader`, `manager` or `worker` |
| Avail, State | Availability (active, pause, drain) and state (ready, down) |
| Address | Node IP address |
| OS/Arch, Engine | Platform and MCR engine version |
| vCPUs, RAM (GiB) | Node resources |
| Orchestrators, Collection | MKE labels: `swarm` and/or `kube`, and the access collection (for example `/System`, `/Shared`) |
| Status | Status message, for example MKE's `Healthy MKE manager` or the reason a node is down |

Nodes that aren't `ready` and `active` are also reported as `WARN` messages. `--nodes-csv` and `--json` add each node's full ID and its created and updated times.

Uptime, OS release (for example RHEL 8.10), hypervisor and GPU aren't available from the node list, so they aren't collected.

### Example output
By default, the audit prints a per-node table followed by a summary table. Progress and error messages are written to stderr in the standard Mirantis log format (`INFO`, `WARN`, `FATA`), so redirecting `--csv`, `--nodes-csv` or `--json` output to a file captures only the data. With `-t`, levels are colored (cyan, yellow and red); set `NO_COLOR=1` to turn colors off.

```text
INFO[0000] Connected to the Docker API via /var/run/docker.sock
INFO[0000] Cluster ID: 4ysfudgvpfagt1yy0gwf9viqi
INFO[0000] Connected node: mke-mgr-01, Red Hat Enterprise Linux 8.10 (Ootpa), kernel 4.18.0-553.el8_10.x86_64, engine 25.0.14m1
INFO[0000] MKE version: 3.8.8
INFO[0000] Retrieved 2 nodes (managers: 1, workers: 1)
WARN[0000] Node mke-wkr-01: state down, availability active (heartbeat failure)

+------------+------------+--------+--------+-------+-----------+--------------+-----------+-------+-----------+---------------+------------+---------------------+
| Hostname   | Node ID    | Role   | Avail  | State | Address   | OS/Arch      | Engine    | vCPUs | RAM (GiB) | Orchestrators | Collection | Status              |
+------------+------------+--------+--------+-------+-----------+--------------+-----------+-------+-----------+---------------+------------+---------------------+
| mke-mgr-01 | p8ntfkxhex | leader | active | ready | 10.0.0.11 | linux/x86_64 | 25.0.14m1 |     8 |     31.13 | swarm+kube    | /System    | Healthy MKE manager |
| mke-wkr-01 | i7bni64o55 | worker | active | down  | 10.0.0.21 | linux/x86_64 | 25.0.14m1 |    12 |     62.38 | kube          | /Shared    | heartbeat failure   |
+------------+------------+--------+--------+-------+-----------+--------------+-----------+-------+-----------+---------------+------------+---------------------+

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

Status messages longer than 60 characters are shortened in the table; `--nodes-csv` and `--json` contain the full text.

If the container can't reach the API, it exits with an error such as:

```text
FATA[0000] Missing docker.sock. You must run the container with "-v /var/run/docker.sock:/var/run/docker.sock" or set UCP_URL with a client bundle mounted at /data
```

### On the cluster

1. Load a UCP client bundle (or skip the bundle and run directly on a manager).
2. Run the container:

    ```bash
    docker run -t --rm --name mcr-cluster-config \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e affinity:container==ucp-controller \
      twizda/mcr-cluster-config
    ```

### On a local engine

1. Find your UCP URL and the local path to your extracted client bundle.
2. Run the container locally, updating `UCP_URL` and the volume path:

    ```bash
    docker run -t --rm --name mcr-cluster-config \
      -e UCP_URL="ucp.example.com" \
      -v /path/to/your/client/bundle:/data:ro \
      twizda/mcr-cluster-config
    ```

### From a UCP support dump

Analyze static files from a support dump locally. This is useful when API access is restricted.

Run the script from the directory where the support dump was extracted. By default it prints the same per-node table as the container (read from the dump's `ucp-nodes.txt`), followed by a core-distribution table and a summary table. It needs `bash`, `awk` and `bc`, and works with the bash 3.2 that ships with macOS. Per-node details also need `jq`; without it, the script prints a warning and shows only the summary.

```bash
./support-dump-count-cores.sh --csv > cluster_report.csv
