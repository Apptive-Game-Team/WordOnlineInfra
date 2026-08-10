FROM docker:27-cli

RUN apk add --no-cache bash curl

COPY swap.sh /usr/local/bin/swap.sh
COPY loop.sh /usr/local/bin/loop.sh
RUN chmod +x /usr/local/bin/swap.sh /usr/local/bin/loop.sh

ENTRYPOINT ["/usr/local/bin/loop.sh"]
