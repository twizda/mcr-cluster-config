import requests
import csv
import os
import sys
from collections import Counter

# Get environment variables
MKE_HOST = os.getenv("MKE_HOST")
USERNAME = os.getenv("MKE_USER")
PASSWORD = os.getenv("MKE_PASSWORD")

def get_inventory():
    if not all([MKE_HOST, USERNAME, PASSWORD]):
        print("Error: Please provide MKE_HOST, MKE_USER, and MKE_PASSWORD.")
        sys.exit(1)

    # Clean up MKE_HOST just in case
    host = MKE_HOST.replace("https://", "").replace("http://", "").strip("/")
    base_url = f"https://{host}"
    
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

    headers = {"Authorization": f"Bearer {token}"}

    # 2. Pull Cluster Info
    print("[*] Fetching cluster info...")
    try:
        info_resp = requests.get(f"{base_url}/info", headers=headers, verify=False)
        info_data = info_resp.json()
        cluster_id = info_data.get('Swarm', {}).get('Cluster', {}).get('ID', 'Unknown')
    except Exception:
        cluster_id = "Unknown"

    # 3. Pull Versions from Swarm Services (Primary for MSR and MKE)
    print("[*] Searching Swarm services for MSR and MKE versions...")
    msr_version = "N/A"
    mke_container_ver = None
    
    try:
        svc_resp = requests.get(f"{base_url}/services", headers=headers, verify=False)
        if svc_resp.ok:
            for svc in svc_resp.json():
                spec = svc.get('Spec', {})
                task_template = spec.get('TaskTemplate', {})
                container_spec = task_template.get('ContainerSpec', {})
                image = container_spec.get('Image', '')
                
                # Check for MSR/DTR
                if ('mirantis/dtr' in image or 'docker/dtr' in image) and msr_version == "N/A":
                    # Extracts version, e.g., mirantis/dtr-api:2.9.19@sha256:...
                    msr_version = image.split(':', 1)[-1].split('@')[0]
                
                # Check for MKE/UCP
                if ('mirantis/ucp' in image) and not mke_container_ver:
                    mke_container_ver = image.split(':', 1)[-1].split('@')[0]
        else:
            print(f"[-] /services API returned HTTP {svc_resp.status_code}")
    except Exception as e:
        print(f"[-] Error fetching services: {e}")

    # Fallback for MKE version via Kubernetes API (if Swarm services didn't catch it)
    if not mke_container_ver:
        print("[*] Falling back to Kubernetes API for MKE version...")
        try:
            k8s_resp = requests.get(f"{base_url}/kubernetes/api/v1/namespaces/kube-system/pods", headers=headers, verify=False)
            if k8s_resp.ok:
                for pod in k8s_resp.json().get('items', []):
                    for container in pod.get('spec', {}).get('containers', []):
                        image = container.get('image', '')
                        if 'mirantis/ucp' in image and not mke_container_ver:
                            mke_container_ver = image.split(':', 1)[-1].split('@')[0]
                            break
            else:
                print(f"[-] /kubernetes API returned HTTP {k8s_resp.status_code}")
        except Exception as e:
            print(f"[-] Error fetching Kubernetes pods: {e}")

    # 4. Pull Node Data and Aggregate
    print("[*] Fetching node metadata and aggregating totals...")
    node_resp = requests.get(f"{base_url}/nodes", headers=headers, verify=False)
    nodes = node_resp.json()

    total_nodes = len(nodes)
    total_cores = 0
    managers = 0
    workers = 0
    mcr_versions = set()
    
    mke_version = mke_container_ver or "N/A"
    memory_counts = Counter()

    for node in nodes:
        spec = node.get('Spec', {})
        desc = node.get('Description', {})
        
        # Roles
        if spec.get('Role') == 'manager':
            managers += 1
        else:
            workers += 1
            
        # MCR (Engine) Version
        engine_ver = desc.get('Engine', {}).get('EngineVersion')
        if engine_ver:
            mcr_versions.add(engine_ver)
            
        # MKE Version Check: Node Labels (Fallback 3)
        if mke_version == "N/A":
            node_labels = spec.get('Labels', {})
            if 'com.docker.ucp.version' in node_labels:
                mke_version = node_labels['com.docker.ucp.version']
                
            engine_labels = desc.get('Engine', {}).get('Labels', {})
            if 'com.docker.ucp.version' in engine_labels:
                mke_version = engine_labels['com.docker.ucp.version']
            
        # Resources (CPU & RAM)
        res = desc.get('Resources', {})
        cpus = res.get('NanoCPUs', 0) / 1_000_000_000
        total_cores += cpus
        
        ram_gb = round(res.get('MemoryBytes', 0) / (1024**3))
        memory_counts[ram_gb] += 1

    mem_strings = []
    for ram, count in sorted(memory_counts.items()):
        mem_strings.append(f"{count}x nodes {ram}GB")
    memory_str = "\n".join(mem_strings)
    
    mcr_str = ", ".join(mcr_versions)

    # 5. Write to CSV
    output_file = "mke_cluster_summary.csv"
    with open(output_file, mode='w', newline='') as f:
        writer = csv.writer(f)
        
        writer.writerow([
            "Cluster Name", "Cluster ID", "Total Cores", "Total Nodes", 
            "Managers", "Workers", "MCR", "MKE", "MSR", 
            "CPU Type/Model", "Memory"
        ])
        
        writer.writerow([
            MKE_HOST,
            cluster_id,
            int(total_cores),
            total_nodes,
            managers,
            workers,
            mcr_str,
            mke_version,
            msr_version,
            "Unknown (Not in API)",
            memory_str
        ])

    print(f"[+] Success! Cluster summary written to {output_file}")

if __name__ == "__main__":
    requests.packages.urllib3.disable_warnings()
    get_inventory()
