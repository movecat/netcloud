# KCloud SSR Docker

这套文件把原来的 `kcloud.sh` 改成 Docker 运行方式，保留核心功能：

- 从自己维护的 `movecat/shadowsocksr-manyuser`（`master`）构建镜像
- 自动生成 `user-config.json`
- 自动生成 `usermysql.json`
- 自动生成 `apiconfig.py`
- 支持 `legendsockssr`、`sspanelv3`、`glzjinmod`、`sspanelv2`、`mudbjson`
- 支持单端口多用户 `additional_ports`
- 支持 Docker restart 策略

## 一键安装（Debian 12 / 13）

### 面板模式（推荐）

在 WHMCS 后台「插件 → LegendSock → 节点接入」添加节点，页面会显示节点密钥和下面这样一行命令，在节点上用 root 执行即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/movecat/netcloud/main/install.sh) --panel https://huohuxx.com --node-key 节点密钥
```

- 节点通过面板的节点接口同步用户和上报流量，**节点上不保存数据库账号密码**。
- 单端口端口、加密、协议、混淆、单端口密码、限速都由面板下发；在面板改了之后节点会在一分钟内自动重启生效（改了端口要在节点上执行一次 `kcloud-ssr update`，让防火墙跟着改）。
- 已装好的数据库模式节点，执行同一行命令就会切换到面板模式。



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

