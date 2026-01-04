#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

REPO="https://github.com/mastalee928/zjmf-lxd-server"
NAME="lxdimages"
INSTALL_DIR="/usr/local/bin"
FORCE=false
DELETE=false
INSTALL_MODE=""

log() { echo -e "$1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
err() { log "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "请使用 root 运行"

while [[ $# -gt 0 ]]; do
  case $1 in
    -f|--force) FORCE=true; shift;;
    -d|--delete) DELETE=true; shift;;
    -h|--help)
      echo "========================================"
      echo "     lxdimages 镜像管理工具安装脚本"
      echo "========================================"
      echo
      echo "用法: $0 [选项]"
      echo
      echo "说明:"
      echo "  此脚本用于管理 LXD 容器模板，提供两种方式："
      echo "  1. 下载预构建的容器模板（快速，适合性能较低的机器）"
      echo "  2. 安装 lxdimages 工具（用于本机构建模板）"
      echo
      echo "选项:"
      echo "  -f, --force    强制重新安装工具（仅适用于选项2）"
      echo "  -d, --delete   删除已安装的工具"
      echo "  -h, --help     显示此帮助信息"
      echo
      echo "示例:"
      echo "  $0              # 交互式选择安装方式"
      echo "  $0 -f           # 强制重新安装工具"
      echo "  $0 -d           # 删除工具"
      echo
      echo "详细教程: https://github.com/mastalee928/zjmf-lxd-server/wiki"
      exit 0;;
    *) err "未知参数: $1 (使用 -h 查看帮助)";;
  esac
done

if [[ $DELETE == true ]]; then
  echo
  echo "========================================"
  echo "        删除 lxdimages"
  echo "========================================"
  echo
  
  if [[ -f "$INSTALL_DIR/$NAME" ]]; then
    warn "此操作将删除已安装的 $NAME 程序！"
    echo "  程序位置: $INSTALL_DIR/$NAME"
    echo
    read -p "确定要继续吗? (y/N): " CONFIRM
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
      ok "取消删除操作"
      exit 0
    fi
    
    rm -f "$INSTALL_DIR/$NAME"
    echo
    ok "已删除 $NAME 程序"
  else
    warn "程序 $NAME 未安装，无需删除"
  fi
  exit 0
fi

echo
echo "========================================"
echo "     LXD 容器模板管理"
echo "========================================"
echo
echo "请选择安装方式："
echo
echo "  [1] 下载预构建容器模板"
echo "      - 快速安装，无需构建"
echo "      - 适合性能较低的机器"
echo "      - 模板已预先构建优化"
echo
echo "  [2] 安装 lxdimages 工具"
echo "      - 用于本机构建容器模板"
echo "      - 适合性能较好的机器"
echo "      - 可自定义构建配置"
echo
read -p "请选择 [1-2]: " INSTALL_MODE

while [[ ! $INSTALL_MODE =~ ^[1-2]$ ]]; do
  warn "无效选择，请输入 1 或 2"
  read -p "请选择 [1-2]: " INSTALL_MODE
done

if [[ $INSTALL_MODE == "1" ]]; then
  echo
  echo "========================================"
  echo "   下载预构建容器模板"
  echo "========================================"
  echo
  
  info "检测系统架构..."
  sys_arch=$(uname -m)
  case $sys_arch in
    x86_64) 
      arch="amd64"
      info "检测到架构: x86_64 (amd64)"
      ;;
    aarch64|arm64) 
      arch="arm64"
      info "检测到架构: $sys_arch (arm64)"
      ;;
    *) 
      err "不支持的架构: $sys_arch，仅支持 amd64 和 arm64"
      ;;
  esac
  
  info "检查系统依赖..."
  if ! command -v wget &> /dev/null; then
    info "检测包管理器..."
    PKG_MANAGER=""
    if command -v apt-get &> /dev/null; then
      PKG_MANAGER="apt"
      info "使用 APT 安装 wget..."
      apt-get update -y >/dev/null 2>&1
      apt-get install -y wget || err "wget 安装失败"
    elif command -v dnf &> /dev/null; then
      PKG_MANAGER="dnf"
      info "使用 DNF 安装 wget..."
      dnf install -y wget || err "wget 安装失败"
    elif command -v yum &> /dev/null; then
      PKG_MANAGER="yum"
      info "使用 YUM 安装 wget..."
      yum install -y wget || err "wget 安装失败"
    elif command -v zypper &> /dev/null; then
      PKG_MANAGER="zypper"
      info "使用 Zypper 安装 wget..."
      zypper install -y wget || err "wget 安装失败"
    elif command -v pacman &> /dev/null; then
      PKG_MANAGER="pacman"
      info "使用 Pacman 安装 wget..."
      pacman -S --noconfirm wget || err "wget 安装失败"
    else
      err "无法检测到包管理器，请手动安装 wget"
    fi
    ok "wget 安装完成"
  else
    ok "wget 已安装"
  fi
  
  IMAGES_BASE_URL="https://github.com/mastalee928/zjmf-lxd-server/releases/download/images"
  
  declare -A DISTROS
  DISTROS=(
    ["alma"]="alma8 alma9 alma10"
    ["alpine"]="alpine319 alpine320 alpine321 alpine322 alpineEdge"
    ["amazon"]="amazon2023"
    ["centos"]="centos9 centos10"
    ["debian"]="debian11 debian12 debian13"
    ["fedora"]="fedora41 fedora42"
    ["oracle"]="oracle8 oracle9"
    ["rocky"]="rocky8 rocky9 rocky10"
    ["suse"]="suse155 suse156 suseTumbleweed"
    ["ubuntu"]="ubuntu2204 ubuntu2404 ubuntu2410"
  )
  
  echo
  echo "========================================"
  echo "   选择导入方式"
  echo "========================================"
  echo
  echo "  [1] 全部导入（所有发行版的所有版本）"
  echo "  [2] 单个发行版全部导入"
  echo "  [3] 自定义导入（手动选择）"
  echo "  [4] 预设模板导入（推荐常用组合）"
  echo
  read -p "请选择 [1-4]: " IMPORT_MODE
  
  while [[ ! $IMPORT_MODE =~ ^[1-4]$ ]]; do
    warn "无效选择，请输入 1-4"
    read -p "请选择 [1-4]: " IMPORT_MODE
  done
  
  download_and_import_image() {
    local image_name="$1"
    local image_url="${IMAGES_BASE_URL}/${image_name}-${arch}.tar.gz"
    
    info "下载: ${image_name}-${arch}.tar.gz"
    
    local temp_file=$(mktemp)
    if wget -q --show-progress -O "$temp_file" "$image_url"; then
      info "导入到 LXD..."
      if lxc image import "$temp_file" --alias "$image_name"; then
        ok "成功导入: $image_name"
      else
        warn "导入失败: $image_name"
      fi
      rm -f "$temp_file"
    else
      warn "下载失败: ${image_name}-${arch}.tar.gz"
      rm -f "$temp_file"
    fi
  }
  
  case $IMPORT_MODE in
    1)
      echo
      ok "开始导入所有容器模板..."
      echo
      
      total=0
      for distro in "${!DISTROS[@]}"; do
        for version in ${DISTROS[$distro]}; do
          ((total++))
        done
      done
      
      warn "警告: 将下载并导入 $total 个模板，可能需要较长时间"
      read -p "确定要继续吗? (y/N): " CONFIRM
      if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        ok "取消导入操作"
        exit 0
      fi
      
      echo
      current=0
      for distro in "${!DISTROS[@]}"; do
        for version in ${DISTROS[$distro]}; do
          ((current++))
          echo "[$current/$total] 处理: $version"
          download_and_import_image "$version"
          echo
        done
      done
      ;;
      
    2)
      echo
      echo "可用的发行版："
      echo
      distro_list=($(echo "${!DISTROS[@]}" | tr ' ' '\n' | sort))
      for i in "${!distro_list[@]}"; do
        echo "  [$((i+1))] ${distro_list[$i]}"
      done
      echo
      read -p "请选择发行版 [1-${#distro_list[@]}]: " DISTRO_CHOICE
      
      while [[ ! $DISTRO_CHOICE =~ ^[0-9]+$ ]] || [[ $DISTRO_CHOICE -lt 1 ]] || [[ $DISTRO_CHOICE -gt ${#distro_list[@]} ]]; do
        warn "无效选择"
        read -p "请选择发行版 [1-${#distro_list[@]}]: " DISTRO_CHOICE
      done
      
      selected_distro="${distro_list[$((DISTRO_CHOICE-1))]}"
      versions="${DISTROS[$selected_distro]}"
      version_array=($versions)
      
      echo
      ok "已选择: $selected_distro (共 ${#version_array[@]} 个版本)"
      read -p "确定要导入所有版本吗? (y/N): " CONFIRM
      if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        ok "取消导入操作"
        exit 0
      fi
      
      echo
      current=0
      for version in $versions; do
        ((current++))
        echo "[$current/${#version_array[@]}] 处理: $version"
        download_and_import_image "$version"
        echo
      done
      ;;
      
    3)
      echo
      echo "可用的容器模板："
      echo
      
      all_images=()
      for distro in $(echo "${!DISTROS[@]}" | tr ' ' '\n' | sort); do
        echo "[$distro]"
        for version in ${DISTROS[$distro]}; do
          all_images+=("$version")
          echo "  [${#all_images[@]}] $version"
        done
        echo
      done
      
      echo "请输入要导入的模板编号（多个用空格分隔，如: 1 3 5）："
      read -p "编号: " CUSTOM_CHOICES
      
      selected_images=()
      for choice in $CUSTOM_CHOICES; do
        if [[ $choice =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#all_images[@]} ]]; then
          selected_images+=("${all_images[$((choice-1))]}")
        fi
      done
      
      if [[ ${#selected_images[@]} -eq 0 ]]; then
        err "未选择任何模板"
      fi
      
      echo
      ok "已选择 ${#selected_images[@]} 个模板:"
      for img in "${selected_images[@]}"; do
        echo "  - $img"
      done
      
      read -p "确定要导入吗? (y/N): " CONFIRM
      if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        ok "取消导入操作"
        exit 0
      fi
      
      echo
      current=0
      for img in "${selected_images[@]}"; do
        ((current++))
        echo "[$current/${#selected_images[@]}] 处理: $img"
        download_and_import_image "$img"
        echo
      done
      ;;
      
    4)
      echo
      echo "可用的预设模板组合："
      echo
      echo "  [1] 最小化（1个）"
      echo "      - ubuntu2404"
      echo
      echo "  [2] 常用发行版（3个）"
      echo "      - ubuntu2404, debian12, alpine321"
      echo
      echo "  [3] LTS长期支持版（4个）"
      echo "      - ubuntu2204, ubuntu2404, debian12, rocky9"
      echo
      echo "  [4] 开发测试环境（6个）"
      echo "      - ubuntu2404, debian12, alpine321, fedora42, rocky9, centos10"
      echo
      echo "  [5] 全发行版代表（10个）"
      echo "      - ubuntu2404, debian12, alpine321, fedora42"
      echo "      - rocky9, centos10, alma9, oracle9, suse156, amazon2023"
      echo
      read -p "请选择预设 [1-5]: " PRESET_CHOICE
      
      while [[ ! $PRESET_CHOICE =~ ^[1-5]$ ]]; do
        warn "无效选择"
        read -p "请选择预设 [1-5]: " PRESET_CHOICE
      done
      
      case $PRESET_CHOICE in
        1) preset_images="ubuntu2404" ;;
        2) preset_images="ubuntu2404 debian12 alpine321" ;;
        3) preset_images="ubuntu2204 ubuntu2404 debian12 rocky9" ;;
        4) preset_images="ubuntu2404 debian12 alpine321 fedora42 rocky9 centos10" ;;
        5) preset_images="ubuntu2404 debian12 alpine321 fedora42 rocky9 centos10 alma9 oracle9 suse156 amazon2023" ;;
      esac
      
      preset_array=($preset_images)
      echo
      ok "已选择预设 $PRESET_CHOICE (共 ${#preset_array[@]} 个模板)"
      read -p "确定要导入吗? (y/N): " CONFIRM
      if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        ok "取消导入操作"
        exit 0
      fi
      
      echo
      current=0
      for img in $preset_images; do
        ((current++))
        echo "[$current/${#preset_array[@]}] 处理: $img"
        download_and_import_image "$img"
        echo
      done
      ;;
  esac
  
  echo
  ok "容器模板导入完成！"
  echo
  info "已导入的镜像列表："
  echo
  lxc image list
  echo
  
  exit 0
fi

echo
echo "========================================"
echo "   安装 lxdimages 工具"
echo "========================================"
echo

echo
echo "========================================"
echo "      步骤 1/4: 检测系统环境"
echo "========================================"
echo

info "检测系统架构..."
sys_arch=$(uname -m)
case $sys_arch in
  x86_64) 
    arch="amd64"
    BIN="lxdimages-amd64"
    info "检测到架构: x86_64 (amd64)"
    ;;
  aarch64|arm64) 
    arch="arm64"
    BIN="lxdimages-arm64"
    info "检测到架构: $sys_arch (arm64)"
    ;;
  *) 
    err "不支持的架构: $sys_arch，仅支持 amd64 和 arm64"
    ;;
esac

info "检查程序是否已安装..."
if [[ -f "$INSTALL_DIR/$NAME" ]]; then
  if [[ $FORCE != true ]]; then
    echo
    err "$NAME 已安装
    
提示：
  - 删除: $0 -d
  - 强制重新安装: $0 -f"
  else
    echo
    warn "检测到 $NAME 已安装"
    warn "使用了 -f 参数，将强制重新安装"
    echo
    read -p "确定要继续吗? (y/N): " FORCE_CONFIRM
    if [[ $FORCE_CONFIRM != "y" && $FORCE_CONFIRM != "Y" ]]; then
      ok "取消重新安装操作"
      exit 0
    fi
  fi
fi

ok "环境检测通过"

echo
echo "========================================"
echo "      步骤 2/4: 检查系统依赖"
echo "========================================"
echo

info "检测包管理器..."
PKG_MANAGER=""
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
    info "包管理器: APT (Debian/Ubuntu)"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    info "包管理器: YUM (CentOS/RHEL)"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    info "包管理器: DNF (Fedora/RHEL 8+)"
elif command -v zypper &> /dev/null; then
    PKG_MANAGER="zypper"
    info "包管理器: Zypper (openSUSE)"
elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
    info "包管理器: Pacman (Arch Linux)"
else
    err "无法检测到支持的包管理器"
fi

info "安装依赖工具（curl, wget）..."
case $PKG_MANAGER in
    apt)
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget || err "依赖安装失败"
        ;;
    yum)
        yum install -y curl wget || err "依赖安装失败"
        ;;
    dnf)
        dnf install -y curl wget || err "依赖安装失败"
        ;;
    zypper)
        zypper install -y curl wget || err "依赖安装失败"
        ;;
    pacman)
        pacman -S --noconfirm curl wget || err "依赖安装失败"
        ;;
esac

ok "依赖工具安装完成"

echo
echo "========================================"
echo "       步骤 3/4: 下载程序"
echo "========================================"
echo

DOWNLOAD_URL="$REPO/raw/refs/heads/main/lxdimages/$BIN"
info "下载程序: $DOWNLOAD_URL"

TMP=$(mktemp)
if ! wget -q --show-progress -O "$TMP" "$DOWNLOAD_URL"; then
  err "下载失败: $DOWNLOAD_URL"
fi

if [[ ! -s "$TMP" ]]; then
  rm -f "$TMP"
  err "下载的文件为空或无效"
fi

echo
echo "========================================"
echo "       步骤 4/4: 安装程序"
echo "========================================"
echo

info "安装程序到 $INSTALL_DIR/$NAME"
mkdir -p "$INSTALL_DIR"
mv "$TMP" "$INSTALL_DIR/$NAME"
chmod +x "$INSTALL_DIR/$NAME"

if [[ ! -x "$INSTALL_DIR/$NAME" ]]; then
  err "安装失败: 程序不可执行"
fi

echo
ok "安装完成！"
echo "程序路径: $INSTALL_DIR/$NAME"
echo "系统架构: $arch"
echo "二进制文件: $BIN"

if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
  warn "$INSTALL_DIR 不在 PATH 中，请手动添加或使用完整路径"
  echo "可以运行: export PATH=\"\$PATH:$INSTALL_DIR\""
fi

echo
info "程序信息:"
if "$INSTALL_DIR/$NAME" --version 2>/dev/null; then
  :
elif "$INSTALL_DIR/$NAME" -v 2>/dev/null; then
  :
elif "$INSTALL_DIR/$NAME" version 2>/dev/null; then
  :
else
  echo "程序已安装，可以使用 $NAME 命令运行"
fi

echo
ok "$NAME 安装完成！"
echo "详细教程: https://github.com/mastalee928/zjmf-lxd-server/wiki"