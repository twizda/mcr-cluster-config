FROM alpine:latest
MAINTAINER Matt Bentley <mbentley@mbentley.net>

RUN apk add --no-cache bash curl jq

COPY swarm-core-audit.sh /usr/local/bin/swarm-core-audit.sh

CMD ["/usr/local/bin/swarm-core-audit.sh"]
