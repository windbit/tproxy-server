# Relay и его MTProxy в одном образе: relay ходит в бэкенд только по loopback.
FROM golang:1.24-bookworm AS relay
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -o /out/tproxy-server ./cmd/tproxy-server

FROM debian:bookworm-slim AS mtproxy
# Тот же коммит и хеш, что закрепляет deploy/install-mtproxy.sh.
ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates curl libssl-dev zlib1g-dev
RUN curl -fsSL -o /tmp/mtproxy.tar.gz "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
	&& echo "${MTPROXY_SHA256}  /tmp/mtproxy.tar.gz" | sha256sum -c - \
	&& mkdir /build && tar -C /build --strip-components=1 -xzf /tmp/mtproxy.tar.gz \
	&& make -C /build -j"$(nproc)"

FROM debian:bookworm-slim
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl iproute2 libssl3 util-linux zlib1g \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy \
	&& useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy
COPY --from=relay /out/tproxy-server /usr/local/bin/tproxy-server
COPY --from=mtproxy /build/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY deploy/docker/site /srv/site
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
