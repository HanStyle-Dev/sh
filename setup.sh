#!/bin/sh
set -e

DEBUG_MODE=false

info() {
    if [ "$DEBUG_MODE" = true ]; then
        printf "\033[0;34m[INFO]\033[0m %s\n" "$1"
    fi
}

success() {
    printf "\033[0;32m[SUCCESS]\033[0m %s\n" "$1"
}

warning() {
    printf "\033[0;33m[WARNING]\033[0m %s\n" "$1"
}

error() {
    printf "\033[0;31m[ERROR]\033[0m %s\n" "$1"
}

debug() {
    if [ "$DEBUG_MODE" = true ]; then
        printf "\033[0;34m[DEBUG]\033[0m %s\n" "$1"
    fi
}

handle_error() {
    error "脚本执行出错"
    exit 1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用root权限运行此脚本"
        exit 1
    fi
}

install_package() {
    local package_name="$1"
    local package_map="$2"

    info "正在安装 $package_name..."

    local package=""
    case $OS in
        ubuntu|debian)
            package=$(echo "$package_map" | grep -oP "ubuntu|debian=\K[^,]*")
            apt-get update
            apt-get install -y $package
            ;;
        centos|rhel|fedora)
            package=$(echo "$package_map" | grep -oP "centos|rhel|fedora=\K[^,]*")
            yum install -y $package
            ;;
        alpine)
            package=$(echo "$package_map" | grep -oP "alpine=\K[^,]*")
            apk add $package
            ;;
        *)
            error "不支持的操作系统: $OS，无法自动安装 $package_name"
            return 1
            ;;
    esac

    return 0
}

check_and_install_command() {
    local command_name="$1"
    local package_map="$2"
    local required="$3"

    if ! command -v "$command_name" > /dev/null 2>&1; then
        warning "$command_name 命令不存在，尝试安装..."

        if ! install_package "$command_name" "$package_map"; then
            if [ "$required" = "true" ]; then
                error "无法安装 $command_name 命令，请手动安装"
                return 1
            else
                warning "无法安装 $command_name 命令，但这不是必需的"
                return 0
            fi
        fi

        if ! command -v "$command_name" > /dev/null 2>&1; then
            if [ "$required" = "true" ]; then
                error "安装后仍无法找到 $command_name 命令，请手动安装"
                return 1
            else
                warning "安装后仍无法找到 $command_name 命令，但这不是必需的"
                return 0
            fi
        fi
    fi

    return 0
}

check_required_commands() {
    debug "检查必要的命令是否存在..."

    local ss_packages="ubuntu=iproute2,debian=iproute2,centos=iproute,rhel=iproute,fedora=iproute,alpine=iproute2"
    local dig_packages="ubuntu=dnsutils,debian=dnsutils,centos=bind-utils,rhel=bind-utils,fedora=bind-utils,alpine=bind-tools"
    local nslookup_packages="$dig_packages"

    check_and_install_command "ss" "$ss_packages" "true" || exit 1
    check_and_install_command "dig" "$dig_packages" "false"

    if ! command -v dig > /dev/null 2>&1; then
        check_and_install_command "nslookup" "$nslookup_packages" "true" || exit 1
    else
        check_and_install_command "nslookup" "$nslookup_packages" "false"
    fi

    debug "所有必要的命令都已存在"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        debug "检测到操作系统: $OS $VERSION"
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VERSION=$(lsb_release -sr)
        debug "检测到操作系统: $OS $VERSION"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VERSION=$DISTRIB_RELEASE
        debug "检测到操作系统: $OS $VERSION"
    elif [ -f /etc/debian_version ]; then
        OS=debian
        VERSION=$(cat /etc/debian_version)
        debug "检测到操作系统: $OS $VERSION"
    elif [ -f /etc/redhat-release ]; then
        OS=centos
        VERSION=$(cat /etc/redhat-release | sed 's/.*release \([0-9]\).*/\1/')
        debug "检测到操作系统: $OS $VERSION"
    elif [ -f /etc/alpine-release ]; then
        OS=alpine
        VERSION=$(cat /etc/alpine-release)
        debug "检测到操作系统: $OS $VERSION"
    else
        error "无法检测操作系统类型"
        exit 1
    fi
}

get_command_version() {
    local command="$1"
    local version_cmd="$2"

    if command -v "$command" > /dev/null 2>&1; then
        local version
        version=$(eval "$version_cmd" 2>/dev/null || echo "未知")
        echo "$version"
        return 0
    fi
    return 1
}

check_docker() {
    debug "检查Docker是否已安装..."
    local version

    if version=$(get_command_version "docker" "docker --version | cut -d ' ' -f3 | tr -d ','"); then
        debug "Docker已安装，版本: $version"
        DOCKER_VERSION="$version"
        DOCKER_INSTALLED=true
    else
        debug "Docker未安装"
        DOCKER_INSTALLED=false
    fi
}

check_docker_compose() {
    debug "检查Docker Compose是否已安装..."
    local version

    if version=$(get_command_version "docker-compose" "docker-compose --version | cut -d ' ' -f3 | tr -d ','"); then
        debug "Docker Compose已安装，版本: $version"
        COMPOSE_VERSION="$version"
        COMPOSE_INSTALLED=true
    elif version=$(get_command_version "docker" "docker compose version 2>/dev/null | head -n 1 | cut -d ' ' -f4"); then
        debug "Docker Compose插件已安装，版本: $version"
        COMPOSE_VERSION="$version"
        COMPOSE_INSTALLED=true
        COMPOSE_IS_PLUGIN=true
    else
        debug "Docker Compose未安装"
        COMPOSE_INSTALLED=false
    fi
}

install_docker() {
    if [ "$DOCKER_INSTALLED" = true ] && [ "$COMPOSE_INSTALLED" = true ]; then
        debug "Docker和Docker Compose已安装，跳过安装步骤"
        return
    fi

    printf "正在安装Docker和Docker Compose...\n"

    case $OS in
        ubuntu|debian|centos|rhel|fedora)
            debug "使用阿里云镜像安装Docker和Docker Compose..."
            curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun --compose

            if [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
                systemctl enable docker
                systemctl start docker
            fi
            ;;
        alpine)
            debug "在Alpine Linux上安装Docker和Docker Compose..."
            apk update
            apk add docker docker-compose
            rc-update add docker boot
            service docker start
            ;;
        *)
            error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac

    if command -v docker > /dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version | cut -d ' ' -f3 | tr -d ',')
        success "Docker安装成功，版本: $DOCKER_VERSION"
        DOCKER_INSTALLED=true
    else
        error "Docker安装失败"
        exit 1
    fi

    if command -v docker-compose > /dev/null 2>&1 || command -v docker > /dev/null 2>&1 && docker compose --help > /dev/null 2>&1; then
        if command -v docker-compose > /dev/null 2>&1; then
            COMPOSE_VERSION=$(docker-compose --version | cut -d ' ' -f3 | tr -d ',')
        else
            COMPOSE_VERSION=$(docker compose version | head -n 1 | cut -d ' ' -f4)
        fi
        success "Docker Compose安装成功，版本: $COMPOSE_VERSION"
        COMPOSE_INSTALLED=true
    else
        warning "Docker Compose可能未通过get.docker.com脚本安装成功，尝试手动安装..."
        case $OS in
            ubuntu|debian|centos|rhel|fedora)
                debug "安装Docker Compose插件..."
                mkdir -p /usr/local/lib/docker/cli-plugins
                curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
                chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
                ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
                ;;
            alpine)
                debug "在Alpine Linux上安装Docker Compose..."
                apk add docker-compose
                ;;
        esac

        if command -v docker-compose > /dev/null 2>&1 || command -v docker > /dev/null 2>&1 && docker compose --help > /dev/null 2>&1; then
            if command -v docker-compose > /dev/null 2>&1; then
                COMPOSE_VERSION=$(docker-compose --version | cut -d ' ' -f3 | tr -d ',')
            else
                COMPOSE_VERSION=$(docker compose version | head -n 1 | cut -d ' ' -f4)
            fi
            success "Docker Compose安装成功，版本: $COMPOSE_VERSION"
            COMPOSE_INSTALLED=true
        else
            error "Docker Compose安装失败"
            exit 1
        fi
    fi
}

install_docker_compose() {
    debug "Docker Compose的安装已在Docker安装过程中完成"
}

generate_docker_compose() {
    debug "生成docker-compose.yaml文件..."
    cat > docker-compose.yaml << 'EOF'
services:
  unbound:
    image: nodecloud/unbound:latest
    container_name: unbound
    ports:
      - "53:53/udp"
      - "53:53/tcp"
    restart: always
    privileged: true
    depends_on:
      - redis
    logging:
      driver: json-file
      options:
        max-size: "128m"
        max-file: "3"
    mem_limit: 512m
    cpus: 0.5
    tmpfs:
      - /tmp:size=64m
    healthcheck:
      test: ["CMD", "nslookup", "google.com", "127.0.0.1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  redis:
    image: redis:alpine
    container_name: redis
    command: redis-server --save 43200 1 7200 100 --loglevel warning --rdbchecksum no --io-threads 4 --io-threads-do-reads yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - "redis-data:/data"
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "128m"
        max-file: "3"
    mem_limit: 384m
    cpus: 0.5
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  homebox:
    image: xgheaven/homebox
    ports:
      - 80:3300
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "128m"
        max-file: "3"
    mem_limit: 256m
    cpus: 0.3
    tmpfs:
      - /tmp:size=64m

  uptime:
    image: louislam/uptime-kuma
    ports:
      - 8080:3001
    volumes:
      - "uptime-kuma:/app/data"
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "128m"
        max-file: "3"
    mem_limit: 512m
    cpus: 0.5
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3001"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  iperf3:
    image: networkstatic/iperf3
    ports:
      - "5201:5201/tcp"
      - "5201:5201/udp"
    command: -s -V -d -p 5201
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "128m"
        max-file: "3"
    mem_limit: 128m
    cpus: 0.2

volumes:
  redis-data:
    driver: local
  uptime-kuma:
    driver: local
EOF
    success "docker-compose.yaml文件生成成功"
}

get_docker_compose_cmd() {
    if [ -n "${DOCKER_COMPOSE_CMD:-}" ]; then
        echo "$DOCKER_COMPOSE_CMD"
        return
    fi

    if [ "${COMPOSE_IS_PLUGIN:-false}" = true ] || ! command -v docker-compose > /dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        DOCKER_COMPOSE_CMD="docker-compose"
    fi

    echo "$DOCKER_COMPOSE_CMD"
}

docker_compose_exec() {
    local cmd="$1"
    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    debug "执行: $compose_cmd $cmd"
    $compose_cmd $cmd
    return $?
}

check_service_health() {
    local service_name="$1"
    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    if [ "$($compose_cmd ps $service_name | grep -c "Up")" -gt 0 ]; then
        debug "$service_name 服务运行正常"
        return 0
    else
        error "$service_name 服务运行异常"
        return 1
    fi
}

test_dns_resolution() {
    local host_ip="$1"
    local max_retries=5
    local retry_interval=10
    local retry_count=0
    local dns_test_success=false

    debug "测试DNS解析..."

    while [ $retry_count -lt $max_retries ]; do
        if timeout 5 dig @$host_ip google.com +short > /dev/null 2>&1 ||
           timeout 5 nslookup google.com $host_ip > /dev/null 2>&1; then
            debug "DNS解析测试成功"
            dns_test_success=true
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                debug "DNS解析测试失败，等待 $retry_interval 秒后重试 ($retry_count/$max_retries)..."
                sleep $retry_interval
            fi
        fi
    done

    if [ "$dns_test_success" = false ]; then
        warning "DNS解析测试失败，但这可能是因为服务刚刚启动，需要更多时间初始化"
        warning "您可以稍后手动测试: dig @$host_ip google.com 或 nslookup google.com $host_ip"
        return 1
    fi

    return 0
}

start_services() {
    printf "正在启动服务...\n"
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')

    debug "拉取所需的Docker镜像..."
    if ! docker_compose_exec "pull"; then
        error "拉取Docker镜像失败"
        return 1
    fi

    debug "启动服务..."
    if ! docker_compose_exec "up -d"; then
        error "启动Docker服务失败"
        return 1
    fi

    debug "等待服务启动（30秒）..."
    sleep 30

    if [ "$DEBUG_MODE" = true ]; then
        docker_compose_exec "ps"
    fi

    debug "检查各个服务的健康状态..."
    check_service_health "redis"

    if check_service_health "unbound"; then
        test_dns_resolution "127.0.0.1"
    fi

    check_service_health "homebox"
    check_service_health "uptime"
    check_service_health "iperf3"

    printf "\n"
    info "服务访问信息:"
    printf "%s\n" "------------------------------------"
    printf "Homebox: http://%s:80\n" "$host_ip"
    printf "Uptime Kuma: http://%s:8080\n" "$host_ip"
    printf "DNS服务: %s:53\n" "$host_ip"
    printf "iperf3服务: %s:5201\n" "$host_ip"
    printf "%s\n" "------------------------------------"
}

check_port_53() {
    debug "检查UDP 53端口是否被占用..."

    if ss -ulpn | grep -q ":53 "; then
        warning "UDP 53端口已被占用"

        if systemctl is-active systemd-resolved > /dev/null 2>&1; then
            debug "检测到systemd-resolved服务正在运行并可能占用53端口"

            if ss -ulpn | grep ":53 " | grep -q "systemd-resolve"; then
                debug "确认是systemd-resolved服务占用了53端口"
            fi

            if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
                debug "在Ubuntu/Debian系统上，systemd-resolved服务通常会占用53端口"
                echo "正在修改systemd-resolved配置以释放53端口..."

                cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak

                if grep -q "^#DNSStubListener=" /etc/systemd/resolved.conf; then
                    sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                elif grep -q "^DNSStubListener=" /etc/systemd/resolved.conf; then
                    sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                else
                    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
                fi

                systemctl restart systemd-resolved

                sleep 2
                if ! ss -ulpn | grep -q ":53 "; then
                    success "成功释放53端口"
                else
                    error "无法释放53端口，请手动检查并解决"
                    read -p "是否继续安装？(y/n): " continue_choice
                    if [ "$continue_choice" != "y" ] && [ "$continue_choice" != "Y" ]; then
                        exit 1
                    fi
                fi
            else
                warning "检测到非Ubuntu/Debian系统，请手动释放53端口"
                read -p "是否继续安装？(y/n): " continue_choice
                if [ "$continue_choice" != "y" ] && [ "$continue_choice" != "Y" ]; then
                    exit 1
                fi
            fi
        else
            warning "53端口被其他服务占用，请手动检查并释放该端口"
            echo "占用53端口的进程信息:"
            ss -ulpn | grep ":53 "

            read -p "是否继续安装？(y/n): " continue_choice
            if [ "$continue_choice" != "y" ] && [ "$continue_choice" != "Y" ]; then
                exit 1
            fi
        fi
    else
        debug "UDP 53端口未被占用，可以正常使用"
    fi
}

show_usage() {
    cat << EOF
使用方法: $0 [选项]

选项:
  -h, --help     显示此帮助信息
  -s, --skip-docker  跳过Docker安装（如果已安装）
  -f, --force    强制重新安装所有组件
  -p, --port PORT    指定DNS服务使用的端口（默认: 53）
  -d, --debug    显示详细调试信息
  -c, --clean    清理Docker Compose安装的容器并删除配置文件

示例:
  $0              # 标准安装
  $0 --skip-docker   # 跳过Docker安装
  $0 --port 5353     # 使用5353端口代替53端口
  $0 --debug     # 显示详细调试信息
  $0 --clean     # 清理已安装的容器和配置
EOF
}

parse_args() {
    SKIP_DOCKER=false
    FORCE_INSTALL=false
    DNS_PORT=53
    CLEAN_MODE=false

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -s|--skip-docker)
                SKIP_DOCKER=true
                shift
                ;;
            -f|--force)
                FORCE_INSTALL=true
                shift
                ;;
            -p|--port)
                DNS_PORT="$2"
                shift 2
                ;;
            -d|--debug)
                DEBUG_MODE=true
                shift
                ;;
            -c|--clean)
                CLEAN_MODE=true
                shift
                ;;
            *)
                warning "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if ! echo "$DNS_PORT" | grep -q '^[0-9]\+$' || [ "$DNS_PORT" -lt 1 ] || [ "$DNS_PORT" -gt 65535 ]; then
        error "无效的端口号: $DNS_PORT"
        exit 1
    fi

    if [ "$DNS_PORT" != "53" ]; then
        info "将使用端口 $DNS_PORT 代替默认的53端口"
    fi

    if [ "$DEBUG_MODE" = true ]; then
        debug "调试模式已开启"
        debug "参数设置: SKIP_DOCKER=$SKIP_DOCKER, FORCE_INSTALL=$FORCE_INSTALL, DNS_PORT=$DNS_PORT, CLEAN_MODE=$CLEAN_MODE"
    fi

    export SKIP_DOCKER FORCE_INSTALL DNS_PORT DEBUG_MODE CLEAN_MODE
}

cleanup() {
    debug "执行清理操作..."
}

clean_services() {
    printf "正在清理Docker Compose服务和配置文件...\n"

    if [ -f "docker-compose.yaml" ]; then
        debug "找到docker-compose.yaml文件"

        if command -v docker > /dev/null 2>&1; then
            if command -v docker-compose > /dev/null 2>&1 || command -v docker > /dev/null 2>&1 && docker compose --help > /dev/null 2>&1; then
                debug "停止并删除Docker容器..."
                if ! docker_compose_exec "down -v"; then
                    warning "停止容器时出现问题，尝试强制删除..."
                    docker_compose_exec "rm -f"
                fi

                success "已停止并删除所有容器"
            else
                warning "未找到Docker Compose，无法停止容器"
            fi
        else
            warning "未找到Docker，无法停止容器"
        fi

        debug "删除docker-compose.yaml文件..."
        rm -f docker-compose.yaml
        success "已删除docker-compose.yaml文件"
    else
        warning "当前目录下未找到docker-compose.yaml文件"
    fi
}

check_compose_file() {
    if [ -f "docker-compose.yaml" ]; then
        debug "当前目录下已存在docker-compose.yaml文件"
        if [ "$FORCE_INSTALL" = true ]; then
            debug "由于指定了强制安装，将覆盖现有文件"
            return 0
        else
            warning "当前目录下已存在docker-compose.yaml文件"
            read -p "是否覆盖现有文件？(y/n): " overwrite_choice
            if [ "$overwrite_choice" = "y" ] || [ "$overwrite_choice" = "Y" ]; then
                debug "用户选择覆盖现有文件"
                return 0
            else
                debug "用户选择不覆盖现有文件"
                return 1
            fi
        fi
    fi
    return 0
}

main() {
    parse_args "$@"
    trap cleanup 0

    if [ "$DEBUG_MODE" = true ]; then
        echo "======================================"
        echo "Docker 和 Docker Compose 安装脚本"
        echo "======================================"
        echo "调试模式已开启"
        echo "======================================"
    else
        echo "Docker 和 Docker Compose 安装脚本"
    fi

    if [ "$CLEAN_MODE" = true ]; then
        clean_services
        printf "\n"
        success "清理操作已完成！"
        exit 0
    fi

    check_root
    detect_os
    check_required_commands

    if [ "$SKIP_DOCKER" = true ] && [ "$FORCE_INSTALL" = false ]; then
        debug "跳过Docker安装（根据用户参数）"
    else
        check_docker
        check_docker_compose

        if [ "$FORCE_INSTALL" = true ] || [ "$DOCKER_INSTALLED" = false ] || [ "$COMPOSE_INSTALLED" = false ]; then
            install_docker
        fi
    fi

    check_port_53

    if ! check_compose_file; then
        echo ""
        info "安装已取消"
        exit 0
    fi

    generate_docker_compose

    if [ "$DNS_PORT" != "53" ]; then
        info "修改docker-compose.yaml以使用端口 $DNS_PORT"
        sed -i "s/- \"53:53\/udp\"/- \"$DNS_PORT:53\/udp\"/" docker-compose.yaml
        sed -i "s/- \"53:53\/tcp\"/- \"$DNS_PORT:53\/tcp\"/" docker-compose.yaml
    fi

    start_services

    printf "\n"
    success "所有操作已完成！"
}

main "$@"
