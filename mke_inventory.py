import requests
import json
import csv
import os
import sys

# Get environment variables from Docker run
MKE_HOST = os.getenv("MKE_HOST")
USERNAME = os.getenv("MKE_USER")
PASSWORD = os.getenv("MKE_PASSWORD")

def get_inventory():
    if not all([MKE_HOST, USERNAME, PASSWORD]):
        print("Error: Please provide MKE_HOST, MKE_USER, and MKE_PASSWORD.")
        sys.exit(1)

    base_url = f"https://{MKE_HOST}"
    
    # 1. Authenticate
    print(f"[*] Connecting to {base_url}...")
    try:
        auth_resp = requests.post(
            f"{base_url}/auth/login", 
            json={"username": USERNAME, "password": PASSWORD}, 
            verify=False
        )
        auth_resp.raise_for_status()
        token = auth_resp.json().get("auth_token")
    except Exception as e:
        print(f"[-] Authentication failed: {e}")
        sys.exit(1)

    # 2. Pull Node Data
    print("[*] Fetching node metadata...")
    headers = {"Authorization": f"Bearer {token}"}
    node_resp = requests.get(f"{base_url}/nodes", headers=headers, verify=False)
    nodes = node_resp.json()

    # 3. Parse and Write to CSV
    output_file = "mke_inventory.csv"
    with open(output_file, mode='w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Node_ID", "Hostname", "Role", "CPUs", "RAM_GB", "State", "Is_K8s"])

        for node in nodes:
            n_id = node.get('ID')
            spec = node.get('Spec', {})
            desc = node.get('Description', {})
            status = node.get('Status', {})
            
            # Check MKE labels for K8s status
            labels = spec.get('Labels', {})
            is_k8s = labels.get('com.docker.ucp.orchestrator.kubernetes') == 'true'
            
            # Resources
            res = desc.get('Resources', {})
            cpus = res.get('NanoCPUs', 0) / 1_000_000_000
            ram_gb = round(res.get('MemoryBytes', 0) / (1024**3))

            writer.writerow([
                n_id,
                desc.get('Hostname'),
                spec.get('Role'),
                f"{cpus:.0f}",
                ram_gb,
                status.get('State'),
                is_k8s
            ])

    print(f"[+] Success! Inventory written to {output_file}")

if __name__ == "__main__":
    requests.packages.urllib3.disable_warnings()
    get_inventory()
