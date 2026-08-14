FROM docker:27-cli

RUN apk add --no-cache bash curl jq

COPY swap.sh /usr/local/bin/swap.sh
COPY seed.sh /usr/local/bin/seed.sh
COPY loop.sh /usr/local/bin/loop.sh
RUN chmod +x /usr/local/bin/swap.sh /usr/local/bin/seed.sh /usr/local/bin/loop.sh

ENTRYPOINT ["/usr/local/bin/loop.sh"]
