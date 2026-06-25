FROM alpine:3.18
RUN apk add --no-cache inotify-tools ca-certificates bash exiftool curl jq
COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh
VOLUME ["/consume"]
WORKDIR /consume
ENTRYPOINT ["/usr/local/bin/watch.sh"]
