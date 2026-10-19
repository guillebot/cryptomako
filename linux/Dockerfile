# CryptoMako Linux CLI (format-8 SIV_GCM)
FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/cryptomako .

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends fuse3 ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --uid 10001 --shell /usr/sbin/nologin cryptomako
COPY --from=build /out/cryptomako /usr/local/bin/cryptomako
USER cryptomako
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 CMD cryptomako version || exit 1
# A mount still needs --device /dev/fuse and either --cap-add SYS_ADMIN or a setuid fusermount3.
ENTRYPOINT ["cryptomako"]
