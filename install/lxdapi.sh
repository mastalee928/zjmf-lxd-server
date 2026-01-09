#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

REPO="https://github.com/mastalee928/zjmf-lxd-server"
VERSION=""
NAME="lxdapi"
DIR="/opt/$NAME"
CFG="$DIR/config.yaml"
SERVICE="/etc/systemd/system/$NAME.service"
DB_FILE="lxdapi.db"
FORCE=false
DELETE=false

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "请使用 root 运行"

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version) VERSION="$2"; [[ $VERSION != v* ]] && VERSION="v$VERSION"; shift 2;;
    -f|--force) FORCE=true; shift;;
    -d|--delete) DELETE=true; shift;;
    -h|--help) echo "$0 -v 版本 [-f] [-d]"; exit 0;;
    *) err "未知参数 $1";;
  esac
done

if [[ $DELETE == true ]]; then
  echo "警告: 此操作将删除所有数据，包括数据库文件！"
  
  read -p "确定要继续吗? (y/N): " CONFIRM
  if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    ok "取消删除操作"
    exit 0
  fi
  
  systemctl stop $NAME 2>/dev/null || true
  systemctl disable $NAME 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  if [[ -d "$DIR" ]]; then
    rm -rf "$DIR"
    ok "已删除 $NAME 服务和目录"
  else
    ok "目录 $DIR 不存在，无需删除"
  fi
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  err "必须提供版本号参数，使用 -v 或 --version 指定版本"
fi

echo
echo "========================================"
echo "      步骤 1/8: 检测系统环境"
echo "========================================"
echo

info "检测操作系统..."
if [[ -f /etc/os-release ]]; then
  OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d'"' -f2)
  OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d'"' -f2)
  echo "  系统: $OS_NAME ${OS_VERSION:-}"
else
  echo "  系统: 未知 Linux 发行版"
fi

info "检测系统架构..."
arch=$(uname -m)
case $arch in
  x86_64) 
    BIN="lxdapi-amd64"
    echo "  架构: amd64"
    ;;
  aarch64|arm64) 
    BIN="lxdapi-arm64"
    echo "  架构: arm64"
    ;;
  *) 
    err "不支持的架构: $arch，仅支持 amd64 和 arm64"
    ;;
esac

ok "系统环境检测完成"

echo
echo "========================================"
echo "      步骤 2/8: 检查 LXD 环境"
echo "========================================"
echo

info "检查 LXD 是否已安装..."
if ! command -v lxd &> /dev/null; then
  err "未检测到 LXD，请先安装 LXD"
fi
ok "LXD 已安装"

info "检查 LXD 版本..."
lxd_full_version=$(lxd --version 2>/dev/null)
if [[ -z "$lxd_full_version" ]]; then
  err "无法获取 LXD 版本信息"
fi

lxd_major=$(echo "$lxd_full_version" | grep -oE '^[0-9]+' | head -1)
lxd_minor=$(echo "$lxd_full_version" | grep -oE '^[0-9]+\.[0-9]+' | cut -d. -f2)

echo "  当前版本: $lxd_full_version"

if [[ -z "$lxd_major" ]]; then
  err "无法解析 LXD 版本号: $lxd_full_version"
fi

version_ok=false
if [[ "$lxd_major" -ge 7 ]]; then
  version_ok=true
elif [[ "$lxd_major" -eq 6 ]]; then
  version_ok=true
elif [[ "$lxd_major" -eq 5 ]]; then
  if [[ -n "$lxd_minor" ]] && [[ "$lxd_minor" -ge 21 ]]; then
    version_ok=true
  fi
fi

if [[ "$version_ok" != true ]]; then
  err "LXD 版本必须 >= 5.21 或 >= 6.0，当前版本: $lxd_full_version"
fi

ok "LXD 版本检查通过 (版本: $lxd_full_version)"

echo
echo "========================================"
echo "      步骤 3/8: 检查版本状态"
echo "========================================"
echo

DOWNLOAD_URL="$REPO/releases/download/$VERSION/$BIN.zip"

UPGRADE=false
if [[ -d "$DIR" ]] && [[ -f "$DIR/version" ]]; then
  CUR=$(cat "$DIR/version")
  if [[ $CUR != "$VERSION" || $FORCE == true ]]; then
    UPGRADE=true
    info "检测到已安装版本: $CUR"
    info "执行升级操作: $CUR -> $VERSION"
  else
    ok "已是最新版本 $VERSION"
    exit 0
  fi
else
  info "未检测到已安装版本"
  info "执行全新安装: $VERSION"
fi

echo
echo "========================================"
echo "      步骤 4/8: 安装系统依赖"
echo "========================================"
echo

info "检测包管理器..."
pkg_manager=""
if command -v apt &> /dev/null; then
  pkg_manager="apt"
  echo "  使用: APT (Debian/Ubuntu)"
elif command -v dnf &> /dev/null; then
  pkg_manager="dnf"
  echo "  使用: DNF (Fedora/RHEL 8+)"
elif command -v yum &> /dev/null; then
  pkg_manager="yum"
  echo "  使用: YUM (RHEL/CentOS)"
elif command -v zypper &> /dev/null; then
  pkg_manager="zypper"
  echo "  使用: Zypper (openSUSE)"
elif command -v pacman &> /dev/null; then
  pkg_manager="pacman"
  echo "  使用: Pacman (Arch Linux)"
else
  err "未检测到支持的包管理器"
fi

info "更新软件包列表..."
case $pkg_manager in
  apt)
    apt update -y
    ;;
  dnf)
    dnf check-update -y || true
    ;;
  yum)
    yum check-update -y || true
    ;;
  zypper)
    zypper refresh
    ;;
  pacman)
    pacman -Sy --noconfirm
    ;;
esac

info "安装依赖包..."
case $pkg_manager in
  apt)
    apt install -y curl wget unzip zip openssl xxd systemd iptables-persistent lxcfs || err "依赖安装失败"
    ;;
  dnf)
    dnf install -y curl wget unzip zip openssl xxd systemd iptables-services lxcfs || warn "部分依赖安装失败"
    ;;
  yum)
    yum install -y curl wget unzip zip openssl xxd systemd iptables-services lxcfs || warn "部分依赖安装失败"
    ;;
  zypper)
    zypper install -y curl wget unzip zip openssl xxd systemd iptables lxcfs || warn "部分依赖安装失败"
    ;;
  pacman)
    pacman -S --noconfirm curl wget unzip zip openssl xxd systemd iptables lxcfs || warn "部分依赖安装失败"
    ;;
esac

if command -v lxcfs &> /dev/null; then
  systemctl enable lxcfs 2>/dev/null || true
  systemctl start lxcfs 2>/dev/null || true
  
  if systemctl is-active --quiet lxcfs; then
    ok "LXCFS 服务已安装并运行"
  else
    warn "LXCFS 已安装但服务未运行，容器资源视图功能可能不可用"
  fi
else
  warn "LXCFS 未安装，容器资源视图功能将不可用"
fi

ok "系统依赖安装完成"

echo
echo "========================================"
echo "      步骤 5/8: 准备环境"
echo "========================================"
echo

if systemctl is-active --quiet $NAME 2>/dev/null; then
  info "停止当前服务..."
  systemctl stop $NAME 2>/dev/null || true
  ok "服务已停止"
else
  info "服务未运行，跳过停止操作"
fi

if [[ $UPGRADE == true ]]; then
  info "清理旧程序文件..."
  find "$DIR" -maxdepth 1 -type f ! -name "$DB_FILE" ! -name "$DB_FILE-shm" ! -name "$DB_FILE-wal" -delete 2>/dev/null || true
  for subdir in "$DIR"/*; do
    if [[ -d "$subdir" ]]; then
      rm -rf "$subdir" 2>/dev/null || true
    fi
  done
  ok "旧文件已清理（保留数据库）"
fi

info "创建安装目录..."
mkdir -p "$DIR"
ok "环境准备完成"

echo
echo "========================================"
echo "      步骤 6/8: 下载和安装程序"
echo "========================================"
echo

info "下载 $NAME $VERSION..."
TMP=$(mktemp -d)
wget -qO "$TMP/app.zip" "$DOWNLOAD_URL" || err "下载失败"

info "解压安装文件..."
unzip -qo "$TMP/app.zip" -d "$DIR"
chmod +x "$DIR/$BIN"
echo "$VERSION" > "$DIR/version"
rm -rf "$TMP"

ok "程序文件安装完成"

get_default_interface() {
  ip route | grep default | head -1 | awk '{print $5}' || echo "eth0"
}

get_interface_ipv4() {
  local interface="$1"
  ip -4 addr show "$interface" 2>/dev/null | grep inet | grep -v 127.0.0.1 | head -1 | awk '{print $2}' | cut -d/ -f1 || echo ""
}

get_interface_ipv6() {
  local interface="$1"
  ip -6 addr show "$interface" 2>/dev/null | grep inet6 | grep -v "::1" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -d/ -f1 || echo ""
}

DEFAULT_INTERFACE=$(get_default_interface)
DEFAULT_IPV4=$(get_interface_ipv4 "$DEFAULT_INTERFACE")
DEFAULT_IPV6=$(get_interface_ipv6 "$DEFAULT_INTERFACE")
DEFAULT_IP=$(curl -s 4.ipw.cn || echo "$DEFAULT_IPV4")
DEFAULT_HASH=$(openssl rand -hex 8 | tr 'a-f' 'A-F')
DEFAULT_PORT="8080"

echo
echo "========================================"
echo "      步骤 7/9: 配置向导"
echo "========================================"
echo
echo "    LXD API 服务配置向导 - $VERSION"
echo

echo "==== 步骤 1/7: 基础信息配置 ===="
echo

read -p "服务器外网 IP [$DEFAULT_IP]: " EXTERNAL_IP
EXTERNAL_IP=${EXTERNAL_IP:-$DEFAULT_IP}

read -p "API 访问密钥 [$DEFAULT_HASH]: " API_HASH
API_HASH=${API_HASH:-$DEFAULT_HASH}

read -p "API 服务端口 [$DEFAULT_PORT]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-$DEFAULT_PORT}

ok "基础信息配置完成"
echo

echo "==== 步骤 2/7: 存储池配置 ===="
echo

DETECTED_POOLS_LIST=$(lxc storage list --format csv 2>/dev/null | cut -d, -f1 | grep -v "^NAME$" | head -10)
if [[ -n "$DETECTED_POOLS_LIST" ]]; then
  echo "检测到的存储池："
  echo "$DETECTED_POOLS_LIST" | sed 's/^/  - /'
else
  warn "未检测到存储池"
fi
echo
echo "存储池配置方式："
echo "1. 自动使用所有检测到的存储池"
echo "2. 手动指定存储池列表"
echo
read -p "请选择 [1-2]: " STORAGE_MODE

while [[ ! $STORAGE_MODE =~ ^[1-2]$ ]]; do
  warn "无效选择，请输入 1 或 2"
  read -p "请选择 [1-2]: " STORAGE_MODE
done

case $STORAGE_MODE in
  1)
    DETECTED_POOLS=$(lxc storage list --format csv 2>/dev/null | cut -d, -f1 | grep -v "^NAME$" | head -10 | tr '\n' ' ')
    if [[ -n "$DETECTED_POOLS" ]]; then
      STORAGE_POOLS=""
      for pool in $DETECTED_POOLS; do
        if [[ -n "$STORAGE_POOLS" ]]; then
          STORAGE_POOLS="$STORAGE_POOLS, \"$pool\""
        else
          STORAGE_POOLS="\"$pool\""
        fi
      done
      ok "已自动配置存储池: $DETECTED_POOLS"
    else
      STORAGE_POOLS="\"default\""
      warn "未检测到存储池，使用默认配置: default"
    fi
    ;;
  2)
    echo "请输入存储池名称，多个存储池用空格分隔（按优先级顺序）"
    echo "示例: default zfs-pool btrfs-pool"
    read -p "存储池列表: " MANUAL_POOLS
    if [[ -n "$MANUAL_POOLS" ]]; then
      STORAGE_POOLS=""
      for pool in $MANUAL_POOLS; do
        if [[ -n "$STORAGE_POOLS" ]]; then
          STORAGE_POOLS="$STORAGE_POOLS, \"$pool\""
        else
          STORAGE_POOLS="\"$pool\""
        fi
      done
      ok "已手动配置存储池: $MANUAL_POOLS"
    else
      STORAGE_POOLS="\"default\""
      warn "输入为空，使用默认配置: default"
    fi
    ;;
esac
echo

echo "==== 步骤 3/7: 数据库与队列后端组合 ===="
echo
echo "请选择数据库与任务队列后端组合："
echo "1. SQLite + Database 队列 (轻量级方案)"
echo "2. SQLite + Redis 队列 (标准方案)"
echo "3. PostgreSQL + Redis 队列 (企业级方案)"
echo "4. MySQL/MariaDB + Redis 队列 (传统企业级方案)"
echo
read -p "请选择组合 [1-4]: " DB_COMBO_CHOICE

while [[ ! $DB_COMBO_CHOICE =~ ^[1-4]$ ]]; do
  warn "无效选择，请输入 1-4"
  read -p "请选择组合 [1-4]: " DB_COMBO_CHOICE
done

case $DB_COMBO_CHOICE in
  1)
    DB_TYPE="sqlite"
    QUEUE_BACKEND="database"
    ok "已选择: SQLite + Database 队列 (轻量级方案)"
    ;;
  2)
    DB_TYPE="sqlite"
    QUEUE_BACKEND="redis"
    ok "已选择: SQLite + Redis 队列 (使用本地Redis)"
    
    if ! command -v redis-server &> /dev/null; then
      info "正在安装 Redis..."
      apt update -y && apt install -y redis-server || err "Redis 安装失败"
      systemctl enable redis-server
      systemctl start redis-server
      ok "Redis 安装完成"
    else
      ok "检测到 Redis 已安装"
      systemctl is-active --quiet redis-server || {
        info "正在启动 Redis 服务..."
        systemctl start redis-server
      }
    fi
    
    if command -v redis-cli >/dev/null 2>&1; then
      if redis-cli -h 127.0.0.1 -p 6379 PING 2>/dev/null | grep -q PONG; then
        ok "本地 Redis 连接测试成功"
      else
        warn "本地 Redis 连接测试失败"
      fi
    fi
    ;;
  3)
    DB_TYPE="postgres"
    QUEUE_BACKEND="redis"
    ok "已选择: PostgreSQL + Redis 队列 (使用本地Redis)"
    echo
    echo "==== PostgreSQL 配置 ===="
    warn "PostgreSQL 数据库需要您自行备份，请注意数据安全"
    echo
    read -p "我已了解备份责任，确认继续? (y/N): " PG_BACKUP_CONFIRM
    if [[ $PG_BACKUP_CONFIRM != "y" && $PG_BACKUP_CONFIRM != "Y" ]]; then
      echo "已取消配置，请先备份数据库后重新运行安装脚本"
      exit 0
    fi
    echo
    
    read -p "PostgreSQL 服务器地址 [localhost]: " DB_POSTGRES_HOST
    DB_POSTGRES_HOST=${DB_POSTGRES_HOST:-localhost}
    
    read -p "PostgreSQL 端口 [5432]: " DB_POSTGRES_PORT
    DB_POSTGRES_PORT=${DB_POSTGRES_PORT:-5432}
    
    read -p "PostgreSQL 用户名 [lxdapi]: " DB_POSTGRES_USER
    DB_POSTGRES_USER=${DB_POSTGRES_USER:-lxdapi}
    
    read -p "PostgreSQL 密码: " DB_POSTGRES_PASSWORD
    while [[ -z "$DB_POSTGRES_PASSWORD" ]]; do
      warn "PostgreSQL 密码不能为空"
      read -p "PostgreSQL 密码: " DB_POSTGRES_PASSWORD
    done
    
    read -p "PostgreSQL 数据库名 [lxdapi]: " DB_POSTGRES_DATABASE
    DB_POSTGRES_DATABASE=${DB_POSTGRES_DATABASE:-lxdapi}
    
    if command -v psql >/dev/null 2>&1; then
      if PGPASSWORD="$DB_POSTGRES_PASSWORD" psql -h"$DB_POSTGRES_HOST" -p"$DB_POSTGRES_PORT" -U"$DB_POSTGRES_USER" -d"$DB_POSTGRES_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        ok "PostgreSQL 连接测试成功"
      else
        warn "PostgreSQL 连接测试失败，请检查配置"
      fi
    else
      warn "未找到 psql 客户端，跳过连接测试"
    fi
    
    echo
    if ! command -v redis-server &> /dev/null; then
      info "正在安装 Redis..."
      apt update -y && apt install -y redis-server || err "Redis 安装失败"
      systemctl enable redis-server
      systemctl start redis-server
      ok "Redis 安装完成"
    else
      ok "检测到 Redis 已安装"
      systemctl is-active --quiet redis-server || {
        info "正在启动 Redis 服务..."
        systemctl start redis-server
      }
    fi
    ;;
  4)
    QUEUE_BACKEND="redis"
    echo
    echo "请选择数据库类型："
    echo "1. MySQL 5.7+"
    echo "2. MariaDB 10.x+"
    read -p "请选择 [1-2]: " MYSQL_TYPE
    
    while [[ ! $MYSQL_TYPE =~ ^[1-2]$ ]]; do
      warn "无效选择，请输入 1 或 2"
      read -p "请选择 [1-2]: " MYSQL_TYPE
    done
    
    if [[ $MYSQL_TYPE == "1" ]]; then
      DB_TYPE="mysql"
      ok "已选择: MySQL + Redis 队列"
    else
      DB_TYPE="mariadb"
      ok "已选择: MariaDB + Redis 队列"
    fi
    
    echo
    echo "==== $DB_TYPE 配置 ===="
    warn "$DB_TYPE 数据库需要您自行备份，请注意数据安全"
    echo
    read -p "我已了解备份责任，确认继续? (y/N): " MYSQL_BACKUP_CONFIRM
    if [[ $MYSQL_BACKUP_CONFIRM != "y" && $MYSQL_BACKUP_CONFIRM != "Y" ]]; then
      echo "已取消配置，请先备份数据库后重新运行安装脚本"
      exit 0
    fi
    echo
    
    read -p "$DB_TYPE 服务器地址 [localhost]: " DB_MYSQL_HOST
    DB_MYSQL_HOST=${DB_MYSQL_HOST:-localhost}
    
    read -p "$DB_TYPE 端口 [3306]: " DB_MYSQL_PORT
    DB_MYSQL_PORT=${DB_MYSQL_PORT:-3306}
    
    read -p "$DB_TYPE 用户名 [lxdapi]: " DB_MYSQL_USER
    DB_MYSQL_USER=${DB_MYSQL_USER:-lxdapi}
    
    read -p "$DB_TYPE 密码: " DB_MYSQL_PASSWORD
    while [[ -z "$DB_MYSQL_PASSWORD" ]]; do
      warn "$DB_TYPE 密码不能为空"
      read -p "$DB_TYPE 密码: " DB_MYSQL_PASSWORD
    done
    
    read -p "$DB_TYPE 数据库名 [lxdapi]: " DB_MYSQL_DATABASE
    DB_MYSQL_DATABASE=${DB_MYSQL_DATABASE:-lxdapi}
    
    if command -v mysql >/dev/null 2>&1; then
      if mysql -h"$DB_MYSQL_HOST" -P"$DB_MYSQL_PORT" -u"$DB_MYSQL_USER" -p"$DB_MYSQL_PASSWORD" -e "USE $DB_MYSQL_DATABASE;" 2>/dev/null; then
        ok "$DB_TYPE 连接测试成功"
      else
        warn "$DB_TYPE 连接测试失败，请检查配置"
      fi
    else
      warn "未找到 mysql 客户端，跳过连接测试"
    fi
    
    echo
    if ! command -v redis-server &> /dev/null; then
      info "正在安装 Redis..."
      apt update -y && apt install -y redis-server || err "Redis 安装失败"
      systemctl enable redis-server
      systemctl start redis-server
      ok "Redis 安装完成"
    else
      ok "检测到 Redis 已安装"
      systemctl is-active --quiet redis-server || {
        info "正在启动 Redis 服务..."
        systemctl start redis-server
      }
    fi
    ;;
esac

ok "数据库与队列配置完成"
echo

echo "==== 步骤 4/7: 流量监控性能配置 ===="
echo
echo "请选择流量监控性能方案："
echo "1. 高性能模式 (适用独立服务器 8核+)         - CPU占用 10-15%, 封禁响应 ~10秒"
echo "2. 标准模式 (适用独立服务器 4-8核)          - CPU占用 5-10%, 封禁响应 ~15秒"
echo "3. 轻量模式 (适用独立服务器 2-4核)          - CPU占用 2-5%, 封禁响应 ~30秒"
echo "4. 最小模式 (适用无独享内核或共享VPS)       - CPU占用 0.5-2%, 封禁响应 ~60秒"
echo "5. 自定义模式 (手动配置所有参数)"
echo
read -p "请选择 [1-5, 默认2]: " TRAFFIC_MODE
TRAFFIC_MODE=${TRAFFIC_MODE:-2}

while [[ ! $TRAFFIC_MODE =~ ^[1-5]$ ]]; do
  warn "无效选择，请输入 1-5"
  read -p "请选择 [1-5, 默认2]: " TRAFFIC_MODE
  TRAFFIC_MODE=${TRAFFIC_MODE:-2}
done

case $TRAFFIC_MODE in
  1)
    # 高性能模式
    TRAFFIC_INTERVAL=5
    TRAFFIC_BATCH_SIZE=20
    TRAFFIC_LIMIT_CHECK_INTERVAL=10
    TRAFFIC_LIMIT_CHECK_BATCH_SIZE=20
    TRAFFIC_AUTO_RESET_INTERVAL=600
    TRAFFIC_AUTO_RESET_BATCH_SIZE=20
    ok "已选择: 高性能模式"
    ;;
  2)
    # 标准模式
    TRAFFIC_INTERVAL=10
    TRAFFIC_BATCH_SIZE=10
    TRAFFIC_LIMIT_CHECK_INTERVAL=15
    TRAFFIC_LIMIT_CHECK_BATCH_SIZE=10
    TRAFFIC_AUTO_RESET_INTERVAL=900
    TRAFFIC_AUTO_RESET_BATCH_SIZE=10
    ok "已选择: 标准模式 (推荐)"
    ;;
  3)
    # 轻量模式
    TRAFFIC_INTERVAL=15
    TRAFFIC_BATCH_SIZE=5
    TRAFFIC_LIMIT_CHECK_INTERVAL=30
    TRAFFIC_LIMIT_CHECK_BATCH_SIZE=5
    TRAFFIC_AUTO_RESET_INTERVAL=1800
    TRAFFIC_AUTO_RESET_BATCH_SIZE=5
    ok "已选择: 轻量模式"
    ;;
  4)
    # 最小模式
    TRAFFIC_INTERVAL=30
    TRAFFIC_BATCH_SIZE=3
    TRAFFIC_LIMIT_CHECK_INTERVAL=60
    TRAFFIC_LIMIT_CHECK_BATCH_SIZE=3
    TRAFFIC_AUTO_RESET_INTERVAL=3600
    TRAFFIC_AUTO_RESET_BATCH_SIZE=3
    ok "已选择: 最小模式"
    ;;
  5)
    # 自定义模式
    ok "已选择: 自定义模式"
    echo
    echo "==== 流量统计配置 ===="
    read -p "流量统计间隔（秒，建议5-30）[10]: " TRAFFIC_INTERVAL
    TRAFFIC_INTERVAL=${TRAFFIC_INTERVAL:-10}
    
    read -p "流量统计批量（建议3-20）[10]: " TRAFFIC_BATCH_SIZE
    TRAFFIC_BATCH_SIZE=${TRAFFIC_BATCH_SIZE:-10}
    
    echo
    echo "==== 流量限制检测配置 ===="
    read -p "限制检测间隔（秒，建议10-60）[15]: " TRAFFIC_LIMIT_CHECK_INTERVAL
    TRAFFIC_LIMIT_CHECK_INTERVAL=${TRAFFIC_LIMIT_CHECK_INTERVAL:-15}
    
    read -p "限制检测批量（建议3-20）[10]: " TRAFFIC_LIMIT_CHECK_BATCH_SIZE
    TRAFFIC_LIMIT_CHECK_BATCH_SIZE=${TRAFFIC_LIMIT_CHECK_BATCH_SIZE:-10}
    
    echo
    echo "==== 自动重置检查配置 ===="
    read -p "自动重置检查间隔（秒，建议600-3600）[900]: " TRAFFIC_AUTO_RESET_INTERVAL
    TRAFFIC_AUTO_RESET_INTERVAL=${TRAFFIC_AUTO_RESET_INTERVAL:-900}
    
    read -p "自动重置检查批量（建议3-20）[10]: " TRAFFIC_AUTO_RESET_BATCH_SIZE
    TRAFFIC_AUTO_RESET_BATCH_SIZE=${TRAFFIC_AUTO_RESET_BATCH_SIZE:-10}
    
    ok "自定义配置完成"
    ;;
esac

ok "流量监控性能配置完成"
echo

echo "==== 步骤 5/7: 网络管理方案 ===="
echo
echo "请选择网络模式："
echo "1. IPv4 NAT共享"
echo "2. IPv6 NAT共享"
echo "3. IPv4/IPv6 NAT共享 (双栈)"
echo "4. IPv4 NAT共享 + IPv6独立"
echo "5. IPv4独立"
echo "6. IPv6独立"
echo "7. IPv4独立 + IPv6独立"
echo
read -p "请选择网络模式 [1-7]: " NETWORK_MODE

while [[ ! $NETWORK_MODE =~ ^[1-7]$ ]]; do
  warn "无效选择，请输入 1-7"
  read -p "请选择网络模式 [1-7]: " NETWORK_MODE
done

case $NETWORK_MODE in
  1)
    NAT_SUPPORT="true"
    IPV6_NAT_SUPPORT="false"
    IPV4_BINDING_ENABLED="false"
    IPV6_BINDING_ENABLED="false"
    ok "已选择: 模式1 - IPv4 NAT共享"
    ;;
  2)
    NAT_SUPPORT="false"
    IPV6_NAT_SUPPORT="true"
    IPV4_BINDING_ENABLED="false"
    IPV6_BINDING_ENABLED="false"
    ok "已选择: 模式2 - IPv6 NAT共享"
    ;;
  3)
    NAT_SUPPORT="true"
    IPV6_NAT_SUPPORT="true"
    IPV4_BINDING_ENABLED="false"
    IPV6_BINDING_ENABLED="false"
    ok "已选择: 模式3 - IPv4/IPv6 NAT共享 (双栈)"
    ;;
  4)
    NAT_SUPPORT="true"
    IPV6_NAT_SUPPORT="false"
    IPV4_BINDING_ENABLED="false"
    IPV6_BINDING_ENABLED="true"
    ok "已选择: 模式4 - IPv4 NAT共享 + IPv6独立"
    ;;
  5)
    NAT_SUPPORT="false"
    IPV6_NAT_SUPPORT="false"
    IPV4_BINDING_ENABLED="true"
    IPV6_BINDING_ENABLED="false"
    ok "已选择: 模式5 - IPv4独立"
    ;;
  6)
    NAT_SUPPORT="false"
    IPV6_NAT_SUPPORT="false"
    IPV4_BINDING_ENABLED="false"
    IPV6_BINDING_ENABLED="true"
    ok "已选择: 模式6 - IPv6独立"
    ;;
  7)
    NAT_SUPPORT="false"
    IPV6_NAT_SUPPORT="false"
    IPV4_BINDING_ENABLED="true"
    IPV6_BINDING_ENABLED="true"
    ok "已选择: 模式7 - IPv4独立 + IPv6独立"
    ;;
esac

echo
echo "==== 网络接口配置 ===="
read -p "外网网卡接口 [$DEFAULT_INTERFACE]: " NETWORK_INTERFACE
NETWORK_INTERFACE=${NETWORK_INTERFACE:-$DEFAULT_INTERFACE}

if [[ $NAT_SUPPORT == "true" ]]; then
  read -p "外网 IPv4 地址 [$DEFAULT_IPV4]: " NETWORK_IPV4
  NETWORK_IPV4=${NETWORK_IPV4:-$DEFAULT_IPV4}
else
  NETWORK_IPV4=""
fi

if [[ $IPV6_NAT_SUPPORT == "true" ]]; then
  read -p "外网 IPv6 地址 [$DEFAULT_IPV6]: " NETWORK_IPV6
  NETWORK_IPV6=${NETWORK_IPV6:-$DEFAULT_IPV6}
else
  NETWORK_IPV6=""
fi

if [[ $IPV4_BINDING_ENABLED == "true" ]]; then
  echo
  echo "==== IPv4 独立绑定配置 ===="
  read -p "IPv4 绑定网卡接口 [$DEFAULT_INTERFACE]: " IPV4_BINDING_INTERFACE
  IPV4_BINDING_INTERFACE=${IPV4_BINDING_INTERFACE:-$DEFAULT_INTERFACE}
  
  while [[ -z "$IPV4_POOL_START" ]]; do
    read -p "IPv4 地址池起始地址 (如: 192.168.1.100): " IPV4_POOL_START
    if [[ -z "$IPV4_POOL_START" ]]; then
      warn "IPv4 地址池起始地址不能为空，请重新输入"
    fi
  done
  
  read -p "IPv4 地址池大小 [100]: " IPV4_POOL_SIZE
  IPV4_POOL_SIZE=${IPV4_POOL_SIZE:-100}
else
  IPV4_BINDING_INTERFACE=""
  IPV4_POOL_START=""
  IPV4_POOL_SIZE=""
fi

if [[ $IPV6_BINDING_ENABLED == "true" ]]; then
  echo
  echo "==== IPv6 独立绑定配置 ===="
  read -p "IPv6 绑定网卡接口 [$DEFAULT_INTERFACE]: " IPV6_BINDING_INTERFACE
  IPV6_BINDING_INTERFACE=${IPV6_BINDING_INTERFACE:-$DEFAULT_INTERFACE}
  
  while [[ -z "$IPV6_POOL_START" ]]; do
    read -p "IPv6 地址池起始地址 (如: 2001:db8::1000): " IPV6_POOL_START
    if [[ -z "$IPV6_POOL_START" ]]; then
      warn "IPv6 地址池起始地址不能为空，请重新输入"
    fi
  done
  
  read -p "IPv6 地址池大小 [1000]: " IPV6_POOL_SIZE
  IPV6_POOL_SIZE=${IPV6_POOL_SIZE:-1000}
else
  IPV6_BINDING_INTERFACE=""
  IPV6_POOL_START=""
  IPV6_POOL_SIZE=""
fi

ok "网络配置完成"
echo

echo "==== 步骤 6/7: Nginx 反向代理配置 ===="
echo
echo "是否启用 Nginx 反向代理功能？"
echo "此功能允许为容器配置域名反向代理（需要已安装 Nginx）"
echo
read -p "是否启用 Nginx 反向代理? (y/N): " ENABLE_NGINX_PROXY

if [[ $ENABLE_NGINX_PROXY == "y" || $ENABLE_NGINX_PROXY == "Y" ]]; then
  NGINX_PROXY_ENABLED="true"
  
  # 检测并安装 Nginx
  if ! command -v nginx &> /dev/null; then
    info "正在安装 Nginx..."
    apt update -y && apt install -y nginx || err "Nginx 安装失败"
    systemctl enable nginx
    systemctl start nginx
    ok "Nginx 安装完成"
  else
    ok "检测到 Nginx 已安装"
  fi
  
  # 配置 Nginx 日志轮转（保留3天）
  if [[ -d "/etc/logrotate.d" ]]; then
    cat > /etc/logrotate.d/nginx-lxdapi <<'EOF'
/var/log/nginx/*-access.log /var/log/nginx/*-error.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
EOF
    ok "Nginx 日志轮转配置已创建（保留3天）"
  fi
  
  ok "Nginx 反向代理功能已启用"
else
  NGINX_PROXY_ENABLED="false"
  ok "已禁用 Nginx 反向代理功能"
fi

echo
echo "==== 步骤 7/7: 管理面板配置 ===="
echo
echo "是否启用 Web 管理面板？"
echo "管理面板提供可视化的容器管理界面，无需命令行操作"
echo
read -p "是否启用管理面板? (Y/n): " ENABLE_ADMIN_PANEL

if [[ $ENABLE_ADMIN_PANEL == "n" || $ENABLE_ADMIN_PANEL == "N" ]]; then
  ADMIN_PANEL_ENABLED="false"
  ADMIN_USERNAME="admin"
  ADMIN_PASSWORD="admin123"
  ADMIN_SESSION_SECRET=$(openssl rand -base64 32)
  ok "已禁用管理面板"
else
  ADMIN_PANEL_ENABLED="true"
  echo
  echo "==== 管理员账号配置 ===="
  
  read -p "管理员用户名 [admin]: " ADMIN_USERNAME
  ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
  
  while true; do
    read -s -p "管理员密码（至少6位）: " ADMIN_PASSWORD
    echo
    if [[ ${#ADMIN_PASSWORD} -lt 6 ]]; then
      warn "密码长度至少6位，请重新输入"
      continue
    fi
    read -s -p "确认密码: " ADMIN_PASSWORD_CONFIRM
    echo
    if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
      warn "两次密码不一致，请重新输入"
      continue
    fi
    break
  done
  
  ADMIN_SESSION_SECRET=$(openssl rand -base64 32)
  
  ok "管理面板配置完成"
  info "访问地址: https://$EXTERNAL_IP:$SERVER_PORT/admin/login"
  info "管理员用户名: $ADMIN_USERNAME"
fi

echo
echo "========================================"
echo "      步骤 8/9: 生成配置文件"
echo "========================================"
echo

info "正在生成配置文件..."

replace_config_var() {
  local placeholder="$1"
  local value="$2"
  escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
  sed -i "s/\${$placeholder}/$escaped_value/g" "$CFG"
}

# 自动获取CPU核心数作为worker_count
CPU_CORES=$(nproc 2>/dev/null || echo "4")
# 限制在合理范围内 (最少2个，最多16个)
if [[ $CPU_CORES -lt 2 ]]; then
  WORKER_COUNT=2
elif [[ $CPU_CORES -gt 16 ]]; then
  WORKER_COUNT=16
else
  WORKER_COUNT=$CPU_CORES
fi
info "检测到 CPU 核心数: $CPU_CORES，设置 Worker 数量为: $WORKER_COUNT"

replace_config_var "SERVER_PORT" "$SERVER_PORT"
replace_config_var "PUBLIC_NETWORK_IP_ADDRESS" "$EXTERNAL_IP"
replace_config_var "API_ACCESS_HASH" "$API_HASH"
replace_config_var "STORAGE_POOLS" "$STORAGE_POOLS"
replace_config_var "WORKER_COUNT" "$WORKER_COUNT"

replace_config_var "DB_TYPE" "$DB_TYPE"
if [[ $DB_TYPE == "mysql" || $DB_TYPE == "mariadb" ]]; then
  replace_config_var "DB_MYSQL_HOST" "$DB_MYSQL_HOST"
  replace_config_var "DB_MYSQL_PORT" "$DB_MYSQL_PORT"
  replace_config_var "DB_MYSQL_USER" "$DB_MYSQL_USER"
  replace_config_var "DB_MYSQL_PASSWORD" "$DB_MYSQL_PASSWORD"
  replace_config_var "DB_MYSQL_DATABASE" "$DB_MYSQL_DATABASE"
  replace_config_var "DB_POSTGRES_HOST" "localhost"
  replace_config_var "DB_POSTGRES_PORT" "5432"
  replace_config_var "DB_POSTGRES_USER" "lxdapi"
  replace_config_var "DB_POSTGRES_PASSWORD" "your_password"
  replace_config_var "DB_POSTGRES_DATABASE" "lxdapi"
elif [[ $DB_TYPE == "postgres" ]]; then
  replace_config_var "DB_POSTGRES_HOST" "$DB_POSTGRES_HOST"
  replace_config_var "DB_POSTGRES_PORT" "$DB_POSTGRES_PORT"
  replace_config_var "DB_POSTGRES_USER" "$DB_POSTGRES_USER"
  replace_config_var "DB_POSTGRES_PASSWORD" "$DB_POSTGRES_PASSWORD"
  replace_config_var "DB_POSTGRES_DATABASE" "$DB_POSTGRES_DATABASE"
  replace_config_var "DB_MYSQL_HOST" "localhost"
  replace_config_var "DB_MYSQL_PORT" "3306"
  replace_config_var "DB_MYSQL_USER" "lxdapi"
  replace_config_var "DB_MYSQL_PASSWORD" "your_password"
  replace_config_var "DB_MYSQL_DATABASE" "lxdapi"
else
  replace_config_var "DB_MYSQL_HOST" "localhost"
  replace_config_var "DB_MYSQL_PORT" "3306"
  replace_config_var "DB_MYSQL_USER" "lxdapi"
  replace_config_var "DB_MYSQL_PASSWORD" "your_password"
  replace_config_var "DB_MYSQL_DATABASE" "lxdapi"
  replace_config_var "DB_POSTGRES_HOST" "localhost"
  replace_config_var "DB_POSTGRES_PORT" "5432"
  replace_config_var "DB_POSTGRES_USER" "lxdapi"
  replace_config_var "DB_POSTGRES_PASSWORD" "your_password"
  replace_config_var "DB_POSTGRES_DATABASE" "lxdapi"
fi

replace_config_var "QUEUE_BACKEND" "$QUEUE_BACKEND"

replace_config_var "NAT_SUPPORT" "$NAT_SUPPORT"
replace_config_var "IPV6_NAT_SUPPORT" "$IPV6_NAT_SUPPORT"
replace_config_var "NETWORK_EXTERNAL_INTERFACE" "$NETWORK_INTERFACE"
replace_config_var "NETWORK_EXTERNAL_IPV4" "$NETWORK_IPV4"
replace_config_var "NETWORK_EXTERNAL_IPV6" "$NETWORK_IPV6"

replace_config_var "IPV4_BINDING_ENABLED" "$IPV4_BINDING_ENABLED"
replace_config_var "IPV4_BINDING_INTERFACE" "$IPV4_BINDING_INTERFACE"
replace_config_var "IPV4_POOL_START" "$IPV4_POOL_START"
replace_config_var "IPV4_POOL_SIZE" "$IPV4_POOL_SIZE"

replace_config_var "IPV6_BINDING_ENABLED" "$IPV6_BINDING_ENABLED"
replace_config_var "IPV6_BINDING_INTERFACE" "$IPV6_BINDING_INTERFACE"
replace_config_var "IPV6_POOL_START" "$IPV6_POOL_START"
replace_config_var "IPV6_POOL_SIZE" "$IPV6_POOL_SIZE"

replace_config_var "TRAFFIC_INTERVAL" "$TRAFFIC_INTERVAL"
replace_config_var "TRAFFIC_BATCH_SIZE" "$TRAFFIC_BATCH_SIZE"
replace_config_var "TRAFFIC_LIMIT_CHECK_INTERVAL" "$TRAFFIC_LIMIT_CHECK_INTERVAL"
replace_config_var "TRAFFIC_LIMIT_CHECK_BATCH_SIZE" "$TRAFFIC_LIMIT_CHECK_BATCH_SIZE"
replace_config_var "TRAFFIC_AUTO_RESET_INTERVAL" "$TRAFFIC_AUTO_RESET_INTERVAL"
replace_config_var "TRAFFIC_AUTO_RESET_BATCH_SIZE" "$TRAFFIC_AUTO_RESET_BATCH_SIZE"

replace_config_var "NGINX_PROXY_ENABLED" "$NGINX_PROXY_ENABLED"

replace_config_var "ADMIN_PANEL_ENABLED" "$ADMIN_PANEL_ENABLED"
replace_config_var "ADMIN_USERNAME" "$ADMIN_USERNAME"
replace_config_var "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
replace_config_var "ADMIN_SESSION_SECRET" "$ADMIN_SESSION_SECRET"

ok "配置文件已生成"

echo
echo "========================================"
echo "      步骤 9/9: 创建服务并启动"
echo "========================================"
echo

info "创建系统服务..."

cat > "$SERVICE" <<EOF
[Unit]
Description=lxdapi-MastaLee
After=network.target

[Service]
WorkingDirectory=$DIR
ExecStart=$DIR/$BIN
Restart=always
RestartSec=5
Environment=GIN_MODE=release

[Install]
WantedBy=multi-user.target
EOF

info "启动服务..."
systemctl daemon-reload
systemctl enable --now $NAME

ok "系统服务已创建并启动"

echo

echo "========================================"
echo "          安装/升级完成"
echo "========================================"
echo
echo "服务信息:"
echo "  数据目录: $DIR"
echo "  外网 IP: $EXTERNAL_IP"
echo "  API 端口: $SERVER_PORT"
echo "  API Hash: $API_HASH"
echo
echo "数据库配置:"
case $DB_TYPE in
  sqlite)
    echo "  数据库: SQLite (lxdapi.db)"
    ;;
  mysql)
    echo "  数据库: MySQL ($DB_MYSQL_HOST:$DB_MYSQL_PORT/$DB_MYSQL_DATABASE)"
    ;;
  mariadb)
    echo "  数据库: MariaDB ($DB_MYSQL_HOST:$DB_MYSQL_PORT/$DB_MYSQL_DATABASE)"
    ;;
  postgres)
    echo "  数据库: PostgreSQL ($DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DATABASE)"
    ;;
esac
echo "  任务队列: $QUEUE_BACKEND"
if [[ $QUEUE_BACKEND == "redis" ]]; then
  echo "  Redis: 127.0.0.1:6379 (本地)"
fi
echo
echo "存储池配置: [$STORAGE_POOLS]"
echo
echo "网络模式:"
case $NETWORK_MODE in
  1) echo "  IPv4 NAT";;
  2) echo "  IPv4 + IPv6 NAT";;
  3) echo "  全功能模式 (IPv4 NAT + IPv6 NAT + IPv6 独立绑定)";;
  4) echo "  混合模式 (IPv4 NAT + IPv6 独立绑定)";;
  5) echo "  纯 IPv6 公网 模式";;
esac
echo
echo "流量监控性能:"
case $TRAFFIC_MODE in
  1) echo "  模式: 高性能模式 (统计间隔: ${TRAFFIC_INTERVAL}秒, 检测间隔: ${TRAFFIC_LIMIT_CHECK_INTERVAL}秒)";;
  2) echo "  模式: 标准模式 (统计间隔: ${TRAFFIC_INTERVAL}秒, 检测间隔: ${TRAFFIC_LIMIT_CHECK_INTERVAL}秒)";;
  3) echo "  模式: 轻量模式 (统计间隔: ${TRAFFIC_INTERVAL}秒, 检测间隔: ${TRAFFIC_LIMIT_CHECK_INTERVAL}秒)";;
  4) echo "  模式: 最小模式 (统计间隔: ${TRAFFIC_INTERVAL}秒, 检测间隔: ${TRAFFIC_LIMIT_CHECK_INTERVAL}秒)";;
  5) echo "  模式: 自定义模式 (统计间隔: ${TRAFFIC_INTERVAL}秒, 检测间隔: ${TRAFFIC_LIMIT_CHECK_INTERVAL}秒)";;
esac
echo
echo "反向代理:"
if [[ $NGINX_PROXY_ENABLED == "true" ]]; then
  echo "  状态: 已启用 (Nginx 已安装并启动)"
else
  echo "  状态: 未启用"
fi
echo
echo "管理面板:"
if [[ $ADMIN_PANEL_ENABLED == "true" ]]; then
  echo "  状态: 已启用"
  echo "  访问: https://$EXTERNAL_IP:$SERVER_PORT/admin/login"
  echo "  用户: $ADMIN_USERNAME"
else
  echo "  状态: 未启用"
fi
echo
echo "LXCFS 资源视图:"
if command -v lxcfs &> /dev/null; then
  if systemctl is-active --quiet lxcfs; then
    echo "  状态: 已安装并运行"
    echo "  挂载: /var/lib/lxcfs"
    echo "  功能: 容器内将显示真实的资源限制"
  else
    echo "  状态: 已安装但未运行"
    echo "  提示: 运行 'systemctl start lxcfs' 启动服务"
  fi
else
  echo "  状态: 未安装"
  echo "  提示: 安装后容器可显示真实资源限制"
fi
echo

info "等待服务稳定..."
sleep 3

echo
echo "========================================"
echo "服务状态:"
echo "========================================"
systemctl status $NAME --no-pager
