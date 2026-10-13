# Pinned by digest for reproducible builds. To update, run
# `docker buildx imagetools inspect alpine:3.24` and replace the digest.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Release version: the single source of truth, updated by scripts/prepare-release.sh.
# The scripts print it at startup, and it fills the image's version label.
ENV MCR_CLUSTER_CONFIG_VERSION=0.5.4

# Use LABEL to provide maintainer information and other metadata
LABEL maintainer="Tom Wizda <twizda@mirantis.com>" \
      version="${MCR_CLUSTER_CONFIG_VERSION}" \
      description="Docker Swarm / MKE cluster audit: node details, CPU and memory, from the API or a support dump"

# Apply Alpine security updates released after the base image was built,
# then add the tools the script needs ('bc' is required for memory and CPU math)
RUN apk upgrade --no-cache \
    && apk add --no-cache bash curl jq bc

COPY swarm-core-audit.sh support-dump-count-cores.sh /usr/local/bin/

# Ensure the scripts are executable. The support dump script runs with:
#   docker run --rm -v "$PWD":/dump:ro -w /dump --entrypoint support-dump-count-cores.sh <image>
RUN chmod +x /usr/local/bin/swarm-core-audit.sh /usr/local/bin/support-dump-count-cores.sh

# Use the absolute path to bash to ensure multi-platform compatibility
ENTRYPOINT ["/bin/bash", "/usr/local/bin/swarm-core-audit.sh"]
