# MKE Inventory Tool (v2.0)

This tool provides a lightweight, containerized way to extract a hardware and role inventory from a **Mirantis Kubernetes Engine (MKE) 3.8** cluster. 

It connects to the MKE API, retrieves node metadata (CPU, RAM, Role, and Orchestrator status), and exports the results to a clean CSV file.

## Features
* **No Local Dependencies:** Runs entirely inside Docker; no Python or `requests` library needed on your host.
* **Automated Conversion:** Converts Raw `NanoCPUs` to Cores and `Bytes` to `GB`.
* **Orchestrator Aware:** Identifies if a node is running Kubernetes or Swarm based on MKE-specific labels.

---

## Prerequisites
* **Docker** installed on your machine.
* **Network access** to an MKE Manager node (via HTTPS).
* **MKE Credentials** (Username and Password). Use the least-privileged account that works: the tool only reads `/info`, `/services`, `/nodes` and the `kube-system` pod list. An admin account is guaranteed to work; a read-only (View Only) account may be sufficient but has not yet been verified.
* **MKE CA certificate** (`ca.pem`). It is included in any MKE client bundle, or can be downloaded with `curl -k https://<MKE_HOST>/ca > ca.pem` (verify its fingerprint with your MKE administrator before trusting it).

---

## Getting Started

### 1. Build the Image
From the root of the `mcr-cluster-config` directory, build the Docker image:

```bash
docker build -t mke-inventory-tool:2.0 .
```

### 2. Run the Inventory Export
The container writes its output to `/out`, so mount the host directory you want the CSV in there. Running with your own UID/GID makes the CSV owned by you rather than root.

**Option A: interactive password prompt (recommended).** The password is never written to your shell history or the container environment:
```bash
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e MKE_HOST="<MKE_MANAGER_IP_OR_FQDN>" \
  -e MKE_USER="<USERNAME>" \
  -e MKE_CA_BUNDLE=/certs/ca.pem \
  -v "$(pwd)/ca.pem":/certs/ca.pem:ro \
  -v "$(pwd)":/out \
  mke-inventory-tool:2.0
```

**Option B: password file (for automation).** Store the password in a file only you can read, and mount it read-only:
```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e MKE_HOST="<MKE_MANAGER_IP_OR_FQDN>" \
  -e MKE_USER="<USERNAME>" \
  -e MKE_PASSWORD_FILE=/run/secrets/mke_password \
  -e MKE_CA_BUNDLE=/certs/ca.pem \
  -v "$HOME/.mke_password":/run/secrets/mke_password:ro \
  -v "$(pwd)/ca.pem":/certs/ca.pem:ro \
  -v "$(pwd)":/out \
  mke-inventory-tool:2.0
```
Create the password file with `chmod 600`. `MKE_PASSWORD` is still accepted for backwards compatibility, but avoid passing it with `-e` on the command line: it is recorded in shell history and visible via `ps` and `docker inspect`.

#### Environment variables
| Variable | Required | Description |
|---|---|---|
| `MKE_HOST` | Yes | MKE manager IP or FQDN (no `https://`). |
| `MKE_USER` | Yes | MKE username. |
| `MKE_PASSWORD_FILE` | One of these, or `-it` for a prompt | Path to a file containing the password. |
| `MKE_PASSWORD` | | Password (discouraged, see above). |
| `MKE_CA_BUNDLE` | Recommended | Path to the MKE CA certificate. Without it, the system CA store is used, which only works if MKE has a publicly trusted certificate. |
| `MKE_INSECURE` | No | Set to `true` to disable TLS verification. **Not recommended**: credentials can be intercepted. Prints a warning. |

### 3. Review the Results
Once the container finishes, you will find a file named `mke_cluster_summary.csv` in your folder. The CSV includes:
* **Cluster Name** / **Cluster ID**: The MKE host and Swarm cluster ID.
* **Total Cores** / **Total Nodes**: Aggregate CPU cores and node count.
* **Managers** / **Workers**: Node counts by role.
* **MCR**, **MKE**, **MSR**: Detected product versions.
* **Memory**: Node count per RAM size (e.g. `3x nodes 16GB`).

Cell values that begin with `=`, `+`, `-` or `@` are prefixed with `'` so spreadsheet applications do not evaluate them as formulas.

Troubleshooting
Connection Refused: Ensure the MKE_HOST is reachable from your Docker container and that you haven't included https:// in the environment variable (the script adds it automatically).

TLS verification failed: MKE typically uses a self-signed CA. Set `MKE_CA_BUNDLE` to the MKE `ca.pem` as shown above. Only use `MKE_INSECURE=true` as a last resort on a trusted network.

Permission denied writing the CSV: Run with `--user "$(id -u):$(id -g)"` so the container can write to the mounted directory.

Auth Failure: Verify the username and password, and that the account can read nodes and services in MKE.

Updating dependencies: Python dependencies are pinned with hashes in `requirements.txt`. To update, edit `requirements.in` and regenerate with `pip-compile --generate-hashes --strip-extras --allow-unsafe -o requirements.txt requirements.in`. To update the base image, pull `python:3.11-slim` and replace the digest in the `Dockerfile`.

Development & Branching
This version is part of the 2.0 release branch.
To contribute or modify:

Bash
git checkout 2.0
# Make changes
git add .
git commit -m "Updated inventory logic"
git push origin 2.0
