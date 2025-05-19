FROM alpine:latest
# MAINTAINER Tom Wizda <twizda@mirantis.com>
LABEL Maintainer_Name="Tom Wizda"
LABEL Maintainer_Email="twizda@mirantis.com"
LABEL BuildDate="20250519"

RUN apk update && apk upgrade && apk add --no-cache bash curl jq

COPY swarm_core_count.sh /swarm_core_count.sh

CMD ["/swarm_core_count.sh"]
