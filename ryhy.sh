#!/bin/bash
#==========================================================================
# Reality + Hysteria2 安全部署脚本 (Sing-Box 内核)
# 功能: 交互式生成、修改配置、端口跳跃、混淆、保活
# 版本: 2.0.0
#==========================================================================

set -e

#--------------------------- 颜色定义 ---------------------------#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#--------------------------- 路径定义 ---------------------------#
SINGBOX_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
CONFIG_FILE="${SINGBOX_DIR}/config.json"
VARS_FILE="${SINGBOX_DIR}/.vars"
BACKUP_DIR="${SINGBOX_DIR}/backups"
LOG_FILE="/var/log/sing-box-deploy.log"

#--------------------------- 全局变量 ---------------------------#
declare -A VARS

#--------------------------- 日志函数 ---------------------------#
log() {
    local level=$1; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
    case $level in
        ERROR) echo -e "${RED}[错误]${NC} $*" ;;
        WARN)  echo -e "${YELLOW}[警告]${NC} $*" ;;
        INFO)  echo -e "${GREEN}[信息]${NC} $*" ;;
        *)     echo -e "$*" ;;
    esac
}

#--------------------------- 权限检查 ---------------------------#
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本必须以 root 权限运行！${NC}"
        exit 1
    fi
}

#--------------------------- 依赖检查 ---------------------------#
check_deps() {
    local deps=("curl" "jq" "openssl" "ufw" "systemctl")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log INFO "安装缺失依赖: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >> "$LOG_FILE" 2>&1
    fi
}

#--------------------------- 目录初始化 ---------------------------#
init_dirs() {
    mkdir -p "$SINGBOX_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

#--------------------------- 生成随机值 ---------------------------#
gen_uuid() {
    if command -v sing-box &>/dev/null; then
        sing-box generate uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

gen_password() {
    openssl rand -base64 24 | tr -d "=+/" | head -c 32
}

gen_short_id() {
    openssl rand -hex 8
}

gen_reality_keypair() {
    if command -v sing-box &>/dev/null; then
        sing-box generate reality-keypair 2>/dev/null
    fi
}

#--------------------------- 读取保存的变量 ---------------------------#
load_vars() {
    if [[ -f "$VARS_FILE" ]]; then
        source "$VARS_FILE"
        VARS[REALITY_UUID]="${REALITY_UUID:-}"
        VARS[REALITY_PORT]="${REALITY_PORT:-}"
        VARS[REALITY_SERVER_NAME]="${REALITY_SERVER_NAME:-}"
        VARS[REALITY_DEST]="${REALITY_DEST:-}"
        VARS[REALITY_PRIVATE_KEY]="${REALITY_PRIVATE_KEY:-}"
        VARS[REALITY_PUBLIC_KEY]="${REALITY_PUBLIC_KEY:-}"
        VARS[REALITY_SHORT_ID]="${REALITY_SHORT_ID:-}"
        VARS[HY2_PASSWORD]="${HY2_PASSWORD:-}"
        VARS[HY2_PORT]="${HY2_PORT:-}"
        VARS[HY2_HOP_START]="${HY2_HOP_START:-}"
        VARS[HY2_HOP_END]="${HY2_HOP_END:-}"
        VARS[HY2_OBFS_PASSWORD]="${HY2_OBFS_PASSWORD:-}"
        VARS[SNI]="${SNI:-}"
        VARS[TCP_KEEPALIVE_INTERVAL]="${TCP_KEEPALIVE_INTERVAL:-30}"
        VARS[HY2_HEARTBEAT]="${HY2_HEARTBEAT:-10s}"
        VARS[HY2_IDLE_TIMEOUT]="${HY2_IDLE_TIMEOUT:-0}"
        VARS[HY2_MIN_HOP_INTERVAL]="${HY2_MIN_HOP_INTERVAL:-10s}"
        VARS[HY2_MAX_HOP_INTERVAL]="${HY2_MAX_HOP_INTERVAL:-60s}"
    fi
}

#--------------------------- 保存变量 ---------------------------#
save_vars() {
    cat > "$VARS_FILE" << EOF
REALITY_UUID="${VARS[REALITY_UUID]}"
REALITY_PORT="${VARS[REALITY_PORT]}"
REALITY_SERVER_NAME="${VARS[REALITY_SERVER_NAME]}"
REALITY_DEST="${VARS[REALITY_DEST]}"
REALITY_PRIVATE_KEY="${VARS[REALITY_PRIVATE_KEY]}"
REALITY_PUBLIC_KEY="${VARS[REALITY_PUBLIC_KEY]}"
REALITY_SHORT_ID="${VARS[REALITY_SHORT_ID]}"
HY2_PASSWORD="${VARS[HY2_PASSWORD]}"
HY2_PORT="${VARS[HY2_PORT]}"
HY2_HOP_START="${VARS[HY2_HOP_START]}"
HY2_HOP_END="${VARS[HY2_HOP_END]}"
HY2_OBFS_PASSWORD="${VARS[HY2_OBFS_PASSWORD]}"
SNI="${VARS[SNI]}"
TCP_KEEPALIVE_INTERVAL="${VARS[TCP_KEEPALIVE_INTERVAL]}"
HY2_HEARTBEAT="${VARS[HY2_HEARTBEAT]}"
HY2_IDLE_TIMEOUT="${VARS[HY2_IDLE_TIMEOUT]}"
HY2_MIN_HOP_INTERVAL="${VARS[HY2_MIN_HOP_INTERVAL]}"
HY2_MAX_HOP_INTERVAL="${VARS[HY2_MAX_HOP_INTERVAL]}"
EOF
    chmod 600 "$VARS_FILE"
}

#--------------------------- 获取服务器IP ---------------------------#
get_server_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s4 --connect-timeout 5 ipinfo.io/ip 2>/dev/null) || \
    ip=$(curl -s4 --connect-timeout 5 icanhazip.com 2>/dev/null)
    echo "$ip"
}

#--------------------------- 验证端口 ---------------------------#
validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        return 1
    fi
    return 0
}

validate_port_range() {
    local start=$1 end=$2
    if ! validate_port "$start" || ! validate_port "$end"; then
        return 1
    fi
    if [[ "$start" -ge "$end" ]]; then
        return 1
    fi
    if [[ $((end - start)) -lt 10 ]]; then
        return 2
    fi
    return 0
}

#--------------------------- 安装 Sing-Box ---------------------------#
install_singbox() {
    log INFO "检查 Sing-Box 安装状态..."
    
    if command -v sing-box &>/dev/null; then
        local current_ver
        current_ver=$(sing-box version 2>/dev/null | grep -oP 'version \K[0-9.]+' | head -1)
        log INFO "已安装 Sing-Box 版本: ${current_ver}"
        read -p "是否重新安装最新版? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    log INFO "开始安装 Sing-Box..."
    if curl -fsSL https://sing-box.app/gpg.key | gpg --dearmor -o /etc/apt/keyrings/sing-box.gpg 2>/dev/null; then
        echo "deb [signed-by=/etc/apt/keyrings/sing-box.gpg] https://sing-box.app/debian stable main" > /etc/apt/sources.list.d/sing-box.list
        apt-get update -qq && apt-get install -y sing-box >> "$LOG_FILE" 2>&1
    else
        local arch
        arch=$(uname -m)
        case $arch in
            x86_64) arch="amd64" ;;
            aarch64) arch="arm64" ;;
            *) log ERROR "不支持的架构: $arch"; return 1 ;;
        esac
        
        local latest_url="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${arch}.tar.gz"
        curl -sL "$latest_url" -o /tmp/sing-box.tar.gz
        tar -xzf /tmp/sing-box.tar.gz -C /tmp
        mv /tmp/sing-box-*/sing-box "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-*
    fi
    
    log INFO "Sing-Box 安装完成"
}

#--------------------------- 配置 Reality ---------------------------#
configure_reality() {
    echo ""
    echo -e "${CYAN}========== Reality 配置 ==========${NC}"
    
    if [[ -n "${VARS[REALITY_UUID]}" ]]; then
        echo -e "当前 UUID: ${GREEN}${VARS[REALITY_UUID]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入新 UUID (回车自动生成): " input_uuid
            VARS[REALITY_UUID]="${input_uuid:-$(gen_uuid)}"
        fi
    else
        read -p "请输入 Reality UUID (回车自动生成): " input_uuid
        VARS[REALITY_UUID]="${input_uuid:-$(gen_uuid)}"
    fi
    
    if [[ -n "${VARS[REALITY_PORT]}" ]]; then
        echo -e "当前端口: ${GREEN}${VARS[REALITY_PORT]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            while true; do
                read -p "请输入 Reality 端口 (1-65535, 默认443): " input_port
                input_port="${input_port:-443}"
                if validate_port "$input_port"; then
                    VARS[REALITY_PORT]="$input_port"
                    break
                else
                    log ERROR "无效端口号，请重新输入"
                fi
            done
        fi
    else
        while true; do
            read -p "请输入 Reality 端口 (1-65535, 默认443): " input_port
            input_port="${input_port:-443}"
            if validate_port "$input_port"; then
                VARS[REALITY_PORT]="$input_port"
                break
            else
                log ERROR "无效端口号，请重新输入"
            fi
        done
    fi
    
    if [[ -n "${VARS[REALITY_DEST]}" ]]; then
        echo -e "当前回落域名: ${GREEN}${VARS[REALITY_DEST]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入回落域名 (默认: www.microsoft.com): " input_dest
            VARS[REALITY_DEST]="${input_dest:-www.microsoft.com}"
        fi
    else
        read -p "请输入回落域名 (默认: www.microsoft.com): " input_dest
        VARS[REALITY_DEST]="${input_dest:-www.microsoft.com}"
    fi
    
    if [[ -n "${VARS[REALITY_SERVER_NAME]}" ]]; then
        echo -e "当前 serverName: ${GREEN}${VARS[REALITY_SERVER_NAME]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入 serverName (默认与回落域名相同): " input_sn
            VARS[REALITY_SERVER_NAME]="${input_sn:-${VARS[REALITY_DEST]}}"
        fi
    else
        read -p "请输入 serverName (默认与回落域名相同): " input_sn
        VARS[REALITY_SERVER_NAME]="${input_sn:-${VARS[REALITY_DEST]}}"
    fi
    
    if [[ -z "${VARS[REALITY_PRIVATE_KEY]}" ]] || [[ -z "${VARS[REALITY_PUBLIC_KEY]}" ]]; then
        echo "正在生成 Reality 密钥对..."
        local keypair
        keypair=$(gen_reality_keypair)
        if [[ -n "$keypair" ]]; then
            VARS[REALITY_PRIVATE_KEY]=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}')
            VARS[REALITY_PUBLIC_KEY]=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}')
            log INFO "密钥对生成成功"
        else
            log ERROR "密钥对生成失败，请确认 sing-box 已正确安装"
            return 1
        fi
    fi
    
    if [[ -z "${VARS[REALITY_SHORT_ID]}" ]]; then
        VARS[REALITY_SHORT_ID]=$(gen_short_id)
        echo -e "已生成 Short ID: ${GREEN}${VARS[REALITY_SHORT_ID]}${NC}"
    fi
    
    save_vars
    echo -e "${GREEN}✓ Reality 配置完成${NC}"
}

#--------------------------- 配置 Hysteria2 ---------------------------#
configure_hysteria2() {
    echo ""
    echo -e "${CYAN}========== Hysteria2 配置 ==========${NC}"
    
    if [[ -n "${VARS[HY2_PASSWORD]}" ]]; then
        echo -e "当前密码: ${GREEN}${VARS[HY2_PASSWORD]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入新密码 (回车自动生成): " input_pw
            VARS[HY2_PASSWORD]="${input_pw:-$(gen_password)}"
        fi
    else
        read -p "请输入 Hysteria2 密码 (回车自动生成): " input_pw
        VARS[HY2_PASSWORD]="${input_pw:-$(gen_password)}"
    fi
    
    if [[ -n "${VARS[HY2_PORT]}" ]]; then
        echo -e "当前端口: ${GREEN}${VARS[HY2_PORT]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            while true; do
                read -p "请输入 Hysteria2 端口 (1-65535, 默认8443): " input_port
                input_port="${input_port:-8443}"
                if validate_port "$input_port"; then
                    VARS[HY2_PORT]="$input_port"
                    break
                else
                    log ERROR "无效端口号，请重新输入"
                fi
            done
        fi
    else
        while true; do
            read -p "请输入 Hysteria2 端口 (1-65535, 默认8443): " input_port
            input_port="${input_port:-8443}"
            if validate_port "$input_port"; then
                VARS[HY2_PORT]="$input_port"
                break
            else
                log ERROR "无效端口号，请重新输入"
            fi
        done
    fi
    
    echo ""
    echo -e "${YELLOW}端口跳跃说明: 服务器会在指定范围内随机切换端口${NC}"
    echo -e "${YELLOW}建议范围: 30000-50000 (至少10个端口)${NC}"
    
    if [[ -n "${VARS[HY2_HOP_START]}" ]] && [[ -n "${VARS[HY2_HOP_END]}" ]]; then
        echo -e "当前跳跃范围: ${GREEN}${VARS[HY2_HOP_START]}-${VARS[HY2_HOP_END]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            configure_hop_ports
        fi
    else
        configure_hop_ports
    fi
    
    echo ""
    echo -e "${YELLOW}跳跃间隔说明: 设置随机范围后，客户端会在此范围内随机选择切换时间${NC}"
    
    if [[ -n "${VARS[HY2_MIN_HOP_INTERVAL]}" ]]; then
        echo -e "当前最小/最大跳跃间隔: ${GREEN}${VARS[HY2_MIN_HOP_INTERVAL]} / ${VARS[HY2_MAX_HOP_INTERVAL]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "最小跳跃间隔 (默认10s, 最低5s): " input_min
            VARS[HY2_MIN_HOP_INTERVAL]="${input_min:-10s}"
            read -p "最大跳跃间隔 (默认60s): " input_max
            VARS[HY2_MAX_HOP_INTERVAL]="${input_max:-60s}"
        fi
    else
        read -p "最小跳跃间隔 (默认10s, 最低5s): " input_min
        VARS[HY2_MIN_HOP_INTERVAL]="${input_min:-10s}"
        read -p "最大跳跃间隔 (默认60s): " input_max
        VARS[HY2_MAX_HOP_INTERVAL]="${input_max:-60s}"
    fi
    
    if [[ -n "${VARS[HY2_OBFS_PASSWORD]}" ]]; then
        echo -e "当前混淆密码: ${GREEN}${VARS[HY2_OBFS_PASSWORD]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "请输入混淆密码 (回车自动生成): " input_obfs
            VARS[HY2_OBFS_PASSWORD]="${input_obfs:-$(gen_password)}"
        fi
    else
        read -p "请输入混淆密码 (回车自动生成): " input_obfs
        VARS[HY2_OBFS_PASSWORD]="${input_obfs:-$(gen_password)}"
    fi
    
    if [[ -z "${VARS[SNI]}" ]]; then
        VARS[SNI]="www.bing.com"
    fi
    
    save_vars
    echo -e "${GREEN}✓ Hysteria2 配置完成${NC}"
}

configure_hop_ports() {
    while true; do
        read -p "请输入跳跃起始端口 (默认30000): " input_start
        input_start="${input_start:-30000}"
        read -p "请输入跳跃结束端口 (默认50000): " input_end
        input_end="${input_end:-50000}"
        
        validate_port_range "$input_start" "$input_end"
        local ret=$?
        if [[ $ret -eq 0 ]]; then
            VARS[HY2_HOP_START]="$input_start"
            VARS[HY2_HOP_END]="$input_end"
            break
        elif [[ $ret -eq 2 ]]; then
            log WARN "端口范围太小(至少10个)，建议扩大范围"
            read -p "是否仍使用此范围? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                VARS[HY2_HOP_START]="$input_start"
                VARS[HY2_HOP_END]="$input_end"
                break
            fi
        else
            log ERROR "无效的端口范围，请重新输入"
        fi
    done
}

#--------------------------- 配置保活参数 ---------------------------#
configure_keepalive() {
    log INFO "配置保活参数..."
    
    echo ""
    echo -e "${CYAN}========== 保活配置 ==========${NC}"
    echo -e "${YELLOW}保活功能可防止长时间无流量时连接被运营商/QoS中断${NC}"
    echo ""
    
    if [[ -z "${VARS[TCP_KEEPALIVE_INTERVAL]}" ]]; then
        read -p "TCP 保活间隔(秒, 默认30): " input_interval
        VARS[TCP_KEEPALIVE_INTERVAL]="${input_interval:-30}"
    else
        echo -e "当前 TCP 保活间隔: ${GREEN}${VARS[TCP_KEEPALIVE_INTERVAL]}秒${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "TCP 保活间隔(秒, 默认30): " input_interval
            VARS[TCP_KEEPALIVE_INTERVAL]="${input_interval:-30}"
        fi
    fi
    
    if [[ -z "${VARS[HY2_HEARTBEAT]}" ]]; then
        read -p "Hysteria2 心跳间隔(默认10s): " input_hb
        VARS[HY2_HEARTBEAT]="${input_hb:-10s}"
    else
        echo -e "当前 Hysteria2 心跳间隔: ${GREEN}${VARS[HY2_HEARTBEAT]}${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Hysteria2 心跳间隔(默认10s): " input_hb
            VARS[HY2_HEARTBEAT]="${input_hb:-10s}"
        fi
    fi
    
    if [[ -z "${VARS[HY2_IDLE_TIMEOUT]}" ]]; then
        read -p "Hysteria2 空闲超时(秒, 0=不超时, 默认0): " input_idle
        VARS[HY2_IDLE_TIMEOUT]="${input_idle:-0}"
    else
        echo -e "当前 Hysteria2 空闲超时: ${GREEN}${VARS[HY2_IDLE_TIMEOUT]}秒${NC}"
        read -p "是否修改? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Hysteria2 空闲超时(秒, 0=不超时, 默认0): " input_idle
            VARS[HY2_IDLE_TIMEOUT]="${input_idle:-0}"
        fi
    fi
    
    save_vars
    echo -e "${GREEN}✓ 保活配置完成${NC}"
}

#--------------------------- 备份配置 ---------------------------#
backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_name="config_$(date +%Y%m%d_%H%M%S).json"
        cp "$CONFIG_FILE" "${BACKUP_DIR}/${backup_name}"
        log INFO "配置已备份: ${backup_name}"
        ls -t "${BACKUP_DIR}"/config_*.json 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
    fi
}

#--------------------------- 生成 Sing-Box 配置 ---------------------------#
generate_singbox_config() {
    log INFO "生成 Sing-Box 配置..."
    backup_config
    
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VARS[REALITY_PORT]},
      "sniff": true,
      "sniff_override_destination": false,
      "users": [
        {
          "uuid": "${VARS[REALITY_UUID]}",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${VARS[REALITY_SERVER_NAME]}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${VARS[REALITY_DEST]}",
            "server_port": 443
          },
          "private_key": "${VARS[REALITY_PRIVATE_KEY]}",
          "short_id": ["${VARS[REALITY_SHORT_ID]}"]
        }
      },
      "transport": {
        "type": "tcp",
        "tcp": {
          "keepalive_interval": ${VARS[TCP_KEEPALIVE_INTERVAL]}
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${VARS[HY2_PORT]},
      "sniff": true,
      "sniff_override_destination": false,
      "up_mbps": 1000,
      "down_mbps": 1000,
      "idle_timeout": "${VARS[HY2_IDLE_TIMEOUT]}s",
      "heartbeat": "${VARS[HY2_HEARTBEAT]}",
      "users": [
        {
          "password": "${VARS[HY2_PASSWORD]}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${VARS[SNI]}",
        "alpn": ["h3"],
        "min_version": "1.2",
        "max_version": "1.3",
        "cipher_suites": "TLS_CHACHA20_POLY1305_SHA256"
      },
      "masquerade": "https://${VARS[SNI]}",
      "obfs": {
        "type": "salamander",
        "password": "${VARS[HY2_OBFS_PASSWORD]}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "block"
      }
    ]
  }
}
EOF
    
    log INFO "Sing-Box 配置生成完成"
    chmod 600 "$CONFIG_FILE"
}

#--------------------------- 生成分享链接 ---------------------------#
generate_links() {
    local server_ip
    server_ip=$(get_server_ip)
    
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          节点分享链接                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    
    # Reality 链接
    local reality_link="vless://${VARS[REALITY_UUID]}@${server_ip}:${VARS[REALITY_PORT]}?encryption=none&flow=&security=reality&sni=${VARS[REALITY_SERVER_NAME]}&fp=chrome&pbk=${VARS[REALITY_PUBLIC_KEY]}&sid=${VARS[REALITY_SHORT_ID]}&type=tcp&headerType=none#Reality-${server_ip}"
    
    echo -e "${GREEN}═══ Reality 节点 ═══${NC}"
    echo -e "${YELLOW}链接:${NC}"
    echo "$reality_link"
    echo ""
    
    # Hysteria2 链接 (含随机跳跃间隔参数)
    local hy2_link="hysteria2://${VARS[HY2_PASSWORD]}@${server_ip}:${VARS[HY2_PORT]}?sni=${VARS[SNI]}&alpn=h3&obfs=salamander&obfs-password=${VARS[HY2_OBFS_PASSWORD]}&min-hop-interval=${VARS[HY2_MIN_HOP_INTERVAL]}&max-hop-interval=${VARS[HY2_MAX_HOP_INTERVAL]}&mport=${VARS[HY2_HOP_START]}%2C${VARS[HY2_HOP_END]}#Hysteria2-${server_ip}"
    
    echo -e "${GREEN}═══ Hysteria2 节点 ═══${NC}"
    echo -e "${YELLOW}链接:${NC}"
    echo "$hy2_link"
    echo ""
    
    cat > "${SINGBOX_DIR}/links.txt" << EOF
Reality 节点:
${reality_link}

Hysteria2 节点:
${hy2_link}
EOF
    chmod 600 "${SINGBOX_DIR}/links.txt"
    
    echo -e "${GREEN}链接已保存到: ${SINGBOX_DIR}/links.txt${NC}"
}

#--------------------------- 配置防火墙 ---------------------------#
configure_firewall() {
    log INFO "配置防火墙规则..."
    
    if [[ -n "${VARS[REALITY_PORT]}" ]]; then
        ufw allow "${VARS[REALITY_PORT]}/tcp" comment "Reality" >> "$LOG_FILE" 2>&1
        log INFO "放行 Reality 端口: ${VARS[REALITY_PORT]}/tcp"
    fi
    
    if [[ -n "${VARS[HY2_PORT]}" ]]; then
        ufw allow "${VARS[HY2_PORT]}/udp" comment "Hysteria2" >> "$LOG_FILE" 2>&1
        log INFO "放行 Hysteria2 主端口: ${VARS[HY2_PORT]}/udp"
    fi
    
    if [[ -n "${VARS[HY2_HOP_START]}" ]] && [[ -n "${VARS[HY2_HOP_END]}" ]]; then
        ufw allow "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}/udp" comment "Hysteria2 Hop" >> "$LOG_FILE" 2>&1
        log INFO "放行 Hysteria2 跳跃端口范围: ${VARS[HY2_HOP_START]}-${VARS[HY2_HOP_END]}/udp"
    fi
    
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >> "$LOG_FILE" 2>&1
        log INFO "UFW 防火墙已启用"
    fi
    
    log INFO "防火墙配置完成"
}

#--------------------------- 设置 NAT 端口转发 ---------------------------#
setup_nat_forwarding() {
    log INFO "配置 NAT 端口转发 (端口跳跃)..."
    
    iptables -t nat -D PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}" 2>/dev/null || true
    
    iptables -t nat -A PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}"
    ip6tables -t nat -A PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}"
    
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    else
        apt-get install -y -qq iptables-persistent >> "$LOG_FILE" 2>&1
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    fi
    
    log INFO "NAT 端口转发配置完成"
}

#--------------------------- 配置系统参数 ---------------------------#
configure_sysctl() {
    log INFO "优化系统参数..."
    
    cat > /etc/sysctl.d/99-singbox.conf << EOF
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# UDP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# 启用 IP 转发
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    
    sysctl -p /etc/sysctl.d/99-singbox.conf >> "$LOG_FILE" 2>&1
    log INFO "系统参数优化完成"
}

#--------------------------- 启动服务 ---------------------------#
start_service() {
    log INFO "启动 Sing-Box 服务..."
    
    systemctl enable sing-box >> "$LOG_FILE" 2>&1
    systemctl restart sing-box >> "$LOG_FILE" 2>&1
    
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        log INFO "Sing-Box 服务运行正常"
    else
        log ERROR "Sing-Box 服务启动失败，请检查日志: journalctl -u sing-box -n 50"
        return 1
    fi
}

#--------------------------- 状态检查 ---------------------------#
check_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          服务状态检查                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    
    if systemctl is-active --quiet sing-box; then
        echo -e "Sing-Box:    ${GREEN}运行中${NC}"
    else
        echo -e "Sing-Box:    ${RED}未运行${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}端口监听状态:${NC}"
    if [[ -n "${VARS[REALITY_PORT]}" ]]; then
        if ss -tlnp | grep -q ":${VARS[REALITY_PORT]} "; then
            echo -e "  Reality ${VARS[REALITY_PORT]}/tcp:    ${GREEN}监听中${NC}"
        else
            echo -e "  Reality ${VARS[REALITY_PORT]}/tcp:    ${RED}未监听${NC}"
        fi
    fi
    
    if [[ -n "${VARS[HY2_PORT]}" ]]; then
        if ss -ulnp | grep -q ":${VARS[HY2_PORT]} "; then
            echo -e "  Hysteria2 ${VARS[HY2_PORT]}/udp: ${GREEN}监听中${NC}"
        else
            echo -e "  Hysteria2 ${VARS[HY2_PORT]}/udp: ${RED}未监听${NC}"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}UFW 状态:${NC}"
    ufw status verbose | grep -E "^${VARS[REALITY_PORT]}|^${VARS[HY2_PORT]}|${VARS[HY2_HOP_START]}" 2>/dev/null || echo "  (未找到相关规则)"
}

#--------------------------- 修改配置 ---------------------------#
modify_config() {
    load_vars
    
    while true; do
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          修改配置菜单                    ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}当前配置:${NC}"
        echo -e "  Reality UUID:      ${GREEN}${VARS[REALITY_UUID]:-未设置}${NC}"
        echo -e "  Reality 端口:      ${GREEN}${VARS[REALITY_PORT]:-未设置}${NC}"
        echo -e "  Reality 回落:      ${GREEN}${VARS[REALITY_DEST]:-未设置}${NC}"
        echo -e "  Hysteria2 密码:    ${GREEN}${VARS[HY2_PASSWORD]:-未设置}${NC}"
        echo -e "  Hysteria2 端口:    ${GREEN}${VARS[HY2_PORT]:-未设置}${NC}"
        echo -e "  跳跃端口范围:      ${GREEN}${VARS[HY2_HOP_START]:-未设置}-${VARS[HY2_HOP_END]:-未设置}${NC}"
        echo -e "  随机跳跃间隔:      ${GREEN}${VARS[HY2_MIN_HOP_INTERVAL]:-未设置} ~ ${VARS[HY2_MAX_HOP_INTERVAL]:-未设置}${NC}"
        echo -e "  混淆密码:          ${GREEN}${VARS[HY2_OBFS_PASSWORD]:-未设置}${NC}"
        echo -e "  TCP保活间隔:       ${GREEN}${VARS[TCP_KEEPALIVE_INTERVAL]:-未设置}秒${NC}"
        echo -e "  HY2心跳间隔:       ${GREEN}${VARS[HY2_HEARTBEAT]:-未设置}${NC}"
        echo -e "  HY2空闲超时:       ${GREEN}${VARS[HY2_IDLE_TIMEOUT]:-未设置}秒${NC}"
        echo ""
        echo "1. 修改 Reality 配置"
        echo "2. 修改 Hysteria2 配置"
        echo "3. 修改保活参数"
        echo "4. 重新生成所有配置"
        echo "5. 重新部署服务"
        echo "6. 返回主菜单"
        echo ""
        read -p "请选择 [1-6]: " choice
        
        case $choice in
            1) configure_reality ;;
            2) configure_hysteria2 ;;
            3) configure_keepalive ;;
            4)
                generate_singbox_config
                generate_links
                configure_firewall
                setup_nat_forwarding
                log INFO "配置已重新生成"
                ;;
            5)
                generate_singbox_config
                generate_links
                configure_firewall
                setup_nat_forwarding
                configure_sysctl
                start_service
                log INFO "服务已重新部署"
                ;;
            6) return ;;
            *) log ERROR "无效选择" ;;
        esac
    done
}

#--------------------------- 完全卸载 ---------------------------#
uninstall() {
    echo ""
    echo -e "${RED}⚠️  警告: 这将完全卸载 Sing-Box 和所有配置！${NC}"
    read -p "确认卸载? 输入 YES 继续: " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        echo "已取消"
        return
    fi
    
    log WARN "开始卸载..."
    
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    
    iptables -t nat -D PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "${VARS[HY2_HOP_START]}:${VARS[HY2_HOP_END]}" -j REDIRECT --to-port "${VARS[HY2_PORT]}" 2>/dev/null || true
    
    rm -rf "$SINGBOX_DIR" 2>/dev/null
    rm -f "$SINGBOX_BIN" 2>/dev/null
    rm -f /etc/apt/sources.list.d/sing-box.list 2>/dev/null
    rm -f /etc/apt/keyrings/sing-box.gpg 2>/dev/null
    rm -f /etc/sysctl.d/99-singbox.conf 2>/dev/null
    
    log INFO "卸载完成"
}

#--------------------------- 主菜单 ---------------------------#
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║   Reality + Hysteria2 安全部署脚本      ║${NC}"
        echo -e "${CYAN}║         Sing-Box 内核 v2.0              ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo "1. 完整部署 (交互式配置 + 安装 + 启动)"
        echo "2. 仅重新配置"
        echo "3. 修改现有配置"
        echo "4. 查看节点链接"
        echo "5. 查看服务状态"
        echo "6. 启动/重启服务"
        echo "7. 停止服务"
        echo "8. 完全卸载"
        echo "0. 退出"
        echo ""
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1)
                load_vars
                install_singbox
                configure_reality
                configure_hysteria2
                configure_keepalive
                generate_singbox_config
                generate_links
                configure_firewall
                setup_nat_forwarding
                configure_sysctl
                start_service
                check_status
                echo ""
                echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
                echo -e "${GREEN}║           部署完成！                    ║${NC}"
                echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}请务必在云服务商安全组中放行以下端口:${NC}"
                echo -e "  - Reality TCP: ${VARS[REALITY_PORT]}"
                echo -e "  - Hysteria2 UDP: ${VARS[HY2_PORT]}"
                echo -e "  - 跳跃端口 UDP: ${VARS[HY2_HOP_START]}-${VARS[HY2_HOP_END]}"
                ;;
            2)
                load_vars
                configure_reality
                configure_hysteria2
                configure_keepalive
                generate_singbox_config
                generate_links
                configure_firewall
                setup_nat_forwarding
                start_service
                ;;
            3) modify_config ;;
            4)
                load_vars
                generate_links
                ;;
            5) check_status ;;
            6) start_service ;;
            7)
                systemctl stop sing-box
                log INFO "Sing-Box 服务已停止"
                ;;
            8)
                load_vars
                uninstall
                ;;
            0)
                echo "再见！"
                exit 0
                ;;
            *) log ERROR "无效选择，请重试" ;;
        esac
    done
}

#--------------------------- 脚本入口 ---------------------------#
main() {
    check_root
    check_deps
    init_dirs
    load_vars
    main_menu
}

main "$@"
