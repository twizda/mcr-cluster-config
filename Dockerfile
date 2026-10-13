# Pinned by digest for reproducible builds. To update, run
# `docker buildx imagetools inspect alpine:3.24` and replace the digest.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Use LABEL to provide maintainer information and other metadata
LABEL maintainer="Tom Wizda <twizda@mirantis.com>" \
      version="0.5.0" \
      description="Docker Swarm CPU and Memory checking tool"

# Apply Alpine security updates released after the base image was built,
# then add the tools the script needs ('bc' is required for memory and CPU math)
RUN apk upgrade --no-cache \
    && apk add --no-cache bash curl jq bc

COPY swarm-core-audit.sh /usr/local/bin/swarm-core-audit.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/swarm-core-audit.sh

# Use the absolute path to bash to ensure multi-platform compatibility
ENTRYPOINT ["/bin/bash", "/usr/local/bin/swarm-core-audit.sh"]
