# HanStyle 服务器工具集

这个项目提供了一系列脚本，用于快速初始化和配置服务器环境，包括Docker服务、DNS服务、监控工具和性能测试工具。全部脚本采用POSIX兼容的shell语法，确保在各种环境下可靠运行。

## 项目组件

### 1. setup.sh

自动化安装 Docker、Docker Compose 以及一系列常用服务的脚本。脚本具有以下特点：

- 自动检测操作系统类型（Ubuntu、Debian、CentOS、RHEL、Fedora、Alpine Linux）
- 智能安装必要依赖和命令（ss、dig、nslookup等）
- 自动处理端口冲突问题，特别是53端口被systemd-resolved占用的情况
- 提供彩色输出和详细日志，便于故障排查
- 支持多种配置选项，如调整DNS端口、跳过Docker安装等

#### 包含的Docker服务

- **Unbound DNS 服务器**：提供本地DNS解析服务，配置了健康检查
- **Redis**：内存数据库，用于缓存，配置了持久化和性能优化
- **Homebox**：简洁的自托管主页，端口80
- **Uptime Kuma**：服务监控工具，端口8080，带数据持久化
- **iperf3**：网络性能测试工具，TCP/UDP端口5201

所有服务都配置了资源限制（内存、CPU）和日志轮转，确保长期稳定运行。

### 2. ubuntu-init.sh

Ubuntu服务器初始化脚本，专为新建服务器设计，提供以下功能：

- 修复主机名解析问题（添加本地主机名到/etc/hosts）
- 处理非交互式环境，支持管道方式运行
- 替换APT源为阿里云镜像（可选，交互式确认）
- 更新系统补丁（apt update && apt upgrade）
- 安装常用命令行工具（htop, net-tools, curl, wget, vim, dnsutils, unzip）
- 自动检测并安装虚拟化集成包（针对不同云环境）
- 修改SSH默认端口（交互式设置，要求端口在1024-65534范围内）
- 配置自动安全更新（unattended-upgrades）
- 关闭UFW防火墙（可选，交互式确认）
- 启用BBR拥塞控制（提升网络性能）
- 设置时区为Asia/Shanghai并配置NTP同步（使用阿里云NTP服务器）
- 完成后提供详细的配置报告和重启选项

## 快速开始

### setup.sh 在线运行

使用以下命令可以直接从 GitHub 获取并运行脚本（需要root权限）：

```bash
curl -fsSL https://raw.githubusercontent.com/HanStyle-Dev/sh/main/setup.sh | sudo sh
```

如果需要指定参数，可以使用以下方式：

```bash
curl -fsSL https://raw.githubusercontent.com/HanStyle-Dev/sh/main/setup.sh | sudo sh -s -- --debug
```

### ubuntu-init.sh 在线运行

以普通用户身份运行（脚本会自动获取sudo权限）：

```bash
curl -fsSL https://raw.githubusercontent.com/HanStyle-Dev/sh/main/ubuntu-init.sh | sh
```

### 手动下载运行

1. 克隆仓库：

```bash
git clone https://github.com/HanStyle-Dev/sh.git
cd sh
```

2. 运行脚本：

```bash
# 运行 setup.sh (需要root权限)
sudo ./setup.sh

# 运行 ubuntu-init.sh (使用普通用户)
./ubuntu-init.sh
```

## 使用选项

### setup.sh 命令行选项

脚本支持以下命令行选项：

- `-h, --help`：显示帮助信息和使用示例
- `-s, --skip-docker`：如果已安装 Docker，跳过 Docker 安装步骤
- `-f, --force`：强制重新安装所有组件，覆盖已有配置
- `-p, --port PORT`：指定 DNS 服务使用的端口（默认: 53）
- `-d, --debug`：显示详细调试信息，包括命令执行和系统检测
- `-c, --clean`：清理 Docker Compose 安装的容器和卷，并删除配置文件

#### 示例用法

```bash
# 标准安装
sudo ./setup.sh

# 跳过 Docker 安装
sudo ./setup.sh --skip-docker

# 使用非默认端口（当53端口被占用时）
sudo ./setup.sh --port 5353

# 显示详细调试信息（故障排查时使用）
sudo ./setup.sh --debug

# 清理已安装的容器和配置
sudo ./setup.sh --clean
```

### ubuntu-init.sh 交互选项

以普通用户身份运行（需要sudo权限）：

```bash
./ubuntu-init.sh
```

脚本会提供以下交互式选项：
- 设置新的SSH端口号（必须在1024-65534范围内）
- 是否替换APT源为阿里云镜像（适合中国大陆服务器）
- 是否关闭系统防火墙（UFW）
- 完成后是否重启系统

脚本还支持非交互式运行（通过管道方式），此时会使用默认选项：
- SSH端口：22222
- 不替换APT源
- 不关闭防火墙
- 不自动重启

## 服务访问

setup.sh 安装完成后，可以通过以下地址访问各服务：

- **Homebox**: `http://<服务器IP>:80` - 自托管主页
- **Uptime Kuma**: `http://<服务器IP>:8080` - 监控工具，首次访问需要设置管理员账户
- **DNS 服务**: `<服务器IP>:53` - 可通过 `dig @<服务器IP> google.com` 测试
- **iperf3 服务**: `<服务器IP>:5201` - 可通过 `iperf3 -c <服务器IP>` 测试网络性能

## 系统要求与兼容性

- **setup.sh**：
  - 支持的操作系统：Ubuntu、Debian、CentOS、RHEL、Fedora、Alpine Linux
  - 自动适配不同的包管理器（apt、yum、apk）
  - 需要 root 权限运行脚本
  - 需要互联网连接以下载必要的软件包
  - 最低内存推荐：1GB（运行所有服务）

- **ubuntu-init.sh**：
  - 仅支持 Ubuntu 系统
  - 需要以普通用户运行（具有sudo权限）
  - 支持SSH远程执行和管道方式运行
  - 会自动处理无交互终端的情况
  - 需要互联网连接以下载必要的软件包

## 故障排除

### DNS服务问题

如果 DNS 服务（端口 53）无法启动，可能是因为系统的 systemd-resolved 服务正在占用该端口。脚本会尝试自动解决这个问题：

1. 检测端口占用情况
2. 修改systemd-resolved配置（设置DNSStubListener=no）
3. 配置替代DNS服务器（1.1.1.1和8.8.8.8）

如果自动修复失败，您可以：

1. 使用非默认端口：`sudo ./setup.sh --port 5353`
2. 手动停止systemd-resolved：`sudo systemctl stop systemd-resolved`
3. 使用调试模式查看详细信息：`sudo ./setup.sh --debug`

### Docker相关问题

如果Docker安装失败：

1. 检查网络连接是否正常
2. 使用`--debug`选项查看详细错误信息
3. 尝试手动安装Docker，然后使用`--skip-docker`选项运行脚本

## 贡献

欢迎提交 Issues 和 Pull Requests 到 [GitHub 仓库](https://github.com/HanStyle-Dev/sh)。

## 许可证

[MIT License](LICENSE)
