# luci-app-ipv6prefixsnat

为 OpenWrt / LuCI 提供一个**自动发现接口**的 IPv6 Prefix SNAT 管理界面，支持：

- LuCI 页面管理
- ubus / JSON-RPC 管理
- 开机自动重建规则
- hotplug 在接口 `ifup` / `ifupdate` / `ifdown` 时自动重建规则
- 自动遍历逻辑接口，动态识别可用的 IPv6 出口接口与前缀
- 运行时预览与当前已生效规则展示

## 功能说明

本应用**不再手工选择某一个 IPv6 WAN 接口**，而是在运行时自动：

1. 遍历系统中的逻辑接口
2. 读取 `ubus call network.interface dump` 的运行时接口信息
3. 筛选出满足以下条件的接口：
   - `up=true`
   - 存在 `l3_device` 或 `device`
   - 存在可用的已分配 IPv6 前缀
4. 默认跳过以下前缀：
   - 未指定地址 (`::`)
   - loopback (`::1`)
   - IPv4-mapped IPv6 (`::ffff:*`)
   - link-local (`fe80::/10`)
   - 已废弃的 site-local (`fec0::/10`)
   - ULA (`fc00::/7` / `fd00::/8`)
   - multicast (`ff00::/8`)
5. 为每个可用出口接口生成“**其他前缀 -> 当前出口前缀**”的前缀转换规则

## IPv6 前缀获取方式

程序当前会从 `network.interface dump` 返回结果中的 `ipv6-prefix[*].assigned.*` 中**遍历所有候选已分配前缀**，并为每个逻辑接口选取**第一个满足条件的全局 IPv6 前缀**作为该接口当前前缀。

也就是说，程序不再固定依赖：

- `@['ipv6-prefix'][0].assigned.lan.address`
- `@['ipv6-prefix'][0].assigned.lan.mask`

而是会遍历类似这样的结构：

```json
{
  "ipv6-prefix": [
    {
      "assigned": {
        "lan": {
          "address": "2001:db8:1234:56::",
          "mask": 64
        },
        "guest": {
          "address": "2001:db8:1234:57::",
          "mask": 64
        }
      }
    }
  ]
}
```

程序会将候选值组合为：

```text
<address>/<mask>
```

例如：

```text
2001:db8:1234:56::/64
```

### 当前选择策略

为避免同一个出口设备重复参与规则生成，当前实现采用以下策略：

- 对每个逻辑接口遍历 `ipv6-prefix[*].assigned.*`
- 选取**第一个合格前缀**作为该接口当前前缀
- 同一 `device` 只保留一次

若某个接口没有返回任何合格前缀，则该接口会被自动跳过，不参与规则生成。

## 规则文件位置

本应用会为 nftables 生成独立的 `table ip6 ipv6prefixsnat_nat`，规则文件路径为：

```text
/usr/share/nftables.d/ruleset-post/90-ipv6prefixsnat.nft
```

生成的规则结构类似如下：

```nft
table ip6 ipv6prefixsnat_nat {
    chain srcnat {
        type nat hook postrouting priority srcnat; policy accept;

        oifname "pppoe-wan00" ip6 saddr != 2001:db8:1::/64 \
            snat ip6 prefix to ip6 saddr map { 2001:db8:2::/64 : 2001:db8:1::/64, 2001:db8:3::/64 : 2001:db8:1::/64 }

        oifname "pppoe-wan01" ip6 saddr != 2001:db8:2::/64 \
            snat ip6 prefix to ip6 saddr map { 2001:db8:1::/64 : 2001:db8:2::/64, 2001:db8:3::/64 : 2001:db8:2::/64 }
    }
}
```

其含义是：

- 当流量从某个出口设备发出时
- 如果源地址前缀不是该出口当前前缀
- 则把“其他已发现接口的前缀”映射为“当前出口前缀”

## 自动更新机制

本应用保留并强化了自动更新机制：

- **开机自启动**：服务启用后，设备重启时会自动执行规则重建
- **接口事件自动重建**：当接口发生 `ifup` / `ifupdate` / `ifdown` 时，hotplug 自动重新检测接口并重建规则
- **配置变更自动重建**：提交 `ipv6prefixsnat`、`network`、`firewall` 配置后，服务会触发 reload

因此以下情况通常都会自动更新规则：

- IPv6 前缀变化
- 实际出口设备变化
- 某条上联接口上下线
- 设备重启后网络重新建立

## 界面说明

LuCI 页面当前分为以下几个区域：

- **启用** 复选框
- **当前运行状态**
- **当前已生效规则**
- **运行时预览规则**

### 当前运行状态

显示：

- 启用状态
- 已发现接口数
- 规则文件是否存在
- nft 运行表是否存在
- `fw4 auto_includes` 状态
- 当前环境是否可应用

“原因”字段默认**只在当前不可应用时显示**，避免正常状态下界面信息冗余。

### 当前已生效规则

该区域显示：

- 当前真正已生效的规则内容
- 规则来源（运行时 nft 表或规则文件）
- 当前规则对应接口列表

### 运行时预览规则

该区域显示：

- 按当前检测结果生成的预览规则
- 预览规则对应接口列表
- 当前运行环境是否满足应用条件

“原因”字段默认**只在当前不可应用时显示**。

页面入口：

```text
网络 -> IPv6 Prefix SNAT
```

## UCI 配置

配置文件：

```text
/etc/config/ipv6prefixsnat
```

默认内容：

```uci
config ipv6prefixsnat 'config'
    option enabled '0'
```

说明：

- `enabled=1`：启用自动前缀转换规则
- `enabled=0`：禁用并移除规则

## 依赖

- `luci-base`
- `rpcd`
- `uhttpd-mod-ubus`
- `firewall4`
- `nftables`
- `jsonfilter`
- `libubox`

## 编译

把本目录放到你的 LuCI 源码树中，例如：

```sh
cd luci/applications
cp -a /path/to/luci-app-ipv6prefixsnat .
```

然后在 OpenWrt 根目录：

```sh
make menuconfig
make package/luci-app-ipv6prefixsnat/compile V=s
```

## 安装与升级说明

### 首次安装

首次安装后，通常会通过 `uci-defaults` 完成初始化，包括：

- 补齐默认配置
- 修正脚本权限
- 启用服务
- 重启 `rpcd`
- 按当前接口状态尝试重建规则

### 升级安装

为避免某些 `apk`/升级阶段出现安装后脚本直接调用 init 服务导致的权限问题，包的 `postinst` 只执行轻量操作：

- 修正关键脚本权限
- 重启 `rpcd`

因此在某些升级路径下，如果升级后服务没有自动启用或重建，可手动执行：

```sh
/etc/init.d/ipv6prefixsnat enable
/etc/init.d/ipv6prefixsnat restart
```

## 服务管理

启用并启动：

```sh
/etc/init.d/ipv6prefixsnat enable
/etc/init.d/ipv6prefixsnat start
```

重建规则：

```sh
/etc/init.d/ipv6prefixsnat restart
```

停用并移除规则：

```sh
/etc/init.d/ipv6prefixsnat stop
```

检查是否已启用开机启动：

```sh
/etc/init.d/ipv6prefixsnat enabled; echo $?
```

若返回 `0`，通常表示已启用。

## ubus 示例

查询状态：

```sh
ubus call ipv6prefixsnat get_status '{}'
ubus call ipv6prefixsnat get_current_rules '{}'
ubus call ipv6prefixsnat test_runtime '{}'
```

启用并应用：

```sh
ubus call ipv6prefixsnat set_config '{"enabled": true}'
ubus call ipv6prefixsnat apply '{}'
```

停用：

```sh
ubus call ipv6prefixsnat disable '{}'
```

按当前运行状态重新检测并重建：

```sh
ubus call ipv6prefixsnat reload_runtime '{}'
```

## HTTP JSON-RPC 示例

先登录获取 `ubus_rpc_session`：

```sh
curl -s http://192.168.1.1/ubus \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"root","password":"你的密码"}]}'
```

启用并应用：

```sh
curl -s http://192.168.1.1/ubus \
  -d '{"jsonrpc":"2.0","id":2,"method":"call","params":["<ubus_rpc_session>","ipv6prefixsnat","set_config",{"enabled":1}]}'

curl -s http://192.168.1.1/ubus \
  -d '{"jsonrpc":"2.0","id":3,"method":"call","params":["<ubus_rpc_session>","ipv6prefixsnat","apply",{}]}'
```

## 运行机制

1. LuCI 页面或外部程序通过 RPC 修改启用状态
2. 后端脚本自动遍历逻辑接口并读取 `network.interface dump` 运行时状态
3. 从 `ipv6-prefix[*].assigned.*` 遍历候选已分配前缀
4. 为每个逻辑接口选择第一个合格前缀
5. 筛选出可用的 IPv6 接口、设备名与前缀
6. 按 `device` 去重，避免同一出口设备重复参与规则生成
7. 生成临时规则文件并使用 `nft -c -f` 校验语法
8. 校验通过后写入 `/usr/share/nftables.d/ruleset-post/90-ipv6prefixsnat.nft`
9. 删除旧的 `ip6 ipv6prefixsnat_nat` 运行表，避免独立 table 叠加
10. 执行 `fw4 reload`
11. 成功应用后记录当前已应用规则对应接口，用于 LuCI “当前已生效规则”展示
12. 后续在接口事件、服务 reload 或系统重启后自动重新检测并重建

## 注意事项

- 默认至少需要 **2 个有效的活动 IPv6 接口**，否则不会生成前缀映射规则
- 默认会跳过未指定地址、loopback、IPv4-mapped IPv6、link-local、site-local、ULA 与 multicast 前缀
- 依赖 `firewall.@defaults[0].auto_includes=1`
- 如果当前没有足够的可用 IPv6 接口，应用规则时会自动移除旧规则，避免残留错误配置
- 如果某个接口没有返回任何合格的 `ipv6-prefix[*].assigned.*` 前缀，该接口不会参与规则生成
- 本应用会优先显示当前已经生效的规则，并单独显示运行时预览规则，便于对比当前状态与实时检测结果

