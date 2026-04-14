#!/bin/bash

# =============================================================
# Fail2ban 全参数交互式安装与配置脚本 (极致兼容优化版)
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
echo -e "${CYAN}${BOLD}       Fail2ban 全参数交互式高级配置脚本        ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# -------------------------------------------------------------
# 1. 交互式参数收集
# -------------------------------------------------------------
echo -e "${YELLOW}--- 基础防御参数 ---${NC}"
read -p "1. 白名单 IP (多个用空格隔开。直接回车默认: 127.0.0.1/8 ::1): " INPUT_IGNOREIP
IGNOREIP=${INPUT_IGNOREIP:-"127.0.0.1/8 ::1"}

read -p "2. 封禁时长 (如 10m, 1h, 1d。直接回车默认: 24h): " INPUT_BANTIME
BANTIME=${INPUT_BANTIME:-"24h"}

read -p "3. 统计时间窗口 (直接回车默认: 10m): " INPUT_FINDTIME
FINDTIME=${INPUT_FINDTIME:-"10m"}

read -p "4. 最大密码错误次数 (直接回车默认: 3): " INPUT_MAXRETRY
MAXRETRY=${INPUT_MAXRETRY:-"3"}

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
FQDN=$(hostname -f 2>/dev/null || hostname)
SENDER="fail2ban@${FQDN}"
if [[ "$ACTION" != "action_" ]]; then
    read -p "    -> 请输入接收报警的邮箱地址: " INPUT_EMAIL
    DESTEMAIL=${INPUT_EMAIL:-"root@localhost"}
fi

echo "7. 日志监控引擎 (backend):"
echo "   [1] auto    : 自动选择 (默认，推荐脚本自动判定)"
echo "   [2] systemd : 强制读取 systemd journal (推荐新版系统)"
echo "   [3] polling : 传统轮询读取文件"
read -p "请输入序号 [1-3] (直接回车默认 1): " INPUT_BACKEND
case "$INPUT_BACKEND" in
    2) BACKEND="systemd" ;;
    3) BACKEND="polling" ;;
    *) BACKEND="auto" ;;
esac

# -------------------------------------------------------------
# 2. 智能逻辑优化：自动修复 backend
# -------------------------------------------------------------
# 如果用户选 auto，但系统不存在传统日志文件，强制切换为 systemd
if [[ "$BACKEND" == "auto" ]]; then
    if [[ ! -f /var/log/auth.log ]] && [[ ! -f /var/log/secure ]]; then
        echo -e "${YELLOW}[!] 检测到系统不存在传统日志文件，自动切换 backend 为 systemd${NC}"
        BACKEND="systemd"
    fi
fi

echo -e "\n${GREEN}[*] 参数收集完毕，正在执行安装与配置...${NC}\n"
sleep 1

# -------------------------------------------------------------
# 3. 包管理器检测与安装
# -------------------------------------------------------------
check_cmd() { command -v "$1" &>/dev/null; }
get_pkg_manager() {
    if check_cmd apt-get;  then echo "apt"
    elif check_cmd dnf;    then echo "dnf"
    elif check_cmd yum;    then echo "yum"
    else echo "unknown"
    fi
}

PKG_MGR=$(get_pkg_manager)
PKGS=(fail2ban)
[[ "$ACTION" == "action_mwl" ]] && PKGS+=(whois)

case "$PKG_MGR" in
    apt)
        apt-get update -qq && apt-get install -y "${PKGS[@]}"
        ;;
    dnf|yum)
        $PKG_MGR install -y epel-release 2>/dev/null || true
        $PKG_MGR install -y "${PKGS[@]}"
        ;;
    *)
        echo -e "${RED}错误：不支持的包管理器。${NC}" ; exit 1 ;;
esac

# -------------------------------------------------------------
# 4. 生成动态配置文件 (优化版)
# -------------------------------------------------------------
echo -e "${GREEN}[*] 正在生成 Fail2ban 配置文件...${NC}"
mkdir -p /etc/fail2ban/jail.d

# 预判 logpath 逻辑
LOG_LINE="logpath = %(sshd_log)s"
[[ "$BACKEND" == "systemd" ]] && LOG_LINE="# logpath = (systemd mode does not need this)"

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
$LOG_LINE
EOF

# -------------------------------------------------------------
# 5. 服务清理与启动
# -------------------------------------------------------------
echo -e "${GREEN}[*] 正在清理残留并启动服务...${NC}"

# 核心：必须清理残留的 sock 文件，否则重启会报错
rm -f /var/run/fail2ban/fail2ban.sock

if check_cmd systemctl; then
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban
else
    service fail2ban restart
fi

# -------------------------------------------------------------
# 6. 验证结果
# -------------------------------------------------------------
sleep 2
if fail2ban-client status sshd &>/dev/null; then
    echo -e "${GREEN}[√] Fail2ban 启动成功！${NC}"
    fail2ban-client status sshd
else
    echo -e "${RED}[!] 启动失败，可能的原因：${NC}"
    echo "1. 请检查防火墙组件 ($BANACTION) 是否安装"
    echo "2. 执行 fail2ban-server -f -v start 查看前台报错"
fi

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}配置完成！已根据你的环境自动适配日志后端：$BACKEND${NC}"
echo -e "${CYAN}=================================================${NC}\n"
