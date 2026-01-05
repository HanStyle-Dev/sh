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
  echo "❌ 请勿以 root 用户运行此脚本,请切换到普通用户并确保已加入 sudo 组。"
  exit 1
fi

# P0 修复: 强化 sudo 权限检查,不掩盖错误
if ! sudo -v; then
  echo "❌ 当前用户没有 sudo 权限,请联系管理员添加到 sudo 组"
  echo "提示: sudo usermod -aG sudo \$(whoami)"
  exit 1
fi

# 修复主机名解析问题
HOSTNAME=$(hostname)
if ! grep -q "127.0.0.1 $HOSTNAME" /etc/hosts; then
  echo "==> 修复主机名解析..."
  echo "127.0.0.1 $HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
fi

set -e

# ==== 工具函数 ====

# P2: 添加统一日志函数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { printf "${BLUE}ℹ %s${NC}\n" "$1"; }
success() { printf "${GREEN}✓ %s${NC}\n" "$1"; }
warning() { printf "${YELLOW}⚠ %s${NC}\n" "$1"; }
error() { printf "${RED}✗ %s${NC}\n" "$1" >&2; }

# P2: 提取通用备份函数 (DRY 原则)
backup_file() {
  _backup_file="$1"
  _backup_timestamp="${2:-$(date +%Y%m%d_%H%M%S)}"

  # 创建原始备份 (仅首次)
  if [ ! -f "${_backup_file}.original" ]; then
    sudo cp "$_backup_file" "${_backup_file}.original"
    info "创建原始备份: ${_backup_file}.original"
  fi

  # 创建时间戳备份
  sudo cp "$_backup_file" "${_backup_file}.bak.${_backup_timestamp}"
  info "创建时间戳备份: ${_backup_file}.bak.${_backup_timestamp}"
}

# ==== 模块化功能函数 ====

# 配置 APT 源
configure_apt() {
  # P0: 添加幂等性检测
  if grep -q "${APT_MIRROR}" /etc/apt/sources.list 2>/dev/null; then
    info "APT 源已经配置为 ${APT_MIRROR},跳过"
    return 0
  fi

  if [ "$REPLACE_APT" = "y" ] || [ "$REPLACE_APT" = "Y" ]; then
    echo "==> 备份并替换 APT 源为 ${APT_MIRROR}..."
    CODENAME=$(lsb_release -sc)
    backup_file /etc/apt/sources.list "${timestamp}"
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME}-security main restricted universe multiverse
deb https://${APT_MIRROR}/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
EOF
    success "APT 源已替换为 ${APT_MIRROR}"
  else
    info "跳过 APT 源替换"
  fi
}

# 安装常用工具
install_packages() {
  # P0: 修复 nexttrace 源重复添加
  if [ ! -f /etc/apt/sources.list.d/nexttrace.list ]; then
    info "添加 nexttrace 软件源"
    echo "deb [trusted=yes] https://github.com/nxtrace/nexttrace-debs/releases/latest/download ./" | sudo tee /etc/apt/sources.list.d/nexttrace.list > /dev/null
  else
    info "nexttrace 源已存在,跳过"
  fi

  # P1: 合并 apt update 调用优化性能
  echo "==> 更新软件包索引并升级系统补丁..."
  sudo apt update && sudo apt upgrade -y

  echo "==> 安装常用命令行工具..."
  sudo apt install -y --no-install-recommends $COMMON_PACKAGES

  # P1: 批量安装虚拟化包
  echo "==> 检测并安装虚拟化集成包..."
  VIRT_PACKAGES=""
  for pkg in linux-azure open-vm-tools qemu-guest-agent; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      VIRT_PACKAGES="$VIRT_PACKAGES $pkg"
    fi
  done

  if [ -n "$VIRT_PACKAGES" ]; then
    sudo apt install -y --no-install-recommends $VIRT_PACKAGES
    success "已安装虚拟化包:$VIRT_PACKAGES"
  else
    warning "未检测到可用的虚拟化集成包"
  fi

  # 安装 nexttrace
  if ! command -v nexttrace >/dev/null 2>&1; then
    echo "==> 安装 nexttrace..."
    sudo apt install -y nexttrace
  else
    info "nexttrace 已安装,跳过"
  fi
}

# 配置 SSH
configure_ssh() {
  # P0: 添加幂等性检测
  _ssh_current_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')

  if [ "$_ssh_current_port" = "$SSH_PORT" ]; then
    info "SSH 端口已经是 ${SSH_PORT},跳过配置"
    return 0
  fi

  echo "==> 修改 SSH 默认端口为 ${SSH_PORT}..."
  backup_file /etc/ssh/sshd_config "${timestamp}"

  sudo sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port ${SSH_PORT}/" /etc/ssh/sshd_config

  # P0: SSH 配置语法检查
  if ! sudo sshd -t; then
    error "SSH 配置语法检查失败,正在回滚..."
    sudo cp "/etc/ssh/sshd_config.bak.${timestamp}" /etc/ssh/sshd_config
    return 1
  fi

  # 重载 SSH 服务
  if ! sudo systemctl reload ssh; then
    error "SSH 服务重载失败,正在回滚..."
    sudo cp "/etc/ssh/sshd_config.bak.${timestamp}" /etc/ssh/sshd_config
    sudo systemctl reload ssh
    return 1
  fi

  # P0: 等待服务重载并验证新端口
  sleep 2

  if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} "; then
    success "SSH 端口已成功设置为 ${SSH_PORT}"

    # P1: 增强警告提示
    echo ""
    echo "════════════════════════════════════════════════"
    warning "SSH 端口已修改为: ${SSH_PORT}"
    warning "请在新终端测试连接: ssh -p ${SSH_PORT} user@host"
    warning "确认连接成功后再关闭当前会话!"
    echo "════════════════════════════════════════════════"
    echo ""
  else
    error "SSH 端口监听失败,正在回滚..."
    sudo cp "/etc/ssh/sshd_config.bak.${timestamp}" /etc/ssh/sshd_config
    sudo systemctl reload ssh
    return 1
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

  # P2: 改进错误处理,移除 || true
  if ! sudo sysctl -p >/dev/null 2>&1; then
    warning "BBR 配置加载失败,可能需要重启生效"
    return 1
  fi
  success "BBR 已成功启用"
}

# 配置时区和 NTP
configure_timezone() {
  echo "==> 设置时区为 ${TIMEZONE},启用 NTP 同步..."
  sudo timedatectl set-timezone "$TIMEZONE"
  sudo timedatectl set-ntp true

  # P2: 改进错误处理
  if sudo sed -i "s|^#*NTP=.*|NTP=${NTP_SERVER}|" /etc/systemd/timesyncd.conf; then
    sudo systemctl restart systemd-timesyncd
    success "时区和 NTP 配置完成"
  else
    warning "NTP 服务器配置失败"
  fi
}

# 显示最终检测结果
show_results() {
  # P2: 优化输出格式
  printf "\n═══════════════════════════════════\n"
  printf "         最终配置检测结果          \n"
  printf "═══════════════════════════════════\n\n"

  # BBR 状态
  _bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未启用")
  printf "%-20s %s\n" "BBR 拥塞控制:" "$_bbr_status"

  # 队列调度
  _qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置")
  printf "%-20s %s\n" "队列调度算法:" "$_qdisc"

  # 时区
  _tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "未知")
  printf "%-20s %s\n" "系统时区:" "$_tz"

  # NTP 同步
  _ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  if [ "$_ntp_sync" = "yes" ]; then
    printf "%-20s %s\n" "NTP 同步:" "✓ 已同步"
  else
    printf "%-20s %s\n" "NTP 同步:" "❌ 未同步"
  fi

  # UFW 状态
  _ufw_status="未安装"
  if command -v ufw >/dev/null 2>&1; then
    _ufw_status=$(sudo ufw status 2>/dev/null | head -n1)
  fi
  printf "%-20s %s\n" "UFW 状态:" "$_ufw_status"

  # 自动更新
  _auto_upg_val=$(grep -E 'APT::Periodic::Unattended-Upgrade' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | awk -F '"' '{print $2}')
  if [ "${_auto_upg_val}" = "1" ]; then
    printf "%-20s %s\n" "自动更新:" "✓ 已开启"
  else
    printf "%-20s %s\n" "自动更新:" "❌ 未开启"
  fi

  # SSH 端口
  _ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
  printf "%-20s %s\n" "SSH 端口:" "${_ssh_port:-未设置}"

  # 53端口状态
  if ss -ulpn 2>/dev/null | grep -q ":53 "; then
    printf "%-20s %s\n" "53端口状态:" "❌ 被占用"
  else
    printf "%-20s %s\n" "53端口状态:" "✓ 可用"
  fi

  # 待升级包数量
  _upgrade_count=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
  printf "%-20s %s\n" "待升级软件包:" "$_upgrade_count 个"

  printf "\n"
}

# 幂等的键值配置函数:确保配置文件中的键值对只出现一次
# 用法: ensure_kv "配置文件" "键" "值"
ensure_kv() {
  _kv_file="$1"
  _kv_key="$2"
  _kv_val="$3"

  if grep -q "^${_kv_key}=" "$_kv_file" 2>/dev/null; then
    sudo sed -i "s|^${_kv_key}=.*|${_kv_key}=${_kv_val}|" "$_kv_file"
  elif grep -q "^#${_kv_key}=" "$_kv_file" 2>/dev/null; then
    sudo sed -i "s|^#${_kv_key}=.*|${_kv_key}=${_kv_val}|" "$_kv_file"
  else
    echo "${_kv_key}=${_kv_val}" | sudo tee -a "$_kv_file" > /dev/null
  fi
}

# 可复用的端口53释放函数
# 返回值: 0=成功释放或无需处理, 1=失败
free_port53() {
  _port53_timestamp="$1"

  if ! systemctl is-active systemd-resolved >/dev/null 2>&1; then
    return 0
  fi

  if ! ss -ulpn 2>/dev/null | grep -q ":53 "; then
    return 0
  fi

  if ! ss -ulpn 2>/dev/null | grep ":53 " | grep -q "systemd-resolve"; then
    warning "53端口被其他服务占用,非 systemd-resolved"
    return 1
  fi

  echo "==> 正在配置 systemd-resolved 以释放 53 端口..."

  # P0: 备份原始 resolv.conf 链接目标
  _resolv_target=""
  if [ -L /etc/resolv.conf ]; then
    _resolv_target=$(readlink -f /etc/resolv.conf)
    info "备份 resolv.conf 链接目标: $_resolv_target"
  fi

  # 备份配置文件
  if [ -n "$_port53_timestamp" ]; then
    backup_file /etc/systemd/resolved.conf "${_port53_timestamp}"
  fi

  # 使用幂等方式设置 DNSStubListener
  ensure_kv /etc/systemd/resolved.conf "DNSStubListener" "no"

  # 重启服务
  if ! sudo systemctl restart systemd-resolved; then
    error "systemd-resolved 重启失败"
    return 1
  fi

  # P0: 配置 resolv.conf,使用可用上游 DNS
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

  # P0: 验证 DNS 解析
  sleep 1
  if ! nslookup google.com >/dev/null 2>&1 && ! host google.com >/dev/null 2>&1; then
    error "DNS 解析失败,正在回滚配置..."

    # 回滚 resolv.conf
    if [ -n "$_resolv_target" ]; then
      sudo ln -sf "$_resolv_target" /etc/resolv.conf
      info "已回滚 resolv.conf 到: $_resolv_target"
    fi

    # 回滚 systemd-resolved 配置
    if [ -f "/etc/systemd/resolved.conf.bak.${_port53_timestamp}" ]; then
      sudo cp "/etc/systemd/resolved.conf.bak.${_port53_timestamp}" /etc/systemd/resolved.conf
      sudo systemctl restart systemd-resolved
    fi

    return 1
  fi

  success "systemd-resolved 已配置为不占用 53 端口,DNS 解析正常"
  return 0
}

# ==== 交互式选项 ====
# 确保从终端读取输入,而不是标准输入
# 尝试直接使用/dev/tty,这在管道模式下也能工作
if [ -t 0 ]; then
  # 标准输入是终端,可以直接使用
  TTY_INPUT=/dev/stdin
elif [ -c /dev/tty ]; then
  # 标准输入不是终端,但/dev/tty可用
  TTY_INPUT=/dev/tty
else
  # P1: 优化非交互模式提示信息
  echo ""
  warning "无法检测到交互式终端,使用默认配置:"
  echo "  - SSH 端口: ${DEFAULT_SSH_PORT}"
  echo "  - APT 源替换: 否"
  echo "  - 关闭防火墙: 否"
  echo ""

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
