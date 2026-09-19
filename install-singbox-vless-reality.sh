#!/bin/sh
set -eu

# VLESS + Reality installer for standard VPS and IPv4 NAT instances.
# NAT instances use NAT_PORT_PAIRS, for example 11570:80,11571:81.

CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"
LINK_FILE="$CONFIG_DIR/vless-reality-link.txt"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本。" >&2
  exit 1
fi

detect_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null |
      awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null |
      awk '/inet / && $2 !~ /^127\./ { print $2; exit }'
  fi
}

is_valid_ipv4() {
  printf "%s\n" "$1" | awk -F. '
    BEGIN { valid = 1 }
    NF != 4 { valid = 0; next }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i > 255) valid = 0
      }
    }
    END { exit valid ? 0 : 1 }
  '
}

detect_public_ipv4() {
  for endpoint in \
    https://api.ipify.org \
    https://ipv4.icanhazip.com \
    https://ifconfig.me/ip
  do
    candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null || true)
    if is_valid_ipv4 "$candidate"; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done

  return 1
}

is_private_ipv4() {
  printf "%s\n" "$1" | awk -F. '
    BEGIN { private = 0 }
    NF != 4 { exit 1 }
    {
      if ($1 == 10 ||
          ($1 == 172 && $2 >= 16 && $2 <= 31) ||
          ($1 == 192 && $2 == 168) ||
          ($1 == 100 && $2 >= 64 && $2 <= 127)) {
        private = 1
      }
    }
    END { exit private ? 0 : 1 }
  '
}

port_available() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v port="$1" '
      NR > 1 && $4 ~ (":" port "$") { used = 1 }
      END { exit used ? 1 : 0 }
    '
    return
  fi

  return 0
}

choose_nat_port_pair() {
  old_ifs=$IFS
  IFS=,

  for pair in $NAT_PORT_PAIRS; do
    public_port=${pair%%:*}
    listen_port=${pair#*:}

    case "$public_port:$listen_port" in
      *[!0-9:]*|:*|*:) continue ;;
    esac

    if port_available "$listen_port"; then
      printf "%s\n" "$pair"
      IFS=$old_ifs
      return 0
    fi
  done

  IFS=$old_ifs
  return 1
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

  echo "不支持当前的软件包管理器。仅支持 Alpine（apk）和 Debian/Ubuntu（apt）。" >&2
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

  echo "未找到受支持的服务管理器。" >&2
  exit 1
}

PRIVATE_IPV4=$(detect_ipv4)
LISTEN_ADDR=${LISTEN_ADDR:-$PRIVATE_IPV4}
PUBLIC_HOST=${PUBLIC_HOST:-$(detect_public_ipv4 || true)}
SNI=${SNI:-www.microsoft.com}

if is_private_ipv4 "$LISTEN_ADDR"; then
  if [ -n "${NAT_PORT_PAIRS:-}" ] && [ -z "${LISTEN_PORT:-}" ] && [ -z "${PUBLIC_PORT:-}" ]; then
    selected_pair=$(choose_nat_port_pair || true)
    if [ -z "$selected_pair" ]; then
      echo "NAT_PORT_PAIRS 中的内网端口均被占用，无法自动选择监听端口。" >&2
      exit 1
    fi
    PUBLIC_PORT=${selected_pair%%:*}
    LISTEN_PORT=${selected_pair#*:}
  elif [ -n "${LISTEN_PORT:-}" ] && [ -n "${PUBLIC_PORT:-}" ]; then
    :
  else
    echo "检测到 NAT 内网 IP。请设置 NAT_PORT_PAIRS，或同时设置 LISTEN_PORT 和 PUBLIC_PORT。" >&2
    exit 1
  fi
else
  LISTEN_PORT=${LISTEN_PORT:-443}
  PUBLIC_PORT=${PUBLIC_PORT:-$LISTEN_PORT}
fi

case "$LISTEN_ADDR" in
  *:*|"") echo "请填写具体的 IPv4 地址，不能使用 :: 或 0.0.0.0。" >&2; exit 1 ;;
esac

case "$LISTEN_PORT:$PUBLIC_PORT" in
  *[!0-9:]*|:*|*:) echo "端口必须是纯数字。" >&2; exit 1 ;;
esac

case "$PUBLIC_HOST" in
  "")
    echo "无法自动获取公网 IPv4。请检查服务器网络，或用 PUBLIC_HOST=公网IP 重新执行脚本。" >&2
    exit 1
    ;;
  *[!A-Za-z0-9.-]*) echo "公网 IP 或域名含有不支持的字符。" >&2; exit 1 ;;
esac

case "$SNI" in
  ""|*[!A-Za-z0-9.-]*) echo "SNI 为空，或含有不支持的字符。" >&2; exit 1 ;;
esac

install_sing_box
SING_BOX=$(command -v sing-box)

echo "自动配置：内网监听 $LISTEN_ADDR:$LISTEN_PORT，公网连接 $PUBLIC_HOST:$PUBLIC_PORT"

UUID=$("$SING_BOX" generate uuid)
KEYPAIR=$("$SING_BOX" generate reality-keypair)
PRIVATE_KEY=$(printf "%s\n" "$KEYPAIR" | awk '/PrivateKey:/ {print $2}')
PUBLIC_KEY=$(printf "%s\n" "$KEYPAIR" | awk '/PublicKey:|Password \(PublicKey\):/ {print $NF}')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "生成 VLESS 或 Reality 凭据失败。" >&2
  exit 1
fi

install -d -m 0755 "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
  backup="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG_FILE" "$backup"
  echo "原配置已备份到：$backup"
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
echo "sing-box 已启动。"
echo "服务端内网监听：$LISTEN_ADDR:$LISTEN_PORT"
echo "客户端公网连接：$PUBLIC_HOST:$PUBLIC_PORT"
echo "VLESS 链接："
cat "$LINK_FILE"
echo
echo "链接已保存到：$LINK_FILE"
