# KCloud SSR Docker

这套文件把原来的 `kcloud.sh` 改成 Docker 运行方式，保留核心功能：

- 从 `movecat/shadowsocksr-manyuser` 构建镜像
- 自动生成 `user-config.json`
- 自动生成 `usermysql.json`
- 自动生成 `apiconfig.py`
- 支持 `legendsockssr`、`sspanelv3`、`glzjinmod`、`sspanelv2`、`mudbjson`
- 支持单端口多用户 `additional_ports`
- 支持 Docker restart 策略

## 一键安装 Debian 13

服务器上用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
```

如果仓库改成私有，需要先准备 GitHub token。Fine-grained token 给 `movecat/netcloud` 仓库 `Contents: Read-only` 权限即可；classic token 需要 `repo` 权限。服务器上用 root 执行：

```bash
export GITHUB_TOKEN=你的GitHubToken
bash <(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/movecat/netcloud/main/install.sh)
unset GITHUB_TOKEN
```

安装完成后的常用命令：

```bash
kcloud-ssr status
kcloud-ssr logs
kcloud-ssr restart
kcloud-ssr config
```

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
