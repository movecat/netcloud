# KCloud SSR Docker

这套文件把原来的 `kcloud.sh` 改成 Docker 运行方式，保留核心功能：

- 从 `movecat/shadowsocksr-manyuser`（`modern` 分支）构建镜像
- 自动生成 `user-config.json`
- 自动生成 `usermysql.json`
- 自动生成 `apiconfig.py`
- 支持 `legendsockssr`、`sspanelv3`、`glzjinmod`、`sspanelv2`、`mudbjson`
- 支持单端口多用户 `additional_ports`
- 支持 Docker restart 策略

## 一键安装（Debian 12 / 13）

一行命令装完，不再逐项提问（以 LegendSock 面板为例）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh) \
  --db-host 47.244.157.80 --db-name rrsls --db-user rrsls --db-pass '数据库密码' \
  --single-port 59113 --single-pass '单端口密码'
```

- 加密、协议、混淆默认 `chacha20 / auth_aes128_md5 / tls1.2_ticket_auth`，可用 `--single-method / --single-protocol / --single-obfs` 改，必须和面板里的单端口设置一致。
- 默认只开单端口（`--single-only on`），不再给每个用户单独开端口。
- 默认开启严格防火墙（只放行 SSH 和单端口）和 BBR / TCP 缓冲区调优；不要的话加 `--firewall off` / `--no-tune`。
- 全部选项：`install.sh --help`。不带选项运行时和以前一样逐项提问。
- 云服务商的安全组还要放行单端口（TCP 和 UDP）。

如果仓库改成私有，需要先准备 GitHub token。Fine-grained token 给 `movecat/netcloud` 和 `movecat/shadowsocksr-manyuser` 仓库 `Contents: Read-only` 权限即可；classic token 需要 `repo` 权限：

```bash
export GITHUB_TOKEN=你的GitHubToken
bash <(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/movecat/netcloud/main/install.sh) --db-host ...
unset GITHUB_TOKEN
```

## 管理命令

```bash
kcloud-ssr status      # 运行状态
kcloud-ssr log         # 实时日志
kcloud-ssr restart     # 重启
kcloud-ssr config      # 修改配置（.env）并重启
kcloud-ssr update      # 升级到最新版（保留配置）
kcloud-ssr version     # 当前版本
kcloud-ssr uninstall   # 卸载
```

节点程序来自 `movecat/shadowsocksr-manyuser` 的 `modern` 分支（Python 3.12；用户超额、被暂停或改密码后立即断开其现有连接；停止时先把未提交的流量写回数据库）。

## 多实例

一台服务器可以跑多个实例，但每个实例必须使用不同的端口段和单端口。

```bash
KCLOUD_NAME=kcloud-a bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
KCLOUD_NAME=kcloud-b bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
```

私有仓库的多实例写法：

```bash
export GITHUB_TOKEN=你的GitHubToken
KCLOUD_NAME=kcloud-a bash <(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
KCLOUD_NAME=kcloud-b bash <(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
unset GITHUB_TOKEN
```

安装后分别管理：

```bash
kcloud-a logs
kcloud-b restart
```

如果数据库在宿主机本机，Compose 使用 `network_mode: host`，所以 `DB_HOST=127.0.0.1` 可以直接指向宿主机 MySQL。

如果数据库在其他服务器，直接填写远程地址即可。
