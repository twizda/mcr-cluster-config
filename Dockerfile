FROM alpine:latest

# Use LABEL to provide maintainer information and other metadata
LABEL maintainer="Tom Wizda <twizda@mirantis.com>" \
      version="0.3.1" \
      description="Docker Swarm CPU and Memory checking tool"

# Added 'bc' which is required for memory and CPU math
RUN apk add --no-cache bash curl jq bc

COPY swarm-core-audit.sh /usr/local/bin/swarm-core-audit.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/swarm-core-audit.sh

# Use the absolute path to bash to ensure multi-platform compatibility
ENTRYPOINT ["/bin/bash", "/usr/local/bin/swarm-core-audit.sh"]
