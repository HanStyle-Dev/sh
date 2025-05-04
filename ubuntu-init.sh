#!/bin/sh
# 文件名: ubuntu-init.sh

# 0. 确保以普通用户运行并缓存 sudo 权限
if [ "$(id -u)" -eq 0 ]; then
  echo "请勿以 root 用户运行此脚本，请切换到普通用户并确保已加入 sudo 组。"
  exit 1
fi
sudo -v

set -e

# ==== 交互式选项 ====
# 0.1 输入 SSH 新端口号，必须正确输入
while true; do
  printf "请输入新的 SSH 端口号（1024-65534）: "
  read SSH_PORT
  if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65534 ] 2>/dev/null; then
    break
  else
    echo "端口号必须为数字，且在1024到65534之间，请重试。"
  fi
done

# 0.2 交互选项：是否替换 APT 源、是否关闭防火墙 (UFW)
echo "==> 请选择接下来的操作："
printf " 1) 是否替换 APT 源为阿里云镜像？[y/N]: "
read REPLACE_APT
printf " 2) 是否关闭系统防火墙（UFW）？[y/N]: "
read DISABLE_FW
echo

# 时间戳用于备份
timestamp=$(date +%Y%m%d_%H%M%S)

# 1. 替换 APT 源为阿里云（简洁版）
if [ "$REPLACE_APT" = "y" ] || [ "$REPLACE_APT" = "Y" ]; then
  echo "==> 备份并替换 APT 源为阿里云镜像..."
  CODENAME=$(lsb_release -sc)
  sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.${timestamp}
  sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb https://mirrors.aliyun.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
EOF
  echo "APT 源已替换，备份保存在 /etc/apt/sources.list.bak.${timestamp}"
else
  echo "==> 跳过 APT 源替换。"
fi

# 2. 更新并升级系统补丁
echo "==> 更新并升级系统补丁..."
sudo apt update && sudo apt upgrade -y

# 3. 安装常用工具及虚拟化集成包
echo "==> 安装常用命令行工具..."
sudo apt install -y --no-install-recommends htop net-tools curl wget vim dnsutils unzip

echo "==> 安装虚拟化集成包..."
for pkg in linux-azure open-vm-tools qemu-guest-agent; do
  if apt-cache show "$pkg" &>/dev/null; then
    sudo apt install -y --no-install-recommends "$pkg"
  else
    echo "提示：$pkg 不可用，已跳过。"
  fi
done

# 4. 修改 SSH 默认端口
echo "==> 修改 SSH 默认端口为 ${SSH_PORT}..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.${timestamp}
sudo sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port ${SSH_PORT}/" /etc/ssh/sshd_config
if sudo sshd -t; then
  sudo systemctl reload ssh
  echo "SSH 端口已设置为 $(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}')"
else
  echo "⚠ SSH 配置语法检查失败，请检查 /etc/ssh/sshd_config。"
fi

# 5. 配置自动安全更新
echo "==> 安装并配置 unattended-upgrades..."
sudo apt install -y unattended-upgrades
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
  | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades

# 6. 关闭 UFW（可选）
if [ "$DISABLE_FW" = "y" ] || [ "$DISABLE_FW" = "Y" ]; then
  echo "==> 停止并禁用 UFW..."
  if command -v ufw &>/dev/null; then
    sudo systemctl stop ufw && sudo systemctl disable ufw
  else
    echo "未检测到 ufw，已跳过。"
  fi
else
  echo "==> 跳过 UFW 关闭。"
fi

# 7. 启用 BBR 拥塞控制
echo "==> 启用 BBR..."
if ! grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf; then
  echo 'net.core.default_qdisc=fq' | sudo tee -a /etc/sysctl.conf
fi
if ! grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf; then
  echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p || echo "⚠ BBR 加载失败"

# 8. 设置时区 & NTP 同步
echo "==> 设置时区为 Asia/Shanghai，启用 NTP 同步..."
sudo timedatectl set-timezone Asia/Shanghai
sudo timedatectl set-ntp true
sudo sed -i 's|^#\?NTP=.*|NTP=ntp.aliyun.com|' /etc/systemd/timesyncd.conf && sudo systemctl restart systemd-timesyncd || true

# 9. 最终结果检测（高亮）
RED="\e[1;31m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; BLUE_BG="\e[44m"; RESET="\e[0m"
echo -e "\n${BLUE_BG}${YELLOW} 最终结果检测 ${RESET}\n"
echo -e "${GREEN}✔ BBR：$(sysctl -n net.ipv4.tcp_congestion_control)${RESET}"
echo -e "${GREEN}✔ 队列调度：$(sysctl -n net.core.default_qdisc)${RESET}"
echo -e "${GREEN}✔ 时区：$(timedatectl status | grep 'Time zone')${RESET}"
echo -e "${GREEN}✔ NTP 同步：$(timedatectl show -p NTPSynchronized | cut -d= -f2)${RESET}"
echo -e "${GREEN}✔ UFW 状态：${RESET}$(command -v ufw &>/dev/null && sudo ufw status | head -n1 || echo '未安装或未启用')"
auto_upg_val=$(grep -E 'APT::Periodic::Unattended-Upgrade' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | awk -F '"' '{print $2}')
auto_upg_status="未开启"
[ "${auto_upg_val}" = "1" ] && auto_upg_status="已开启"
echo -e "${GREEN}✔ 自动更新：${RESET}${auto_upg_status}"
echo -e "${GREEN}✔ SSH 端口：${RESET}$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}')"
echo -e "${YELLOW}⚠ 待升级包：$(apt list --upgradable 2>/dev/null | grep upgradable || echo '无')${RESET}"

# 10. 重启确认
echo "==> 操作完成。"
printf "是否现在重启系统？[y/N]: "
read REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "y" ] || [ "$REBOOT_CONFIRM" = "Y" ]; then
  echo "正在重启..."
  sudo reboot
else
  echo "已取消重启。"
fi
