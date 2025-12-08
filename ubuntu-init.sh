#!/bin/sh

# ==== 可配置变量（可通过环境变量覆盖）====
APT_MIRROR="${APT_MIRROR:-mirrors.aliyun.com}"       # APT 镜像源
NTP_SERVER="${NTP_SERVER:-ntp.aliyun.com}"           # NTP 服务器
DEFAULT_SSH_PORT="${DEFAULT_SSH_PORT:-22222}"        # 默认 SSH 端口
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"                # 时区
COMMON_PACKAGES="${COMMON_PACKAGES:-htop net-tools curl wget vim dnsutils unzip}"
RESOLV_UPSTREAM="${RESOLV_UPSTREAM:-223.5.5.5 8.8.8.8}"  # 关闭 stub 后使用的上游 DNS

# 0. 确保以普通用户运行并缓存 sudo 权限
if [ "$(id -u)" -eq 0 ]; then
  echo "请勿以 root 用户运行此脚本，请切换到普通用户并确保已加入 sudo 组。"
  exit 1
fi
sudo -v || true

# 修复主机名解析问题
HOSTNAME=$(hostname)
if ! grep -q "127.0.0.1 $HOSTNAME" /etc/hosts; then
  echo "==> 修复主机名解析..."
  echo "127.0.0.1 $HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
fi

set -e

# ==== 工具函数 ====

warning() {
  printf "⚠ %s\n" "$1"
}

# ==== 模块化功能函数 ====

# 配置 APT 源
configure_apt() {
  if [ "$REPLACE_APT" = "y" ] || [ "$REPLACE_APT" = "Y" ]; then
    echo "==> 备份并替换 APT 源为 ${APT_MIRROR}..."
    CODENAME=$(lsb_release -sc)
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.${timestamp}
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME}-security main restricted universe multiverse
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
EOF
    echo "APT 源已替换，备份保存在 /etc/apt/sources.list.bak.${timestamp}"
  else
    echo "==> 跳过 APT 源替换。"
  fi
}

# 安装常用工具
install_packages() {
  echo "==> 更新并升级系统补丁..."
  sudo apt update && sudo apt upgrade -y

  echo "==> 安装常用命令行工具..."
  sudo apt install -y --no-install-recommends $COMMON_PACKAGES

  echo "==> 安装虚拟化集成包..."
  for pkg in linux-azure open-vm-tools qemu-guest-agent; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      sudo apt install -y --no-install-recommends "$pkg"
    else
      echo "提示：$pkg 不可用，已跳过。"
    fi
  done

  echo "==> 安装 nexttrace..."
  echo "deb [trusted=yes] https://github.com/nxtrace/nexttrace-debs/releases/latest/download ./" | sudo tee /etc/apt/sources.list.d/nexttrace.list > /dev/null
  sudo apt update
  sudo apt install -y nexttrace
}

# 配置 SSH
configure_ssh() {
  echo "==> 修改 SSH 默认端口为 ${SSH_PORT}..."
  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.${timestamp}
  sudo sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  if sudo sshd -t; then
    sudo systemctl reload ssh
    echo "SSH 端口已设置为 $(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}')"
  else
    echo "⚠ SSH 配置语法检查失败，请检查 /etc/ssh/sshd_config。"
  fi
}

# 配置自动安全更新
configure_auto_updates() {
  echo "==> 安装并配置 unattended-upgrades..."
  sudo apt install -y unattended-upgrades
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
    | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades
}

# 配置防火墙
configure_firewall() {
  if [ "$DISABLE_FW" = "y" ] || [ "$DISABLE_FW" = "Y" ]; then
    echo "==> 停止并禁用 UFW..."
    if command -v ufw >/dev/null 2>&1; then
      sudo systemctl stop ufw && sudo systemctl disable ufw
    else
      echo "未检测到 ufw，已跳过。"
    fi
  else
    echo "==> 跳过 UFW 关闭。"
  fi
}

# 配置 BBR
configure_bbr() {
  echo "==> 启用 BBR..."
  ensure_kv /etc/sysctl.conf "net.core.default_qdisc" "fq"
  ensure_kv /etc/sysctl.conf "net.ipv4.tcp_congestion_control" "bbr"
  sudo sysctl -p || echo "⚠ BBR 加载失败"
}

# 配置时区和 NTP
configure_timezone() {
  echo "==> 设置时区为 ${TIMEZONE}，启用 NTP 同步..."
  sudo timedatectl set-timezone "$TIMEZONE"
  sudo timedatectl set-ntp true
  sudo sed -i "s|^#*NTP=.*|NTP=${NTP_SERVER}|" /etc/systemd/timesyncd.conf && sudo systemctl restart systemd-timesyncd || true
}

# 显示最终检测结果
show_results() {
  printf "\n===== 最终结果检测 =====\n\n"
  printf "✓ BBR：%s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未启用')"
  printf "✓ 队列调度：%s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未设置')"
  printf "✓ 时区：%s\n" "$(timedatectl status 2>/dev/null | grep 'Time zone' || echo '未设置')"
  printf "✓ NTP 同步：%s\n" "$(timedatectl show -p NTPSynchronized 2>/dev/null | cut -d= -f2 || echo '未知')"
  printf "✓ UFW 状态：%s\n" "$(command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | head -n1 || echo '未安装或未启用')"
  
  local auto_upg_val auto_upg_status port53_status
  auto_upg_val=$(grep -E 'APT::Periodic::Unattended-Upgrade' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | awk -F '"' '{print $2}')
  auto_upg_status="未开启"
  [ "${auto_upg_val}" = "1" ] && auto_upg_status="已开启"
  printf "✓ 自动更新：%s\n" "${auto_upg_status}"
  printf "✓ SSH 端口：%s\n" "$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '未设置')"
  
  port53_status="可用"
  ss -ulpn 2>/dev/null | grep -q ":53 " && port53_status="被占用"
  printf "✓ 53端口状态：%s\n" "${port53_status}"
  printf "! 待升级包：%s\n" "$(apt list --upgradable 2>/dev/null | grep -i upgradable || echo '无')"
}

# 幂等的键值配置函数：确保配置文件中的键值对只出现一次
# 用法: ensure_kv "配置文件" "键" "值"
ensure_kv() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  elif grep -q "^#${key}=" "$file" 2>/dev/null; then
    sudo sed -i "s|^#${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" | sudo tee -a "$file" > /dev/null
  fi
}

# 可复用的端口53释放函数
# 返回值: 0=成功释放或无需处理, 1=失败
free_port53() {
  local timestamp="$1"
  
  if ! systemctl is-active systemd-resolved >/dev/null 2>&1; then
    return 0
  fi
  
  if ! ss -ulpn 2>/dev/null | grep -q ":53 "; then
    return 0
  fi
  
  if ! ss -ulpn 2>/dev/null | grep ":53 " | grep -q "systemd-resolve"; then
    echo "⚠ 53端口被其他服务占用，非 systemd-resolved"
    return 1
  fi
  
  echo "==> 正在配置 systemd-resolved 以释放 53 端口..."
  
  # 备份配置文件
  if [ -n "$timestamp" ]; then
    sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak.${timestamp}
  fi
  
  # 使用幂等方式设置 DNSStubListener
  ensure_kv /etc/systemd/resolved.conf "DNSStubListener" "no"
  
  # 重启服务
  sudo systemctl restart systemd-resolved
  
  # 配置 resolv.conf，使用可用上游 DNS
  if [ -L /etc/resolv.conf ]; then
    sudo rm -f /etc/resolv.conf
  fi

  {
    echo "# Generated by ubuntu-init.sh"
    for ns in $RESOLV_UPSTREAM; do
      echo "nameserver $ns"
    done
    echo "options edns0 trust-ad"
  } | sudo tee /etc/resolv.conf > /dev/null
  
  echo "systemd-resolved 已配置为不占用 53 端口"
  return 0
}

# ==== 交互式选项 ====
# 确保从终端读取输入，而不是标准输入
# 尝试直接使用/dev/tty，这在管道模式下也能工作
if [ -t 0 ]; then
  # 标准输入是终端，可以直接使用
  TTY_INPUT=/dev/stdin
elif [ -c /dev/tty ]; then
  # 标准输入不是终端，但/dev/tty可用
  TTY_INPUT=/dev/tty
else
  # 没有可用的终端，使用默认值
  echo "⚠️ 无法检测到交互式终端，将使用默认值。"
  TTY_INPUT=""
  # 设置默认值
  SSH_PORT="$DEFAULT_SSH_PORT"
  REPLACE_APT="n"
  DISABLE_FW="n"
fi

# 0.1 输入 SSH 新端口号，必须正确输入
if [ -n "$TTY_INPUT" ]; then
  SSH_PORT=""
  while [ -z "$SSH_PORT" ]; do
    printf "请输入新的 SSH 端口号（1024-65534）: "
    # 使用exec重定向标准输入到TTY_INPUT
    # 这样可以确保read命令从正确的终端设备读取输入
    if ! read SSH_PORT_INPUT < "$TTY_INPUT"; then
      echo "⚠️ 读取输入失败，使用默认端口 $DEFAULT_SSH_PORT"
      SSH_PORT="$DEFAULT_SSH_PORT"
      break
    fi

    # 检查输入是否为数字
    case "$SSH_PORT_INPUT" in
      ''|*[!0-9]*)
        echo "端口号必须为数字，且在1024到65534之间，请重试。"
        SSH_PORT=""
        ;;
      *)
        # 检查数字范围
        if [ "$SSH_PORT_INPUT" -ge 1024 ] && [ "$SSH_PORT_INPUT" -le 65534 ]; then
          SSH_PORT="$SSH_PORT_INPUT"
        else
          echo "端口号必须为数字，且在1024到65534之间，请重试。"
          SSH_PORT=""
        fi
        ;;
    esac
  done

  # 0.2 交互选项：是否替换 APT 源、是否关闭防火墙 (UFW)
  echo "==> 请选择接下来的操作："
  printf " 1) 是否替换 APT 源为阿里云镜像？[y/N]: "
  read REPLACE_APT < "$TTY_INPUT" || REPLACE_APT="n"
  printf " 2) 是否关闭系统防火墙（UFW）？[y/N]: "
  read DISABLE_FW < "$TTY_INPUT" || DISABLE_FW="n"
  echo
fi

# 时间戳用于备份
timestamp=$(date +%Y%m%d_%H%M%S)

# ==== 主流程（调用模块化函数）====
configure_apt           # 1. 配置 APT 源
install_packages        # 2-3. 更新系统并安装常用工具
configure_ssh           # 4. 配置 SSH 端口
configure_auto_updates  # 5. 配置自动安全更新
configure_firewall      # 6. 配置防火墙

# 6.1 处理 systemd-resolved 占用 53 端口问题
echo "==> 检测并释放 53 端口..."
free_port53 "$timestamp" || warning "53端口释放失败，可能影响后续 DNS 服务部署"

configure_bbr           # 7. 启用 BBR
configure_timezone      # 8. 配置时区和 NTP
show_results            # 9. 显示最终检测结果

# 10. 重启确认
echo "==> 操作完成。"
if [ -n "$TTY_INPUT" ]; then
  printf "是否现在重启系统？[y/N]: "
  read REBOOT_CONFIRM < "$TTY_INPUT" || REBOOT_CONFIRM="n"
  if [ "$REBOOT_CONFIRM" = "y" ] || [ "$REBOOT_CONFIRM" = "Y" ]; then
    echo "正在重启..."
    sudo reboot
  else
    echo "已取消重启。"
  fi
else
  echo "跳过重启确认（非交互模式）。"
fi
