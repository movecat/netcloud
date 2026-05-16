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
    print("set them in kcloud-docker/.env, or use API_INTERFACE=mudbjson", file=sys.stderr)
    sys.exit(64)
if db_required and not env("DB_PASSWORD").strip() and env("ALLOW_EMPTY_DB_PASSWORD", "0") != "1":
    print("missing required database env: DB_PASSWORD", file=sys.stderr)
    print("set ALLOW_EMPTY_DB_PASSWORD=1 only if your database account really has no password", file=sys.stderr)
    sys.exit(64)

speed_limit_kb = env("SPEED_LIMIT_KB").strip()
if speed_limit_kb:
    speed_limit_kb = int(speed_limit_kb)
else:
    speed_limit_kb = int(float_env("SPEED_LIMIT_MBPS", 0) * 128)

single_port_enabled = bool_on("SINGLE_PORT_MODE", "off")

config = {
    "server": env("SERVER_BIND", "0.0.0.0"),
    "server_ipv6": env("SERVER_IPV6_BIND", "::"),
    "server_port": int_env("SERVER_PORT", 8388),
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
        env("SINGLE_PORT", "443"): {
            "passwd": env("SINGLE_PASSWORD", ""),
            "method": env("SINGLE_METHOD", env("SSR_METHOD", "chacha20")),
            "protocol": env("SINGLE_PROTOCOL", "auth_aes128_md5"),
            "protocol_param": env("SINGLE_PROTOCOL_PARAM", "#"),
            "obfs": env("SINGLE_OBFS", "tls1.2_ticket_auth"),
            "obfs_param": env("SINGLE_OBFS_PARAM", ""),
        }
    }

(ssr_dir / "user-config.json").write_text(
    json.dumps(config, ensure_ascii=False, indent=4) + "\n",
    encoding="utf-8",
)

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
(ssr_dir / "usermysql.json").write_text(
    json.dumps(mysql, ensure_ascii=False, indent=4) + "\n",
    encoding="utf-8",
)

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

install_info = f"""# KCloud Proxy Service Docker Info
install_mode={env("INSTALL_MODE", "docker")}
service_port={env("PORT_RANGE", "")}
speed_limit_type={"y" if speed_limit_kb else "n"}
speed_limit={speed_limit_kb}
logs_save_type={env("LOGS_SAVE", "y")}
logs_save_days={env("LOGS_SAVE_DAYS", "30")}
"""
(ssr_dir / "install-info").write_text(install_info, encoding="utf-8")
PY
}

run_server() {
  render_config
  cd "$SSR_DIR"
  ulimit -n "${NOFILE_LIMIT:-51200}" || true
  exec python -u server.py
}

show_status() {
  if pgrep -f "/usr/local/shadowsocks/server.py" >/dev/null; then
    echo "KCloud Proxy Service 正在运行"
  else
    echo "KCloud Proxy Service 已停止"
    return 1
  fi
}

view_connections() {
  if ! command -v ss >/dev/null 2>&1; then
    echo "ss command not found"
    return 1
  fi

  echo "当前 ESTABLISHED 连接:"
  ss -tanp state established 2>/dev/null | awk '
    /python/ {
      split($4, local, ":")
      split($5, remote, ":")
      port = local[length(local)]
      ip = remote[1]
      count[port "|" ip] = 1
    }
    END {
      for (key in count) {
        split(key, parts, "|")
        print "端口: " parts[1] " 连接IP: " parts[2]
      }
    }
  ' | sort -n
}

case "${1:-run}" in
  run|start)
    run_server
    ;;
  render-config)
    render_config
    ;;
  status)
    show_status
    ;;
  view)
    view_connections
    ;;
  shell)
    exec bash
    ;;
  *)
    exec "$@"
    ;;
esac
