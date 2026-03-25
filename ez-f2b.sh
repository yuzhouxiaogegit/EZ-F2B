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
SENDER="fail2ban@$(hostname)"
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
    elif check_cmd zypper; then echo "zypper"  # 新增 SUSE 支持
    elif check_cmd pacman; then echo "pacman"
    elif check_cmd apk;    then echo "apk"
    else echo "unknown"
    fi
}

PKG_MGR=$(get_pkg_manager)

# 动态决定是否安装 whois（避免由于找不到 whois 导致 fail2ban 也装不上）
EXTRA_PKGS=""
[[ "$ACTION" == "action_mwl" ]] && EXTRA_PKGS="whois"

case "$PKG_MGR" in
    apt)
        apt-get update -qq -y
        apt-get install -y fail2ban $EXTRA_PKGS
        ;;
    dnf|yum)
        $PKG_MGR install -y epel-release 2>/dev/null || true # 容错处理
        $PKG_MGR install -y fail2ban $EXTRA_PKGS
        ;;
    zypper)
        zypper install -y fail2ban $EXTRA_PKGS
        ;;
    pacman)
        pacman -Sy --noconfirm fail2ban $EXTRA_PKGS
        ;;
    apk)
        apk update
        apk add fail2ban $EXTRA_PKGS
        ;;
    *)
        echo -e "${RED}错误：无法识别的包管理器，请手动安装 Fail2ban。${NC}"
        exit 1
        ;;
esac

# -------------------------------------------------------------
# 3. 生成动态配置文件
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
banaction_allports = ${BANACTION}-allports
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
# 4. 极致兼容的服务自启与管理
# -------------------------------------------------------------
echo -e "${GREEN}[*] 正在重启服务使其生效...${NC}"

if check_cmd systemctl && systemctl list-units &>/dev/null 2>&1; then
    # 现代 Linux (Systemd)
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}[√] Fail2ban (systemd) 启动指令已执行！${NC}"
elif check_cmd rc-service; then
    # Alpine / Gentoo (OpenRC)
    rc-update add fail2ban default
    rc-service fail2ban restart
    echo -e "${GREEN}[√] Fail2ban (openrc) 启动指令已执行！${NC}"
elif [[ -x /etc/init.d/fail2ban ]]; then
    # 老旧 Linux (SysVinit) - 新增支持
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

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}安装与配置已全部完成！${NC}"
echo -e "使用 ${YELLOW}fail2ban-client status sshd${NC} 即可查看拦截战况。"
echo -e "${CYAN}=================================================${NC}\n"
