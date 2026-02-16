FROM alpine:latest
MAINTAINER Matt Bentley <mbentley@mbentley.net>

RUN apk add --no-cache bash curl jq

COPY swarm_core_audit.sh /swarm_core_audit.sh

CMD ["/swarm_core_audit.sh"]
