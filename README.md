# MKE Inventory Tool (v3.0)

This tool provides a lightweight, containerized way to extract a cluster inventory summary from a **Mirantis Kubernetes Engine (MKE) 3.8** cluster.

It connects to the MKE API, retrieves node metadata (CPU, RAM and role) along with the installed MCR, MKE and MSR versions, and exports a one-row cluster summary to a CSV file ready for spreadsheet import.

## Features
* **No Local Dependencies:** Runs entirely inside Docker; no Python or `requests` library needed on your host.
* **Automated Conversion:** Converts raw `NanoCPUs` to cores and bytes to GB, and groups nodes by memory size.
* **Version Detection:** Reports MCR, MKE and MSR versions, using Swarm services, the Kubernetes API, and node labels as fallbacks.
* **Secure by Default:** Verifies the MKE TLS certificate, keeps the password out of the command line, runs as a non-root user, and uses hash-pinned dependencies. See [Security](#security).

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
docker build -t mke-inventory-tool:3.0 .
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
  mke-inventory-tool:3.0
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
  mke-inventory-tool:3.0
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

## Security
* **TLS verification** is on by default. Provide MKE's CA with `MKE_CA_BUNDLE`; `MKE_INSECURE=true` disables verification and prints a warning.
* **Credentials:** prefer the interactive prompt (`-it`) or `MKE_PASSWORD_FILE`. Passing `MKE_PASSWORD` with `-e` exposes it in shell history, `ps` and `docker inspect`.
* **Container:** the script lives in `/opt/mke-inventory` and runs as an unprivileged user (uid 10001); only `/out` should be mounted.
* **Output:** CSV cells beginning with `=`, `+`, `-` or `@` are prefixed with `'` to prevent formula injection in spreadsheet applications.
* **Supply chain:** the base image is pinned by digest and Python dependencies by version and hash. Packaging tools (`pip`, `setuptools`, `wheel`) are removed from the runtime image.

To scan before releasing a new image:
```bash
pip-audit --require-hashes -r requirements.txt
```
```bash
docker scout cves mke-inventory-tool:3.0
```

---

## Troubleshooting
**Connection Refused:** Ensure the MKE_HOST is reachable from your Docker container and that you haven't included https:// in the environment variable (the script adds it automatically).

**TLS verification failed:** MKE typically uses a self-signed CA. Set `MKE_CA_BUNDLE` to the MKE `ca.pem` as shown above. Only use `MKE_INSECURE=true` as a last resort on a trusted network.

**Permission denied writing the CSV:** Run with `--user "$(id -u):$(id -g)"` so the container can write to the mounted directory.

**Auth Failure:** Verify the username and password, and that the account can read nodes and services in MKE.

**Updating dependencies:** Python dependencies are pinned with hashes in `requirements.txt`. To update, edit `requirements.in` and regenerate with `pip-compile --generate-hashes --strip-extras --allow-unsafe -o requirements.txt requirements.in`. To update the base image, pull `python:3.11-slim` and replace the digest in the `Dockerfile`.

---

## Development & Branching
This version is part of the 3.0 release branch. To contribute or modify, create a feature branch from `3.0` and open a pull request against it:

```bash
git checkout 3.0
git checkout -b my-change
# Make changes
git add .
git commit -m "Updated inventory logic"
git push origin my-change
```
