# mirantis/audit-cluster

Docker image for auditing a Swarm/UCP cluster to return the core counts and other sizing stats based on `alpine:latest`.

To pull this image:
`docker pull mirantis/audit-cluster`

## v0.2 Enhancements
* **Performance Optimization**: API calls are now bundled, reducing network overhead by fetching all node data in a single request.
* **Format Flexibility**: The `support_dump_count_cores.sh` script now supports `--json` and `--csv` flags.
* **Cross-Platform Support**: Optimized for both modern Linux (Bash 4+) and legacy macOS (Bash 3.2).

## Example Usage

There are three methods to run this audit:

1. [**On the cluster**](#on-the-cluster) - Run it directly on a manager via a client bundle.
2. [**On a local engine**](#on-a-local-engine) - Run it on a local machine and communicate to UCP APIs using a client bundle.
3. [**From a UCP support dump**](#from-a-ucp-support-dump) - Analyze static files locally using the provided script.

### On the cluster

1. Load a UCP client bundle (or skip the bundle and run directly on a manager).
2. Run the container:

    ```bash
    docker run -t --rm --name audit-cluster \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e affinity:container==ucp-controller \
      mirantis/audit-cluster
    ```

### On a local engine

1. Find your UCP URL and the local path to your extracted client bundle.
2. Run the container locally, updating `UCP_URL` and the volume path:

    ```bash
    docker run -t --rm --name audit-cluster \
      -e UCP_URL="ucp.example.com" \
      -v /path/to/your/client/bundle:/data:ro \
      mirantis/audit-cluster
    ```

### From a UCP support dump

If you wish to retrieve data from a static UCP support dump, use the `support_dump_count_cores.sh` script.

**New in v0.2:** Output data in specific formats for automation:
```bash
./support_dump_count_cores.sh --json
./support_dump_count_cores.sh --csv
