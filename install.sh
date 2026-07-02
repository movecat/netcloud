#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/movecat/netcloud.git}"
KCLOUD_NAME="${KCLOUD_NAME:-kcloud-ssr}"
APP_DIR="${KCLOUD_DIR:-/opt/${KCLOUD_NAME}}"
CONTAINER_NAME="${KCLOUD_CONTAINER_NAME:-${KCLOUD_NAME}}"
if [[ -n "${KCLOUD_IMAGE:-}" ]]; then
  IMAGE_NAME="$KCLOUD_IMAGE"
else
  IMAGE_NAME="$(printf '%s' "${KCLOUD_NAME}:legacy" | tr '[:upper:]' '[:lower:]')"
fi

if [[ "$IMAGE_NAME" =~ [A-Z] ]]; then
  echo "[错误] Docker 镜像名必须全小写：${IMAGE_NAME}"
  echo "请改用小写 KCLOUD_IMAGE，例如 ${IMAGE_NAME,,}"
  exit 1
fi

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
  local value
  value="$(ask "$text" "")"
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

git_with_auth() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    local auth
    auth="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" "$@"
  else
    git "$@"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  echo "[1/5] 安装 Docker..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg git iptables

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

sync_repo() {
  echo "[2/5] 下载运行文件..."
  if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "[提示] 已检测到 GITHUB_TOKEN，将用于拉取私有仓库。"
  fi
  if [[ -d "$APP_DIR/.git" ]]; then
    git_with_auth -C "$APP_DIR" pull --ff-only
  else
    rm -rf "$APP_DIR"
    git_with_auth clone "$REPO_URL" "$APP_DIR"
  fi
  mkdir -p "$APP_DIR/data" "$APP_DIR/logs"
}

configure_env() {
  echo "[3/5] 配置数据库..."
  echo "旧脚本不需要节点 ID，这里也固定 NODE_ID=0。"
  echo

  local api db_host db_port db_user db_pass db_name server_pub port_range
  local method protocol obfs speed single_mode single_port single_pass single_method single_obfs single_protocol

  api="$(ask "API 接口 legendsockssr/sspanelv3/glzjinmod/sspanelv2/mudbjson" "legendsockssr")"
  db_host="$(ask "数据库地址" "127.0.0.1")"
  db_port="$(ask "数据库端口" "3306")"
  db_user="$(ask "数据库账户" "")"
  db_pass="$(ask "数据库密码" "")"
  db_name="$(ask "数据库名称" "")"
  server_pub="$(ask "节点公网 IP 或域名" "127.0.0.1")"

  if [[ "$api" != "mudbjson" ]]; then
    [[ -z "$db_host" ]] && db_host="$(ask_required "数据库地址")"
    [[ -z "$db_user" ]] && db_user="$(ask_required "数据库账户")"
    [[ -z "$db_pass" ]] && db_pass="$(ask_required "数据库密码")"
    [[ -z "$db_name" ]] && db_name="$(ask_required "数据库名称")"
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

  umask 077
  {
    write_var INSTALL_MODE "docker"
    write_var KCLOUD_CONTAINER_NAME "$CONTAINER_NAME"
    write_var KCLOUD_IMAGE "$IMAGE_NAME"
    write_var API_INTERFACE "$api"
    write_var UPDATE_TIME "60"
    write_var SERVER_PUB_ADDR "$server_pub"
    write_var DB_HOST "$db_host"
    write_var DB_PORT "$db_port"
    write_var DB_USER "$db_user"
    write_var DB_PASSWORD "$db_pass"
    write_var DB_NAME "$db_name"
    write_var NODE_ID "0"
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
    write_var SSR_VERBOSE "-2"
    write_var CONNECT_VERBOSE_INFO "0"
    write_var DOCKER_LOG_MAX_SIZE "20m"
    write_var DOCKER_LOG_MAX_FILE "3"
    write_var LOGS_SAVE "y"
    write_var LOGS_SAVE_DAYS "30"
    write_var NOFILE_LIMIT "51200"
  } > "$APP_DIR/.env"
}

open_firewall() {
  local port_range single_mode single_port iptables_range
  port_range="$(grep '^PORT_RANGE=' "$APP_DIR/.env" | sed -E 's/^PORT_RANGE="?([^"]*)"?$/\1/')"
  single_mode="$(grep '^SINGLE_PORT_MODE=' "$APP_DIR/.env" | sed -E 's/^SINGLE_PORT_MODE="?([^"]*)"?$/\1/')"
  single_port="$(grep '^SINGLE_PORT=' "$APP_DIR/.env" | sed -E 's/^SINGLE_PORT="?([^"]*)"?$/\1/')"
  iptables_range="${port_range/-/:}"

  echo "[4/5] 放行端口..."
  if [[ -n "$iptables_range" ]]; then
    iptables -C INPUT -p tcp --dport "$iptables_range" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$iptables_range" -j ACCEPT
    iptables -C INPUT -p udp --dport "$iptables_range" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$iptables_range" -j ACCEPT
  fi
  if [[ "$single_mode" == "on" && -n "$single_port" ]]; then
    iptables -C INPUT -p tcp --dport "$single_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$single_port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$single_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$single_port" -j ACCEPT
  fi
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
}

write_manager() {
  local manager="/usr/local/bin/${CONTAINER_NAME}"
  cat > "$manager" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$APP_DIR"
case "\${1:-status}" in
  start) docker compose up -d ;;
  stop) docker compose stop ;;
  restart) docker compose up -d --build && docker compose restart ;;
  status) docker compose ps ;;
  logs) docker compose logs -f --tail=200 ;;
  config) \${EDITOR:-nano} "$APP_DIR/.env" ;;
  view) docker exec -it "$CONTAINER_NAME" kcloud-entrypoint view ;;
  shell) docker exec -it "$CONTAINER_NAME" bash ;;
  *) echo "用法: $CONTAINER_NAME start|stop|restart|status|logs|config|view|shell" ;;
esac
EOF
  chmod +x "$manager"
}

start_service() {
  echo "[5/5] 构建并启动 SSR Docker..."
  cd "$APP_DIR"
  docker compose up -d --build
}

install_docker
sync_repo
configure_env
open_firewall
write_manager
start_service

echo
echo "安装完成。常用命令："
echo "  ${CONTAINER_NAME} status"
echo "  ${CONTAINER_NAME} logs"
echo "  ${CONTAINER_NAME} restart"
echo "  ${CONTAINER_NAME} config"
echo
echo "注意：云服务器还需要在云厂商安全组里放行用户端口段和单端口。"
