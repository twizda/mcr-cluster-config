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
* **MKE Admin Credentials** (Username and Password).

---

## Getting Started

### 1. Build the Image
From the root of the `mcr-cluster-config` directory, build the Docker image:

```bash
docker build -t mke-inventory-tool:2.0 .
```

### 2. Run the Inventory Export
To run the tool and save the CSV to your current directory, use the following command.  Replace the environment variables with your cluster details:
```bash
docker run --rm \
  -e MKE_HOST="<MKE_MANAGER_IP_OR_FQDN>" \
  -e MKE_USER="<ADMIN_USERNAME>" \
  -e MKE_PASSWORD="<ADMIN_PASSWORD>" \
  -v "$(pwd)":/app \
  mke-inventory-tool:2.0
```

### 3. Review the Results
Once the container finishes, you will find a file named mke_inventory.csv in your folder.  The CSV includes:
* **Node_ID**: The unique Swarm ID.
* **Hostname**: The system hostname.
* **Role**: Manager or Worker.
* **CPUs**: Total core count.
* **RAM_GB**: Total memory in Gigabytes.
* **State**: Current node health (e.g. ```ready```).
* ** Is_K8s**: Boolean (True/False) indicating if the node is a Kubernetes worker.

Troubleshooting
Connection Refused: Ensure the MKE_HOST is reachable from your Docker container and that you haven't included https:// in the environment variable (the script adds it automatically).

SSL Warnings: The tool is configured to ignore self-signed certificate warnings commonly found in MKE environments.

Auth Failure: Verify that the user has Full Control or Admin permissions within MKE.

Development & Branching
This version is part of the 2.0 release branch.
To contribute or modify:

Bash
git checkout 2.0
# Make changes
git add .
git commit -m "Updated inventory logic"
git push origin 2.0
