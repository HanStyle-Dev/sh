# Docker 服务安装脚本

这是一个自动化安装 Docker、Docker Compose 以及一系列常用服务的脚本。脚本会自动检测系统环境，安装必要的依赖，并启动预配置的服务。

## 包含的服务

- **Unbound DNS 服务器**：提供本地 DNS 解析服务
- **Redis**：内存数据库，用于缓存
- **Homebox**：简洁的自托管主页
- **Uptime Kuma**：服务监控工具
- **iperf3**：网络性能测试工具

## 快速开始

### 在线运行（推荐）

使用以下命令可以直接从 GitHub 获取并运行脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/HanStyle-Dev/sh/main/setup.sh | sudo sh
```

如果需要指定参数，可以使用以下方式：

```bash
curl -fsSL https://raw.githubusercontent.com/HanStyle-Dev/sh/main/setup.sh | sudo sh -s -- --port 5353
```

### 手动下载运行

1. 克隆仓库：

```bash
git clone https://github.com/HanStyle-Dev/sh.git
cd sh
```

2. 运行脚本：

```bash
sudo ./setup.sh
```

## 使用选项

脚本支持以下命令行选项：

- `-h, --help`：显示帮助信息
- `-s, --skip-docker`：如果已安装 Docker，跳过 Docker 安装步骤
- `-f, --force`：强制重新安装所有组件
- `-p, --port PORT`：指定 DNS 服务使用的端口（默认: 53）
- `-d, --debug`：显示详细调试信息
- `-c, --clean`：清理 Docker Compose 安装的容器并删除配置文件

### 示例

```bash
# 标准安装
sudo ./setup.sh

# 跳过 Docker 安装
sudo ./setup.sh --skip-docker

# 使用非默认端口
sudo ./setup.sh --port 5353

# 显示详细调试信息
sudo ./setup.sh --debug

# 清理已安装的容器和配置
sudo ./setup.sh --clean
```

## 服务访问

安装完成后，可以通过以下地址访问各服务：

- Homebox: `http://<服务器IP>:80`
- Uptime Kuma: `http://<服务器IP>:8080`
- DNS 服务: `<服务器IP>:53`
- iperf3 服务: `<服务器IP>:5201`

## 系统要求

- 支持的操作系统：Ubuntu、Debian、CentOS、RHEL、Fedora、Alpine Linux
- 需要 root 权限运行脚本
- 需要互联网连接以下载必要的软件包

## 故障排除

如果 DNS 服务（端口 53）无法启动，可能是因为系统的 systemd-resolved 服务正在占用该端口。脚本会尝试自动解决这个问题，但如果失败，您可以：

1. 使用非默认端口：`sudo ./setup.sh --port 5353`
2. 手动停止 systemd-resolved 服务：`sudo systemctl stop systemd-resolved`

## 贡献

欢迎提交 Issues 和 Pull Requests 到 [GitHub 仓库](https://github.com/HanStyle-Dev/sh)。

## 许可证

[MIT License](LICENSE)
