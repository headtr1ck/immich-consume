FROM golang:1.20-alpine AS builder
RUN apk add --no-cache git build-base
ENV CGO_ENABLED=0
RUN go install github.com/simulot/immich-go@latest

FROM alpine:3.18
RUN apk add --no-cache inotify-tools ca-certificates bash
COPY --from=builder /go/bin/immich-go /usr/local/bin/immich-go
COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh
VOLUME ["/consume"]
WORKDIR /consume
ENTRYPOINT ["/usr/local/bin/watch.sh"]
