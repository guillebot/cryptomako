# CryptoMako Linux CLI (format-8 SIV_GCM)
FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/cryptomako .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends fuse3 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/cryptomako /usr/local/bin/cryptomako
# FUSE needs /dev/fuse + SYS_ADMIN or fusermount3 privileges at runtime.
ENTRYPOINT ["cryptomako"]
