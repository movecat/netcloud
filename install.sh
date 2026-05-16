#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${Kcloud_DIR:-/opt/kcloud-ssr}"
IMAGE_NAME="kcloud-ssr:legacy"
CONTAINER_NAME="kcloud-ssr"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[错误] 请用 root 用户执行"
  exit 1
fi

ask() {
  local text="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "${text} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${text}: " value
    printf '%s' "$value"
  fi
}

ask_required() {
  local text="$1"
  local default="${2:-}"
  local value
  value="$(ask "$text" "$default")"
  if [[ -z "$value" ]]; then
    echo
    echo "[错误] ${text} 不能为空"
    exit 1
  fi
  printf '%s' "$value"
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_var() {
  printf '%s=%s\n' "$1" "$(env_quote "$2")"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  echo "[1/5] 安装 Docker..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg iptables

  . /etc/os-release
  local repo_id="${ID:-debian}"
  local codename="${VERSION_CODENAME:-trixie}"
  if [[ "$repo_id" != "debian" && "$repo_id" != "ubuntu" ]]; then
    repo_id="debian"
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${repo_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_id} ${codename} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    echo "[提示] Docker 官方源安装失败，尝试 Debian 自带包..."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker.io docker-compose-plugin
  fi

  systemctl enable --now docker
}

write_runtime_files() {
  echo "[2/5] 写入 Docker 运行文件..."
  mkdir -p "$APP_DIR/data" "$APP_DIR/logs"

  cat > "$APP_DIR/Dockerfile" <<'DOCKERFILE'
FROM python:3.9-slim-bullseye

ARG SSR_REPO=https://github.com/movecat/shadowsocksr-manyuser.git
ARG SSR_REF=master

ENV PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        iproute2 \
        libsodium23 \
        net-tools \
        procps \
        tzdata; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    git clone --depth=1 --branch "${SSR_REF}" "${SSR_REPO}" /usr/local/shadowsocks; \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    python -m pip install --no-cache-dir PyMySQL; \
    python -c 'from pathlib import Path; import site; p=Path(site.getsitepackages()[0])/"cymysql.py"; p.write_text("from pymysql import *\nfrom pymysql import connect\n")'; \
    python -c 'from pathlib import Path; p=Path("/usr/local/shadowsocks/shadowsocks/lru_cache.py"); s=p.read_text(); s=s.replace("import collections\n","try:\n    from collections.abc import MutableMapping\nexcept ImportError:\n    from collections import MutableMapping\n"); s=s.replace("class LRUCache(collections.MutableMapping):","class LRUCache(MutableMapping):"); p.write_text(s)'

COPY docker-entrypoint.sh /usr/local/bin/kcloud-entrypoint
RUN chmod +x /usr/local/bin/kcloud-entrypoint; \
    mkdir -p /data /var/log/kcloud

WORKDIR /usr/local/shadowsocks
ENTRYPOINT ["kcloud-entrypoint"]
CMD ["run"]
DOCKERFILE

  cat > "$APP_DIR/docker-entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

SSR_DIR=/usr/local/shadowsocks
DATA_DIR=/data
LOG_DIR=/var/log/kcloud

render_config() {
  mkdir -p "$DATA_DIR" "$LOG_DIR"

  python - <<'PY'
import json
import os
import sys
from pathlib import Path

ssr_dir = Path("/usr/local/shadowsocks")
data_dir = Path("/data")

def env(name, default=""):
    return os.environ.get(name, default)

def int_env(name, default):
    value = env(name, str(default)).strip()
    return int(value) if value else int(default)

def float_env(name, default):
    value = env(name, str(default)).strip()
    return float(value) if value else float(default)

def bool_on(name, default="off"):
    return env(name, default).strip().lower() in {"1", "true", "yes", "y", "on"}

api_interface = env("API_INTERFACE", "legendsockssr")
db_required = api_interface != "mudbjson"
required = ["DB_HOST", "DB_USER", "DB_NAME"]
missing = [name for name in required if db_required and not env(name).strip()]
if missing:
    print("missing required database env: " + ", ".join(missing), file=sys.stderr)
    sys.exit(64)
if db_required and not env("DB_PASSWORD").strip() and env("ALLOW_EMPTY_DB_PASSWORD", "0") != "1":
    print("missing required database env: DB_PASSWORD", file=sys.stderr)
    sys.exit(64)

speed_limit_kb = env("SPEED_LIMIT_KB").strip()
if speed_limit_kb:
    speed_limit_kb = int(speed_limit_kb)
else:
    speed_limit_kb = int(float_env("SPEED_LIMIT_MBPS", 0) * 128)

single_port_enabled = bool_on("SINGLE_PORT_MODE", "off")

config = {
    "server": "0.0.0.0",
    "server_ipv6": "::",
    "server_port": 8388,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": env("SERVER_PASSWORD", "pwd"),
    "timeout": int_env("TIMEOUT", 120),
    "udp_timeout": int_env("UDP_TIMEOUT", 60),
    "method": env("SSR_METHOD", "chacha20"),
    "protocol": env("SSR_PROTOCOL", "auth_sha1_v4_compatible"),
    "protocol_param": env("SSR_PROTOCOL_PARAM", ""),
    "obfs": env("SSR_OBFS", "tls1.2_ticket_auth_compatible"),
    "obfs_param": env("SSR_OBFS_PARAM", ""),
    "speed_limit_per_con": speed_limit_kb if single_port_enabled else 0,
    "speed_limit_per_user": speed_limit_kb,
    "dns_ipv6": bool_on("DNS_IPV6", "off"),
    "connect_verbose_info": int_env("CONNECT_VERBOSE_INFO", 1),
    "redirect": ["bing.com", "12.12.1.1"],
    "fast_open": bool_on("FAST_OPEN", "off"),
}

if single_port_enabled:
    config["additional_ports"] = {
        env("SINGLE_PORT", "38310"): {
            "passwd": env("SINGLE_PASSWORD", ""),
            "method": env("SINGLE_METHOD", env("SSR_METHOD", "chacha20")),
            "protocol": env("SINGLE_PROTOCOL", "auth_aes128_md5"),
            "protocol_param": env("SINGLE_PROTOCOL_PARAM", "#"),
            "obfs": env("SINGLE_OBFS", "tls1.2_ticket_auth"),
            "obfs_param": env("SINGLE_OBFS_PARAM", ""),
        }
    }

(ssr_dir / "user-config.json").write_text(json.dumps(config, ensure_ascii=False, indent=4) + "\n", encoding="utf-8")

mysql = {
    "host": env("DB_HOST", "127.0.0.1"),
    "port": int_env("DB_PORT", 3306),
    "user": env("DB_USER", ""),
    "password": env("DB_PASSWORD", ""),
    "db": env("DB_NAME", ""),
    "node_id": int_env("NODE_ID", 0),
    "transfer_mul": float_env("TRANSFER_MUL", 1.0),
    "ssl_enable": int_env("DB_SSL_ENABLE", 0),
    "ssl_ca": env("DB_SSL_CA", ""),
    "ssl_cert": env("DB_SSL_CERT", ""),
    "ssl_key": env("DB_SSL_KEY", ""),
}
(ssr_dir / "usermysql.json").write_text(json.dumps(mysql, ensure_ascii=False, indent=4) + "\n", encoding="utf-8")

mudb = data_dir / "mudb.json"
if not mudb.exists():
    mudb.write_text("[]\n", encoding="utf-8")

apiconfig = f"""# Config
API_INTERFACE = {api_interface!r} #mudbjson, sspanelv2, sspanelv3, sspanelv3ssr, glzjinmod, legendsockssr, muapiv2(not support)
UPDATE_TIME = {int_env("UPDATE_TIME", 60)}
SERVER_PUB_ADDR = {env("SERVER_PUB_ADDR", "127.0.0.1")!r}

# mudb
MUDB_FILE = {str(mudb)!r}

# Mysql
MYSQL_CONFIG = 'usermysql.json'

# API
MUAPI_CONFIG = 'usermuapi.json'
"""
(ssr_dir / "apiconfig.py").write_text(apiconfig, encoding="utf-8")
PY
}

case "${1:-run}" in
  run|start)
    render_config
    cd "$SSR_DIR"
    ulimit -n "${NOFILE_LIMIT:-51200}" || true
    exec python -u server.py
    ;;
  render-config)
    render_config
    ;;
  view)
    ss -tanp state established 2>/dev/null | awk '/python/ {print}' || true
    ;;
  shell)
    exec bash
    ;;
  *)
    exec "$@"
    ;;
esac
ENTRYPOINT
  chmod +x "$APP_DIR/docker-entrypoint.sh"

  cat > "$APP_DIR/docker-compose.yml" <<COMPOSE
services:
  kcloud-ssr:
    build:
      context: .
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./data:/data
      - ./logs:/var/log/kcloud
COMPOSE
}

configure_env() {
  echo "[3/5] 配置数据库和节点..."
  echo
  echo "直接回车会使用默认值。旧脚本预设 1 的默认参数已经填好。"
  echo

  local api db_host db_port db_user db_pass db_name node_id server_pub port_range
  local method protocol obfs speed single_mode single_port single_pass single_method single_obfs single_protocol

  api="$(ask "API 接口 legendsockssr/sspanelv3/glzjinmod/sspanelv2/mudbjson" "legendsockssr")"
  db_host="$(ask "数据库地址" "127.0.0.1")"
  db_port="$(ask "数据库端口" "3306")"
  db_user="$(ask "数据库账户" "")"
  db_pass="$(ask "数据库密码" "")"
  db_name="$(ask "数据库名称" "")"
  node_id="$(ask "节点 ID" "0")"
  server_pub="$(ask "节点公网 IP 或域名" "127.0.0.1")"

  if [[ "$api" != "mudbjson" ]]; then
    [[ -z "$db_host" ]] && db_host="$(ask_required "数据库地址")"
    [[ -z "$db_user" ]] && db_user="$(ask_required "数据库账户")"
    [[ -z "$db_name" ]] && db_name="$(ask_required "数据库名称")"
    [[ -z "$db_pass" ]] && db_pass="$(ask_required "数据库密码")"
  fi

  method="$(ask "默认加密方式" "chacha20")"
  protocol="$(ask "默认协议插件" "auth_sha1_v4_compatible")"
  obfs="$(ask "默认混淆方式" "tls1.2_ticket_auth_compatible")"
  port_range="$(ask "用户端口段" "10000-20000")"
  speed="$(ask "限速 Mbps，0 为不限速" "0")"

  single_mode="$(ask "开启单端口多用户 on/off" "on")"
  single_port="$(ask "单端口端口" "38310")"
  single_pass="$(ask "单端口密码" "change-me")"
  single_method="$(ask "单端口加密方式" "chacha20")"
  single_obfs="$(ask "单端口混淆方式" "tls1.2_ticket_auth")"
  single_protocol="$(ask "单端口协议插件" "auth_aes128_md5")"

  {
    write_var API_INTERFACE "$api"
    write_var UPDATE_TIME "60"
    write_var SERVER_PUB_ADDR "$server_pub"
    write_var DB_HOST "$db_host"
    write_var DB_PORT "$db_port"
    write_var DB_USER "$db_user"
    write_var DB_PASSWORD "$db_pass"
    write_var DB_NAME "$db_name"
    write_var NODE_ID "$node_id"
    write_var TRANSFER_MUL "1.0"
    write_var ALLOW_EMPTY_DB_PASSWORD "0"
    write_var SSR_METHOD "$method"
    write_var SSR_PROTOCOL "$protocol"
    write_var SSR_OBFS "$obfs"
    write_var SSR_PROTOCOL_PARAM ""
    write_var SSR_OBFS_PARAM ""
    write_var PORT_RANGE "$port_range"
    write_var SPEED_LIMIT_MBPS "$speed"
    write_var SPEED_LIMIT_KB ""
    write_var SINGLE_PORT_MODE "$single_mode"
    write_var SINGLE_PORT "$single_port"
    write_var SINGLE_PASSWORD "$single_pass"
    write_var SINGLE_METHOD "$single_method"
    write_var SINGLE_OBFS "$single_obfs"
    write_var SINGLE_PROTOCOL "$single_protocol"
    write_var SINGLE_PROTOCOL_PARAM "#"
    write_var NOFILE_LIMIT "51200"
  } > "$APP_DIR/.env"

  chmod 600 "$APP_DIR/.env"
}

open_firewall() {
  local env_file="$APP_DIR/.env"
  local port_range single_mode single_port iptables_range
  port_range="$(grep '^PORT_RANGE=' "$env_file" | sed -E 's/^PORT_RANGE="?([^"]*)"?$/\1/')"
  single_mode="$(grep '^SINGLE_PORT_MODE=' "$env_file" | sed -E 's/^SINGLE_PORT_MODE="?([^"]*)"?$/\1/')"
  single_port="$(grep '^SINGLE_PORT=' "$env_file" | sed -E 's/^SINGLE_PORT="?([^"]*)"?$/\1/')"
  iptables_range="${port_range/-/:}"

  echo "[4/5] 放行端口..."
  if command -v iptables >/dev/null 2>&1 && [[ -n "$iptables_range" ]]; then
    iptables -C INPUT -p tcp --dport "$iptables_range" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$iptables_range" -j ACCEPT
    iptables -C INPUT -p udp --dport "$iptables_range" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$iptables_range" -j ACCEPT
    if [[ "$single_mode" == "on" && -n "$single_port" ]]; then
      iptables -C INPUT -p tcp --dport "$single_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$single_port" -j ACCEPT
      iptables -C INPUT -p udp --dport "$single_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$single_port" -j ACCEPT
    fi
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || true
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
    ufw allow "$port_range/tcp" || true
    ufw allow "$port_range/udp" || true
    if [[ "$single_mode" == "on" && -n "$single_port" ]]; then
      ufw allow "$single_port/tcp" || true
      ufw allow "$single_port/udp" || true
    fi
  fi
}

write_manager() {
  cat > /usr/local/bin/kcloud-ssr <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${APP_DIR}"
cd "\$APP_DIR"
case "\${1:-status}" in
  start) docker compose up -d ;;
  stop) docker compose stop ;;
  restart) docker compose up -d --build && docker compose restart ;;
  status) docker compose ps ;;
  logs) docker compose logs -f --tail=200 ;;
  config) \${EDITOR:-nano} "\$APP_DIR/.env" ;;
  view) docker exec -it ${CONTAINER_NAME} kcloud-entrypoint view ;;
  shell) docker exec -it ${CONTAINER_NAME} bash ;;
  *) echo "用法: kcloud-ssr start|stop|restart|status|logs|config|view|shell" ;;
esac
EOF
  chmod +x /usr/local/bin/kcloud-ssr
}

start_service() {
  echo "[5/5] 构建并启动 SSR Docker..."
  cd "$APP_DIR"
  docker compose up -d --build
}

install_docker
write_runtime_files
configure_env
open_firewall
write_manager
start_service

echo
echo "安装完成。常用命令："
echo "  kcloud-ssr status"
echo "  kcloud-ssr logs"
echo "  kcloud-ssr restart"
echo "  kcloud-ssr config"
echo
echo "如果是云服务器，记得在云厂商安全组里也放行用户端口段和单端口。"
