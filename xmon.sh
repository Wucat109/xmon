#!/usr/bin/env bash

set -e

APP_NAME="xmon"
PY_SCRIPT="/usr/local/bin/xmon.py"
CONF_FILE="/etc/xmon.conf"
SERVICE_FILE="/etc/systemd/system/xmon.service"
STATE_DIR="/var/lib/xmon"
STATE_FILE="${STATE_DIR}/state.json"
HISTORY_FILE="${STATE_DIR}/history.json"
DAILY_FILE="${STATE_DIR}/daily_baseline.json"

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    red "请用 root 运行此脚本"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}"
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_number() {
  [[ "$1" =~ ^([0-9]+)(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($1 > 0)}"
}

validate_port_list() {
  local input="$1"
  [[ -z "$input" ]] && return 0

  IFS=',' read -ra arr <<< "$input"
  for item in "${arr[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" ]] && continue
    if ! [[ "$item" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    if (( item < 1 || item > 65535 )); then
      return 1
    fi
  done
  return 0
}

validate_config_values() {
  local server_name="$1"
  local threshold="$2"
  local window="$3"
  local sample="$4"
  local sync_every="$5"
  local cooldown="$6"
  local history_days="$7"
  local blacklist="$8"
  local whitelist="$9"

  [[ -z "$server_name" ]] && { red "服务器名称不能为空"; return 1; }

  if ! is_positive_number "$threshold"; then
    red "流量阈值 MiB/s 必须是大于 0 的数字"
    return 1
  fi

  if ! is_positive_int "$window"; then
    red "统计窗口秒数必须是正整数"
    return 1
  fi

  if ! is_positive_int "$sample"; then
    red "采样间隔秒数必须是正整数"
    return 1
  fi

  if ! is_positive_int "$sync_every"; then
    red "iptables 同步周期秒数必须是正整数"
    return 1
  fi

  if ! is_non_negative_int "$cooldown"; then
    red "报警冷却时间秒数必须是非负整数"
    return 1
  fi

  if ! is_positive_int "$history_days"; then
    red "历史保留天数必须是正整数"
    return 1
  fi

  if (( window < sample )); then
    red "统计窗口秒数不能小于采样间隔秒数"
    return 1
  fi

  if (( window % sample != 0 )); then
    yellow "提示：统计窗口秒数不能被采样间隔整除，脚本仍可运行，但窗口采样点会向下取整。"
  fi

  if ! validate_port_list "$blacklist"; then
    red "端口黑名单格式错误，只能是逗号分隔的端口号，如 80,443"
    return 1
  fi

  if ! validate_port_list "$whitelist"; then
    red "端口白名单格式错误，只能是逗号分隔的端口号，如 443,8443,50000"
    return 1
  fi

  return 0
}

apply_clear_or_keep() {
  local new_value="$1"
  local old_value="$2"

  if [[ -z "$new_value" ]]; then
    echo "$old_value"
  elif [[ "$new_value" == "clear" ]]; then
    echo ""
  else
    echo "$new_value"
  fi
}

install_deps() {
  green "[1/4] 安装依赖..."
  apt update
  apt install -y python3 python3-pip iptables sqlite3 curl
  pip3 install --break-system-packages requests >/dev/null 2>&1 || pip3 install requests
}

write_python_script() {
  green "[2/4] 写入 Python 主程序..."
  ensure_dirs

  cat > "${PY_SCRIPT}" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import re
import sys
import json
import time
import sqlite3
import subprocess
from collections import deque

try:
    import requests
except Exception:
    requests = None

CONFIG_FILE = "/etc/xmon.conf"
STATE_DIR = "/var/lib/xmon"
STATE_FILE = f"{STATE_DIR}/state.json"
HISTORY_FILE = f"{STATE_DIR}/history.json"
DAILY_FILE = f"{STATE_DIR}/daily_baseline.json"
LOCK_FILE = f"{STATE_DIR}/xmon.lock"

DEFAULTS = {
    "SERVER_NAME": "unnamed-server",
    "DB_PATH": "/etc/x-ui/x-ui.db",
    "CHAIN_NAME": "XUI_MONITOR",
    "SAMPLE_INTERVAL": "5",
    "WINDOW_SECONDS": "30",
    "ALERT_THRESHOLD_MIB": "15",
    "SYNC_IPTABLES_EVERY": "60",
    "TG_BOT_TOKEN": "",
    "TG_CHAT_ID": "",
    "ALERT_COOLDOWN": "300",
    "PORT_BLACKLIST": "",
    "PORT_WHITELIST": "",
    "HISTORY_KEEP_DAYS": "3",
}

def parse_port_list(s):
    result = []
    for x in str(s).split(","):
        x = x.strip()
        if not x:
            continue
        try:
            p = int(x)
            if 1 <= p <= 65535:
                result.append(p)
        except:
            pass
    return result

def load_config():
    cfg = DEFAULTS.copy()
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()

    cfg["SAMPLE_INTERVAL"] = int(cfg["SAMPLE_INTERVAL"])
    cfg["WINDOW_SECONDS"] = int(cfg["WINDOW_SECONDS"])
    cfg["ALERT_THRESHOLD_MIB"] = float(cfg["ALERT_THRESHOLD_MIB"])
    cfg["SYNC_IPTABLES_EVERY"] = int(cfg["SYNC_IPTABLES_EVERY"])
    cfg["ALERT_COOLDOWN"] = int(cfg["ALERT_COOLDOWN"])
    cfg["PORT_BLACKLIST"] = parse_port_list(cfg.get("PORT_BLACKLIST", ""))
    cfg["PORT_WHITELIST"] = parse_port_list(cfg.get("PORT_WHITELIST", ""))
    cfg["HISTORY_KEEP_DAYS"] = int(cfg.get("HISTORY_KEEP_DAYS", "3"))
    return cfg

def run_cmd(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)

def load_json(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return default

def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

def send_tg(token, chat_id, message):
    if not token or not chat_id:
        print("[WARN][TG] TG 未配置，跳过发送")
        return

    if requests is None:
        print("[WARN][TG] requests 模块不可用，无法发送 TG")
        return

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = {"chat_id": chat_id, "text": message}
    try:
        r = requests.post(url, data=data, timeout=10)
        if not r.ok:
            print(f"[WARN][TG] TG发送失败: {r.status_code} {r.text}")
    except Exception as e:
        print(f"[WARN][TG] TG发送异常: {e}")

def mib(bytes_count):
    return bytes_count / 1024 / 1024

def format_bytes(num):
    num = float(num)
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if num < 1024:
            return f"{num:.2f} {unit}"
        num /= 1024
    return f"{num:.2f} PiB"

def file_size_human(path):
    if not os.path.exists(path):
        return "0 B"
    return format_bytes(os.path.getsize(path))

def filter_ports(port, cfg):
    whitelist = cfg["PORT_WHITELIST"]
    blacklist = cfg["PORT_BLACKLIST"]

    if whitelist and port not in whitelist:
        return False

    if blacklist and port in blacklist:
        return False

    return True

def find_inbounds(db_path, cfg):
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"数据库不存在: {db_path}")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("PRAGMA table_info(inbounds)")
    cols = [row[1] for row in cur.fetchall()]

    if "port" not in cols:
        conn.close()
        raise RuntimeError("inbounds 表中未找到 port 字段")

    select_cols = []
    for x in ("id", "remark", "port", "enable"):
        if x in cols:
            select_cols.append(x)

    cur.execute("SELECT " + ", ".join(select_cols) + " FROM inbounds")
    rows = cur.fetchall()

    ports = {}
    for row in rows:
        d = dict(row)
        try:
            port = int(d.get("port"))
        except:
            continue

        if "enable" in d:
            try:
                if int(d.get("enable", 1)) != 1:
                    continue
            except:
                pass

        if not filter_ports(port, cfg):
            continue

        remark = d.get("remark", f"port-{port}")
        if not remark:
            remark = f"port-{port}"

        ports[port] = {"remark": remark}

    conn.close()
    return ports

def find_all_enabled_inbounds(db_path):
    if not os.path.exists(db_path):
        return {}

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("PRAGMA table_info(inbounds)")
    cols = [row[1] for row in cur.fetchall()]
    if "port" not in cols:
        conn.close()
        return {}

    select_cols = []
    for x in ("id", "remark", "port", "enable"):
        if x in cols:
            select_cols.append(x)

    cur.execute("SELECT " + ", ".join(select_cols) + " FROM inbounds")
    rows = cur.fetchall()

    ports = {}
    for row in rows:
        d = dict(row)
        try:
            port = int(d.get("port"))
        except:
            continue

        if "enable" in d:
            try:
                if int(d.get("enable", 1)) != 1:
                    continue
            except:
                pass

        remark = d.get("remark", f"port-{port}")
        if not remark:
            remark = f"port-{port}"

        ports[port] = {"remark": remark}

    conn.close()
    return ports

def ensure_chain(chain_name):
    run_cmd(["iptables", "-N", chain_name])

    if run_cmd(["iptables", "-C", "INPUT", "-j", chain_name]).returncode != 0:
        run_cmd(["iptables", "-I", "INPUT", "-j", chain_name])

    if run_cmd(["iptables", "-C", "OUTPUT", "-j", chain_name]).returncode != 0:
        run_cmd(["iptables", "-I", "OUTPUT", "-j", chain_name])

def ensure_rule(chain_name, proto, direction, port):
    check_cmd = ["iptables", "-C", chain_name, "-p", proto, f"--{direction}", str(port), "-j", "RETURN"]
    add_cmd = ["iptables", "-A", chain_name, "-p", proto, f"--{direction}", str(port), "-j", "RETURN"]
    if run_cmd(check_cmd).returncode != 0:
        r = run_cmd(add_cmd)
        if r.returncode == 0:
            print(f"[INFO][IPTABLES] 已添加规则: {proto} {direction} {port}")
        else:
            print(f"[WARN][IPTABLES] 添加规则失败: {' '.join(add_cmd)} {r.stderr}")

def delete_rule(chain_name, proto, direction, port):
    while True:
        del_cmd = ["iptables", "-D", chain_name, "-p", proto, f"--{direction}", str(port), "-j", "RETURN"]
        r = run_cmd(del_cmd)
        if r.returncode != 0:
            break
        print(f"[INFO][IPTABLES] 已删除规则: {proto} {direction} {port}")

def list_chain_rules(chain_name):
    result = run_cmd(["iptables", "-S", chain_name])
    if result.returncode != 0:
        return []
    return result.stdout.splitlines()

def parse_rules_ports(chain_name):
    data = {}
    for line in list_chain_rules(chain_name):
        m = re.search(r"-p\s+(tcp|udp)\s+.*--(dport|sport)\s+(\d+)\s+-j\s+RETURN", line)
        if not m:
            continue
        proto = m.group(1)
        direction = m.group(2)
        port = int(m.group(3))
        data.setdefault(port, set()).add((proto, direction))
    return data

def sync_iptables_rules(chain_name, ports):
    ensure_chain(chain_name)
    existing = parse_rules_ports(chain_name)
    wanted_ports = set(ports)

    for port in wanted_ports:
        for proto in ("tcp", "udp"):
            for direction in ("dport", "sport"):
                if port not in existing or (proto, direction) not in existing[port]:
                    ensure_rule(chain_name, proto, direction, port)

    for port in list(existing.keys()):
        if port not in wanted_ports:
            for proto, direction in list(existing[port]):
                delete_rule(chain_name, proto, direction, port)

def remove_chain(chain_name):
    run_cmd(["iptables", "-D", "INPUT", "-j", chain_name])
    run_cmd(["iptables", "-D", "OUTPUT", "-j", chain_name])
    run_cmd(["iptables", "-F", chain_name])
    run_cmd(["iptables", "-X", chain_name])

def parse_iptables_bytes(chain_name, monitored_ports):
    result = run_cmd(["iptables", "-L", chain_name, "-v", "-n", "-x"])
    if result.returncode != 0:
        raise RuntimeError(f"读取 iptables 失败: {result.stderr.strip()}")

    port_totals = {port: 0 for port in monitored_ports}
    for raw in result.stdout.splitlines():
        line = raw.strip()
        if not line or "RETURN" not in line:
            continue

        parts = re.split(r"\s+", line)
        if len(parts) < 2:
            continue

        try:
            bytes_count = int(parts[1])
        except:
            continue

        m = re.search(r"(dpt|spt):(\d+)", line)
        if not m:
            continue
        port = int(m.group(2))
        if port in port_totals:
            port_totals[port] += bytes_count

    return port_totals

class PortState:
    def __init__(self, sample_maxlen):
        self.last_total_bytes = None
        self.samples = deque(maxlen=sample_maxlen)
        self.alerted = False
        self.last_alert_time = 0

def update_daily_baseline(current_totals):
    today = time.strftime("%F")
    now_ts = int(time.time())
    daily = load_json(DAILY_FILE, {"date": today, "baseline_ts": now_ts, "ports": {}})

    if daily.get("date") != today:
        daily = {
            "date": today,
            "baseline_ts": now_ts,
            "ports": {str(port): total for port, total in current_totals.items()}
        }
        save_json(DAILY_FILE, daily)
        return daily

    changed = False
    if "baseline_ts" not in daily:
        daily["baseline_ts"] = now_ts
        changed = True

    for port, total in current_totals.items():
        if str(port) not in daily["ports"]:
            daily["ports"][str(port)] = total
            changed = True

    if changed:
        save_json(DAILY_FILE, daily)

    return daily

def cleanup_state_and_history(monitored_ports):
    monitored_set = set(str(p) for p in monitored_ports)

    state = load_json(STATE_FILE, {})
    if state.get("ports"):
        new_ports = {}
        for p, info in state["ports"].items():
            if p in monitored_set:
                new_ports[p] = info
        state["ports"] = new_ports
        save_json(STATE_FILE, state)

    history = load_json(HISTORY_FILE, {})
    changed = False
    for p in list(history.keys()):
        if p not in monitored_set:
            del history[p]
            changed = True
    if changed:
        save_json(HISTORY_FILE, history)

def prune_history_by_time(history, keep_days):
    cutoff = int(time.time() - keep_days * 86400)
    changed = False
    for port in list(history.keys()):
        arr = history.get(port, [])
        new_arr = [x for x in arr if int(x.get("ts", 0)) >= cutoff]
        if len(new_arr) != len(arr):
            history[port] = new_arr
            changed = True
    return history, changed

def acquire_lock():
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE, "r", encoding="utf-8") as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            print(f"[ERROR] 检测到已有 xmon 进程在运行，PID={old_pid}")
            return False
        except:
            pass
    with open(LOCK_FILE, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    return True

def release_lock():
    try:
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)
    except:
        pass

def cmd_monitored_ports():
    cfg = load_config()
    all_ports = find_all_enabled_inbounds(cfg["DB_PATH"])
    monitored = find_inbounds(cfg["DB_PATH"], cfg)

    wl = set(cfg["PORT_WHITELIST"])
    bl = set(cfg["PORT_BLACKLIST"])

    print("=" * 110)
    print(f"服务器: {cfg['SERVER_NAME']}")
    print(f"链名: {cfg['CHAIN_NAME']}")
    print(f"{'端口':<8} {'备注':<24} {'启用':<6} {'黑名单排除':<12} {'白名单命中':<12} {'实际监控'}")
    print("-" * 110)

    shown = set()
    for port, info in sorted(all_ports.items()):
        shown.add(port)
        bl_hit = ("是" if (port in bl) else "否")
        wl_hit = ("是" if (not wl or port in wl) else "否")
        real = "是" if port in monitored else "否"
        print(f"{port:<8} {info.get('remark','')[:24]:<24} {'是':<6} {bl_hit:<12} {wl_hit:<12} {real}")

    for port in sorted(wl):
        if port not in shown:
            bl_hit = "是" if port in bl else "否"
            wl_hit = "是"
            real = "否"
            print(f"{port:<8} {'<数据库不存在>':<24} {'否':<6} {bl_hit:<12} {wl_hit:<12} {real}")

    print("=" * 110)

def cmd_file_sizes():
    print("=" * 80)
    print(f"STATE_FILE   : {STATE_FILE}   {file_size_human(STATE_FILE)}")
    print(f"HISTORY_FILE : {HISTORY_FILE} {file_size_human(HISTORY_FILE)}")
    print(f"DAILY_FILE   : {DAILY_FILE}   {file_size_human(DAILY_FILE)}")
    print("=" * 80)

def cmd_health():
    cfg = load_config()
    ok = True

    print("=" * 100)
    print("xmon 健康检查")
    print("=" * 100)

    print(f"[CFG] SERVER_NAME={cfg['SERVER_NAME']}")
    print(f"[CFG] DB_PATH={cfg['DB_PATH']}")
    print(f"[CFG] CHAIN_NAME={cfg['CHAIN_NAME']}")
    print(f"[CFG] SAMPLE_INTERVAL={cfg['SAMPLE_INTERVAL']}")
    print(f"[CFG] WINDOW_SECONDS={cfg['WINDOW_SECONDS']}")
    print(f"[CFG] ALERT_THRESHOLD_MIB={cfg['ALERT_THRESHOLD_MIB']}")
    print(f"[CFG] HISTORY_KEEP_DAYS={cfg['HISTORY_KEEP_DAYS']}")

    if os.path.exists(cfg["DB_PATH"]):
        print("[OK ] 数据库文件存在")
        try:
            ports = find_inbounds(cfg["DB_PATH"], cfg)
            print(f"[OK ] 可读取监控端口，共 {len(ports)} 个")
        except Exception as e:
            print(f"[ERR] 数据库读取失败: {e}")
            ok = False
    else:
        print("[ERR] 数据库文件不存在")
        ok = False

    ipt = run_cmd(["iptables", "--version"])
    if ipt.returncode == 0:
        print(f"[OK ] iptables 可用: {ipt.stdout.strip() or ipt.stderr.strip()}")
    else:
        print("[ERR] iptables 不可用")
        ok = False

    ch = run_cmd(["iptables", "-L", cfg["CHAIN_NAME"], "-n"])
    if ch.returncode == 0:
        print(f"[OK ] 链存在: {cfg['CHAIN_NAME']}")
    else:
        print(f"[WARN] 链不存在或尚未创建: {cfg['CHAIN_NAME']}")

    if cfg["TG_BOT_TOKEN"] and cfg["TG_CHAT_ID"]:
        print("[OK ] TG 配置已填写")
    else:
        print("[WARN] TG 配置未完整填写")

    if requests is None:
        print("[WARN] requests 模块不可用")
    else:
        print("[OK ] requests 模块可用")

    svc = run_cmd(["systemctl", "is-active", "xmon"])
    if svc.returncode == 0:
        print(f"[OK ] systemd 服务运行中: {svc.stdout.strip()}")
    else:
        print(f"[WARN] systemd 服务未运行: {svc.stdout.strip() or svc.stderr.strip()}")

    p1 = run_cmd(["dpkg", "-s", "iptables-persistent"])
    if p1.returncode == 0:
        print("[OK ] 已安装 iptables-persistent")
    else:
        print("[WARN] 未安装 iptables-persistent，重启后虽然 xmon 会尝试重建规则，但建议按需安装")

    print(f"[INFO] state 文件大小:   {file_size_human(STATE_FILE)}")
    print(f"[INFO] history 文件大小: {file_size_human(HISTORY_FILE)}")
    print(f"[INFO] daily 文件大小:   {file_size_human(DAILY_FILE)}")

    print("=" * 100)
    print("结果:", "正常" if ok else "存在问题")
    print("=" * 100)

def calc_usage_from_history(history, port, seconds):
    port = str(port)
    arr = history.get(port, [])
    if len(arr) < 2:
        return None

    now = int(time.time())
    target = now - seconds
    recent = arr[-1]
    older = None
    for item in arr:
        if item["ts"] >= target:
            older = item
            break
    if older is None:
        older = arr[0]

    delta = recent["total_bytes_snapshot"] - older["total_bytes_snapshot"]
    if delta < 0:
        delta = 0

    return {
        "start_ts": older["ts"],
        "end_ts": recent["ts"],
        "bytes": delta,
        "human": format_bytes(delta),
    }

def cmd_query_usage_single(port, mode):
    state = load_json(STATE_FILE, {})
    history = load_json(HISTORY_FILE, {})
    port = str(port)

    ports = state.get("ports", {})
    if port not in ports:
        print(f"未找到端口 {port}")
        return

    p = ports[port]

    if mode == "today":
        print("=" * 80)
        print(f"端口: {port}")
        print(f"备注: {p.get('remark','')}")
        print(f"今日累计流量: {p.get('today_human','0 B')}")
        print(f"今日基线起始时间: {p.get('today_baseline_human','未知')}")
        print("=" * 80)
        return

    hours_map = {
        "1h": 3600,
        "6h": 21600,
        "12h": 43200,
    }

    if mode not in hours_map:
        print("未知时间范围")
        return

    result = calc_usage_from_history(history, port, hours_map[mode])
    if not result:
        print("该端口历史数据不足")
        return

    print("=" * 80)
    print(f"端口: {port}")
    print(f"备注: {p.get('remark','')}")
    print(f"起始时间: {time.strftime('%F %T', time.localtime(result['start_ts']))}")
    print(f"结束时间: {time.strftime('%F %T', time.localtime(result['end_ts']))}")
    print(f"累计流量: {result['human']}")
    print("=" * 80)

def cmd_query_usage_rank(mode):
    state = load_json(STATE_FILE, {})
    history = load_json(HISTORY_FILE, {})

    ports = state.get("ports", {})
    rows = []

    if mode == "today":
        for port, info in ports.items():
            rows.append((
                port,
                info.get("remark",""),
                int(info.get("today_bytes", 0)),
                info.get("today_human","0 B"),
                info.get("today_baseline_human","未知"),
            ))
        rows.sort(key=lambda x: x[2], reverse=True)

        print("=" * 110)
        print(f"服务器: {state.get('server_name','')}")
        print(f"{'端口':<8} {'备注':<24} {'今日累计':<16} {'基线起始':<20}")
        print("-" * 110)
        for port, remark, raw, human, base in rows[:50]:
            print(f"{port:<8} {remark[:24]:<24} {human:<16} {base:<20}")
        print("=" * 110)
        return

    hours_map = {
        "1h": 3600,
        "6h": 21600,
        "12h": 43200,
    }

    if mode not in hours_map:
        print("未知时间范围")
        return

    seconds = hours_map[mode]

    for port, info in ports.items():
        result = calc_usage_from_history(history, port, seconds)
        if result:
            rows.append((
                port,
                info.get("remark",""),
                result["bytes"],
                result["human"],
                result["start_ts"],
                result["end_ts"],
            ))
        else:
            rows.append((
                port,
                info.get("remark",""),
                0,
                "0 B",
                0,
                0,
            ))

    rows.sort(key=lambda x: x[2], reverse=True)

    print("=" * 130)
    print(f"服务器: {state.get('server_name','')}")
    print(f"{'端口':<8} {'备注':<24} {'累计流量':<16} {'起始时间':<20} {'结束时间':<20}")
    print("-" * 130)
    for port, remark, raw, human, start_ts, end_ts in rows[:50]:
        start_h = time.strftime('%F %T', time.localtime(start_ts)) if start_ts else "数据不足"
        end_h = time.strftime('%F %T', time.localtime(end_ts)) if end_ts else "数据不足"
        print(f"{port:<8} {remark[:24]:<24} {human:<16} {start_h:<20} {end_h:<20}")
    print("=" * 130)

def main_loop():
    os.makedirs(STATE_DIR, exist_ok=True)

    if not acquire_lock():
        sys.exit(1)

    try:
        cfg = load_config()
        sample_maxlen = max(1, cfg["WINDOW_SECONDS"] // cfg["SAMPLE_INTERVAL"])

        states = {}
        ports_info = {}
        last_sync = 0
        old_chain_name = cfg["CHAIN_NAME"]

        print("[INFO] xmon 启动")
        print(f"[INFO] server={cfg['SERVER_NAME']} sample={cfg['SAMPLE_INTERVAL']}s window={cfg['WINDOW_SECONDS']}s threshold={cfg['ALERT_THRESHOLD_MIB']} MiB/s keep_days={cfg['HISTORY_KEEP_DAYS']} chain={cfg['CHAIN_NAME']}")

        while True:
            try:
                now = time.time()
                cfg = load_config()
                sample_maxlen = max(1, cfg["WINDOW_SECONDS"] // cfg["SAMPLE_INTERVAL"])

                if old_chain_name != cfg["CHAIN_NAME"]:
                    print(f"[INFO][IPTABLES] 检测到链名变更: {old_chain_name} -> {cfg['CHAIN_NAME']}")
                    remove_chain(old_chain_name)
                    old_chain_name = cfg["CHAIN_NAME"]

                if now - last_sync >= cfg["SYNC_IPTABLES_EVERY"] or not ports_info:
                    ports_info = find_inbounds(cfg["DB_PATH"], cfg)
                    sync_iptables_rules(cfg["CHAIN_NAME"], ports_info.keys())

                    for port in list(states.keys()):
                        if port not in ports_info:
                            del states[port]

                    for port in ports_info:
                        if port not in states:
                            states[port] = PortState(sample_maxlen)
                        else:
                            states[port].samples = deque(states[port].samples, maxlen=sample_maxlen)

                    cleanup_state_and_history(ports_info.keys())

                    last_sync = now
                    print(f"[INFO] 当前监控端口: {sorted(ports_info.keys())}")

                if not ports_info:
                    state_out = {
                        "updated_at": int(now),
                        "server_name": cfg["SERVER_NAME"],
                        "ports": {},
                        "config": cfg
                    }
                    save_json(STATE_FILE, state_out)
                    time.sleep(cfg["SAMPLE_INTERVAL"])
                    continue

                current_totals = parse_iptables_bytes(cfg["CHAIN_NAME"], ports_info.keys())
                daily = update_daily_baseline(current_totals)
                baseline_ts = int(daily.get("baseline_ts", int(now)))

                state_ports = {}
                history = load_json(HISTORY_FILE, {})

                for port, info in ports_info.items():
                    st = states[port]
                    curr = current_totals.get(port, 0)

                    curr_mib_s = 0.0
                    avg_mib_s = 0.0

                    base = daily.get("ports", {}).get(str(port), curr)
                    today_bytes = curr - base
                    if today_bytes < 0:
                        today_bytes = 0

                    if st.last_total_bytes is not None:
                        delta = curr - st.last_total_bytes
                        if delta < 0:
                            delta = 0

                        curr_bps = delta / cfg["SAMPLE_INTERVAL"]
                        curr_mib_s = mib(curr_bps)

                        st.samples.append(curr_bps)
                        if len(st.samples) > 0:
                            avg_bps = sum(st.samples) / len(st.samples)
                            avg_mib_s = mib(avg_bps)

                        print(f"[INFO] 端口 {port:<5} remark={info['remark']:<20} 当前={curr_mib_s:>6.2f} MiB/s 近窗均值={avg_mib_s:>6.2f} MiB/s 今日={format_bytes(today_bytes)}")

                        if len(st.samples) == st.samples.maxlen:
                            if avg_mib_s >= cfg["ALERT_THRESHOLD_MIB"]:
                                if (not st.alerted) and (now - st.last_alert_time >= cfg["ALERT_COOLDOWN"]):
                                    msg = (
                                        f"⚠️ [{cfg['SERVER_NAME']}] 3x-ui 端口流量过高报警\n"
                                        f"端口: {port}\n"
                                        f"备注: {info['remark']}\n"
                                        f"当前速度: {curr_mib_s:.2f} MiB/s\n"
                                        f"{cfg['WINDOW_SECONDS']}秒平均: {avg_mib_s:.2f} MiB/s\n"
                                        f"今日累计流量: {format_bytes(today_bytes)}\n"
                                        f"今日基线起始: {time.strftime('%F %T', time.localtime(baseline_ts))}\n"
                                        f"阈值: {cfg['ALERT_THRESHOLD_MIB']:.2f} MiB/s"
                                    )
                                    send_tg(cfg["TG_BOT_TOKEN"], cfg["TG_CHAT_ID"], msg)
                                    st.alerted = True
                                    st.last_alert_time = now
                            else:
                                st.alerted = False

                    st.last_total_bytes = curr

                    state_ports[str(port)] = {
                        "remark": info["remark"],
                        "current_mib_s": round(curr_mib_s, 4),
                        "avg_mib_s": round(avg_mib_s, 4),
                        "total_bytes_snapshot": curr,
                        "today_bytes": today_bytes,
                        "today_human": format_bytes(today_bytes),
                        "today_baseline_ts": baseline_ts,
                        "today_baseline_human": time.strftime('%F %T', time.localtime(baseline_ts)),
                        "alerted": st.alerted,
                        "last_alert_time": int(st.last_alert_time),
                        "samples_count": len(st.samples),
                        "window_seconds": cfg["WINDOW_SECONDS"],
                    }

                    history.setdefault(str(port), [])
                    history[str(port)].append({
                        "ts": int(now),
                        "current_mib_s": round(curr_mib_s, 4),
                        "avg_mib_s": round(avg_mib_s, 4),
                        "total_bytes_snapshot": curr
                    })

                history, changed = prune_history_by_time(history, cfg["HISTORY_KEEP_DAYS"])

                monitored_str = set(str(p) for p in ports_info.keys())
                for p in list(history.keys()):
                    if p not in monitored_str:
                        del history[p]
                        changed = True

                state_out = {
                    "updated_at": int(now),
                    "server_name": cfg["SERVER_NAME"],
                    "ports": state_ports,
                    "config": {
                        "SERVER_NAME": cfg["SERVER_NAME"],
                        "DB_PATH": cfg["DB_PATH"],
                        "CHAIN_NAME": cfg["CHAIN_NAME"],
                        "SAMPLE_INTERVAL": cfg["SAMPLE_INTERVAL"],
                        "WINDOW_SECONDS": cfg["WINDOW_SECONDS"],
                        "ALERT_THRESHOLD_MIB": cfg["ALERT_THRESHOLD_MIB"],
                        "SYNC_IPTABLES_EVERY": cfg["SYNC_IPTABLES_EVERY"],
                        "ALERT_COOLDOWN": cfg["ALERT_COOLDOWN"],
                        "PORT_BLACKLIST": cfg["PORT_BLACKLIST"],
                        "PORT_WHITELIST": cfg["PORT_WHITELIST"],
                        "HISTORY_KEEP_DAYS": cfg["HISTORY_KEEP_DAYS"],
                    }
                }

                save_json(STATE_FILE, state_out)
                save_json(HISTORY_FILE, history)

            except Exception as e:
                print(f"[ERROR] 主循环异常: {e}")

            time.sleep(load_config()["SAMPLE_INTERVAL"])
    finally:
        release_lock()

def cmd_query_port(port):
    state = load_json(STATE_FILE, {})
    history = load_json(HISTORY_FILE, {})
    port = str(port)

    ports = state.get("ports", {})
    if port not in ports:
        print(f"未找到端口 {port} 的最近状态")
        return

    p = ports[port]
    print("=" * 70)
    print(f"服务器: {state.get('server_name','')}")
    print(f"端口: {port}")
    print(f"备注: {p.get('remark','')}")
    print(f"当前速率: {p.get('current_mib_s',0)} MiB/s")
    print(f"最近窗口平均速率: {p.get('avg_mib_s',0)} MiB/s")
    print(f"最近累计字节快照: {p.get('total_bytes_snapshot',0)} bytes")
    print(f"今日累计流量: {p.get('today_human','0 B')}")
    print(f"今日基线起始时间: {p.get('today_baseline_human','未知')}")
    print(f"是否处于报警状态: {p.get('alerted',False)}")
    print(f"采样窗口: {p.get('window_seconds',0)} 秒")
    print(f"状态更新时间: {time.strftime('%F %T', time.localtime(state.get('updated_at',0)))}")
    print("=" * 70)

    arr = history.get(port, [])
    if arr:
        print("最近10条采样记录：")
        for item in arr[-10:]:
            ts = time.strftime('%F %T', time.localtime(item['ts']))
            print(f"{ts} | 当前={item['current_mib_s']} MiB/s | 均值={item['avg_mib_s']} MiB/s | snapshot={item['total_bytes_snapshot']}")
    else:
        print("该端口暂无历史记录")

def main():
    if len(sys.argv) == 1 or sys.argv[1] == "run":
        main_loop()
        return

    cmd = sys.argv[1]

    if cmd == "health":
        cmd_health()
    elif cmd == "monitored-ports":
        cmd_monitored_ports()
    elif cmd == "file-sizes":
        cmd_file_sizes()
    elif cmd == "query-port" and len(sys.argv) >= 3:
        cmd_query_port(sys.argv[2])
    elif cmd == "usage-single" and len(sys.argv) >= 4:
        cmd_query_usage_single(sys.argv[2], sys.argv[3])
    elif cmd == "usage-rank" and len(sys.argv) >= 3:
        cmd_query_usage_rank(sys.argv[2])
    else:
        print("未知命令")
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF

  chmod 755 "${PY_SCRIPT}"
}

write_service() {
  green "[3/4] 生成 systemd 服务..."
  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=xmon 3x-ui traffic monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${PY_SCRIPT} run
Restart=always
RestartSec=5
WorkingDirectory=${STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_config_interactive() {
  local default_server_name
  default_server_name="$(hostname)"

  while true; do
    read -rp "请输入服务器名称/备注（用于TG区分机器） [默认${default_server_name}]: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$default_server_name}

    read -rp "请输入 TG Bot Token（可留空）: " TG_BOT_TOKEN
    read -rp "请输入 TG Chat ID（可留空）: " TG_CHAT_ID

    ALERT_THRESHOLD_MIB=$(read_with_default "请输入流量阈值 MiB/s" "15")
    WINDOW_SECONDS=$(read_with_default "请输入统计窗口秒数" "30")
    SAMPLE_INTERVAL=$(read_with_default "请输入采样间隔秒数" "5")
    SYNC_IPTABLES_EVERY=$(read_with_default "请输入 iptables 同步周期秒数" "60")
    ALERT_COOLDOWN=$(read_with_default "请输入报警冷却时间秒数" "300")
    HISTORY_KEEP_DAYS=$(read_with_default "请输入历史保留天数" "3")

    echo
    cyan "端口黑名单说明：填写后，这些端口将被排除，不参与监控。"
    cyan "适合场景：你只想把自己的某些端口排除掉，例如 50000,50001"
    read -rp "请输入端口黑名单，逗号分隔（留空表示不过滤）: " PORT_BLACKLIST

    echo
    cyan "端口白名单说明：填写后，只监控这些端口，其他端口全部不监控。"
    cyan "适合场景：你只想监控少数几个指定端口，例如 443,8443"
    read -rp "请输入端口白名单，逗号分隔（留空表示监控全部启用端口）: " PORT_WHITELIST

    read -rp "请输入 iptables 链名 [默认XUI_MONITOR]: " CHAIN_NAME
    CHAIN_NAME=${CHAIN_NAME:-XUI_MONITOR}

    if [[ ! "$CHAIN_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
      red "链名只能包含字母、数字、下划线和中划线"
      continue
    fi

    if validate_config_values \
      "$SERVER_NAME" "$ALERT_THRESHOLD_MIB" "$WINDOW_SECONDS" "$SAMPLE_INTERVAL" \
      "$SYNC_IPTABLES_EVERY" "$ALERT_COOLDOWN" "$HISTORY_KEEP_DAYS" \
      "$PORT_BLACKLIST" "$PORT_WHITELIST"; then
      break
    fi

    yellow "输入有误，请重新填写。"
    echo
  done

  cat > "${CONF_FILE}" << EOF
SERVER_NAME=${SERVER_NAME}
DB_PATH=/etc/x-ui/x-ui.db
CHAIN_NAME=${CHAIN_NAME}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL}
WINDOW_SECONDS=${WINDOW_SECONDS}
ALERT_THRESHOLD_MIB=${ALERT_THRESHOLD_MIB}
SYNC_IPTABLES_EVERY=${SYNC_IPTABLES_EVERY}
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
ALERT_COOLDOWN=${ALERT_COOLDOWN}
PORT_BLACKLIST=${PORT_BLACKLIST}
PORT_WHITELIST=${PORT_WHITELIST}
HISTORY_KEEP_DAYS=${HISTORY_KEEP_DAYS}
EOF
  chmod 600 "${CONF_FILE}"
}

read_with_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -rp "${prompt} [默认${default}]: " value
  echo "${value:-$default}"
}

install_or_update_keep_config() {
  install_deps
  write_python_script
  write_service
  chmod 700 "${STATE_DIR}"

  if [[ ! -f "${CONF_FILE}" ]]; then
    yellow "未检测到配置文件，进入首次配置..."
    write_config_interactive
  else
    green "检测到现有配置文件，已保留原配置不变。"
  fi

  systemctl enable --now xmon
  systemctl restart xmon
  systemctl status xmon --no-pager || true
  green "安装/更新完成。"
}

rebuild_config() {
  green "将重新初始化配置..."
  write_config_interactive
  systemctl restart xmon >/dev/null 2>&1 || true
  green "配置已重建。"
}

start_service() {
  systemctl enable --now xmon
}

stop_service() {
  systemctl stop xmon
}

restart_service() {
  systemctl restart xmon
}

show_service_status() {
  systemctl status xmon --no-pager || true
}

show_logs() {
  journalctl -u xmon -f
}

query_port_recent() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    red "状态文件不存在，服务可能还未运行。"
    return
  fi
  read -rp "请输入要查询的端口: " QPORT
  [[ -z "${QPORT}" ]] && { red "端口不能为空"; return; }
  /usr/bin/python3 "${PY_SCRIPT}" query-port "${QPORT}"
}

query_usage_menu() {
  echo
  cyan "请选择查询对象："
  echo "1. 单个端口"
  echo "2. 全部端口排行"
  read -rp "请选择: " target_choice

  echo
  cyan "请选择时间范围："
  echo "1. 最近1小时"
  echo "2. 最近6小时"
  echo "3. 最近12小时"
  echo "4. 今日截至目前"
  read -rp "请选择: " time_choice

  local mode=""
  case "$time_choice" in
    1) mode="1h" ;;
    2) mode="6h" ;;
    3) mode="12h" ;;
    4) mode="today" ;;
    *) red "无效选择"; return ;;
  esac

  case "$target_choice" in
    1)
      read -rp "请输入端口: " QPORT
      [[ -z "${QPORT}" ]] && { red "端口不能为空"; return; }
      /usr/bin/python3 "${PY_SCRIPT}" usage-single "${QPORT}" "${mode}"
      ;;
    2)
      /usr/bin/python3 "${PY_SCRIPT}" usage-rank "${mode}"
      ;;
    *)
      red "无效选择"
      ;;
  esac
}

show_top_ports() {
  /usr/bin/python3 "${PY_SCRIPT}" usage-rank today >/dev/null 2>&1 || true
  /usr/bin/python3 - << PYEOF
import json
state_file = "${STATE_FILE}"
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
except:
    print("状态文件不存在或读取失败")
    raise SystemExit

ports = state.get("ports", {})
items = []
for port, info in ports.items():
    items.append((port, info.get("remark",""), info.get("current_mib_s",0), info.get("avg_mib_s",0), info.get("today_human","0 B"), info.get("alerted",False)))

items.sort(key=lambda x: x[2], reverse=True)

print("=" * 100)
print(f"服务器: {state.get('server_name','')}")
print(f"{'端口':<8} {'备注':<24} {'当前MiB/s':<12} {'窗口均值':<12} {'今日累计':<14} {'报警中'}")
print("-" * 100)
for item in items[:20]:
    port, remark, curr, avg, today, alerted = item
    print(f"{port:<8} {remark[:24]:<24} {curr:<12.4f} {avg:<12.4f} {today:<14} {str(alerted)}")
print("=" * 100)
PYEOF
}

show_monitored_ports() {
  /usr/bin/python3 "${PY_SCRIPT}" monitored-ports || true
}

show_current_config() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    red "配置文件不存在。"
    return
  fi
  cyan "当前配置："
  cat "${CONF_FILE}"
}

modify_config() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    red "配置文件不存在，请先初始化配置。"
    return
  fi

  local SERVER_NAME TG_BOT_TOKEN TG_CHAT_ID ALERT_THRESHOLD_MIB WINDOW_SECONDS SAMPLE_INTERVAL SYNC_IPTABLES_EVERY ALERT_COOLDOWN HISTORY_KEEP_DAYS PORT_BLACKLIST PORT_WHITELIST CHAIN_NAME
  SERVER_NAME="$(grep '^SERVER_NAME=' "${CONF_FILE}" | cut -d'=' -f2-)"
  TG_BOT_TOKEN="$(grep '^TG_BOT_TOKEN=' "${CONF_FILE}" | cut -d'=' -f2-)"
  TG_CHAT_ID="$(grep '^TG_CHAT_ID=' "${CONF_FILE}" | cut -d'=' -f2-)"
  ALERT_THRESHOLD_MIB="$(grep '^ALERT_THRESHOLD_MIB=' "${CONF_FILE}" | cut -d'=' -f2-)"
  WINDOW_SECONDS="$(grep '^WINDOW_SECONDS=' "${CONF_FILE}" | cut -d'=' -f2-)"
  SAMPLE_INTERVAL="$(grep '^SAMPLE_INTERVAL=' "${CONF_FILE}" | cut -d'=' -f2-)"
  SYNC_IPTABLES_EVERY="$(grep '^SYNC_IPTABLES_EVERY=' "${CONF_FILE}" | cut -d'=' -f2-)"
  ALERT_COOLDOWN="$(grep '^ALERT_COOLDOWN=' "${CONF_FILE}" | cut -d'=' -f2-)"
  HISTORY_KEEP_DAYS="$(grep '^HISTORY_KEEP_DAYS=' "${CONF_FILE}" | cut -d'=' -f2-)"
  PORT_BLACKLIST="$(grep '^PORT_BLACKLIST=' "${CONF_FILE}" | cut -d'=' -f2-)"
  PORT_WHITELIST="$(grep '^PORT_WHITELIST=' "${CONF_FILE}" | cut -d'=' -f2-)"
  CHAIN_NAME="$(grep '^CHAIN_NAME=' "${CONF_FILE}" | cut -d'=' -f2-)"

  local OLD_CHAIN_NAME="${CHAIN_NAME}"

  echo
  cyan "直接回车 = 保留当前值"
  cyan "输入 clear = 清空该项（适用于 TG / 黑名单 / 白名单）"

  while true; do
    read -rp "服务器名称/备注 [当前: ${SERVER_NAME}]: " NEW_SERVER_NAME
    read -rp "TG Bot Token [当前: ${TG_BOT_TOKEN}]（回车保留，输入 clear 清空）: " NEW_TG_BOT_TOKEN
    read -rp "TG Chat ID [当前: ${TG_CHAT_ID}]（回车保留，输入 clear 清空）: " NEW_TG_CHAT_ID
    read -rp "流量阈值 MiB/s [当前: ${ALERT_THRESHOLD_MIB}]: " NEW_ALERT_THRESHOLD_MIB
    read -rp "统计窗口秒数 [当前: ${WINDOW_SECONDS}]: " NEW_WINDOW_SECONDS
    read -rp "采样间隔秒数 [当前: ${SAMPLE_INTERVAL}]: " NEW_SAMPLE_INTERVAL
    read -rp "iptables 同步周期秒数 [当前: ${SYNC_IPTABLES_EVERY}]: " NEW_SYNC_IPTABLES_EVERY
    read -rp "报警冷却时间秒数 [当前: ${ALERT_COOLDOWN}]: " NEW_ALERT_COOLDOWN
    read -rp "历史保留天数 [当前: ${HISTORY_KEEP_DAYS}]: " NEW_HISTORY_KEEP_DAYS

    echo
    cyan "端口黑名单说明：这些端口将被排除，不参与监控。"
    read -rp "端口黑名单 [当前: ${PORT_BLACKLIST}]（回车保留，输入 clear 清空）: " NEW_PORT_BLACKLIST

    echo
    cyan "端口白名单说明：只监控这些端口；若为空则默认监控全部启用端口。"
    read -rp "端口白名单 [当前: ${PORT_WHITELIST}]（回车保留，输入 clear 清空）: " NEW_PORT_WHITELIST

    read -rp "iptables 链名 [当前: ${CHAIN_NAME}]: " NEW_CHAIN_NAME

    TMP_SERVER_NAME="$(apply_clear_or_keep "$NEW_SERVER_NAME" "$SERVER_NAME")"
    TMP_TG_BOT_TOKEN="$(apply_clear_or_keep "$NEW_TG_BOT_TOKEN" "$TG_BOT_TOKEN")"
    TMP_TG_CHAT_ID="$(apply_clear_or_keep "$NEW_TG_CHAT_ID" "$TG_CHAT_ID")"
    TMP_ALERT_THRESHOLD_MIB="$(apply_clear_or_keep "$NEW_ALERT_THRESHOLD_MIB" "$ALERT_THRESHOLD_MIB")"
    TMP_WINDOW_SECONDS="$(apply_clear_or_keep "$NEW_WINDOW_SECONDS" "$WINDOW_SECONDS")"
    TMP_SAMPLE_INTERVAL="$(apply_clear_or_keep "$NEW_SAMPLE_INTERVAL" "$SAMPLE_INTERVAL")"
    TMP_SYNC_IPTABLES_EVERY="$(apply_clear_or_keep "$NEW_SYNC_IPTABLES_EVERY" "$SYNC_IPTABLES_EVERY")"
    TMP_ALERT_COOLDOWN="$(apply_clear_or_keep "$NEW_ALERT_COOLDOWN" "$ALERT_COOLDOWN")"
    TMP_HISTORY_KEEP_DAYS="$(apply_clear_or_keep "$NEW_HISTORY_KEEP_DAYS" "$HISTORY_KEEP_DAYS")"
    TMP_PORT_BLACKLIST="$(apply_clear_or_keep "$NEW_PORT_BLACKLIST" "$PORT_BLACKLIST")"
    TMP_PORT_WHITELIST="$(apply_clear_or_keep "$NEW_PORT_WHITELIST" "$PORT_WHITELIST")"
    TMP_CHAIN_NAME="$(apply_clear_or_keep "$NEW_CHAIN_NAME" "$CHAIN_NAME")"

    [[ -z "$TMP_SERVER_NAME" ]] && TMP_SERVER_NAME="$SERVER_NAME"
    [[ -z "$TMP_CHAIN_NAME" ]] && TMP_CHAIN_NAME="$CHAIN_NAME"

    if [[ ! "$TMP_CHAIN_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
      red "链名只能包含字母、数字、下划线和中划线"
      continue
    fi

    if validate_config_values \
      "$TMP_SERVER_NAME" "$TMP_ALERT_THRESHOLD_MIB" "$TMP_WINDOW_SECONDS" "$TMP_SAMPLE_INTERVAL" \
      "$TMP_SYNC_IPTABLES_EVERY" "$TMP_ALERT_COOLDOWN" "$TMP_HISTORY_KEEP_DAYS" \
      "$TMP_PORT_BLACKLIST" "$TMP_PORT_WHITELIST"; then

      SERVER_NAME=$TMP_SERVER_NAME
      TG_BOT_TOKEN=$TMP_TG_BOT_TOKEN
      TG_CHAT_ID=$TMP_TG_CHAT_ID
      ALERT_THRESHOLD_MIB=$TMP_ALERT_THRESHOLD_MIB
      WINDOW_SECONDS=$TMP_WINDOW_SECONDS
      SAMPLE_INTERVAL=$TMP_SAMPLE_INTERVAL
      SYNC_IPTABLES_EVERY=$TMP_SYNC_IPTABLES_EVERY
      ALERT_COOLDOWN=$TMP_ALERT_COOLDOWN
      HISTORY_KEEP_DAYS=$TMP_HISTORY_KEEP_DAYS
      PORT_BLACKLIST=$TMP_PORT_BLACKLIST
      PORT_WHITELIST=$TMP_PORT_WHITELIST
      CHAIN_NAME=$TMP_CHAIN_NAME
      break
    fi

    yellow "输入有误，请重新填写。"
  done

  cat > "${CONF_FILE}" << EOF
SERVER_NAME=${SERVER_NAME}
DB_PATH=/etc/x-ui/x-ui.db
CHAIN_NAME=${CHAIN_NAME}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL}
WINDOW_SECONDS=${WINDOW_SECONDS}
ALERT_THRESHOLD_MIB=${ALERT_THRESHOLD_MIB}
SYNC_IPTABLES_EVERY=${SYNC_IPTABLES_EVERY}
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
ALERT_COOLDOWN=${ALERT_COOLDOWN}
PORT_BLACKLIST=${PORT_BLACKLIST}
PORT_WHITELIST=${PORT_WHITELIST}
HISTORY_KEEP_DAYS=${HISTORY_KEEP_DAYS}
EOF
  chmod 600 "${CONF_FILE}"

  systemctl restart xmon
  green "配置已更新并重启服务。"

  if [[ "${OLD_CHAIN_NAME}" != "${CHAIN_NAME}" ]]; then
    yellow "检测到链名已修改：${OLD_CHAIN_NAME} -> ${CHAIN_NAME}"
    yellow "程序运行后会自动清理旧链。"
  fi
}

test_tg_alert() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    red "配置文件不存在，请先初始化配置。"
    return
  fi

  local TG_BOT_TOKEN TG_CHAT_ID SERVER_NAME
  TG_BOT_TOKEN="$(grep '^TG_BOT_TOKEN=' "${CONF_FILE}" | cut -d'=' -f2-)"
  TG_CHAT_ID="$(grep '^TG_CHAT_ID=' "${CONF_FILE}" | cut -d'=' -f2-)"
  SERVER_NAME="$(grep '^SERVER_NAME=' "${CONF_FILE}" | cut -d'=' -f2-)"

  if [[ -z "${TG_BOT_TOKEN}" || -z "${TG_CHAT_ID}" ]]; then
    red "TG_BOT_TOKEN 或 TG_CHAT_ID 未配置"
    return
  fi

  local msg="🧪 [${SERVER_NAME}] xmon 测试消息
如果你收到了这条消息，说明 TG 报警配置正常。"

  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${msg}" >/dev/null && \
    green "测试消息已发送，请检查 Telegram" || red "发送失败，请检查 TG 配置"
}

health_check() {
  /usr/bin/python3 "${PY_SCRIPT}" health
}

show_file_sizes() {
  /usr/bin/python3 "${PY_SCRIPT}" file-sizes
}

list_inbounds() {
  if [[ ! -f /etc/x-ui/x-ui.db ]]; then
    red "未找到数据库 /etc/x-ui/x-ui.db"
    return
  fi

  echo
  cyan "当前 3x-ui 入站端口："
  sqlite3 /etc/x-ui/x-ui.db "SELECT id, remark, port, enable FROM inbounds;" 2>/dev/null || \
  sqlite3 /etc/x-ui/x-ui.db "SELECT * FROM inbounds LIMIT 20;" 2>/dev/null || true
  echo
}

manual_sync_rules() {
  if [[ ! -f "${SERVICE_FILE}" ]]; then
    red "服务未安装，请先安装。"
    return
  fi
  restart_service
  green "已通过重启服务触发规则同步。"
}

remove_iptables_chain() {
  local chain_name="XUI_MONITOR"
  if [[ -f "${CONF_FILE}" ]]; then
    local conf_chain
    conf_chain="$(grep '^CHAIN_NAME=' "${CONF_FILE}" | head -n1 | cut -d'=' -f2-)"
    if [[ -n "${conf_chain}" ]]; then
      chain_name="${conf_chain}"
    fi
  fi

  if iptables -L "${chain_name}" -n >/dev/null 2>&1; then
    iptables -D INPUT -j "${chain_name}" >/dev/null 2>&1 || true
    iptables -D OUTPUT -j "${chain_name}" >/dev/null 2>&1 || true
    iptables -F "${chain_name}" >/dev/null 2>&1 || true
    iptables -X "${chain_name}" >/dev/null 2>&1 || true
    green "已删除 iptables 链 ${chain_name}"
  else
    yellow "iptables 链 ${chain_name} 不存在，跳过"
  fi
}

uninstall_all() {
  yellow "即将卸载 xmon"
  read -rp "是否停止并删除 systemd 服务？(y/n) [默认y]: " A1
  A1=${A1:-y}
  read -rp "是否删除程序与配置文件？(y/n) [默认y]: " A2
  A2=${A2:-y}
  read -rp "是否删除状态/历史数据？(y/n) [默认y]: " A3
  A3=${A3:-y}
  read -rp "是否删除 iptables 统计链（按当前配置CHAIN_NAME）？(y/n) [默认n]: " A4
  A4=${A4:-n}

  if [[ "${A1}" =~ ^[Yy]$ ]]; then
    systemctl stop xmon >/dev/null 2>&1 || true
    systemctl disable xmon >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    green "已删除 systemd 服务"
  fi

  if [[ "${A2}" =~ ^[Yy]$ ]]; then
    rm -f "${PY_SCRIPT}" "${CONF_FILE}"
    green "已删除程序与配置文件"
  fi

  if [[ "${A3}" =~ ^[Yy]$ ]]; then
    rm -f "${STATE_FILE}" "${HISTORY_FILE}" "${DAILY_FILE}" "${STATE_DIR}/xmon.lock"
    rmdir "${STATE_DIR}" >/dev/null 2>&1 || true
    green "已删除状态与历史数据"
  fi

  if [[ "${A4}" =~ ^[Yy]$ ]]; then
    remove_iptables_chain
  fi

  green "卸载完成"
}

menu() {
  while true; do
    echo
    cyan "================ ${APP_NAME} 管理菜单 ================"
    echo "1.  安装/更新监控（保留现有配置）"
    echo "2.  初始化/重建配置"
    echo "3.  启动服务"
    echo "4.  停止服务"
    echo "5.  重启服务"
    echo "6.  查看服务状态"
    echo "7.  查看实时日志"
    echo
    echo "8.  查询特定端口最近情况"
    echo "9.  查询流量"
    echo "10. 当前速率排行"
    echo "11. 实际监控端口列表"
    echo
    echo "12. 查看当前配置"
    echo "13. 修改配置"
    echo "14. 测试 TG 报警"
    echo "15. 配置健康检查"
    echo "16. 查看数据文件大小"
    echo "17. 列出 3x-ui 入站端口"
    echo "18. 手动同步 iptables 规则"
    echo
    echo "19. 卸载监控"
    echo "0.  退出"
    echo "======================================================"
    read -rp "请选择操作: " choice

    case "$choice" in
      1) install_or_update_keep_config ;;
      2) rebuild_config ;;
      3) start_service ;;
      4) stop_service ;;
      5) restart_service ;;
      6) show_service_status ;;
      7) show_logs ;;
      8) query_port_recent ;;
      9) query_usage_menu ;;
      10) show_top_ports ;;
      11) show_monitored_ports ;;
      12) show_current_config ;;
      13) modify_config ;;
      14) test_tg_alert ;;
      15) health_check ;;
      16) show_file_sizes ;;
      17) list_inbounds ;;
      18) manual_sync_rules ;;
      19) uninstall_all ;;
      0) exit 0 ;;
      *) yellow "无效选择，请重新输入" ;;
    esac
  done
}

check_root
ensure_dirs
menu
