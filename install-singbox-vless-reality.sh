#!/bin/sh
set -eu

# VLESS + Reality installer for standard VPS and IPv4 NAT instances.
# Required NAT setup: map PUBLIC_PORT/TCP to LISTEN_ADDR:LISTEN_PORT/TCP first.

CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"
LINK_FILE="$CONFIG_DIR/vless-reality-link.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root." >&2
  exit 1
fi

prompt() {
  label=$1
  default=$2
  var_name=$3
  printf "%s [%s]: " "$label" "$default"
  read -r value || true
  [ -n "$value" ] || value=$default
  eval "$var_name=\$value"
}

detect_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null |
      awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null |
      awk '/inet / && $2 !~ /^127\./ { print $2; exit }'
  fi
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    return
  fi

  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache sing-box openssl curl ca-certificates
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl gpg
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc
    cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
    apt-get update
    apt-get install -y sing-box openssl
    return
  fi

  echo "Unsupported package manager. Alpine apk and Debian/Ubuntu apt are supported." >&2
  exit 1
}

setup_service() {
  bin=$1

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null
    systemctl restart sing-box
    systemctl is-active --quiet sing-box
    return
  fi

  if command -v rc-service >/dev/null 2>&1; then
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="$bin"
command_args="run -c $CONFIG_FILE"
command_background=yes
pidfile=/run/sing-box.pid
supervisor=supervise-daemon
respawn_delay=3
EOF
    chmod 0755 /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart
    rc-service sing-box status >/dev/null
    return
  fi

  echo "No supported service manager found." >&2
  exit 1
}

PRIVATE_IPV4=$(detect_ipv4)
prompt "Internal listen IPv4" "${LISTEN_ADDR:-$PRIVATE_IPV4}" LISTEN_ADDR
prompt "Internal listen TCP port" "${LISTEN_PORT:-443}" LISTEN_PORT
prompt "Public hostname or IPv4" "${PUBLIC_HOST:-}" PUBLIC_HOST
prompt "Public TCP port" "${PUBLIC_PORT:-$LISTEN_PORT}" PUBLIC_PORT
prompt "Reality handshake domain / SNI" "${SNI:-www.microsoft.com}" SNI

case "$LISTEN_ADDR" in
  *:*|"") echo "Use a concrete IPv4 address, not :: or 0.0.0.0." >&2; exit 1 ;;
esac

case "$LISTEN_PORT:$PUBLIC_PORT" in
  *[!0-9:]*|:*|*:) echo "Ports must be numeric." >&2; exit 1 ;;
esac

case "$PUBLIC_HOST" in
  ""|*[!A-Za-z0-9.-]*) echo "Public hostname/IP contains unsupported characters." >&2; exit 1 ;;
esac

case "$SNI" in
  ""|*[!A-Za-z0-9.-]*) echo "SNI contains unsupported characters." >&2; exit 1 ;;
esac

install_sing_box
SING_BOX=$(command -v sing-box)

UUID=$("$SING_BOX" generate uuid)
KEYPAIR=$("$SING_BOX" generate reality-keypair)
PRIVATE_KEY=$(printf "%s\n" "$KEYPAIR" | awk '/PrivateKey:/ {print $2}')
PUBLIC_KEY=$(printf "%s\n" "$KEYPAIR" | awk '/PublicKey:|Password \(PublicKey\):/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "Failed to generate VLESS or Reality credentials." >&2
  exit 1
fi

install -d -m 0755 "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
  backup="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG_FILE" "$backup"
  echo "Existing config backed up to $backup"
fi

cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "$LISTEN_ADDR",
      "listen_port": $LISTEN_PORT,
      "users": [
        {
          "name": "default",
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
chmod 0600 "$CONFIG_FILE"

"$SING_BOX" check -c "$CONFIG_FILE"
setup_service "$SING_BOX"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$LISTEN_PORT/tcp"
fi

LINK="vless://$UUID@$PUBLIC_HOST:$PUBLIC_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#SingBox-Reality"
umask 077
printf "%s\n" "$LINK" > "$LINK_FILE"

echo
echo "sing-box is running."
echo "Server listener: $LISTEN_ADDR:$LISTEN_PORT"
echo "Client endpoint: $PUBLIC_HOST:$PUBLIC_PORT"
echo "VLESS link:"
cat "$LINK_FILE"
echo
echo "Saved link: $LINK_FILE"
