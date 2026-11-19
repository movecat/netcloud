#!/usr/bin/env bash
# KCloud SSR node installer (Docker). One line, no questions when the options are given.
#
# Panel mode (LegendSock node API; the panel's 节点接入 page shows this line with the node's key):
#   bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh) \
#     --panel https://huohuxx.com --node-key KEY
#
# Database mode:
#   bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh) \
#     --db-host 47.244.157.80 --db-name rrsls --db-user rrsls --db-pass 'xxx' \
#     --single-port 59113 --single-pass 'xxx'
#
# Run without options for the old question-and-answer install. Run it again on an installed node to
# update it (the existing .env is kept unless --reconfigure, --panel or database options are given).
set -euo pipefail

usage() {
  cat <<'USAGE'
用法: install.sh [选项]

面板模式（推荐，节点不保存数据库密码；单端口等设置由面板下发）:
  --panel URL             面板网址，例如 https://huohuxx.com
  --node-key KEY          面板「LegendSock → 节点接入」里生成的节点密钥

数据库模式:
  --api NAME              接口: legendsockssr(默认)/sspanelv3/glzjinmod/sspanelv2/mudbjson
  --db-host HOST          数据库地址
  --db-port PORT          数据库端口 (默认 3306)
  --db-user USER          数据库账号
  --db-pass PASS          数据库密码
  --db-name NAME          数据库名
  --server-addr ADDR      节点公网 IP 或域名 (默认自动检测)

单端口:
  --single-port PORT      单端口端口
  --single-pass PASS      单端口密码
  --single-method M       单端口加密 (默认 chacha20)
  --single-protocol P     单端口协议 (默认 auth_aes128_md5)
  --single-obfs O         单端口混淆 (默认 tls1.2_ticket_auth)
  --single-only on|off    只开单端口、不开每个用户的端口 (默认 on)
  --speed MBPS            每用户限速 Mbps，0 不限速 (默认 0)
  --port-range A-B        --single-only off 时每个用户端口所在的范围 (默认 3000-31000)

其它:
  --name NAME             实例名，也是管理命令名 (默认 kcloud-ssr)
  --firewall strict|off   strict: 只放行 SSH 和节点端口 (默认)；off: 不改防火墙
  --no-tune               不做 BBR / TCP 缓冲区调优
  --ssr-ref BRANCH        shadowsocksr-manyuser 分支 (默认 master)
  --reconfigure           已安装时重新生成 .env
  -h, --help              显示帮助
USAGE
}

KCLOUD_NAME="${KCLOUD_NAME:-kcloud-ssr}"
REPO_URL="${REPO_URL:-https://github.com/movecat/netcloud.git}"
NETCLOUD_REF="${NETCLOUD_REF:-main}"
SSR_REPO="${SSR_REPO:-https://github.com/movecat/shadowsocksr-manyuser.git}"
SSR_REF="${SSR_REF:-master}"
FIREWALL="${FIREWALL:-}"
TUNE="${TUNE:-on}"
RECONFIGURE=0

API="" DB_HOST="" DB_PORT="" DB_USER="" DB_PASS="" DB_NAME="" SERVER_ADDR=""
SINGLE_PORT="" SINGLE_PASS="" SINGLE_METHOD="" SINGLE_PROTOCOL="" SINGLE_OBFS="" SINGLE_ONLY="" SPEED="" PORT_RANGE=""
GIVEN_DB=0
PANEL_URL="" NODE_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel) PANEL_URL="$2"; GIVEN_DB=1; shift 2 ;;
    --node-key) NODE_KEY="$2"; GIVEN_DB=1; shift 2 ;;
    --api) API="$2"; shift 2 ;;
    --db-host) DB_HOST="$2"; GIVEN_DB=1; shift 2 ;;
    --db-port) DB_PORT="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; GIVEN_DB=1; shift 2 ;;
    --db-pass) DB_PASS="$2"; GIVEN_DB=1; shift 2 ;;
    --db-name) DB_NAME="$2"; GIVEN_DB=1; shift 2 ;;
    --server-addr) SERVER_ADDR="$2"; shift 2 ;;
    --single-port) SINGLE_PORT="$2"; shift 2 ;;
    --single-pass) SINGLE_PASS="$2"; shift 2 ;;
    --single-method) SINGLE_METHOD="$2"; shift 2 ;;
    --single-protocol) SINGLE_PROTOCOL="$2"; shift 2 ;;
    --single-obfs) SINGLE_OBFS="$2"; shift 2 ;;
    --single-only) SINGLE_ONLY="$2"; shift 2 ;;
    --speed) SPEED="$2"; shift 2 ;;
    --port-range) PORT_RANGE="$2"; shift 2 ;;
    --name) KCLOUD_NAME="$2"; shift 2 ;;
    --firewall) FIREWALL="$2"; shift 2 ;;
    --no-tune) TUNE=off; shift ;;
    --ssr-ref) SSR_REF="$2"; shift 2 ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[错误] 未知选项: $1"; usage; exit 2 ;;
  esac
done

APP_DIR="${KCLOUD_DIR:-/opt/${KCLOUD_NAME}}"
CONTAINER_NAME="${KCLOUD_CONTAINER_NAME:-${KCLOUD_NAME}}"
IMAGE_NAME="$(printf '%s' "${KCLOUD_IMAGE:-${KCLOUD_NAME}:latest}" | tr '[:upper:]' '[:lower:]')"
ENV_FILE="$APP_DIR/.env"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[错误] 请用 root 用户执行"
  exit 1
fi

# Questions are only asked when stdin is a terminal and the value was not given as an option.
ask() {
  local text="$1" default="${2:-}" value=""
  if [[ ! -t 0 ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${text} [${default}]: " value
  else
    read -r -p "${text}: " value
  fi
  printf '%s' "${value:-$default}"
}

require() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "[错误] 缺少 ${name}（用选项传入，或在终端里交互安装）"
    exit 2
  fi
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

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  { grep -E "^$1=" "$ENV_FILE" || true; } | tail -1 | sed -E 's/^[^=]+="?(.*[^"])?"?$/\1/'
}

set_env() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i -E "s|^$1=.*|$1=$(env_quote "$2" | sed 's/[&|]/\\&/g')|" "$ENV_FILE"
  else
    write_var "$1" "$2" >> "$ENV_FILE"
  fi
}

# The node's single port, from the panel's node API (panel mode).
panel_single_port() {
  curl -fsS --max-time 20 -H "X-Node-Key: $2" "${1%/}/modules/addons/legendsock/nodeapi.php?action=config" \
    | grep -oE '"single_port":[0-9]+' | cut -d: -f2 | grep -E '^[0-9]+$'
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
  echo "[1/6] 检查 Docker..."
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg git iptables

  . /etc/os-release
  local repo_id="${ID:-debian}"
  local codename="${VERSION_CODENAME:-bookworm}"
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

# Check out (or move to the latest) $2 of repository $1 in directory $3, discarding local edits.
checkout() {
  local repo="$1" ref="$2" dir="$3"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" remote set-url origin "$repo"
    git_with_auth -C "$dir" fetch --depth=1 origin "$ref"
    git -C "$dir" checkout -q -f -B "$ref" FETCH_HEAD
    git -C "$dir" reset -q --hard FETCH_HEAD
  else
    rm -rf "$dir"
    git_with_auth clone -q --depth=1 --branch "$ref" "$repo" "$dir"
  fi
}

sync_repo() {
  echo "[2/6] 下载程序..."
  command -v git >/dev/null 2>&1 || { apt-get update; apt-get install -y git; }
  local keep_env=""
  [[ -f "$ENV_FILE" ]] && keep_env="$(cat "$ENV_FILE")"
  checkout "$REPO_URL" "$NETCLOUD_REF" "$APP_DIR"
  [[ -n "$keep_env" ]] && { umask 077; printf '%s\n' "$keep_env" > "$ENV_FILE"; }
  checkout "$SSR_REPO" "$SSR_REF" "$APP_DIR/ssr"
  mkdir -p "$APP_DIR/data" "$APP_DIR/logs"
}

configure_env() {
  echo "[3/6] 节点配置..."
  if [[ -f "$ENV_FILE" && "$RECONFIGURE" -eq 0 && "$GIVEN_DB" -eq 0 ]]; then
    # Keep the installed node's settings; only add settings that newer versions introduced.
    grep -q '^SINGLE_PORT_ONLY=' "$ENV_FILE" || write_var SINGLE_PORT_ONLY "${SINGLE_ONLY:-on}" >> "$ENV_FILE"
    set_env KCLOUD_IMAGE "$IMAGE_NAME"
    set_env KCLOUD_FIREWALL "$FIREWALL"
    if [[ "$(env_get API_INTERFACE)" == "legendsockapi" ]]; then
      # The panel may have moved the node to another port: the firewall follows it.
      local port
      port="$(panel_single_port "$(env_get PANEL_URL)" "$(env_get NODE_KEY)")" && set_env SINGLE_PORT "$port"
    fi
    echo "已保留现有配置 $ENV_FILE（重新配置请加 --reconfigure）"
    return
  fi

  if [[ -n "$PANEL_URL" || -n "$NODE_KEY" ]]; then
    require "--panel" "$PANEL_URL"; require "--node-key" "$NODE_KEY"
    PANEL_URL="${PANEL_URL%/}"
    local port
    if ! port="$(panel_single_port "$PANEL_URL" "$NODE_KEY")"; then
      echo "[错误] 无法从面板读取节点设置，请检查 --panel 网址和 --node-key 密钥"
      exit 2
    fi
    umask 077
    {
      write_var INSTALL_MODE "docker"
      write_var KCLOUD_CONTAINER_NAME "$CONTAINER_NAME"
      write_var KCLOUD_IMAGE "$IMAGE_NAME"
      write_var KCLOUD_FIREWALL "$FIREWALL"
      write_var API_INTERFACE "legendsockapi"
      write_var PANEL_URL "$PANEL_URL"
      write_var NODE_KEY "$NODE_KEY"
      write_var TRANSFER_MUL "1.0"
      write_var SINGLE_PORT_MODE "on"
      write_var SINGLE_PORT_ONLY "on"
      write_var SINGLE_PORT "$port"
      write_var SSR_VERBOSE "-2"
      write_var CONNECT_VERBOSE_INFO "0"
      write_var DOCKER_LOG_MAX_SIZE "20m"
      write_var DOCKER_LOG_MAX_FILE "3"
      write_var LOGS_SAVE "y"
      write_var LOGS_SAVE_DAYS "30"
      write_var NOFILE_LIMIT "51200"
    } > "$ENV_FILE"
    echo "面板模式：单端口 $port，加密 / 协议 / 混淆 / 限速由面板下发"
    return
  fi

  local detected
  detected="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  API="${API:-$(ask "API 接口 legendsockssr/sspanelv3/glzjinmod/sspanelv2/mudbjson" "legendsockssr")}"
  if [[ "$API" != "mudbjson" ]]; then
    DB_HOST="${DB_HOST:-$(ask "数据库地址" "")}"
    DB_PORT="${DB_PORT:-$(ask "数据库端口" "3306")}"
    DB_USER="${DB_USER:-$(ask "数据库账户" "")}"
    DB_PASS="${DB_PASS:-$(ask "数据库密码" "")}"
    DB_NAME="${DB_NAME:-$(ask "数据库名称" "")}"
    require "--db-host" "$DB_HOST"; require "--db-user" "$DB_USER"; require "--db-pass" "$DB_PASS"; require "--db-name" "$DB_NAME"
  fi
  SERVER_ADDR="${SERVER_ADDR:-$(ask "节点公网 IP 或域名" "${detected:-127.0.0.1}")}"
  SINGLE_PORT="${SINGLE_PORT:-$(ask "单端口端口" "")}"
  SINGLE_PASS="${SINGLE_PASS:-$(ask "单端口密码" "")}"
  SINGLE_METHOD="${SINGLE_METHOD:-$(ask "单端口加密方式" "chacha20")}"
  SINGLE_PROTOCOL="${SINGLE_PROTOCOL:-$(ask "单端口协议插件" "auth_aes128_md5")}"
  SINGLE_OBFS="${SINGLE_OBFS:-$(ask "单端口混淆方式" "tls1.2_ticket_auth")}"
  SINGLE_ONLY="${SINGLE_ONLY:-$(ask "只开单端口 on/off" "on")}"
  SPEED="${SPEED:-$(ask "限速 Mbps，0 为不限速" "0")}"
  if [[ "$SINGLE_ONLY" != "on" ]]; then
    PORT_RANGE="${PORT_RANGE:-$(ask "用户端口段" "3000-31000")}"
  fi
  require "--single-port" "$SINGLE_PORT"; require "--single-pass" "$SINGLE_PASS"

  umask 077
  {
    write_var INSTALL_MODE "docker"
    write_var KCLOUD_CONTAINER_NAME "$CONTAINER_NAME"
    write_var KCLOUD_IMAGE "$IMAGE_NAME"
    write_var KCLOUD_FIREWALL "$FIREWALL"
    write_var API_INTERFACE "$API"
    write_var UPDATE_TIME "60"
    write_var SERVER_PUB_ADDR "$SERVER_ADDR"
    write_var DB_HOST "$DB_HOST"
    write_var DB_PORT "${DB_PORT:-3306}"
    write_var DB_USER "$DB_USER"
    write_var DB_PASSWORD "$DB_PASS"
    write_var DB_NAME "$DB_NAME"
    write_var NODE_ID "0"
    write_var TRANSFER_MUL "1.0"
    write_var ALLOW_EMPTY_DB_PASSWORD "0"
    write_var SSR_METHOD "$SINGLE_METHOD"
    write_var SSR_PROTOCOL "$SINGLE_PROTOCOL"
    write_var SSR_OBFS "$SINGLE_OBFS"
    write_var SSR_PROTOCOL_PARAM ""
    write_var SSR_OBFS_PARAM ""
    write_var PORT_RANGE "${PORT_RANGE:-3000-31000}"
    write_var SPEED_LIMIT_MBPS "$SPEED"
    write_var SPEED_LIMIT_KB ""
    write_var SINGLE_PORT_MODE "on"
    write_var SINGLE_PORT_ONLY "$SINGLE_ONLY"
    write_var SINGLE_PORT "$SINGLE_PORT"
    write_var SINGLE_PASSWORD "$SINGLE_PASS"
    write_var SINGLE_METHOD "$SINGLE_METHOD"
    write_var SINGLE_OBFS "$SINGLE_OBFS"
    write_var SINGLE_PROTOCOL "$SINGLE_PROTOCOL"
    write_var SINGLE_PROTOCOL_PARAM "#"
    write_var SSR_VERBOSE "-2"
    write_var CONNECT_VERBOSE_INFO "0"
    write_var DOCKER_LOG_MAX_SIZE "20m"
    write_var DOCKER_LOG_MAX_FILE "3"
    write_var LOGS_SAVE "y"
    write_var LOGS_SAVE_DAYS "30"
    write_var NOFILE_LIMIT "51200"
  } > "$ENV_FILE"
}

tune_system() {
  [[ "$TUNE" == "on" ]] || return 0
  echo "[4/6] 网络调优（BBR、TCP 缓冲区）..."
  cat > /etc/sysctl.d/90-kcloud.conf <<'SYSCTL'
# KCloud SSR node: BBR and buffers sized for long-distance links.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65000
fs.file-max = 1048576
SYSCTL
  sysctl --system >/dev/null
}

# Strict firewall: loopback, established traffic, SSH and the node's ports; everything else dropped.
# Saved to /etc/iptables and restored at boot by kcloud-firewall.service.
setup_firewall() {
  [[ "$FIREWALL" == "strict" ]] || { echo "[5/6] 防火墙：不修改"; return 0; }
  echo "[5/6] 防火墙：只放行 SSH 和节点端口..."
  command -v iptables >/dev/null 2>&1 || { apt-get update; apt-get install -y iptables; }
  local ssh_ports node_ports=() p
  ssh_ports="$( (sshd -T 2>/dev/null | awk '/^port /{print $2}'; [[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $4}' <<<"$SSH_CONNECTION") | sort -un)"
  [[ -n "$ssh_ports" ]] || ssh_ports=22
  node_ports+=("$(env_get SINGLE_PORT)")
  if [[ "$(env_get SINGLE_PORT_ONLY)" != "on" ]]; then
    node_ports+=("$(env_get PORT_RANGE | tr '-' ':')")
  fi
  mkdir -p /etc/iptables
  for tool in iptables ip6tables; do
    local rules="*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p $([[ $tool == iptables ]] && echo icmp || echo ipv6-icmp) -j ACCEPT"
    for p in $ssh_ports; do rules+=$'\n'"-A INPUT -p tcp --dport $p -j ACCEPT"; done
    for p in "${node_ports[@]}"; do
      [[ -n "$p" ]] || continue
      rules+=$'\n'"-A INPUT -p tcp --dport $p -j ACCEPT"$'\n'"-A INPUT -p udp --dport $p -j ACCEPT"
    done
    rules+=$'\n'"COMMIT"
    local file=/etc/iptables/rules.$([[ $tool == iptables ]] && echo v4 || echo v6)
    printf '%s\n' "$rules" > "$file"
    # Replace only the filter table's INPUT chain; Docker's own chains are left alone.
    "$tool" -P INPUT ACCEPT
    "$tool" -F INPUT
    "${tool}-restore" --noflush < "$file"
  done
  cat > /etc/systemd/system/kcloud-firewall.service <<'UNIT'
[Unit]
Description=KCloud node firewall rules
Before=network-pre.target docker.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables -F INPUT; iptables-restore --noflush /etc/iptables/rules.v4; ip6tables -F INPUT; ip6tables-restore --noflush /etc/iptables/rules.v6'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q kcloud-firewall.service
  echo "放行: SSH ${ssh_ports//$'\n'/ }，节点 ${node_ports[*]}"
}

write_manager() {
  local manager="/usr/local/bin/${CONTAINER_NAME}"
  cat > "$manager" <<EOF
#!/usr/bin/env bash
# Manage the KCloud SSR node "$CONTAINER_NAME" ($APP_DIR).
set -euo pipefail
cd "$APP_DIR"
case "\${1:-status}" in
  start) docker compose up -d ;;
  stop) docker compose stop ;;
  restart) docker compose up -d --build --force-recreate ;;
  status) docker compose ps; docker exec "$CONTAINER_NAME" kcloud-entrypoint status || true ;;
  log|logs) docker compose logs -f --tail=200 ;;
  config) \${EDITOR:-nano} "$APP_DIR/.env" && docker compose up -d --force-recreate ;;
  update) KCLOUD_NAME="$KCLOUD_NAME" SSR_REF="\${2:-$SSR_REF}" bash "$APP_DIR/install.sh" --name "$KCLOUD_NAME" --no-tune ;;
  version) echo "netcloud \$(git -C "$APP_DIR" log -1 --format='%h %cs')"; echo "ssr \$(git -C "$APP_DIR/ssr" log -1 --format='%h %cs %s')" ;;
  view) docker exec -it "$CONTAINER_NAME" kcloud-entrypoint view ;;
  shell) docker exec -it "$CONTAINER_NAME" bash ;;
  uninstall)
    read -r -p "确定卸载 $CONTAINER_NAME？(输入 yes 确认): " ok
    [[ "\$ok" == "yes" ]] || exit 1
    docker compose down --rmi local || true
    rm -f "/usr/local/bin/$CONTAINER_NAME"
    echo "已卸载容器和管理命令；配置保留在 $APP_DIR，防火墙规则保留在 /etc/iptables" ;;
  *) echo "用法: $CONTAINER_NAME start|stop|restart|status|log|config|update [分支]|version|view|shell|uninstall" ;;
esac
EOF
  chmod +x "$manager"
}

start_service() {
  echo "[6/6] 构建并启动..."
  cd "$APP_DIR"
  docker compose up -d --build --force-recreate
}

FIREWALL="${FIREWALL:-$(env_get KCLOUD_FIREWALL)}"
FIREWALL="${FIREWALL:-strict}"

install_docker
sync_repo
configure_env
tune_system
[[ "$FIREWALL" == "none" ]] || setup_firewall
write_manager
start_service

echo
echo "完成。管理命令: ${CONTAINER_NAME} status | log | restart | config | update | version | uninstall"
if [[ "$FIREWALL" == "strict" ]]; then
  echo "云服务商的安全组 / 防火墙也要放行单端口 $(env_get SINGLE_PORT)（TCP 和 UDP）。"
fi
