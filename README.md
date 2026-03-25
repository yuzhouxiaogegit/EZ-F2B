# ez-f2b.sh

一键交互式安装并配置 Fail2ban 的 Shell 脚本，支持主流 Linux 发行版，自动处理版本兼容问题。

## 系统要求

- 需要 **root** 权限运行
- 支持以下包管理器：`apt` / `dnf` / `yum` / `zypper` / `pacman` / `apk`
- 对应发行版：Debian/Ubuntu、CentOS/RHEL/Fedora、SUSE、Arch Linux、Alpine Linux

## 快速开始

```bash
curl -O https://raw.githubusercontent.com/yuzhouxiaogegit/EZ-F2B/main/ez-f2b.sh && chmod +x ez-f2b.sh && sudo ./ez-f2b.sh
```

脚本运行后会逐步提示输入以下参数，全部支持直接回车使用默认值。

| 参数         | 默认值               | 说明                                 |
| ------------ | -------------------- | ------------------------------------ |
| 白名单 IP    | `127.0.0.1/8 ::1`    | 多个 IP 用空格隔开，永不封禁         |
| 封禁时长     | `1h`                 | 支持 `s` / `m` / `h` / `d` 单位      |
| 统计时间窗口 | `10m`                | 在此时间内超过最大错误次数则触发封禁 |
| 最大错误次数 | `5`                  | 触发封禁的失败次数阈值               |
| 防火墙动作   | `iptables-multiport` | 见下方说明                           |
| 封禁附带动作 | `action_` (仅封禁)   | 见下方说明                           |
| 日志监控引擎 | `auto`               | 见下方说明                           |

### 防火墙动作

| 选项 | 值                   | 适用场景                 |
| ---- | -------------------- | ------------------------ |
| 1    | `iptables-multiport` | 通用，兼容性最好（默认） |
| 2    | `ufw`                | Ubuntu / Debian          |
| 3    | `firewalld`          | CentOS / RHEL            |

### 封禁附带动作

| 选项 | 值           | 说明                            |
| ---- | ------------ | ------------------------------- |
| 1    | `action_`    | 仅静默封禁 IP（默认）           |
| 2    | `action_mw`  | 封禁 IP 并发送邮件通知          |
| 3    | `action_mwl` | 封禁 IP、发邮件，并附带相关日志 |

> 选择邮件动作时，脚本会自动检测并安装所需的 MTA（`mailutils` / `mailx`）。

### 日志监控引擎

| 选项 | 值        | 说明                   |
| ---- | --------- | ---------------------- |
| 1    | `auto`    | 自动选择，推荐（默认） |
| 2    | `systemd` | 读取 systemd journal   |
| 3    | `polling` | 传统轮询读取文件       |

## 脚本行为

1. 收集所有参数后，自动检测包管理器并安装 `fail2ban`
2. 检测 fail2ban 版本，若低于 `0.10` 自动将时间参数转换为秒数（旧版本不支持 `1h` 格式）
3. 生成 `/etc/fail2ban/jail.local` 配置文件
4. 自动适配服务管理器（systemd / OpenRC / SysVinit）并启动服务
5. 启动后验证服务状态，异常时输出日志查看命令

## 使用教程

### 第一步：下载脚本

```bash
curl -O https://raw.githubusercontent.com/yuzhouxiaogegit/EZ-F2B/main/ez-f2b.sh
chmod +x ez-f2b.sh
```

或者直接克隆仓库：

```bash
git clone https://github.com/yuzhouxiaogegit/EZ-F2B.git
cd EZ-F2B
chmod +x ez-f2b.sh
```

### 第二步：运行脚本

```bash
sudo ./ez-f2b.sh
```

### 第三步：按提示填写参数

脚本启动后会依次询问以下内容，**不熟悉的参数直接回车使用默认值即可**：

```
--- 基础防御参数 ---
1. 白名单 IP (多个用空格隔开。直接回车默认: 127.0.0.1/8 ::1):
   → 填入你自己的 IP，防止误封自己，例如：1.2.3.4 127.0.0.1/8 ::1

2. 封禁时长 (如 10m, 1h, 1d。直接回车默认: 1h):
   → 建议生产环境设置 24h 或更长

3. 统计时间窗口 (直接回车默认: 10m):
   → 在此窗口内达到错误次数上限才触发封禁

4. 最大密码错误次数 (直接回车默认: 5):
   → 建议设置 3~5 次

--- 高级控制参数 ---
5. 防火墙动作:
   → Ubuntu/Debian 用户可选 2 (ufw)，CentOS/RHEL 可选 3 (firewalld)，其余选 1

6. 触发封禁后的附带动作:
   → 不需要邮件通知直接回车，需要则选 2 或 3 并填写邮箱

7. 日志监控引擎:
   → 直接回车使用 auto 即可
```

### 第四步：等待安装完成

脚本会自动完成以下操作，无需手动干预：

- 安装 fail2ban（及邮件工具，如果选了邮件动作）
- 写入 `/etc/fail2ban/jail.local`
- 启动并设置开机自启
- 验证服务是否正常运行

看到以下输出说明安装成功：

```
[√] Fail2ban 服务运行正常。
================================================
安装与配置已全部完成！
使用 fail2ban-client status sshd 即可查看拦截战况。
================================================
```

---

### 场景示例

**场景一：普通 VPS，只防 SSH 暴力破解（推荐新手）**

全部回车使用默认值即可，5 次错误封禁 1 小时。

**场景二：高安全要求服务器**

```
封禁时长：7d
最大错误次数：3
白名单 IP：填入你的固定 IP
```

**场景三：Ubuntu + ufw 环境**

```
防火墙动作：选 2 (ufw)
```

确保 ufw 已启用：

```bash
ufw status
# 若未启用
ufw enable
```

**场景四：需要邮件告警**

```
封禁附带动作：选 2 (action_mw)
邮箱地址：your@email.com
```

脚本会自动安装 mailutils，配置完成后每次封禁都会收到邮件通知。

---

## 查看运行状态

```bash
# 查看 SSH 防护状态及已封禁 IP
fail2ban-client status sshd

# 查看所有 jail 状态
fail2ban-client status

# 手动解封某个 IP
fail2ban-client set sshd unbanip <IP>

# 查看服务日志（systemd）
journalctl -xe -u fail2ban
```

## 生成的配置文件

脚本会写入 `/etc/fail2ban/jail.local`，内容示例：

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 1h
findtime  = 10m
maxretry = 5
backend = auto
banaction = iptables-multiport
banaction_allports = iptables-allports
destemail = root@localhost
sender = fail2ban@your.hostname
mta = sendmail
action = %(action_)s

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
```

## License

MIT
