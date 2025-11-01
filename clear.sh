#!/bin/bash

##############################################################################
# 终极优化版用户清除脚本 (v4.0)
# 
# 优化内容：
#   1. 保留系统服务用户和指定用户的账号
#   2. 删除普通用户的账号
#   3. 在最后彻底清理所有非root进程（包括保留用户的进程）
#   4. 确保系统只剩root进程运行
#
# 用户分类：
#   - root: 完全不动
#   - 系统服务用户: 保留账号，杀进程
#   - 保留用户(如ubuntu): 保留账号，杀进程
#   - 普通用户: 删除账号，杀进程
#
##############################################################################

set -Eeuo pipefail

LOG_FILE="/dev/null"
LOCK_FILE="/var/run/clear-users.lock"
HAS_SYSTEMCTL=false
HAS_LOGINCTL=false
HAS_DPKG=false
HAS_APT_GET=false
HAS_APT_MARK=false
HAS_FLOCK=false

trap 'print_error "命令失败: ${BASH_COMMAND:-?} (行: ${LINENO})"; exit 1' ERR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置参数
KEEP_USERS="root ubuntu"
REMOVE_USERS=false
DRY_RUN=false
BACKUP=false
BACKUP_DIR="/root/user_backup_$(date +%Y%m%d_%H%M%S)"
KILL_ALL_NON_ROOT=false  # 默认保持安全，需显式启用彻底清理
SAFE_REMOTE=false        # 远程安全模式：保护当前会话与网络
PROTECT_SESSIONS=false   # 是否保护当前会话/TTY/sshd
PROTECT_NETWORK=false    # 是否保留关键网络服务
PURGE_CONTAINERS=false   # 是否卸载容器/编排组件及附加服务
FORCE=false              # 是否跳过交互确认

UID_MIN=1000
NOLOGIN_SHELL="/usr/sbin/nologin"
DELETE_USER_CMD=""
DELETE_USER_ARGS=()
DELETED_USER_COUNTER=0

declare -A PRESERVED_USER_SET=()
declare -a PRESERVED_USERS_LIST=()
declare -a DELETE_USERS_LIST=()
declare -A SYSTEM_SERVICE_USER_SET=()
declare -A SERVICE_USER_CACHE=()
declare -a NON_ROOT_SERVICE_UNITS=()
declare -a PROTECTED_PIDS=()
SERVICE_USER_CACHE_READY=false

# 系统服务用户黑名单 - 保留账号但杀进程
SYSTEM_USERS=(
    "nobody"
    "systemd-network"
    "systemd-resolve"
    "systemd-timesync"
    "messagebus"
    "syslog"
    "uuidd"
    "dbus"
    "_apt"
    "daemon"
    "bin"
    "sys"
    "sync"
    "games"
    "man"
    "lp"
    "mail"
    "news"
    "uucp"
    "proxy"
    "www-data"
    "backup"
    "list"
    "irc"
    "gnats"
    "systemd-coredump"
    "node_exporter"
    "prometheus"
    "grafana"
    "mongodb"
    "mysql"
    "postgres"
    "redis"
    "nginx"
    "docker"
)

# 常见服务用户模式
SERVICE_USER_PATTERNS=(
    "^_.*"
    ".*-service$"
    ".*_exporter$"
    "^systemd-.*"
)

# 日志设置
detect_capabilities() {
    HAS_SYSTEMCTL=false
    HAS_LOGINCTL=false
    HAS_DPKG=false
    HAS_APT_GET=false
    HAS_APT_MARK=false
    HAS_FLOCK=false

    if command -v systemctl >/dev/null 2>&1; then
        HAS_SYSTEMCTL=true
    fi

    if command -v loginctl >/dev/null 2>&1; then
        HAS_LOGINCTL=true
    fi

    if command -v dpkg >/dev/null 2>&1; then
        HAS_DPKG=true
    fi

    if command -v apt-get >/dev/null 2>&1; then
        HAS_APT_GET=true
    fi

    if command -v apt-mark >/dev/null 2>&1; then
        HAS_APT_MARK=true
    fi

    if command -v flock >/dev/null 2>&1; then
        HAS_FLOCK=true
    fi
}

# 日志设置
detect_uid_min() {
    local candidate
    candidate=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null | tail -n1)
    if [[ "$candidate" =~ ^[0-9]+$ ]]; then
        UID_MIN=$candidate
    fi
}

resolve_nologin_shell() {
    local candidate
    candidate=$(command -v nologin 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        echo "$candidate"
        return
    fi

    for candidate in "/usr/sbin/nologin" "/sbin/nologin" "/usr/bin/nologin"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done

    echo "/usr/sbin/nologin"
}

select_delete_user_command() {
    if command -v deluser >/dev/null 2>&1; then
        DELETE_USER_CMD=$(command -v deluser)
        DELETE_USER_ARGS=(--remove-home)
        return 0
    fi

    if command -v userdel >/dev/null 2>&1; then
        DELETE_USER_CMD=$(command -v userdel)
        DELETE_USER_ARGS=(-r)
        return 0
    fi

    print_error "系统缺少 deluser 或 userdel 命令，无法删除账号"
    return 1
}

ensure_systemd_metadata() {
    if [ "$SERVICE_USER_CACHE_READY" = true ]; then
        return 0
    fi

    SERVICE_USER_CACHE_READY=true

    if [ "$HAS_SYSTEMCTL" != true ]; then
        return 0
    fi

    local services=()
    mapfile -t services < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}') || true

    declare -A seen_service=()

    local svc user
    for svc in "${services[@]}"; do
        [ -n "$svc" ] || continue
        if [ -n "${seen_service[$svc]+x}" ]; then
            continue
        fi

        user=$(systemctl show -p User --value "$svc" 2>/dev/null | tr -d '\n')
        if [ -n "$user" ] && [ "$user" != "root" ]; then
            SERVICE_USER_CACHE["$user"]=1
            SYSTEM_SERVICE_USER_SET["$user"]=1
            NON_ROOT_SERVICE_UNITS+=("$svc")
        fi

        seen_service["$svc"]=1
    done
}

add_preserved_user() {
    local user=$1
    [ -n "$user" ] || return 0

    if [ -z "${PRESERVED_USER_SET[$user]+x}" ]; then
        PRESERVED_USER_SET["$user"]=1
        PRESERVED_USERS_LIST+=("$user")
    fi
}

initialize_user_sets() {
    PRESERVED_USERS_LIST=()
    DELETE_USERS_LIST=()
    PRESERVED_USER_SET=()
    SYSTEM_SERVICE_USER_SET=()

    ensure_systemd_metadata

    declare -A keep_user_map=()
    local keep_user
    for keep_user in $KEEP_USERS; do
        [ -n "$keep_user" ] || continue
        keep_user_map["$keep_user"]=1
        add_preserved_user "$keep_user"
    done

    add_preserved_user "root"

    while IFS=: read -r user _ uid _ _ _ _; do
        [ -n "$user" ] || continue

        if [ "$user" = "root" ]; then
            continue
        fi

        if [ -n "${keep_user_map[$user]+x}" ]; then
            add_preserved_user "$user"
            continue
        fi

        if is_system_service_user "$user"; then
            add_preserved_user "$user"
            continue
        fi

        if [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge "$UID_MIN" ]; then
            DELETE_USERS_LIST+=("$user")
        else
            add_preserved_user "$user"
        fi
    done < <(getent passwd)

    if [ ${#PRESERVED_USERS_LIST[@]} -gt 0 ]; then
        mapfile -t PRESERVED_USERS_LIST < <(printf "%s\n" "${PRESERVED_USERS_LIST[@]}" | sort -u)
    fi

    if [ ${#DELETE_USERS_LIST[@]} -gt 0 ]; then
        mapfile -t DELETE_USERS_LIST < <(printf "%s\n" "${DELETE_USERS_LIST[@]}" | sort -u)
    fi
}

refresh_user_state() {
    initialize_user_sets
}

setup_logging() {
    for log_dir in "/tmp" "$HOME" "."; do
        if [ -w "$log_dir" ]; then
            LOG_FILE="${log_dir}/cleanup_users_$(date +%s).log"
            if touch "$LOG_FILE" 2>/dev/null; then
                return 0
            fi
        fi
    done
    LOG_FILE="/dev/null"
}

log() {
    local level=$1
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

acquire_lock() {
    if [ "$HAS_FLOCK" != true ]; then
        print_warning "系统缺少 flock 命令，跳过并发保护"
        return 0
    fi

    if ! exec 9>"$LOCK_FILE" 2>/dev/null; then
        print_warning "无法创建或写入锁文件 $LOCK_FILE，跳过并发保护"
        return 0
    fi

    if ! flock -n 9; then
        print_error "已有实例在运行（锁文件: $LOCK_FILE）"
        exit 1
    fi

    return 0
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO" "$1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    log "SUCCESS" "$1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING" "$1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR" "$1"
}

print_progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $1"
}

collect_protected_pids() {
    PROTECTED_PIDS=()

    if [ "$PROTECT_SESSIONS" != true ]; then
        return
    fi

    local pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        PROTECTED_PIDS+=("$pid")
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$pid" ] || break
    done

    local tty
    tty=$(ps -p $$ -o tty= | tr -d ' ')
    if [ -n "$tty" ] && [ "$tty" != "?" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            PROTECTED_PIDS+=("$pid")
        done < <(ps -t "$tty" -o pid= 2>/dev/null | tr -d ' ')
    fi

    if [ -n "${SSH_CONNECTION:-}" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            PROTECTED_PIDS+=("$pid")
        done < <(pgrep -x sshd 2>/dev/null || true)
    fi

    if [ ${#PROTECTED_PIDS[@]} -gt 0 ]; then
        mapfile -t PROTECTED_PIDS < <(printf "%s\n" "${PROTECTED_PIDS[@]}" | awk 'NF' | sort -u)
    fi
}

is_pid_protected() {
    local target=$1
    if [ -z "$target" ] || [ ${#PROTECTED_PIDS[@]} -eq 0 ]; then
        return 1
    fi

    local protected_pid
    for protected_pid in "${PROTECTED_PIDS[@]}"; do
        if [ "$protected_pid" = "$target" ]; then
            return 0
        fi
    done

    return 1
}

filter_protected_pid_stream() {
    local pid
    while read -r pid; do
        [ -n "$pid" ] || continue
        if ! is_pid_protected "$pid"; then
            echo "$pid"
        fi
    done
}

forcefully_cleanup_user_processes() {
    local user=$1
    [ -n "$user" ] || return 0

    print_warning "强制终止用户 $user 的剩余会话/进程"

    if [ "$HAS_LOGINCTL" = true ]; then
        loginctl kill-user "$user" 2>/dev/null || true
    fi

    pkill -TERM -u "$user" 2>/dev/null || true
    sleep 1
    pkill -KILL -u "$user" 2>/dev/null || true

    local uid
    uid=$(id -u "$user" 2>/dev/null || true)
    if [ -n "$uid" ] && [ "$HAS_SYSTEMCTL" = true ]; then
        systemctl kill "user@${uid}.service" --kill-who=all 2>/dev/null || true
        systemctl stop "user@${uid}.service" --no-block 2>/dev/null || true
    fi

    return 0
}

is_package_installed() {
    local package=$1
    if [ "$HAS_DPKG" != true ]; then
        return 1
    fi

    dpkg -s "$package" >/dev/null 2>&1
}

join_by_space() {
    local IFS=' '
    echo "$*"
}

service_exists() {
    local service=$1

    if [ "$HAS_SYSTEMCTL" != true ]; then
        return 1
    fi

    if systemctl list-unit-files "${service}.service" --no-legend >/dev/null 2>&1; then
        return 0
    fi

    if systemctl status "${service}.service" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

stop_service_if_exists() {
    local service=$1

    if [ "$HAS_SYSTEMCTL" != true ]; then
        return 0
    fi

    if ! service_exists "$service"; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] systemctl stop $service"
        print_info "[DRY-RUN] systemctl disable $service"
        return 0
    fi

    print_info "停止服务: $service"
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
    return 0
}

stop_container_services() {
    local services=(k3s k3s-agent docker containerd)
    local result=0

    local service
    for service in "${services[@]}"; do
        stop_service_if_exists "$service" || result=1
    done

    return "$result"
}

kill_processes_by_pattern() {
    local pattern=$1
    local description=$2

    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)

    if [ -z "$pids" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] pkill -TERM -f '$pattern'"
        print_info "[DRY-RUN] pkill -KILL -f '$pattern'"
        return 0
    fi

    print_warning "终止残留进程: $description"
    pkill -TERM -f "$pattern" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$pattern" 2>/dev/null || true

    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        print_warning "$description 仍有残留进程: $pids"
        return 1
    fi

    return 0
}

cleanup_container_processes() {
    local result=0

    kill_processes_by_pattern 'containerd-shim' 'containerd-shim 进程' || result=1
    kill_processes_by_pattern 'containerd( |$)' 'containerd 主进程' || result=1
    kill_processes_by_pattern 'dockerd' 'dockerd 进程' || result=1

    return "$result"
}

purge_tailscale_stack() {
    local result=0
    local packages=(tailscale tailscale-unstable)
    local state_paths=(/var/lib/tailscale /var/cache/tailscale /run/tailscale)

    stop_service_if_exists "tailscaled" || result=1
    kill_processes_by_pattern 'tailscaled' 'tailscaled 守护进程' || result=1

    unhold_packages_if_needed "Tailscale" "${packages[@]}" || result=1
    purge_packages_if_installed "Tailscale" "${packages[@]}" || result=1

    local path
    for path in "${state_paths[@]}"; do
        if [ -e "$path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY-RUN] rm -rf $path"
            else
                rm -rf "$path" 2>/dev/null || true
            fi
        fi
    done

    return "$result"
}

cleanup_skypilot_stack() {
    local result=0
    local conda_env_path="/root/miniconda3/envs/skypilot"
    local state_dir="/root/.skypilot"
    local conda_bin="${CONDA_EXE:-}"
    local sky_cmd=""

    kill_processes_by_pattern 'sky.server.server' 'SkyPilot API Server' || result=1
    kill_processes_by_pattern 'multiprocessing.resource_tracker' 'SkyPilot 资源追踪进程' || result=1
    kill_processes_by_pattern 'SkyPilot:executor' 'SkyPilot executor 进程' || result=1
    kill_processes_by_pattern 'ray::' 'Ray 分布式进程' || result=1

    if [ -z "$conda_bin" ] && [ -x "/root/miniconda3/bin/conda" ]; then
        conda_bin="/root/miniconda3/bin/conda"
    fi

    sky_cmd=$(command -v sky 2>/dev/null || true)
    if [ -n "$sky_cmd" ]; then
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] sky --uninstall-shell-completion auto"
        else
            sky --uninstall-shell-completion auto >/dev/null 2>&1 || true
        fi
    fi

    if command -v ray >/dev/null 2>&1; then
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] ray stop --force"
        else
            ray stop --force >/dev/null 2>&1 || true
        fi
    fi

    if [ -d "$conda_env_path" ]; then
        if [ "$DRY_RUN" = true ]; then
            if [ -n "$conda_bin" ]; then
                print_info "[DRY-RUN] $conda_bin env remove -y -n skypilot"
            else
                print_info "[DRY-RUN] rm -rf $conda_env_path"
            fi
        else
            if [ -n "$conda_bin" ]; then
                "$conda_bin" env remove -y -n skypilot 2>/dev/null || rm -rf "$conda_env_path" 2>/dev/null || true
            else
                rm -rf "$conda_env_path" 2>/dev/null || true
            fi
        fi
    fi

    local python_candidates=()
    if command -v python3 >/dev/null 2>&1; then
        python_candidates+=("python3")
    fi
    if command -v python >/dev/null 2>&1; then
        python_candidates+=("python")
    fi
    if [ -x "/root/miniconda3/bin/python" ]; then
        python_candidates+=("/root/miniconda3/bin/python")
    fi

    local pkg
    local py
    local packages=(skypilot skypilot-nightly)

    for py in "${python_candidates[@]}"; do
        if ! "$py" -m pip --version >/dev/null 2>&1; then
            continue
        fi
        for pkg in "${packages[@]}"; do
            if "$py" -m pip show "$pkg" >/dev/null 2>&1; then
                if [ "$DRY_RUN" = true ]; then
                    print_info "[DRY-RUN] $py -m pip uninstall -y $pkg"
                else
                    "$py" -m pip uninstall -y "$pkg" >/dev/null 2>&1 || result=1
                fi
            fi
        done
    done

    local cleanup_paths=(
        "$state_dir"
        "/root/.sky"
        "/root/.config/skypilot"
        "/root/.cache/skypilot"
        "/root/.local/state/skypilot"
        "/root/sky_workdir"
    )

    local path
    for path in "${cleanup_paths[@]}"; do
        if [ -e "$path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY-RUN] rm -rf $path"
            else
                rm -rf "$path" 2>/dev/null || true
            fi
        fi
    done

    return "$result"
}

cleanup_csi_sidecars() {
    local result=0
    local plugin_paths=(
        /var/lib/kubelet/plugins/ru.yandex.s3.csi
        /var/lib/kubelet/plugins_registry/ru.yandex.s3.csi
    )

    kill_processes_by_pattern 'csi-node-driver-registrar' 'Kubernetes CSI node-driver-registrar' || result=1
    kill_processes_by_pattern '/s3driver' 'Yandex S3 CSI 驱动' || result=1

    local path
    for path in "${plugin_paths[@]}"; do
        if [ -e "$path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY-RUN] rm -rf $path"
            else
                rm -rf "$path" 2>/dev/null || true
            fi
        fi
    done

    return "$result"
}

cleanup_coredns_processes() {
    local result=0
    local cleanup_paths=(/etc/coredns /var/lib/coredns /var/run/coredns)

    stop_service_if_exists "coredns" || result=1

    kill_processes_by_pattern '/coredns' 'CoreDNS 守护进程' || result=1

    local path
    for path in "${cleanup_paths[@]}"; do
        if [ -e "$path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY-RUN] rm -rf $path"
            else
                rm -rf "$path" 2>/dev/null || true
            fi
        fi
    done

    return "$result"
}

cleanup_runit_supervision() {
    local result=0
    local runit_dir="/etc/service/enabled"

    if [ -d "$runit_dir" ]; then
        local svc_path
        for svc_path in "$runit_dir"/*; do
            [ -d "$svc_path" ] || continue
            if command -v sv >/dev/null 2>&1; then
                if [ "$DRY_RUN" = true ]; then
                    print_info "[DRY-RUN] sv stop $svc_path"
                    print_info "[DRY-RUN] sv down $svc_path"
                else
                    sv stop "$svc_path" 2>/dev/null || true
                    sv down "$svc_path" 2>/dev/null || true
                fi
            fi
        done

        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] rm -rf $runit_dir"
        else
            rm -rf "$runit_dir" 2>/dev/null || true
        fi
    fi

    stop_service_if_exists "runsvdir" || result=1
    stop_service_if_exists "runsvdir-start" || result=1

    kill_processes_by_pattern 'runsvdir' 'runit runsvdir 守护进程' || result=1
    kill_processes_by_pattern 'coreutils --coreutils-prog-shebang=sleep /usr/bin/sleep infinity' 'runit 占位进程' || result=1

    return "$result"
}

unhold_packages_if_needed() {
    local label=$1
    shift
    local packages=("$@")

    if [ "$HAS_APT_MARK" != true ]; then
        return 0
    fi

    local held_list=()
    mapfile -t held_list < <(apt-mark showhold 2>/dev/null || true)
    if [ ${#held_list[@]} -eq 0 ]; then
        return 0
    fi

    local to_unhold=()
    local pkg held
    for pkg in "${packages[@]}"; do
        for held in "${held_list[@]}"; do
            if [ "$pkg" = "$held" ]; then
                to_unhold+=("$pkg")
                break
            fi
        done
    done

    if [ ${#to_unhold[@]} -eq 0 ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] apt-mark unhold ${to_unhold[*]}"
        return 0
    fi

    print_info "$label: 解除保留标记 (${#to_unhold[@]} 个包)"
    if apt-mark unhold "${to_unhold[@]}"; then
        return 0
    fi

    print_error "$label: 解除保留标记失败"
    return 1
}

purge_packages_if_installed() {
    local label=$1
    shift
    local packages=("$@")
    local to_purge=()

    if [ "$HAS_APT_GET" != true ] || [ "$HAS_DPKG" != true ]; then
        print_info "$label: 系统缺少 apt-get/dpkg，跳过卸载"
        return 0
    fi

    local pkg
    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            to_purge+=("$pkg")
        fi
    done

    if [ ${#to_purge[@]} -eq 0 ]; then
        print_info "$label: 未检测到已安装的目标包"
        return 0
    fi

    if [ "$HAS_APT_MARK" = true ]; then
        if ! unhold_packages_if_needed "$label" "${to_purge[@]}"; then
            return 1
        fi
    else
        print_info "$label: 未检测到 apt-mark，可能存在被 hold 的包需手动解除"
    fi

    local cmd=(apt-get -y --allow-change-held-packages purge "${to_purge[@]}")

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] $(join_by_space "${cmd[@]}")"
        return 0
    fi

    print_info "$label: 开始卸载 (${#to_purge[@]} 个包)"
    # 在稳定目录内执行，避免卸载脚本删除当前工作目录时触发 getcwd 失败
    if (cd / && "${cmd[@]}"); then
        print_success "$label: 已卸载 ${#to_purge[@]} 个包"
        return 0
    fi

    print_error "$label: 卸载失败"
    return 1
}

purge_kubernetes_stack() {
    local kubernetes_packages=(
        kubeadm
        kubelet
        kubectl
        kubernetes-cni
        cri-tools
        etcd-client
        coredns
    )
    purge_packages_if_installed "Kubernetes 工具链" "${kubernetes_packages[@]}"
}

purge_docker_stack() {
    local docker_packages=(
        docker-ce
        docker-ce-cli
        docker-compose-plugin
        docker-buildx-plugin
        docker-ce-rootless-extras
        containerd.io
    )
    purge_packages_if_installed "Docker/Containerd 组件" "${docker_packages[@]}"
}

purge_k3s_installation() {
    local server_uninstall="/usr/local/bin/k3s-uninstall.sh"
    local agent_uninstall="/usr/local/bin/k3s-agent-uninstall.sh"
    local has_k3s=false

    if [ -x "$server_uninstall" ] || [ -x "$agent_uninstall" ] || command -v k3s >/dev/null 2>&1; then
        has_k3s=true
    fi

    if [ "$has_k3s" != true ]; then
        print_info "k3s: 未检测到可卸载的安装"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] systemctl stop k3s"
        print_info "[DRY-RUN] systemctl stop k3s-agent"
        if [ -x "$server_uninstall" ]; then
            print_info "[DRY-RUN] bash $server_uninstall"
        fi
        if [ -x "$agent_uninstall" ]; then
            print_info "[DRY-RUN] bash $agent_uninstall"
        fi
        return 0
    fi

    if [ "$HAS_SYSTEMCTL" = true ]; then
        print_info "k3s: 停止相关服务"
        systemctl stop k3s 2>/dev/null || true
        systemctl stop k3s-agent 2>/dev/null || true
        systemctl disable k3s 2>/dev/null || true
        systemctl disable k3s-agent 2>/dev/null || true
    else
        print_warning "k3s: 系统缺少 systemctl，跳过服务停止"
    fi

    local result=0

    if [ -x "$server_uninstall" ]; then
        print_info "k3s: 执行卸载脚本 $server_uninstall"
        if ! bash "$server_uninstall"; then
            print_warning "k3s: 执行 $server_uninstall 时出现错误"
            result=1
        fi
    fi

    if [ -x "$agent_uninstall" ]; then
        print_info "k3s: 执行卸载脚本 $agent_uninstall"
        if ! bash "$agent_uninstall"; then
            print_warning "k3s: 执行 $agent_uninstall 时出现错误"
            result=1
        fi
    fi

    if [ "$result" -eq 0 ]; then
        print_success "k3s: 卸载流程完成"
    else
        print_warning "k3s: 卸载流程已完成但存在警告"
    fi

    return "$result"
}

purge_container_infrastructure() {
    print_info "========== 容器/编排组件卸载 =========="

    local overall_status=0

    if [ "$HAS_APT_GET" != true ] || [ "$HAS_DPKG" != true ]; then
        print_warning "包管理工具不可用：将仅执行进程与服务清理，跳过软件包卸载"
    fi

    stop_container_services || overall_status=1
    purge_kubernetes_stack || overall_status=1
    purge_docker_stack || overall_status=1
    purge_k3s_installation || overall_status=1
    cleanup_container_processes || overall_status=1
    purge_tailscale_stack || overall_status=1
    cleanup_skypilot_stack || overall_status=1
    cleanup_csi_sidecars || overall_status=1
    cleanup_coredns_processes || overall_status=1
    cleanup_runit_supervision || overall_status=1

    if [ "$overall_status" -eq 0 ]; then
        print_success "容器/编排组件卸载流程完成"
    else
        print_warning "容器/编排组件卸载流程完成（存在警告或失败）"
    fi

    echo ""
    return "$overall_status"
}

show_help() {
    cat << 'EOF'
用法: bash clear.sh [选项]

选项:
    -h, --help              显示此帮助信息
    --keep-users LIST       指定要保留的用户（逗号分隔，默认: root,ubuntu）
    --remove                删除普通用户账户（默认只杀进程）
    --backup                删除前备份用户数据
    --backup-dir DIR        指定备份目录
    --dry-run               模拟运行，显示将要执行的操作
    --safe-remote           启用远程安全模式（保护当前会话与网络服务）
    --full-clean            启用终极清理（会终止所有非root进程）
    --purge-containers      卸载Kubernetes工具链、Docker/Containerd、k3s 及附加网络/调度服务
    --force                 跳过确认提示（危险！）

工作模式:
    1. 系统服务用户 (nobody, node_exporter等): 保留账号，杀进程
    2. 保留用户 (root, ubuntu): 保留账号，杀进程（root进程除外）
    3. 普通用户: 删除账号，杀进程
    4. 最终清理: 确保所有非root进程被终止

示例:
    # 仅杀死所有非root进程（保留所有账号）
    bash clear.sh

    # 杀死进程 + 删除普通用户账号（带备份）
    bash clear.sh --remove --backup

    # 保留额外用户
    bash clear.sh --remove --keep-users "root,ubuntu,admin"

安全提示:
    - root用户和root进程完全不受影响
    - 系统服务用户账号被保留但进程会被终止
    - 保留用户账号被保留但进程会被终止
    - 在启用 --full-clean 时会彻底清理所有非root进程
    - SSH 会话中默认开启安全远程模式；如需强制断线请显式指定 --full-clean
    - 使用 --purge-containers 会卸载容器/编排组件（Kubernetes、Docker、k3s）与相关辅助服务（Tailscale、SkyPilot、runit），可能导致业务中断

EOF
    exit 0
}

parse_arguments() {
    FORCE=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            --keep-users)
                KEEP_USERS="${2//,/ }"
                shift 2
                ;;
            --remove)
                REMOVE_USERS=true
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --safe-remote)
                SAFE_REMOTE=true
                shift
                ;;
            --full-clean)
                KILL_ALL_NON_ROOT=true
                SAFE_REMOTE=false
                PROTECT_SESSIONS=false
                PROTECT_NETWORK=false
                shift
                ;;
            --purge-containers)
                PURGE_CONTAINERS=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            *)
                print_error "未知选项: $1"
                echo ""
                show_help
                ;;
        esac
    done
    
    export FORCE
}

# 检查用户是否是系统服务用户
is_system_service_user() {
    local user=$1

    if [ -z "$user" ]; then
        return 1
    fi

    # root特殊处理
    if [ "$user" = "root" ]; then
        return 0
    fi

    for sys_user in "${SYSTEM_USERS[@]}"; do
        if [ "$user" = "$sys_user" ]; then
            SYSTEM_SERVICE_USER_SET["$user"]=1
            return 0
        fi
    done

    for pattern in "${SERVICE_USER_PATTERNS[@]}"; do
        if [[ "$user" =~ $pattern ]]; then
            SYSTEM_SERVICE_USER_SET["$user"]=1
            return 0
        fi
    done

    if [ -n "${SERVICE_USER_CACHE[$user]+x}" ]; then
        SYSTEM_SERVICE_USER_SET["$user"]=1
        return 0
    fi

    ensure_systemd_metadata

    if [ -n "${SERVICE_USER_CACHE[$user]+x}" ]; then
        SYSTEM_SERVICE_USER_SET["$user"]=1
        return 0
    fi

    return 1
}

# 检查用户是否需要保留账号
is_account_preserved() {
    local user=$1
    
    # root永远保留
    if [ "$user" = "root" ]; then
        return 0
    fi
    
    # 检查保留用户列表
    for keep_user in $KEEP_USERS; do
        if [ "$user" = "$keep_user" ]; then
            return 0
        fi
    done
    
    # 检查系统服务用户
    if is_system_service_user "$user"; then
        return 0
    fi
    
    return 1
}

# 获取要删除账号的用户列表（仅普通用户）
get_users_to_delete() {
    if [ ${#DELETE_USERS_LIST[@]} -eq 0 ]; then
        return 0
    fi

    printf "%s\n" "${DELETE_USERS_LIST[@]}"
}

# 获取所有需要保留账号的用户
get_preserved_users() {
    if [ ${#PRESERVED_USERS_LIST[@]} -eq 0 ]; then
        return 0
    fi

    printf "%s\n" "${PRESERVED_USERS_LIST[@]}"
}

# 显示用户分类
show_user_classification() {
    local preserved_count=${#PRESERVED_USERS_LIST[@]}
    local delete_count=${#DELETE_USERS_LIST[@]}

    echo ""
    print_info "========== 用户分类 =========="
    echo ""

    print_success "Root用户 (完全不动):"
    echo -e "  ${GREEN}✓${NC} root"
    echo ""

    if [ $preserved_count -gt 0 ]; then
        print_success "保留账号的用户 ($preserved_count 个) - 账号保留，进程会被终止:"
        local user
        for user in "${PRESERVED_USERS_LIST[@]}"; do
            [ "$user" = "root" ] && continue
            local procs
            procs=$(ps -u "$user" -o pid= 2>/dev/null | wc -l | tr -d ' ')
            local user_type=""

            if [ -n "${SYSTEM_SERVICE_USER_SET[$user]+x}" ]; then
                user_type="${CYAN}(系统服务)${NC}"
            elif [ -n "${PRESERVED_USER_SET[$user]+x}" ]; then
                user_type="${GREEN}(保留用户)${NC}"
            fi

            echo -e "  ${GREEN}✓${NC} $user (进程: $procs) $user_type"
        done
        echo ""
    fi

    if [ $delete_count -eq 0 ]; then
        print_info "没有要删除账号的普通用户"
        return 1
    fi

    print_warning "要删除账号的普通用户 ($delete_count 个) - 账号删除，进程终止:"
    local index=0
    local user
    for user in "${DELETE_USERS_LIST[@]}"; do
        if [ $index -ge 30 ]; then
            break
        fi
        local procs
        procs=$(ps -u "$user" -o pid= 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${RED}×${NC} $user (进程: $procs)"
        index=$((index + 1))
    done

    if [ $delete_count -gt 30 ]; then
        echo "  ... (还有 $((delete_count - 30)) 个用户)"
    fi

    echo ""
    return 0
}

# 备份用户数据
backup_user_data() {
    if [ "$BACKUP" = false ] || [ "$DRY_RUN" = true ]; then
        return
    fi
    
    print_info "备份用户数据到: $BACKUP_DIR"
    
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        print_error "无法创建备份目录: $BACKUP_DIR"
        return 1
    }
    
    local users=("${DELETE_USERS_LIST[@]}")
    local count=0

    if [ ${#users[@]} -eq 0 ]; then
        print_info "没有普通用户需要备份"
        return 0
    fi

    local user
    for user in "${users[@]}"; do
        local home_dir=$(getent passwd "$user" | cut -d: -f6)
        
        if [ -d "$home_dir" ]; then
            print_progress "备份 $user 的数据..."
            
            tar --numeric-owner --one-file-system --warning=no-file-changed -czf "$BACKUP_DIR/${user}_home.tar.gz" -C "$(dirname "$home_dir")" "$(basename "$home_dir")" 2>/dev/null || {
                print_warning "备份 $user 失败"
                continue
            }
            
            getent passwd "$user" >> "$BACKUP_DIR/passwd.bak"
            getent group "$user" >> "$BACKUP_DIR/group.bak" 2>/dev/null || true
            
            ((count++))
        fi
    done
    
    print_success "已备份 $count 个用户的数据"
    echo ""
}

# 步骤1: 终止用户会话
terminate_sessions() {
    print_info "步骤 1/6: 终止用户会话（跳过保留用户）"

    local users_to_terminate=("${DELETE_USERS_LIST[@]}")

    if [ ${#users_to_terminate[@]} -eq 0 ]; then
        print_info "没有用户需要终止会话"
        echo ""
        return 0
    fi

    local count=0

    local user
    for user in "${users_to_terminate[@]}"; do
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] 将强制终止 $user 的会话/进程"
        else
            forcefully_cleanup_user_processes "$user"
            ((count++))
        fi
    done

    if [ "$DRY_RUN" != true ] && [ $count -gt 0 ]; then
        sleep 1
        print_success "已终止 $count 个用户会话"
    fi
    echo ""
}

# 步骤2: 禁用普通用户登录
disable_user_login() {
    print_info "步骤 2/6: 禁用普通用户登录"
    
    local users=("${DELETE_USERS_LIST[@]}")
    local count=0
    local total=${#users[@]}
    local current=0

    if [ $total -eq 0 ]; then
        print_info "没有普通用户需要禁用登录"
        echo ""
        return 0
    fi

    local user
    for user in "${users[@]}"; do
        ((current++))
        
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] usermod -L -s $NOLOGIN_SHELL $user"
        else
            usermod -L -s "$NOLOGIN_SHELL" "$user" 2>/dev/null && ((count++)) || true
        fi
        
        if [ $((current % 10)) -eq 0 ] || [ $current -eq $total ]; then
            print_progress "进度: $current/$total"
        fi
    done
    
    if [ "$DRY_RUN" != true ] && [ $count -gt 0 ]; then
        print_success "已禁用 $count 个普通用户的登录"
    fi
    echo ""
}

# 步骤3: 终止systemd进程
kill_systemd_processes() {
    print_info "步骤 3/6: 终止所有非root的systemd进程"
    
    ensure_systemd_metadata

    local services_to_stop=("${NON_ROOT_SERVICE_UNITS[@]}")

    if [ "$PROTECT_NETWORK" = true ] && [ ${#services_to_stop[@]} -gt 0 ]; then
        local filtered_services=()
        local svc
        for svc in "${services_to_stop[@]}"; do
            case "$svc" in
                systemd-networkd.service|systemd-resolved.service)
                    continue
                    ;;
            esac
            filtered_services+=("$svc")
        done
        services_to_stop=("${filtered_services[@]}")
    fi

    if [ ${#services_to_stop[@]} -gt 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            local svc
            for svc in "${services_to_stop[@]}"; do
                print_info "[DRY-RUN] systemctl stop $svc"
            done
        elif [ "$HAS_SYSTEMCTL" = true ]; then
            systemctl stop "${services_to_stop[@]}" 2>/dev/null || true
        fi
    fi

    local systemd_pids
    systemd_pids=$(ps -eo user=,pid=,comm= | awk '$1 != "root" && $3 ~ /systemd/{print $2}')

    if [ -z "$systemd_pids" ]; then
        echo ""
        return 0
    fi

    local pid_array=()
    mapfile -t pid_array <<< "$systemd_pids"

    if [ "$PROTECT_SESSIONS" = true ] && [ ${#pid_array[@]} -gt 0 ]; then
        collect_protected_pids
        local filtered=""
        filtered=$(printf "%s\n" "${pid_array[@]}" | filter_protected_pid_stream)
        mapfile -t pid_array <<< "$filtered"
    fi

    if [ ${#pid_array[@]} -eq 0 ]; then
        echo ""
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] 将终止 systemd 相关进程"
        printf "  %s\n" "${pid_array[@]}"
    else
        printf "%s\n" "${pid_array[@]}" | xargs kill -TERM 2>/dev/null || true
        sleep 1
        printf "%s\n" "${pid_array[@]}" | xargs kill -KILL 2>/dev/null || true
        print_success "已尝试终止 systemd 相关进程"
    fi
    echo ""
}

# 步骤4: 终止所有非root用户进程（第一轮）
kill_user_processes_first_round() {
    print_info "步骤 4/6: 终止待删除用户的进程（第一轮）"

    local targets=("${DELETE_USERS_LIST[@]}")

    if [ ${#targets[@]} -eq 0 ]; then
        print_info "没有普通用户需要清理进程"
        echo ""
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        local user
        for user in "${targets[@]}"; do
            local count
            count=$(ps -u "$user" -o pid= 2>/dev/null | wc -l | tr -d ' ')
            [ -n "$count" ] || count=0
            print_info "[DRY-RUN] $user: 将终止 $count 个进程"
        done
        echo ""
        return 0
    fi

    collect_protected_pids

    local pid_list=()
    local user
    for user in "${targets[@]}"; do
        while read -r pid; do
            [ -n "$pid" ] || continue
            pid_list+=("$pid")
        done < <(ps -u "$user" -o pid= 2>/dev/null | tr -d ' ')
    done

    if [ ${#pid_list[@]} -eq 0 ]; then
        print_info "待删除用户无活跃进程"
        echo ""
        return 0
    fi

    mapfile -t pid_list < <(printf "%s\n" "${pid_list[@]}" | awk 'NF' | sort -u)

    local filtered_pids=""
    filtered_pids=$(printf "%s\n" "${pid_list[@]}" | filter_protected_pid_stream)

    if [ -z "$filtered_pids" ]; then
        print_info "目标进程已全部受保护或不存在"
        echo ""
        return 0
    fi

    local filtered_array=()
    mapfile -t filtered_array <<< "$filtered_pids"
    local initial_count=${#filtered_array[@]}

    if [ $initial_count -gt 0 ]; then
        printf "%s\n" "${filtered_array[@]}" | xargs kill -TERM 2>/dev/null || true
        sleep 2
        printf "%s\n" "${filtered_array[@]}" | xargs kill -KILL 2>/dev/null || true
    fi

    local remaining=0
    for user in "${targets[@]}"; do
        local current
        current=$(ps -u "$user" -o pid= 2>/dev/null | wc -l | tr -d ' ')
        [ -n "$current" ] || current=0
        remaining=$((remaining + current))
    done

    print_success "已尝试终止 $initial_count 个进程（剩余 $remaining 个目标进程）"
    echo ""
}

# 步骤5: 删除普通用户账号
delete_user_accounts() {
    if [ "$REMOVE_USERS" = false ]; then
        print_info "步骤 5/6: 跳过用户账号删除（使用 --remove 启用）"
        echo ""
        return
    fi
    
    print_info "步骤 5/6: 删除普通用户账号"

    local users=("${DELETE_USERS_LIST[@]}")
    local count=0
    local failed=0
    local total=${#users[@]}
    local current=0
    DELETED_USER_COUNTER=0

    if [ $total -eq 0 ]; then
        print_info "没有普通用户需要删除"
        echo ""
        return 0
    fi

    local user
    for user in "${users[@]}"; do
        ((current++))

        if [ "$DRY_RUN" = true ]; then
            if [ -n "$DELETE_USER_CMD" ]; then
                print_info "[DRY-RUN] $DELETE_USER_CMD ${DELETE_USER_ARGS[*]} $user"
            else
                print_info "[DRY-RUN] 删除用户 $user"
            fi
        else
            pkill -9 -u "$user" 2>/dev/null || true
            sleep 0.1

            if "$DELETE_USER_CMD" "${DELETE_USER_ARGS[@]}" "$user" 2>/dev/null; then
                rm -rf "/var/mail/$user" "/var/spool/mail/$user" 2>/dev/null || true
                ((count++))
            else
                print_warning "删除用户 $user 失败"
                ((failed++))
            fi
        fi

        if [ $((current % 5)) -eq 0 ] || [ $current -eq $total ]; then
            print_progress "进度: $current/$total (成功: $count, 失败: $failed)"
        fi
    done

    if [ "$DRY_RUN" != true ]; then
        echo ""
        if [ $count -gt 0 ]; then
            print_success "已删除 $count 个普通用户账号"
        fi
        if [ $failed -gt 0 ]; then
            print_warning "失败 $failed 个"
        fi
        DELETED_USER_COUNTER=$count
    fi
    echo ""
}

# 步骤6: 最终清理 - 确保所有非root进程被终止
final_cleanup_all_non_root_processes() {
    if [ "$KILL_ALL_NON_ROOT" != true ]; then
        print_info "步骤 6/6: 跳过最终清理（KILL_ALL_NON_ROOT=false）"
        echo ""
        return 0
    fi

    print_info "步骤 6/6: 最终清理 - 确保所有非root进程被终止"
    print_warning "这一步会终止所有非root进程，包括保留用户的进程！"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        local snapshot
        snapshot=$(ps -eo user=,pid=,cmd= | awk '$1 != "root"')
        local non_root_procs
        non_root_procs=$(printf "%s\n" "$snapshot" | wc -l | tr -d ' ')
        print_info "[DRY-RUN] 将终止剩余的 $non_root_procs 个非root进程"

        print_info "[DRY-RUN] 将被终止的进程示例:"
        printf "%s\n" "$snapshot" | head -20 | awk '{cmd=$3; for(i=4;i<=NF;i++){cmd=cmd" "$i} printf "  [DRY-RUN] %-12s %6s %s\n", $1, $2, cmd}'

        echo ""
        return
    fi
    
    local round=0
    local max_rounds=5
    
    while [ $round -lt $max_rounds ]; do
        ((round++))
        
        local snapshot
        snapshot=$(ps -eo user=,pid= | awk '$1 != "root"')
        local non_root_procs
        non_root_procs=$(printf "%s\n" "$snapshot" | wc -l | tr -d ' ')

        if [ $non_root_procs -eq 0 ]; then
            print_success "所有非root进程已清理完成！"
            break
        fi

        print_progress "清理轮次 $round/$max_rounds - 剩余 $non_root_procs 个非root进程"

        local pid_array=()
        while read -r pid; do
            [ -n "$pid" ] || continue
            pid_array+=("$pid")
        done < <(printf "%s\n" "$snapshot" | awk '{print $2}')

        if [ ${#pid_array[@]} -eq 0 ]; then
            continue
        fi

        if [ "$PROTECT_SESSIONS" = true ]; then
            collect_protected_pids
            local filtered=""
            filtered=$(printf "%s\n" "${pid_array[@]}" | filter_protected_pid_stream)
            mapfile -t pid_array <<< "$filtered"
        fi

        if [ ${#pid_array[@]} -eq 0 ]; then
            continue
        fi

        printf "%s\n" "${pid_array[@]}" | xargs kill -TERM 2>/dev/null || true
        sleep 1
        printf "%s\n" "${pid_array[@]}" | xargs kill -KILL 2>/dev/null || true

        sleep 1
    done
    
    # 最终验证
    local final_non_root=$(ps -eo user= | awk '$1 != "root"' | wc -l | tr -d ' ')
    
    echo ""
    if [ $final_non_root -eq 0 ]; then
        print_success "✅ 完美！所有非root进程已被彻底清理"
    elif [ $final_non_root -lt 10 ]; then
        print_warning "⚠️  还剩 $final_non_root 个非root进程（可能是顽固进程）"
        echo ""
        print_info "剩余进程列表:"
        ps -eo user=,pid=,cmd= | awk '$1 != "root" {cmd=$3; for(i=4;i<=NF;i++){cmd=cmd" "$i} printf "  %-12s %6s %s\n", $1, $2, cmd}'
    else
        print_error "❌ 还有 $final_non_root 个非root进程未清理"
        echo ""
        print_info "剩余进程统计:"
        ps -eo user= | awk '$1 != "root"' | sort | uniq -c | sort -rn | head -10 | while read count user; do
            echo "  $count  $user"
        done
    fi
    
    echo ""
}

# 验证结果
verify_results() {
    print_info "========== 最终验证 =========="
    echo ""
    
    refresh_user_state

    local root_procs
    root_procs=$(ps -eo user= | awk '$1 == "root"' | wc -l | tr -d ' ')
    local non_root_procs
    non_root_procs=$(ps -eo user= | awk '$1 != "root"' | wc -l | tr -d ' ')
    local total_procs=$((root_procs + non_root_procs))

    print_info "进程统计:"
    echo -e "  ${GREEN}root进程:${NC} $root_procs"
    echo -e "  ${RED}非root进程:${NC} $non_root_procs"
    echo -e "  总进程: $total_procs"
    echo ""

    if [ $non_root_procs -gt 0 ]; then
        print_warning "非root进程分布:"
        ps -eo user= | awk '$1 != "root"' | sort | uniq -c | sort -rn | while read -r count user; do
            echo -e "  ${YELLOW}$count${NC}  $user"
        done
        echo ""
    fi

    if command -v loginctl >/dev/null 2>&1; then
        local sessions
        sessions=$(loginctl list-sessions --no-legend 2>/dev/null | wc -l | tr -d ' ')
        print_info "活跃会话数: $sessions"
        echo ""
    fi

    local preserved_count=${#PRESERVED_USERS_LIST[@]}
    local deleted_users=$DELETED_USER_COUNTER

    print_info "账号统计:"
    echo -e "  ${GREEN}保留的用户账号:${NC} $preserved_count 个"
    if [ "$REMOVE_USERS" = true ]; then
        echo -e "  ${RED}已删除的账号:${NC} $deleted_users 个"
    else
        echo -e "  ${YELLOW}未删除账号${NC}（使用 --remove 启用删除）"
    fi
    echo ""

    print_info "保留的用户账号列表:"
    local user
    for user in "${PRESERVED_USERS_LIST[@]}"; do
        local procs
        procs=$(ps -u "$user" -o pid= 2>/dev/null | wc -l | tr -d ' ')
        if [ "$user" = "root" ]; then
            echo -e "  ${GREEN}✓${NC} $user (进程: $procs) ${GREEN}(root用户)${NC}"
        elif [ -n "${SYSTEM_SERVICE_USER_SET[$user]+x}" ]; then
            echo -e "  ${GREEN}✓${NC} $user (进程: $procs) ${CYAN}(系统服务)${NC}"
        else
            echo -e "  ${GREEN}✓${NC} $user (进程: $procs) ${GREEN}(保留用户)${NC}"
        fi
    done

    echo ""
    print_info "==============================="
    echo ""
}

# 显示摘要
show_summary() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║           操作配置摘要                     ║${NC}"
    echo -e "${MAGENTA}╠════════════════════════════════════════════╣${NC}"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "保留用户: $KEEP_USERS"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "删除普通用户账号: $([ "$REMOVE_USERS" = true ] && echo "是" || echo "否")"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "备份用户数据: $([ "$BACKUP" = true ] && echo "是" || echo "否")"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "杀死所有非root进程: $([ "$KILL_ALL_NON_ROOT" = true ] && echo "是" || echo "否")"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "安全远程模式: $([ "$SAFE_REMOTE" = true ] && echo "是" || echo "否")"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "卸载容器/编排组件/附加服务: $([ "$PURGE_CONTAINERS" = true ] && echo "是" || echo "否")"
    printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "模拟运行: $([ "$DRY_RUN" = true ] && echo "是" || echo "否")"
    if [ "$LOG_FILE" != "/dev/null" ]; then
        printf "${MAGENTA}║${NC} %-42s ${MAGENTA}║${NC}\n" "日志: $(basename $LOG_FILE)"
    fi
    echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
    echo ""
}

##############################################################################
# 主程序
##############################################################################

main() {
    setup_logging
    detect_capabilities

    if [ "$EUID" -ne 0 ]; then
        print_error "此脚本需要root权限运行"
        print_info "请使用: sudo bash $0"
        exit 1
    fi

    acquire_lock

    parse_arguments "$@"

    if [ "$PURGE_CONTAINERS" = true ] && { [ "$HAS_APT_GET" != true ] || [ "$HAS_DPKG" != true ]; }; then
        print_warning "已启用 --purge-containers，但系统缺少 apt/dpkg，软件包卸载将被跳过"
    fi

    if [ "$KILL_ALL_NON_ROOT" = true ]; then
        SAFE_REMOTE=false
        PROTECT_SESSIONS=false
        PROTECT_NETWORK=false
    else
        if [ "$SAFE_REMOTE" != true ] && [ -n "${SSH_CONNECTION:-}" ] && [ "${FORCE:-false}" != true ]; then
            SAFE_REMOTE=true
            print_info "检测到SSH会话，已自动启用安全远程模式"
        fi

        if [ "$SAFE_REMOTE" = true ]; then
            PROTECT_SESSIONS=true
            PROTECT_NETWORK=true
        fi
    fi

    detect_uid_min
    NOLOGIN_SHELL=$(resolve_nologin_shell)
    initialize_user_sets

    if [ "$REMOVE_USERS" = true ]; then
        select_delete_user_command || exit 1
    fi
    
    show_summary
    
    if ! show_user_classification; then
        if [ "$REMOVE_USERS" = true ]; then
            print_info "没有普通用户需要删除"
        fi
    fi
    
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        print_warning "========== 模拟运行模式 =========="
        print_warning "不会执行实际操作，仅显示将要执行的命令"
        print_warning "====================================="
    else
        if [ "$FORCE" != true ]; then
            echo ""
            print_warning "⚠️  即将执行以下操作："
            echo "  1. 终止所有用户会话"
            echo "  2. 禁用普通用户登录"
            echo "  3. 终止所有systemd进程"
            echo "  4. 终止所有非root用户进程"
            if [ "$REMOVE_USERS" = true ]; then
                echo "  5. 删除普通用户账号和home目录"
            else
                echo "  5. 跳过删除账号"
            fi
            if [ "$KILL_ALL_NON_ROOT" = true ]; then
                echo "  6. ${RED}最终清理 - 彻底终止所有非root进程${NC}"
            else
                echo "  6. 跳过最终清理（安全模式）"
            fi
            if [ "$PURGE_CONTAINERS" = true ]; then
                echo "  * ${RED}附加操作 - 卸载 Kubernetes/Docker/k3s 等容器组件并终止相关网络/编排服务${NC}"
            fi
            echo ""
            print_warning "注意: 保留用户(如ubuntu)的账号会保留，但进程会被终止！"
            if [ "$KILL_ALL_NON_ROOT" = true ]; then
                print_warning "同时会终止 systemd-networkd、systemd-resolved 等关键服务，SSH/网络会立即断开"
            fi
            echo ""
            
            read -p "$(echo -e ${RED}是否继续? 请输入 ${YELLOW}yes${RED} 确认: ${NC})" -r confirm
            if [[ ! $confirm =~ ^yes$ ]]; then
                print_info "操作已取消"
                exit 0
            fi
        fi
    fi

    if [ "$PURGE_CONTAINERS" = true ]; then
        if ! purge_container_infrastructure; then
            print_error "容器/编排组件卸载失败，已中止"
            exit 1
        fi
    fi

    echo ""
    print_info "开始执行操作..."
    echo ""
    
    # 备份数据
    if [ "$BACKUP" = true ] && [ "$REMOVE_USERS" = true ]; then
        backup_user_data
    fi
    
    # 执行清理步骤（添加错误处理）
    terminate_sessions || {
        print_error "步骤1失败：终止用户会话"
        exit 1
    }

    disable_user_login || {
        print_error "步骤2失败：禁用用户登录"
        exit 1
    }

    kill_systemd_processes || {
        print_error "步骤3失败：终止systemd进程"
        exit 1
    }

    kill_user_processes_first_round || {
        print_error "步骤4失败：终止用户进程"
        exit 1
    }

    delete_user_accounts || {
        print_error "步骤5失败：删除用户账号"
        exit 1
    }

    refresh_user_state

    # 最终彻底清理
    final_cleanup_all_non_root_processes || {
        print_error "步骤6失败：最终清理"
        exit 1
    }
    
    # 验证结果
    if [ "$DRY_RUN" != true ]; then
        verify_results
    fi
    
    echo ""
    if [ "$DRY_RUN" = true ]; then
        print_success "✅ 模拟运行完成"
    else
        print_success "✅ 操作完成！"
        
        if [ "$BACKUP" = true ] && [ -d "$BACKUP_DIR" ]; then
            print_info "📦 备份位置: $BACKUP_DIR"
        fi
    fi
    
    if [ "$LOG_FILE" != "/dev/null" ]; then
        print_info "📄 详细日志: $LOG_FILE"
    fi
    
    echo ""
}

main "$@"
