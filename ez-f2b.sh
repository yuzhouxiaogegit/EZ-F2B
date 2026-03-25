#!/bin/bash

# =============================================================
# Fail2ban 全参数交互式安装与配置脚本 (极致兼容版)
# =============================================================

NC='\033[0m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须使用 root 用户运行此脚本！${NC}"
    exit 1
fi

clear
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}${BOLD}       Fail2ban 全参数交互式高级配置脚本       ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# -------------------------------------------------------------
# 1. 交互式参数收集
# -------------------------------------------------------------
echo -e "${YELLOW}--- 基础防御参数 ---${NC}"
read -p "1. 白名单 IP (多个用空格隔开。直接回车默认: 127.0.0.1/8 ::1): " INPUT_IGNOREIP
IGNOREIP=${INPUT_IGNOREIP:-"127.0.0.1/8 ::1"}

read -p "2. 封禁时长 (如 10m, 1h, 1d。直接回车默认: 1h): " INPUT_BANTIME
BANTIME=${INPUT_BANTIME:-"1h"}

read -p "3. 统计时间窗口 (直接回车默认: 10m): " INPUT_FINDTIME
FINDTIME=${INPUT_FINDTIME:-"10m"}

read -p "4. 最大密码错误次数 (直接回车默认: 5): " INPUT_MAXRETRY
MAXRETRY=${INPUT_MAXRETRY:-"5"}

echo -e "\n${YELLOW}--- 高级控制参数 ---${NC}"
echo "5. 防火墙动作:"
echo "   [1] iptables-multiport (默认，通用且兼容性最好)"
echo "   [2] ufw (Ubuntu/Debian 常用)"
echo "   [3] firewalld (CentOS/RHEL 常用)"
read -p "请输入序号 [1-3] (直接回车默认 1): " INPUT_BANACTION
case "$INPUT_BANACTION" in
    2) BANACTION="ufw" ;;
    3) BANACTION="firewalld" ;;
    *) BANACTION="iptables-multiport" ;;
esac

# fix: 只有 iptables 系列才有 -allports 变体
case "$BANACTION" in
    iptables-multiport) BANACTION_ALLPORTS="iptables-allports" ;;
    *)                  BANACTION_ALLPORTS="$BANACTION" ;;
esac

echo "6. 触发封禁后的附带动作:"
echo "   [1] action_    : 仅静默封禁 IP (默认)"
echo "   [2] action_mw  : 封禁 IP 并发送邮件通知"
echo "   [3] action_mwl : 封禁 IP、发邮件，并附带相关日志"
read -p "请输入序号 [1-3] (直接回车默认 1): " INPUT_ACTION
case "$INPUT_ACTION" in
    2) ACTION="action_mw" ;;
    3) ACTION="action_mwl" ;;
    *) ACTION="action_" ;;
esac

DESTEMAIL="root@localhost"
# fix: 使用 hostname -f 获取 FQDN，避免短主机名导致非法邮件地址
FQDN=$(hostname -f 2>/dev/null || hostname)
SENDER="fail2ban@${FQDN}"
if [[ "$ACTION" != "action_" ]]; then
    read -p "   -> 请输入接收报警的邮箱地址: " INPUT_EMAIL
    DESTEMAIL=${INPUT_EMAIL:-"root@localhost"}
fi

echo "7. 日志监控引擎 (backend):"
echo "   [1] auto    : 自动选择 (默认，推荐)"
echo "   [2] systemd : 读取 systemd journal"
echo "   [3] polling : 传统轮询读取文件"
read -p "请输入序号 [1-3] (直接回车默认 1): " INPUT_BACKEND
case "$INPUT_BACKEND" in
    2) BACKEND="systemd" ;;
    3) BACKEND="polling" ;;
    *) BACKEND="auto" ;;
esac

echo -e "\n${GREEN}[*] 参数收集完毕，正在执行安装与配置...${NC}\n"
sleep 1

# -------------------------------------------------------------
# 2. 极致兼容的包管理器检测与安装
# -------------------------------------------------------------
check_cmd() { command -v "$1" &>/dev/null; }

get_pkg_manager() {
    if check_cmd apt-get;  then echo "apt"
    elif check_cmd dnf;    then echo "dnf"
    elif check_cmd yum;    then echo "yum"
    elif check_cmd zypper; then echo "zypper"
    elif check_cmd pacman; then echo "pacman"
    elif check_cmd apk;    then echo "apk"
    else echo "unknown"
    fi
}

PKG_MGR=$(get_pkg_manager)

# fix: 用数组管理包列表，避免空变量展开问题
PKGS=(fail2ban)
if [[ "$ACTION" == "action_mwl" ]]; then
    PKGS+=(whois)
fi
# fix: 邮件动作需要 MTA，检测并补充安装
if [[ "$ACTION" != "action_" ]]; then
    if ! check_cmd sendmail && ! check_cmd msmtp; then
        case "$PKG_MGR" in
            apt)           PKGS+=(mailutils) ;;
            dnf|yum)       PKGS+=(mailx) ;;
            zypper|pacman) PKGS+=(mailutils) ;;
        esac
    fi
fi

case "$PKG_MGR" in
    apt)
        apt-get update -qq
        apt-get install -y "${PKGS[@]}"
        ;;
    dnf|yum)
        $PKG_MGR install -y epel-release 2>/dev/null || true
        $PKG_MGR install -y "${PKGS[@]}"
        ;;
    zypper)
        zypper install -y "${PKGS[@]}"
        ;;
    pacman)
        pacman -Sy --noconfirm "${PKGS[@]}"
        ;;
    apk)
        apk update
        apk add "${PKGS[@]}"
        ;;
    *)
        echo -e "${RED}错误：无法识别的包管理器，请手动安装 Fail2ban。${NC}"
        exit 1
        ;;
esac

# -------------------------------------------------------------
# 3. 检测 fail2ban 版本，旧版本不支持时间字符串，转换为秒数
# -------------------------------------------------------------
F2B_VER=$(fail2ban-server --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
F2B_MAJOR=$(echo "$F2B_VER" | cut -d. -f1)
F2B_MINOR=$(echo "$F2B_VER" | cut -d. -f2)

to_seconds() {
    local val="$1"
    if [[ "$val" =~ ^([0-9]+)d$ ]]; then echo $(( ${BASH_REMATCH[1]} * 86400 ))
    elif [[ "$val" =~ ^([0-9]+)h$ ]]; then echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$val" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$val" =~ ^([0-9]+)s?$ ]]; then echo "${BASH_REMATCH[1]}"
    else echo "$val"  # 无法识别则原样返回
    fi
}

# fix: fail2ban < 0.10 不支持时间字符串，转换为秒
if [[ -n "$F2B_MAJOR" ]] && { [[ "$F2B_MAJOR" -lt 0 ]] || { [[ "$F2B_MAJOR" -eq 0 ]] && [[ "$F2B_MINOR" -lt 10 ]]; }; }; then
    echo -e "${YELLOW}[!] 检测到旧版 fail2ban ($F2B_VER)，时间参数将自动转换为秒数。${NC}"
    BANTIME=$(to_seconds "$BANTIME")
    FINDTIME=$(to_seconds "$FINDTIME")
fi

# -------------------------------------------------------------
# 4. 生成动态配置文件
# -------------------------------------------------------------
echo -e "${GREEN}[*] 正在生成 Fail2ban 配置文件...${NC}"
mkdir -p /etc/fail2ban

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = $IGNOREIP
bantime  = $BANTIME
findtime  = $FINDTIME
maxretry = $MAXRETRY
backend = $BACKEND
banaction = $BANACTION
banaction_allports = $BANACTION_ALLPORTS
destemail = $DESTEMAIL
sender = $SENDER
mta = sendmail
action = %($ACTION)s

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

# -------------------------------------------------------------
# 5. 极致兼容的服务自启与管理
# -------------------------------------------------------------
echo -e "${GREEN}[*] 正在重启服务使其生效...${NC}"

# fix: 修正冗余重定向写法
if check_cmd systemctl && systemctl list-units &>/dev/null; then
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}[√] Fail2ban (systemd) 启动指令已执行！${NC}"
elif check_cmd rc-service; then
    rc-update add fail2ban default
    rc-service fail2ban restart
    echo -e "${GREEN}[√] Fail2ban (openrc) 启动指令已执行！${NC}"
elif [[ -x /etc/init.d/fail2ban ]]; then
    if check_cmd update-rc.d; then
        update-rc.d fail2ban defaults
    elif check_cmd chkconfig; then
        chkconfig fail2ban on
    fi
    /etc/init.d/fail2ban restart
    echo -e "${GREEN}[√] Fail2ban (sysvinit) 启动指令已执行！${NC}"
else
    echo -e "${YELLOW}警告：无法自动管理服务，请手动启动 fail2ban (如：fail2ban-server -b)。${NC}"
fi

# fix: 验证服务是否真正启动成功
sleep 2
if fail2ban-client status &>/dev/null; then
    echo -e "${GREEN}[√] Fail2ban 服务运行正常。${NC}"
else
    echo -e "${RED}[!] 警告：fail2ban 可能未正常运行，请检查日志：journalctl -xe -u fail2ban${NC}"
fi

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}安装与配置已全部完成！${NC}"
echo -e "使用 ${YELLOW}fail2ban-client status sshd${NC} 即可查看拦截战况。"
echo -e "${CYAN}=================================================${NC}\n"
