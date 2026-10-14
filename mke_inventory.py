import requests
import csv
import getpass
import os
import sys
import time
from collections import Counter

# Get environment variables
MKE_HOST = os.getenv("MKE_HOST")
USERNAME = os.getenv("MKE_USER")
PASSWORD = os.getenv("MKE_PASSWORD")
PASSWORD_FILE = os.getenv("MKE_PASSWORD_FILE")
CA_BUNDLE = os.getenv("MKE_CA_BUNDLE")
INSECURE = os.getenv("MKE_INSECURE", "").lower() in ("1", "true", "yes")
OUTPUT_DIR = os.getenv("OUTPUT_DIR", ".")

# (connect, read) timeouts in seconds
TIMEOUT = (15, 60)

# Leading characters that spreadsheet apps interpret as a formula
FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")

# Release version, set by the Dockerfile (unset when run outside the image)
VERSION = os.getenv("MKE_INVENTORY_VERSION")

# --- Logging ---
# Mirrors the logrus text format used by Mirantis tooling (and the audit scripts on main),
# e.g. "INFO[0000] message". Levels are colored only when stderr is a terminal and NO_COLOR is unset.
START = time.monotonic()
COLOR = sys.stderr.isatty() and not os.getenv("NO_COLOR")
LEVEL_COLORS = {"INFO": "\033[36m", "WARN": "\033[33m", "FATA": "\033[31m"}


def log(level, message):
    elapsed = int(time.monotonic() - START)
    name = f"{LEVEL_COLORS[level]}{level}\033[0m" if COLOR else level
    print(f"{name}[{elapsed:04d}] {message}", file=sys.stderr, flush=True)


def info(message):
    log("INFO", message)


def warn(message):
    log("WARN", message)


def fatal(message):
    log("FATA", message)
    sys.exit(1)


def plural(count, noun):
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def get_password():
    if PASSWORD_FILE:
        try:
            with open(PASSWORD_FILE) as f:
                return f.read().rstrip("\r\n")
        except OSError as e:
            fatal(f"Unable to read MKE_PASSWORD_FILE: {e}")
    if PASSWORD:
        return PASSWORD
    if sys.stdin.isatty():
        return getpass.getpass("MKE password: ")
    return None


def get_verify():
    if INSECURE:
        warn("MKE_INSECURE is set: TLS certificate verification is DISABLED. "
             "Credentials and API responses can be intercepted; do not use on untrusted networks.")
        requests.packages.urllib3.disable_warnings()
        return False
    if CA_BUNDLE:
        if not os.path.isfile(CA_BUNDLE):
            fatal(f"MKE_CA_BUNDLE file not found: {CA_BUNDLE}. Mount the MKE ca.pem, for example "
                  f"\"-v /path/to/bundle/ca.pem:{CA_BUNDLE}:ro\".")
        return CA_BUNDLE
    return True


def csv_safe(value):
    # Neutralize values that a spreadsheet would evaluate as a formula
    if isinstance(value, str) and value.startswith(FORMULA_PREFIXES):
        return "'" + value
    return value


def get_inventory():
    if VERSION:
        info(f"MKE inventory tool version {VERSION}")

    if not MKE_HOST or not USERNAME:
        fatal("MKE_HOST and MKE_USER must be set.")
    password = get_password()
    if not password:
        fatal("No password provided. Run with -it to be prompted, or set MKE_PASSWORD_FILE.")

    # Clean up MKE_HOST just in case
    host = MKE_HOST.replace("https://", "").replace("http://", "").strip("/")
    base_url = f"https://{host}"

    session = requests.Session()
    session.verify = get_verify()

    # 1. Authenticate
    try:
        auth_resp = session.post(
            f"{base_url}/auth/login",
            json={"username": USERNAME, "password": password},
            timeout=TIMEOUT
        )
        auth_resp.raise_for_status()
        token = auth_resp.json().get("auth_token")
    except requests.exceptions.SSLError as e:
        fatal(f"TLS verification failed for {base_url}: {e}. "
              "Set MKE_CA_BUNDLE to the MKE CA certificate (ca.pem from a client bundle).")
    except requests.exceptions.ConnectionError as e:
        fatal(f"Unable to connect to MKE at {base_url}: {e}")
    except Exception as e:
        fatal(f"Authentication failed for user {USERNAME}: {e}")

    if not token:
        fatal(f"Authentication failed for user {USERNAME}: no auth_token in the response.")
    info(f"Connected to MKE at {base_url} as {USERNAME}")

    session.headers["Authorization"] = f"Bearer {token}"

    # 2. Pull Cluster Info
    try:
        info_resp = session.get(f"{base_url}/info", timeout=TIMEOUT)
        info_resp.raise_for_status()
        info_data = info_resp.json()
        cluster_id = info_data.get('Swarm', {}).get('Cluster', {}).get('ID', 'Unknown')
    except Exception as e:
        warn(f"Unable to read cluster info (/info): {e}")
        cluster_id = "Unknown"
    info(f"Cluster ID: {cluster_id}")

    # 3. Pull Versions from Swarm Services (Primary for MSR and MKE)
    msr_version = "N/A"
    mke_container_ver = None

    try:
        svc_resp = session.get(f"{base_url}/services", timeout=TIMEOUT)
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
            warn(f"Unable to list services (/services returned HTTP {svc_resp.status_code}); "
                 "MSR is reported as N/A and the MKE version is looked up elsewhere")
    except Exception as e:
        warn(f"Unable to list services (/services): {e}")

    # Fallback for MKE version via Kubernetes API (if Swarm services didn't catch it)
    if not mke_container_ver:
        info("MKE version not found in Swarm services; checking the Kubernetes API")
        try:
            k8s_resp = session.get(f"{base_url}/kubernetes/api/v1/namespaces/kube-system/pods", timeout=TIMEOUT)
            if k8s_resp.ok:
                for pod in k8s_resp.json().get('items', []):
                    for container in pod.get('spec', {}).get('containers', []):
                        image = container.get('image', '')
                        if 'mirantis/ucp' in image and not mke_container_ver:
                            mke_container_ver = image.split(':', 1)[-1].split('@')[0]
                            break
            else:
                warn(f"Unable to list kube-system pods (Kubernetes API returned HTTP {k8s_resp.status_code})")
        except Exception as e:
            warn(f"Unable to list kube-system pods (Kubernetes API): {e}")

    # 4. Pull Node Data and Aggregate
    try:
        node_resp = session.get(f"{base_url}/nodes", timeout=TIMEOUT)
        node_resp.raise_for_status()
        nodes = node_resp.json()
    except Exception as e:
        fatal(f"Unable to list nodes (/nodes): {e}")

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

    mcr_str = ", ".join(sorted(mcr_versions))

    info(f"Retrieved {plural(total_nodes, 'node')} (managers: {managers}, workers: {workers})")
    if mke_version == "N/A":
        warn("MKE version not found in services, the Kubernetes API or node labels")
    else:
        info(f"MKE version: {mke_version}")
    if msr_version != "N/A":
        info(f"MSR version: {msr_version}")

    # 5. Write to CSV
    output_file = os.path.join(OUTPUT_DIR, "mke_cluster_summary.csv")
    try:
        f = open(output_file, mode='w', newline='')
    except OSError as e:
        fatal(f"Unable to write {output_file}: {e}. Mount a writable directory at {OUTPUT_DIR} "
              "and run with --user \"$(id -u):$(id -g)\".")
    with f:
        writer = csv.writer(f)

        writer.writerow([
            "Cluster Name", "Cluster ID", "Total Cores", "Total Nodes",
            "Managers", "Workers", "MCR", "MKE", "MSR",
            "CPU Type/Model", "Memory"
        ])

        writer.writerow([csv_safe(v) for v in [
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
        ]])

    info(f"Cluster summary written to {output_file}")

if __name__ == "__main__":
    get_inventory()
