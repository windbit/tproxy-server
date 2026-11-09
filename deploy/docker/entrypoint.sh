#!/usr/bin/env bash
# Собирает конфиги relay и MTProxy из окружения и держит оба процесса:
# упал любой — контейнер выходит, оркестратор его перезапускает.
#
# TPROXY_HOSTNAME          домен прокси
# TPROXY_SECRET            32 hex, тот же secret в ссылке клиента
# TPROXY_TOKEN_KEY         base64 от 32 случайных байт; меняется — рвутся все сессии
# TPROXY_TRUSTED_PROXIES   CIDR фронт-прокси через запятую (сеть Traefik)
set -euo pipefail

: "${TPROXY_HOSTNAME:?}" "${TPROXY_SECRET:?}" "${TPROXY_TOKEN_KEY:?}" "${TPROXY_TRUSTED_PROXIES:?}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
MTPROXY_PORT=2398
MTPROXY_CONFIG_REFRESH_SECONDS=86400
RELAY_DIR=/run/tproxy
MTPROXY_DIR=/run/mtproxy

umask 077
install -d -o tproxy -g tproxy -m 0700 "$RELAY_DIR"
install -d -o root -g mtproxy -m 0750 "$MTPROXY_DIR"

main() {
	write_relay_config
	fetch_telegram_file https://core.telegram.org/getProxySecret "$MTPROXY_DIR/proxy-secret"
	fetch_telegram_file https://core.telegram.org/getProxyConfig "$MTPROXY_DIR/proxy-multi.conf"

	mtproto-proxy -u mtproxy -p 8888 -H "$MTPROXY_PORT" -S "$TPROXY_SECRET" $(nat_args) \
		--aes-pwd "$MTPROXY_DIR/proxy-secret" "$MTPROXY_DIR/proxy-multi.conf" \
		-M "$MTPROXY_WORKERS" -C "$MTPROXY_MAX_CONNECTIONS" &
	setpriv --reuid tproxy --regid tproxy --init-groups tproxy-server -config "$RELAY_DIR/config.json" &
	watch_telegram_config &
	wait -n
	exit 1
}

write_relay_config() {
	printf '%s' "$TPROXY_TOKEN_KEY" | base64 -d > "$RELAY_DIR/token.key"
	if [[ "$(wc -c < "$RELAY_DIR/token.key")" -ne 32 ]]; then
		echo "TPROXY_TOKEN_KEY must decode to 32 bytes" >&2
		exit 1
	fi
	local trusted="[\"${TPROXY_TRUSTED_PROXIES//,/\",\"}\"]"
	cat > "$RELAY_DIR/config.json" <<JSON
{
  "public_hostname": "$TPROXY_HOSTNAME",
  "listen": "0.0.0.0:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/site",
  "static_routes": "exact",
  "token_key_file": "$RELAY_DIR/token.key",
  "profiles_file": "$RELAY_DIR/profiles.json",
  "trusted_proxies": $trusted
}
JSON
	cat > "$RELAY_DIR/profiles.json" <<JSON
{"profiles":[{"name":"default","secret":"$TPROXY_SECRET","backend":"127.0.0.1:$MTPROXY_PORT"}]}
JSON
	chown tproxy:tproxy "$RELAY_DIR"/*
	chmod 0400 "$RELAY_DIR"/*
}

fetch_telegram_file() {
	local url="$1" destination="$2"
	curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 30 \
		--output "$destination.new" "$url"
	chown root:mtproxy "$destination.new"
	chmod 0640 "$destination.new"
	mv -f "$destination.new" "$destination"
}

# MTProxy хеширует свой адрес в ключи middle-end: за NAT без --nat-info
# клиенты подключаются, но ни один поток не получает ответа.
nat_args() {
	local local_address public_address
	local_address="$(ip -4 route get 149.154.175.50 | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n 1)"
	public_address="$(curl --fail --silent --ipv4 --max-time 15 https://api.ipify.org | tr -d '[:space:]')"
	if [[ -n "$local_address" && -n "$public_address" && "$local_address" != "$public_address" ]]; then
		echo "mtproxy: behind NAT $local_address -> $public_address" >&2
		printf -- '--nat-info %s:%s' "$local_address" "$public_address"
	fi
}

# Список middle-end Telegram меняется; новый подхватываем рестартом контейнера.
watch_telegram_config() {
	while sleep "$MTPROXY_CONFIG_REFRESH_SECONDS"; do
		fetch_telegram_file https://core.telegram.org/getProxyConfig "$MTPROXY_DIR/proxy-multi.conf.latest" || continue
		if ! cmp -s "$MTPROXY_DIR/proxy-multi.conf.latest" "$MTPROXY_DIR/proxy-multi.conf"; then
			echo "mtproxy: Telegram config changed, restarting" >&2
			return 1
		fi
	done
}

main
