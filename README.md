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

安装完成后的常用命令：

```bash
kcloud-ssr status
kcloud-ssr logs
kcloud-ssr restart
kcloud-ssr config
```

如果数据库在宿主机本机，Compose 使用 `network_mode: host`，所以 `DB_HOST=127.0.0.1` 可以直接指向宿主机 MySQL。

如果数据库在其他服务器，直接填写远程地址即可。
