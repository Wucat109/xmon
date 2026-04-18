# xmon

一个面向 **3x-ui / x-ui** 的轻量级端口流量监控脚本，用于监控入站端口的实时流量、窗口平均速率、历史流量统计与 Telegram 告警。

---

## 项目简介

`xmon` 是一个基于 **Bash + Python + iptables + systemd** 的监控工具，主要用于 **3x-ui / x-ui** 场景下的端口流量监控。

它会自动读取 3x-ui 数据库中的已启用入站端口，结合 `iptables` 统计端口字节数，并持续计算：

- 当前速率
- 窗口平均速率
- 今日累计流量
- 最近 1 小时 / 6 小时 / 12 小时 / 今日流量
- 当前端口速率排行

同时支持：

- Telegram 超阈值告警
- 黑名单 / 白名单过滤端口
- systemd 后台守护运行
- 配置健康检查
- 数据文件大小检查
- 手动同步规则
- 一键卸载

---

## 功能特性

- 自动安装依赖：
  - `python3`
  - `python3-pip`
  - `iptables`
  - `sqlite3`
  - `curl`
- 自动写入 Python 主程序
- 自动生成 systemd 服务
- 自动读取 3x-ui 入站端口
- 基于 `iptables` 统计端口流量
- 支持查看单端口最近状态
- 支持按时间范围查询流量
- 支持当前速率排行
- 支持 Telegram 告警推送
- 支持端口黑名单 / 白名单
- 支持保留原配置更新
- 支持交互式修改配置
- 支持健康检查
- 支持手动同步规则
- 支持完整卸载

---

## 适用环境

建议在以下环境中使用：

- Debian / Ubuntu
- 已安装并正常运行 **3x-ui / x-ui**
- 系统使用 `systemd`
- 系统提供 `iptables`
- 需要 `root` 权限执行脚本

> 注意：脚本会检查 root 权限，非 root 运行会直接退出。

---

## 工作原理

`xmon` 的运行逻辑大致如下：

1. 从 3x-ui 数据库中读取已启用入站端口
2. 根据白名单和黑名单筛选需要监控的端口
3. 创建并维护专用 `iptables` 统计链
4. 周期性采样端口累计字节数
5. 计算每个端口的当前速率、窗口平均速率与今日累计流量
6. 当速率超过阈值时触发 Telegram 告警
7. 将状态与历史数据保存到本地 JSON 文件中，供后续查询使用

---

## 安装后文件路径

安装完成后，主要文件如下：

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/xmon.py` | Python 主程序 |
| `/etc/xmon.conf` | 配置文件 |
| `/etc/systemd/system/xmon.service` | systemd 服务文件 |
| `/var/lib/xmon/state.json` | 当前状态数据 |
| `/var/lib/xmon/history.json` | 历史采样数据 |
| `/var/lib/xmon/daily_baseline.json` | 每日累计基线数据 |

---

## 下载与运行

仓库地址：

- GitHub：`https://github.com/Wucat109/xmon`
- 脚本页面：`https://github.com/Wucat109/xmon/blob/main/xmon.sh`
- Raw 地址：`https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh`

### 使用 curl 下载

    curl -fsSL -o xmon.sh https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh
    chmod +x xmon.sh
    bash xmon.sh

### 使用 wget 下载

    wget -O xmon.sh https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh
    chmod +x xmon.sh
    bash xmon.sh

### 使用 curl 一行直接运行

    bash <(curl -fsSL https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh)

### 使用 wget 一行直接运行

    bash <(wget -qO- https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh)

---

## 安装说明

运行脚本后，会进入交互式管理菜单。

首次安装推荐选择：

    1. 安装/更新监控（保留现有配置）

如果系统中不存在配置文件，脚本会自动进入首次配置流程。

安装过程会自动完成以下操作：

1. 安装依赖
2. 写入 Python 主程序
3. 创建 systemd 服务
4. 初始化配置文件
5. 启动并设置服务开机自启

---

## 配置文件

配置文件路径：

    /etc/xmon.conf

常见配置项示例：

    SERVER_NAME=my-server
    DB_PATH=/etc/x-ui/x-ui.db
    CHAIN_NAME=XUI_MONITOR
    SAMPLE_INTERVAL=5
    WINDOW_SECONDS=30
    ALERT_THRESHOLD_MIB=15
    SYNC_IPTABLES_EVERY=60
    TG_BOT_TOKEN=
    TG_CHAT_ID=
    ALERT_COOLDOWN=300
    PORT_BLACKLIST=
    PORT_WHITELIST=
    HISTORY_KEEP_DAYS=3

---

## 配置项说明

### `SERVER_NAME`
服务器名称或备注，用于日志、状态显示和 Telegram 告警消息中标识当前机器。

示例：

    hk-node-01

### `DB_PATH`
3x-ui 数据库路径，默认一般为：

    /etc/x-ui/x-ui.db

如果你的面板安装路径不同，需要手动修改。

### `CHAIN_NAME`
`iptables` 统计链名称，默认一般为：

    XUI_MONITOR

通常无需修改，除非你有特殊需求。

### `SAMPLE_INTERVAL`
采样间隔，单位为秒。

示例：

    5

表示每 5 秒采集一次流量数据。

### `WINDOW_SECONDS`
统计窗口秒数，用于计算窗口平均速率。

示例：

    30

表示基于最近 30 秒窗口计算平均流量。

### `ALERT_THRESHOLD_MIB`
告警阈值，单位为 **MiB/s**。

示例：

    15

表示当端口流量超过 `15 MiB/s` 时触发告警逻辑。

### `SYNC_IPTABLES_EVERY`
`iptables` 规则同步周期，单位为秒。

示例：

    60

表示每 60 秒重新同步一次监控规则。

### `TG_BOT_TOKEN`
Telegram 机器人 Token。  
如果不需要 Telegram 告警，可留空。

### `TG_CHAT_ID`
Telegram 接收消息的 Chat ID。  
如果不需要 Telegram 告警，可留空。

### `ALERT_COOLDOWN`
告警冷却时间，单位为秒，用于限制重复告警频率。

示例：

    300

表示同一类告警在 300 秒内不会重复发送。

### `PORT_BLACKLIST`
端口黑名单，黑名单中的端口不会被监控。

示例：

    22,80,443

### `PORT_WHITELIST`
端口白名单。  
如果设置了白名单，则只监控白名单中的端口；如果留空，则默认监控数据库中所有符合条件的端口。

示例：

    10001,10002,10003

### `HISTORY_KEEP_DAYS`
历史数据保留天数。

示例：

    3

---

## 菜单功能说明

脚本提供交互式菜单，常见功能包括：

### 1. 安装/更新监控（保留现有配置）
安装或更新程序。如果配置文件已存在，则保留原配置不变。

### 2. 初始化/重建配置
重新进入配置流程，生成新的配置文件，并在完成后重启服务。

### 3. 启动服务
启动 `xmon` 后台服务。

### 4. 停止服务
停止 `xmon` 服务。

### 5. 重启服务
重启监控服务，使配置或规则重新生效。

### 6. 查看服务状态
查看 systemd 服务当前状态。

### 7. 查看实时日志
实时跟踪 `xmon` 服务日志输出。

### 8. 查询特定端口最近情况
查看某个端口的最近状态，包括：

- 当前速率
- 窗口平均速率
- 今日累计流量
- 报警状态
- 最近若干采样记录

### 9. 查询流量
支持按时间范围查询流量，常见范围包括：

- 最近 1 小时
- 最近 6 小时
- 最近 12 小时
- 今日

既可以查询单个端口，也可以汇总查看多个端口数据。

### 10. 当前速率排行
查看当前所有监控端口的速率排行，快速识别高流量端口。

### 11. 实际监控端口列表
查看数据库端口、白名单、黑名单与最终实际监控端口的对应关系。

### 12. 查看当前配置
直接输出当前配置文件内容。

### 13. 修改配置
交互式修改配置项，支持保留原值，也支持清空可选字段。

### 14. 测试 TG 报警
发送 Telegram 测试消息，验证 `TG_BOT_TOKEN` 和 `TG_CHAT_ID` 是否正确。

### 15. 配置健康检查
检查配置、数据库、`iptables`、依赖模块、服务状态及相关文件情况。

### 16. 查看数据文件大小
查看状态文件、历史文件和基线文件的大小。

### 17. 列出 3x-ui 入站端口
从数据库中读取入站端口并展示。

### 18. 手动同步 iptables 规则
用于手动触发监控规则同步。

### 19. 卸载监控
按提示卸载程序、服务、配置、数据文件和监控链。

---

## 常用命令

### 查看服务状态

    systemctl status xmon --no-pager

### 启动服务

    systemctl enable --now xmon

### 重启服务

    systemctl restart xmon

### 停止服务

    systemctl stop xmon

### 查看实时日志

    journalctl -u xmon -f

---

## Telegram 告警说明

如果配置了以下参数：

- `TG_BOT_TOKEN`
- `TG_CHAT_ID`

当某个端口的流量超过阈值时，脚本会向 Telegram 推送告警消息。

建议配置完成后，在菜单中执行：

    14. 测试 TG 报警

以确认 Telegram 推送工作正常。

---

## 白名单与黑名单逻辑

### 黑名单
黑名单中的端口会被直接排除，不参与监控。

### 白名单
如果设置了白名单，则仅监控白名单中的端口。

### 同时存在时
通常可以理解为：

1. 先读取数据库中已启用的入站端口
2. 再根据白名单限制监控范围
3. 最后通过黑名单排除不需要监控的端口

建议避免同一个端口同时出现在白名单和黑名单中，以免造成理解混乱。

---

## 健康检查建议

安装完成后，建议至少执行一次健康检查，以确认以下项目正常：

- 配置文件存在且格式正确
- 3x-ui 数据库存在且可读取
- `iptables` 可用
- 监控链已创建
- Python 依赖模块可用
- `xmon` systemd 服务处于运行状态
- 数据文件可正常写入
- Telegram 配置完整（如需要）

可在菜单中选择：

    15. 配置健康检查

---

## 卸载说明

如需卸载，可在菜单中选择：

    19. 卸载监控

卸载过程中可根据提示决定是否删除以下内容：

- systemd 服务
- 主程序与配置文件
- 状态与历史数据
- `iptables` 监控链

---

## 注意事项

1. 必须使用 `root` 运行脚本
2. 脚本依赖 `iptables`
3. 主要适配 **3x-ui / x-ui** 环境
4. 默认数据库路径通常为：

       /etc/x-ui/x-ui.db

   如果你的环境路径不同，请自行修改配置
5. 若修改了 `CHAIN_NAME`，建议重启服务让规则重新初始化
6. 如果服务器重启后监控异常，请检查：
   - `xmon` 服务是否已开机自启
   - `iptables` 是否正常可用
   - 系统规则是否被其他脚本覆盖

---

## 推荐使用方式

推荐直接执行以下命令完成安装：

    bash <(curl -fsSL https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh)

如果你更希望先下载再运行，也可以使用：

    wget -O xmon.sh https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh
    chmod +x xmon.sh
    bash xmon.sh

---

## 项目地址

- GitHub 仓库：`https://github.com/Wucat109/xmon`
- 脚本页面：`https://github.com/Wucat109/xmon/blob/main/xmon.sh`
- Raw 下载地址：`https://raw.githubusercontent.com/Wucat109/xmon/main/xmon.sh`

---

## License

如果你准备开源发布，建议补充 `LICENSE` 文件。  
若暂未添加许可证，本项目默认仅按仓库当前公开状态提供参考与使用。
