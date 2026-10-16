# twizda/mcr-cluster-config

Audits a Docker Swarm / Mirantis Kubernetes Engine (MKE, formerly UCP) cluster and reports every node's role, state, operating system, engine version, vCPUs and RAM, with totals by role and OS. Use it for license sizing and capacity reviews.

The project has two scripts:
- **`swarm-core-audit.sh`** reads a live cluster through the Docker or MKE API. It is the entrypoint of the [`twizda/mcr-cluster-config`](https://hub.docker.com/r/twizda/mcr-cluster-config) image.
- **`support-dump-count-cores.sh`** reads an extracted MKE support dump, for when you have no API access.

```bash
docker pull twizda/mcr-cluster-config
```

`docker run` doesn't re-download an image that's already on your machine, so run `docker pull` again to update a cached `latest` after each release.

> **Note:** This project was previously published as `mirantis/audit-cluster`. That image is no longer updated; use `twizda/mcr-cluster-config` instead.

## Ways to run the audit

| Method | Use when | Operating system shown for |
|---|---|---|
| [**Through MKE with a client bundle**](#through-mke-with-a-client-bundle-recommended) (recommended) | You can download an MKE client bundle | All nodes |
| [**On a manager node**](#on-a-manager-node) | You're on a Swarm manager without MKE, or can't use a client bundle | Only the node the container runs on |
| [**From a support dump**](#from-a-support-dump) | You only have an MKE support dump | Nodes with `docker info` output in the dump |
| [**On Windows Server**](#on-windows-server) | The cluster is MCR on Windows Server only, with no Linux machine available | Only the node the script runs on (all nodes through MKE) |

### Through MKE with a client bundle (recommended)

1. Download and extract a client bundle for an MKE user that can view nodes.
2. Run the container from any machine with Docker, pointing `UCP_URL` at MKE and mounting the bundle at `/data`:

    ```bash
    docker run -t --rm --name mcr-cluster-config \
      -e UCP_URL="mke.example.com" \
      -v /path/to/your/client/bundle:/data:ro \
      twizda/mcr-cluster-config
    ```

The bundle's `key.pem` and `cert.pem` are used to authenticate, and `ca.pem` is used to verify MKE's certificate.

Run this with your local Docker, in a shell where the client bundle is **not** loaded (no `source env.sh`). With the bundle loaded, `docker run` starts the container on the cluster, so the `-v` path refers to a cluster node and `/data` is empty.

### On a manager node

Run the container on a Swarm manager with the Docker socket mounted:

```bash
docker run -t --rm --name mcr-cluster-config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  twizda/mcr-cluster-config
```

On SELinux-enforcing hosts such as RHEL, also add `--security-opt label=disable`, otherwise the container can't access the socket. With an MKE client bundle loaded in your shell, add `-e affinity:container==ucp-controller` so MKE schedules the container on a manager. Either way, the container talks to that node's local engine, so the **Operating System** column is filled in only for that node, and a `WARN` says so. Use the client-bundle method above to get every node's operating system.

### From a support dump

Extract the support dump, then run the support-dump script from the image, in the dump's top-level directory. You don't need a local copy of the script or any tools other than Docker:

```bash
cd docker-support-<cluster>-<date>
docker run --rm -v "$PWD":/dump:ro -w /dump --entrypoint support-dump-count-cores.sh twizda/mcr-cluster-config
```

Add `--csv`, `--nodes-csv` or `--json` at the end for other formats. On SELinux-enforcing hosts such as RHEL, also add `--security-opt label=disable`.

Or run the script directly from a checkout of this repository:

```bash
cd docker-support-<cluster>-<date>
/path/to/mcr-cluster-config/support-dump-count-cores.sh
```

Run directly, it needs `bash`, `awk` and `bc`, and works with the bash 3.2 that ships with macOS. Per-node details also need `jq`; without it, the script prints a warning and shows only the summary. The image includes all of these.

Either way, it prints the same per-node table as the live audit, read from the dump's `ucp-nodes.txt`, with each node's operating system taken from any `docker info` output in the dump. That's followed by a core-distribution table and a summary table.

### On Windows Server

The image is a Linux container, so it can't run on Windows Server. On a Windows Swarm manager, use the PowerShell version of the audit, `windows/swarm-core-audit.ps1`. It needs no container: only the `docker` CLI that MCR installs and Windows PowerShell 5.1 or later (included in Windows Server 2016 and later). Run PowerShell as Administrator, or as a member of the `docker-users` group:

```powershell
powershell -ExecutionPolicy Bypass -File .\swarm-core-audit.ps1
```

It prints the same tables, log messages and CSV/JSON as the container. Use `-Csv`, `-NodesCsv` or `-Json` for other formats, and `-OutFile <file>` to save them as UTF-8 (redirecting with `>` in Windows PowerShell 5.1 writes UTF-16). Run `Get-Help .\swarm-core-audit.ps1 -Detailed` for all options.

Without MKE, `docker info` only describes the node the script runs on, so the **Operating System** column is filled in for that node only; run the script on each node if you need every node's operating system. With an MKE client bundle loaded (`env.ps1`), every node's operating system is reported.

## Options

Both scripts accept the same options:

| Option | Output |
|---|---|
| *(none)* | Per-node table and summary table |
| `--csv` | Summary CSV, one row per node group |
| `--nodes-csv` | Per-node CSV, one row per node |
| `--json` | Summary and per-node details in JSON |
| `--help` | Usage |

When running the container, add the option after the image name. Drop `-t` when redirecting output to a file, otherwise the file gets Windows-style (CRLF) line endings:

```bash
docker run --rm -e UCP_URL="mke.example.com" -v /path/to/bundle:/data:ro \
  twizda/mcr-cluster-config --nodes-csv > nodes.csv
```

In `--csv` and `--json` output, every group (all, manager, worker, linux, windows) is included, even when it has zero nodes, so the columns stay consistent between clusters.

### Environment variables

| Variable | Description |
|---|---|
| `UCP_URL` | MKE host (no `https://`). If set, the API is reached using the client bundle mounted at `/data`. Otherwise, `/var/run/docker.sock` is used. |
| `NO_COLOR` | Set to any value to turn off colored log output. |

## Collected data
The audit uses the same information as `docker info`, `docker version` and `docker node ls`.

**Cluster:** cluster ID; the connected node's OS, kernel and engine version; MKE version (when connected through MKE) and MSR version (when MSR runs on the cluster).

**Per node:**

| Column | Source |
|---|---|
| Hostname, Node ID | Node description and ID |
| Role | `leader`, `manager` or `worker` |
| Avail, State | Availability (active, pause, drain) and state (ready, down) |
| Address | Node IP address |
| OS/Arch | Platform, for example `linux/x86_64` |
| Operating System | The `Operating System:` line from `docker info` for that node, for example `Red Hat Enterprise Linux 8.10 (Ootpa)` |
| Engine | MCR engine version |
| vCPUs, RAM (GiB) | Node resources |

`docker info` only describes the engine it's run against, so where the operating system comes from depends on how you run the audit:

| Run mode | Nodes with an operating system |
|---|---|
| Through MKE (`UCP_URL` with a client bundle) | All nodes. MKE's `docker info` lists every node with its operating system. |
| On a manager via `docker.sock` | Only the node the container runs on |
| From a support dump | Every node with `docker info` output in the dump (text or JSON, matched by node name) |

When some nodes have no operating system, the audit prints a `WARN` saying how many were found and why the rest are missing, and shows `-` for them.

Nodes that aren't `ready` and `active` are also reported as `WARN` messages, with the node's status message. `--nodes-csv` adds each node's full ID and its created and updated times. `--json` also includes MKE's orchestrator labels (`swarm`, `kube`), access collection and each node's status message.

Uptime, hypervisor and GPU aren't available from `docker info` or `docker node ls`, so they aren't collected.

## Example output
By default, the audit prints a per-node table followed by a summary table. Progress and error messages are written to stderr in the standard Mirantis log format (`INFO`, `WARN`, `FATA`), so redirecting `--csv`, `--nodes-csv` or `--json` output to a file captures only the data. With `-t`, levels are colored (cyan, yellow and red); set `NO_COLOR=1` to turn colors off.

```text
INFO[0000] mcr-cluster-config version 0.5.4
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

Values longer than 60 characters are shortened in the table; `--nodes-csv` and `--json` contain the full text.

If the container can't reach the API, it exits with an error such as:

```text
FATA[0000] Missing docker.sock. You must run the container with "-v /var/run/docker.sock:/var/run/docker.sock" or set UCP_URL with a client bundle mounted at /data
```

## Development

### Tests
The `tests` directory has three test scripts. CI runs all of them on every pull request and push to `main`; see `.github/workflows/ci.yml`.

| Script | What it checks | Needs |
|---|---|---|
| `tests/check-shared-code.sh` | The code shared by both scripts is identical | `bash` |
| `tests/run-dump-tests.sh` | The support-dump script against the sample dumps in `tests/fixtures`, compared with `tests/expected` | `bash`, `jq`, `bc` |
| `tests/run-swarm-tests.sh` | The image against a throwaway two-node Docker-in-Docker swarm, and a mock MKE API. Also saves the reference output in `tests/expected/audit-*` | Docker (privileged containers) |
| `tests/run-powershell-tests.ps1` | `windows/swarm-core-audit.ps1` against the mock clusters; its output must match the same `tests/expected/audit-*` files as the Linux audit. On PowerShell 7, every test runs a second time with Windows PowerShell 5.1's JSON behavior | PowerShell 5.1 or 7 |
| `tests/run-windows-swarm-tests.ps1` | `windows/swarm-core-audit.ps1` against a real Windows engine in Swarm mode, compared with `docker info` and `docker node ls`. Creates (and afterwards leaves) a single-node swarm if the engine isn't in one | Docker in Windows containers mode (MCR on Windows Server, or Docker Desktop), as Administrator |

CI also runs ShellCheck and PSScriptAnalyzer, runs the support-dump tests on macOS with its built-in bash 3.2, and runs both PowerShell test scripts on a Windows Server runner with Windows PowerShell 5.1 and PowerShell 7.

After a deliberate output change, regenerate the expected files, then review the diff before committing:

```bash
tests/run-dump-tests.sh --update
```

### Shared code
Both scripts contain the same logging and per-node code, between `# >>> shared:<name>` and `# <<< shared:<name>` markers. The copies let the support-dump script be downloaded on its own. Change both copies together; `tests/check-shared-code.sh` fails if they differ.

### Releases
Releases are published by `.github/workflows/release.yml` when a `v0.x` tag is pushed.

1. **Prepare.** Bump the version and update [DOCKERHUB.md](DOCKERHUB.md) and [HARBOR.md](HARBOR.md), then open a pull request with the result:

    ```bash
    scripts/prepare-release.sh 0.5.2 "Short description for the Docker Hub tags table"
    ```

2. **Publish.** After the pull request merges, tag `main` with an annotated tag and push it:

    ```bash
    git checkout main && git pull
    git tag -a v0.5.2 -m "Release v0.5.2: Short title" \
      -m "One or two sentences on what changed for users." \
      -m "- Notable change
    - Another notable change"
    git push origin v0.5.2
    ```

    The tag message's first line (without `Release `) becomes the release title. The rest of the message becomes the summary at the top of the release notes, written in Markdown. Each `-m` starts a new paragraph. Git removes lines starting with `#` from tag messages, so don't use Markdown headings; add `--cleanup=verbatim` if you need them. To write a longer message in your editor, run `git tag -a v0.5.2` with no `-m`.

    To preview the notes before pushing the tag, run `scripts/release-notes.sh v0.5.2`.

The workflow then does the rest:
1. Checks that the tag is on `main` and matches the `Dockerfile` version.
2. Runs the full CI suite.
3. Builds and pushes the `linux/amd64` and `linux/arm64` image, with provenance and an SBOM.
4. Runs Docker Scout and stops if there are any fixable critical or high vulnerabilities. In that case `latest` and the release are left untouched.
5. Moves `latest`.
6. Updates the Docker Hub description from `DOCKERHUB.md`.
7. Creates the GitHub release: the tag message summary, the image and scan result, and the pull requests merged since the previous release.

**Afterwards, copy the image to the Mirantis registry.** The workflow has no credentials for `registry.ci.mirantis.com`, so this step is manual. Once the release workflow finishes, run the following while logged in with `docker login registry.ci.mirantis.com`:

```bash
scripts/push-mirantis-registry.sh 0.5.2
```

The script copies the published image to `registry.ci.mirantis.com/pvt-twizda/mcr-cluster-config` without rebuilding it, so both platforms and the attestations are kept. It tags `<version>` and `latest`, then checks that both match Docker Hub.

Then paste [HARBOR.md](HARBOR.md) into the repository's **Info** tab in Harbor. `prepare-release.sh` updates its tags table and version references alongside `DOCKERHUB.md`, but nothing updates Harbor automatically.

To check the pipeline without publishing anything, run the **Release** workflow manually from the Actions tab. It builds both platforms and runs the tests, but skips every publishing step.

The workflow needs the repository variable `DOCKERHUB_USERNAME` and the secret `DOCKERHUB_TOKEN`, a Docker Hub personal access token with Read, Write, Delete scope.

The `3.0` branch holds a separate tool, the Python MKE inventory tool, released as `v3.x`. Releases on `main` (`v0.x`) are this Swarm/MKE audit.
