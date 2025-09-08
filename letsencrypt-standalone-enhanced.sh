#!/bin/bash
# 增强版独立 Let's Encrypt 安装脚本
# 基于 swizzin 项目，整合 kejilion 的优秀配置

set -e

# 颜色输出函数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 参数解析（支持命令行开关以跳过交互）
parse_args() {
    # 允许通过环境变量预设，命令行优先
    ENABLE_CDN_REALIP=${ENABLE_CDN_REALIP:-}
    ENABLE_NEZHA=${ENABLE_NEZHA:-}
    LE_HOSTNAME=${LE_HOSTNAME:-}
    LE_BACKEND=${LE_BACKEND:-}
    USE_CF=${USE_CF:-}
    LE_CF_EMAIL=${LE_CF_EMAIL:-}
    LE_CF_API=${LE_CF_API:-}
    LE_CF_ZONE=${LE_CF_ZONE:-}
    LE_CF_ZONEEXISTS=${LE_CF_ZONEEXISTS:-}

    while [ $# -gt 0 ]; do
        case "$1" in
            --hostname=*) LE_HOSTNAME="${1#*=}" ;;
            --backend=*) LE_BACKEND="${1#*=}" ;;
            --cdn-realip) ENABLE_CDN_REALIP="yes" ;;
            --no-cdn-realip) ENABLE_CDN_REALIP="no" ;;
            --nezha) ENABLE_NEZHA="yes" ;;
            --no-nezha) ENABLE_NEZHA="no" ;;
            --cf) USE_CF="yes" ;;
            --no-cf) USE_CF="no" ;;
            --cf-email=*) LE_CF_EMAIL="${1#*=}" ;;
            --cf-api=*) LE_CF_API="${1#*=}" ;;
            --cf-zone=*) LE_CF_ZONE="${1#*=}" ;;
            --cf-zone-exists=*) LE_CF_ZONEEXISTS="${1#*=}" ;;
            --help)
                echo "用法: $0 \\
  [--hostname=域名] [--backend=URL] \\
  [--cdn-realip|--no-cdn-realip] [--nezha|--no-nezha] \\
  [--cf|--no-cf] [--cf-email=EMAIL] [--cf-api=API_KEY] [--cf-zone=ZONE] [--cf-zone-exists=yes|no]"; exit 0 ;;
        esac
        shift
    done
}

# 检测 Nginx 特性支持
detect_nginx_features() {
    local info
    info=$(nginx -V 2>&1 || true)
    if echo "$info" | grep -qi -- "--with-http_v2"; then
        SUPPORT_HTTP2="yes"
    else
        SUPPORT_HTTP2="no"
    fi
    if echo "$info" | grep -qi -- "--with-http_v3"; then
        SUPPORT_HTTP3="yes"
    else
        SUPPORT_HTTP3="no"
    fi
}

# 生成/更新 Cloudflare Real-IP 片段
ensure_cloudflare_realip_snippet() {
    mkdir -p /etc/nginx/snippets
    cat > /etc/nginx/snippets/cloudflare-realip.conf << 'EOF'
underscores_in_headers on;
# 静态种子列表（首次安装可用），后续可用更新脚本自动刷新
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;

set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;
EOF
}

# 安装 Cloudflare Real-IP 自动更新（systemd 定时）
install_cloudflare_realip_updater() {
    cat > /usr/local/bin/update-cloudflare-realip.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

TMP_DIR=$(mktemp -d)
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT

curl -fsSL https://www.cloudflare.com/ips-v4 -o "$TMP_DIR/ips-v4" || exit 1
curl -fsSL https://www.cloudflare.com/ips-v6 -o "$TMP_DIR/ips-v6" || exit 1

{
  echo 'underscores_in_headers on;'
  while read -r cidr; do
    [ -n "$cidr" ] && echo "set_real_ip_from $cidr;"
  done < "$TMP_DIR/ips-v4"
  while read -r cidr6; do
    [ -n "$cidr6" ] && echo "set_real_ip_from $cidr6;"
  done < "$TMP_DIR/ips-v6"
  echo 'real_ip_header CF-Connecting-IP;'
} > /etc/nginx/snippets/cloudflare-realip.conf.new

mv /etc/nginx/snippets/cloudflare-realip.conf.new /etc/nginx/snippets/cloudflare-realip.conf

if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx || true
fi
EOF
    chmod +x /usr/local/bin/update-cloudflare-realip.sh

    cat > /etc/systemd/system/cloudflare-realip-update.service << 'EOF'
[Unit]
Description=Update Cloudflare Real-IP ranges for Nginx
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-cloudflare-realip.sh
EOF

    cat > /etc/systemd/system/cloudflare-realip-update.timer << 'EOF'
[Unit]
Description=Weekly update of Cloudflare Real-IP ranges

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cloudflare-realip-update.timer || true
}

# 询问函数
ask() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" -r response
    response=${response:-$default}
    
    if [[ $response =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# 检查 nginx 是否安装
check_nginx() {
    if ! command -v nginx &> /dev/null; then
        log_error "nginx 未安装，请先安装 nginx"
        exit 1
    fi
    
    if ! systemctl is-active --quiet nginx; then
        log_warn "nginx 未运行，尝试启动..."
        systemctl start nginx
    fi
}

# 获取服务器 IP
get_server_ip() {
    local ip=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
    if [ -z "$ip" ]; then
        ip=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "无法获取IP")
    fi
    echo "$ip"
}

# 验证 Cloudflare API
validate_cloudflare_api() {
    local email="$1"
    local api_key="$2"
    
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json")
    
    if echo "$response" | grep -q '"success":false'; then
        log_error "Cloudflare API 验证失败:"
        echo "$response"
        return 1
    fi
    
    return 0
}

# 添加 Cloudflare DNS 记录
add_cloudflare_record() {
    local hostname="$1"
    local ip="$2"
    local email="$3"
    local api_key="$4"
    local zone="$5"
    
    local zoneid=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
    
    if [ -z "$zoneid" ]; then
        log_error "无法找到域名 $zone 的 zone ID"
        return 1
    fi
    
    local addrecord=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" \
        -H "X-Auth-Email: $email" \
        -H "X-Auth-Key: $api_key" \
        -H "Content-Type: application/json" \
        --data "{\"id\":\"$zoneid\",\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"proxied\":true}")
    
    if echo "$addrecord" | grep -q '"success":false'; then
        log_error "添加 DNS 记录失败:"
        echo "$addrecord"
        return 1
    else
        log_success "DNS 记录已添加: $hostname -> $ip"
        return 0
    fi
}

# 安装 acme.sh
install_acme() {
    if [ ! -f /root/.acme.sh/acme.sh ]; then
        log_info "安装 acme.sh..."
        curl https://get.acme.sh | sh
        log_success "acme.sh 安装完成"
    else
        log_info "acme.sh 已安装"
    fi
}

# 设置默认 CA
set_default_ca() {
    log_info "设置默认证书颁发机构为 Let's Encrypt..."
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt || {
        log_warn "无法设置默认 CA，尝试升级 acme.sh..."
        /root/.acme.sh/acme.sh --upgrade || {
            log_error "无法升级 acme.sh"
            exit 1
        }
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt || {
            log_error "无法设置默认证书颁发机构"
            exit 1
        }
        log_success "acme.sh 升级成功"
    }
}

# 申请证书
issue_certificate() {
    local hostname="$1"
    local cf="$2"
    
    log_info "申请证书 for $hostname..."
    
    if [ "$cf" = "yes" ]; then
        /root/.acme.sh/acme.sh --force --issue --dns dns_cf -d "$hostname" || {
            log_error "证书申请失败"
            exit 1
        }
    else
        # 检查是否要应用到默认配置
        if ask "是否要将此证书应用到 nginx 默认配置？"; then
            /root/.acme.sh/acme.sh --force --issue --nginx -d "$hostname" || {
                log_error "证书申请失败"
                exit 1
            }
        else
            systemctl stop nginx
            /root/.acme.sh/acme.sh --force --issue --standalone -d "$hostname" \
                --pre-hook "systemctl stop nginx" \
                --post-hook "systemctl start nginx" || {
                log_error "证书申请失败，请检查信息后重试"
                exit 1
            }
            sleep 1
            systemctl start nginx
        fi
    fi
    
    log_success "证书申请成功"
}

# 创建增强版站点配置
create_enhanced_site_config() {
    local hostname="$1"
    local backend_url="$2"
    local enable_cdn_realip="${3:-no}"
    local enable_nezha_grpc="${4:-no}"
    local enable_nezha_ws="${5:-no}"

    log_info "创建增强版站点配置..."

    # 动态构造 listen 参数（站点级不使用 reuseport，避免与默认站点冲突）
    local listen_ssl_v4="listen 443 ssl;"
    local listen_ssl_v6="listen [::]:443 ssl;"
    local listen_quic_v4=""
    local listen_quic_v6=""
    if [ "${SUPPORT_HTTP2}" = "yes" ]; then
        listen_ssl_v4="listen 443 ssl http2;"
        listen_ssl_v6="listen [::]:443 ssl http2;"
    fi
    if [ "${SUPPORT_HTTP3}" = "yes" ]; then
        listen_quic_v4="listen 443 quic;"
        listen_quic_v6="listen [::]:443 quic;"
    fi

    # 提取后端 host 与端口（供 gRPC/WebSocket 使用）
    local backend_authority backend_host backend_port
    backend_authority=$(echo "$backend_url" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1)
    backend_host=$(echo "$backend_authority" | cut -d: -f1)
    backend_port=$(echo "$backend_authority" | awk -F: '{print $2}')

    cat > /etc/nginx/sites-available/${hostname} << EOF
# HTTP 重定向到 HTTPS（站点级不使用 reuseport）
server {
    listen 80;
    listen [::]:80;
    server_name ${hostname};

    # Let's Encrypt 验证
    location /.well-known {
        alias /srv/.well-known;
        allow all;
        default_type "text/plain";
        autoindex on;
    }

    # 重定向到 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 配置
server {
    ${listen_ssl_v4}
    ${listen_ssl_v6}
    ${listen_quic_v4}
    ${listen_quic_v6}
    
    server_name ${hostname};

    # SSL 证书
    ssl_certificate /etc/nginx/ssl/${hostname}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${hostname}/key.pem;
    include snippets/ssl-params.conf;

    # 基本配置
    client_max_body_size 1000m;
    server_tokens off;
    root /srv/;

    # 包含应用配置
    include /etc/nginx/apps/*.conf;

$( [ "$enable_cdn_realip" = "yes" ] && echo '    include snippets/cloudflare-realip.conf;' )

    # 静态文件处理
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|bmp|swf|eot|svg|ttf|woff|woff2|webp)$ {
        proxy_pass ${backend_url};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;

        # 缓存配置
        proxy_cache my_proxy_cache;
        proxy_set_header Accept-Encoding "";
        aio threads;
        # 仅在支持 HTTP/3 时添加 Alt-Svc
        # shellcheck disable=SC2016
        $( [ "${SUPPORT_HTTP3}" = "yes" ] && echo "add_header Alt-Svc 'h3=\":443\"; ma=86400';" )
        log_not_found off;
        access_log off;
    }

$(
  if [ "$enable_nezha_grpc" = "yes" ] && [ -n "$backend_port" ]; then
    cat << EOR
    # gRPC 相关（哪吒面板）
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
$( [ "$enable_cdn_realip" = "yes" ] && echo '        grpc_set_header nz-realip \$http_CF-Connecting-IP;' )
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://${backend_host}:${backend_port};
    }
EOR
  fi
)

$(
  if [ "$enable_nezha_ws" = "yes" ]; then
    cat << 'EOR'
    # websocket 相关（哪吒面板）
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host $host;
EOR
    if [ "$enable_cdn_realip" = "yes" ]; then
      echo '        proxy_set_header nz-realip $http_CF-Connecting-IP;'
    fi
    cat << EOR
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass ${backend_url};
    }
EOR
  fi
)

    # 主要代理配置
    location / {
        include snippets/proxy.conf;
        proxy_pass ${backend_url};
        
        # 仅在支持 HTTP/3 时添加 Alt-Svc
        # shellcheck disable=SC2016
        $( [ "${SUPPORT_HTTP3}" = "yes" ] && echo "add_header Alt-Svc 'h3=\":443\"; ma=86400';" )
    }

    # 安全配置
    location ~ /\.ht {
        deny all;
    }
    
    # 隐藏敏感文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # 启用站点
    ln -sf /etc/nginx/sites-available/${hostname} /etc/nginx/sites-enabled/
    log_success "站点配置已创建: /etc/nginx/sites-available/${hostname}"
}

# 安装证书
install_certificate() {
    local hostname="$1"
    local backend_url="$2"
    
    log_info "安装证书..."
    
    # 创建证书目录
    mkdir -p /etc/nginx/ssl/${hostname}
    chmod 700 /etc/nginx/ssl
    
    # 安装证书
    /root/.acme.sh/acme.sh --force --install-cert -d "$hostname" \
        --key-file /etc/nginx/ssl/${hostname}/key.pem \
        --fullchain-file /etc/nginx/ssl/${hostname}/fullchain.pem \
        --ca-file /etc/nginx/ssl/${hostname}/chain.pem \
        --reloadcmd "systemctl reload nginx"
    
    # 如果选择应用到默认配置，更新 nginx 配置
    # 创建增强版站点配置
    create_enhanced_site_config "$hostname" "$backend_url"
    
    log_success "证书安装完成"
}

# 主函数
main() {
    log_info "开始增强版 Let's Encrypt 证书安装..."
    parse_args "$@"
    
    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
    
    # 检查 nginx
    check_nginx
    
    # 获取服务器 IP
    local ip=$(get_server_ip)
    log_info "服务器 IP: $ip"
    
    # 获取域名
    local hostname
    if [ -z "$LE_HOSTNAME" ]; then
        read -p "请输入要申请证书的域名: " hostname
    else
        hostname="$LE_HOSTNAME"
    fi
    
    if [ -z "$hostname" ]; then
        log_error "域名不能为空"
        exit 1
    fi
    
    # 获取后端URL（必填）
    local backend_url=""
    if [ -z "$LE_BACKEND" ]; then
        read -p "请输入后端服务URL (例如: http://127.0.0.1:8080): " backend_url
    else
        backend_url="$LE_BACKEND"
    fi
    if [ -z "$backend_url" ]; then
        log_error "后端URL不能为空"
        exit 1
    fi
    
    # 检查是否使用 Cloudflare
    local use_cf="no"
    if [ -n "$LE_CF_API" ] || [ -n "$LE_CF_EMAIL" ] || [ -n "$LE_CF_ZONE" ]; then
        use_cf="yes"
    fi
    if [ -n "$USE_CF" ]; then
        use_cf="$USE_CF"
    elif [ "$use_cf" = "no" ]; then
        if ask "您的 DNS 是否由 Cloudflare 管理？"; then
            use_cf="yes"
        fi
    fi
    
    # 处理 Cloudflare 配置
    if [ "$use_cf" = "yes" ]; then
        # 检查不支持的 TLD
        if [[ $hostname =~ (\.cf$|\.ga$|\.gq$|\.ml$|\.tk$) ]]; then
            log_error "Cloudflare 不支持以下 TLD 的 API 调用: .cf, .ga, .gq, .ml, .tk"
            exit 1
        fi
        
        # 获取 Cloudflare 凭据
        local cf_email cf_api_key cf_zone
        if [ -z "$LE_CF_EMAIL" ]; then
            read -p "请输入 Cloudflare 邮箱: " cf_email
        else
            cf_email="$LE_CF_EMAIL"
        fi
        
        if [ -z "$LE_CF_API" ]; then
            read -p "请输入 Cloudflare API Key: " cf_api_key
        else
            cf_api_key="$LE_CF_API"
        fi
        
        # 验证 API
        if ! validate_cloudflare_api "$cf_email" "$cf_api_key"; then
            exit 1
        fi
        
        # 设置环境变量
        export CF_Key="$cf_api_key"
        export CF_Email="$cf_email"
        
        # 检查是否需要添加 DNS 记录
        local record_exists
        if [ -z "$LE_CF_ZONEEXISTS" ]; then
            if ask "此子域名的记录是否已存在？"; then
                record_exists="yes"
            else
                record_exists="no"
            fi
        else
            record_exists="$LE_CF_ZONEEXISTS"
        fi
        
        if [ "$record_exists" = "no" ]; then
            if [ -z "$LE_CF_ZONE" ]; then
                read -p "请输入主域名 (例如: example.com): " cf_zone
            else
                cf_zone="$LE_CF_ZONE"
            fi
            
            add_cloudflare_record "$hostname" "$ip" "$cf_email" "$cf_api_key" "$cf_zone"
        fi
    fi
    
    # 仅当使用 standalone 挑战且未安装时才安装 socat
    if [ "$use_cf" != "yes" ]; then
        if ! command -v socat >/dev/null 2>&1; then
            log_info "安装 socat..."
            apt-get -qq update
            apt-get -y -qq install socat
        fi
    fi
    
    # 安装和配置 acme.sh
    install_acme
    set_default_ca
    
    # 检测 Nginx 特性用于后续站点生成
    detect_nginx_features
    
    # 申请证书（优先 Cloudflare DNS，否则使用 standalone 模式）
    systemctl stop nginx || true
    if [ "$use_cf" = "yes" ]; then
        log_info "申请证书 (Cloudflare DNS 模式)..."
        /root/.acme.sh/acme.sh --force --issue --dns dns_cf -d "$hostname" || {
            log_error "证书申请失败"
            exit 1
        }
    else
        log_info "申请证书 (standalone 模式)..."
        /root/.acme.sh/acme.sh --force --issue --standalone -d "$hostname" || {
            log_error "证书申请失败"
            exit 1
        }
    fi
    systemctl start nginx || true
    
    # 交互/命令行开关：CDN回源 与 哪吒路由
    # CDN 回源
    if [ -z "$ENABLE_CDN_REALIP" ]; then
        if ask "是否设置 Cloudflare CDN 回源真实IP？"; then ENABLE_CDN_REALIP="yes"; else ENABLE_CDN_REALIP="no"; fi
    fi
    if [ "$ENABLE_CDN_REALIP" = "yes" ]; then
        ensure_cloudflare_realip_snippet
        install_cloudflare_realip_updater
    fi

    # 哪吒 gRPC + WebSocket（打包成一项开关）
    if [ -z "$ENABLE_NEZHA" ]; then
        if ask "是否设置 哪吒 gRPC + WebSocket 路由？"; then ENABLE_NEZHA="yes"; else ENABLE_NEZHA="no"; fi
    fi
    local ENABLE_NEZHA_GRPC="no"
    local ENABLE_NEZHA_WS="no"
    if [ "$ENABLE_NEZHA" = "yes" ]; then
        ENABLE_NEZHA_GRPC="yes"
        ENABLE_NEZHA_WS="yes"
    fi

    # 安装证书 + 生成站点
    install_certificate "$hostname" "$backend_url"
    # 覆盖生成一次以带上开关（证书步骤已经创建一次，不影响）
    create_enhanced_site_config "$hostname" "$backend_url" "$ENABLE_CDN_REALIP" "$ENABLE_NEZHA_GRPC" "$ENABLE_NEZHA_WS"
    
    # 测试配置
    if nginx -t; then
        log_success "nginx 配置测试通过"
        systemctl reload nginx
    else
        log_error "nginx 配置测试失败，请检查配置"
        exit 1
    fi
    
    log_success "增强版 Let's Encrypt 证书安装完成！"
    echo
    log_info "配置信息："
    log_info "  域名: $hostname"
    log_info "  证书位置: /etc/nginx/ssl/$hostname/"
    log_info "  证书文件:"
    log_info "    - 私钥: /etc/nginx/ssl/$hostname/key.pem"
    log_info "    - 证书链: /etc/nginx/ssl/$hostname/fullchain.pem"
    log_info "    - CA 证书: /etc/nginx/ssl/$hostname/chain.pem"
    if [ "$apply_to_default" = "no" ] && [ -n "$backend_url" ]; then
        log_info "  站点配置: /etc/nginx/sites-available/$hostname"
        log_info "  后端服务: $backend_url"
    fi
    echo
    log_info "新增功能："
    log_info "  ✓ HTTP/3 和 QUIC 支持"
    log_info "  ✓ 增强的 SSL 配置"
    log_info "  ✓ 静态文件缓存优化"
    log_info "  ✓ 安全头配置"
    log_info "  ✓ 自动重定向 HTTP 到 HTTPS"
    log_info "  ✓ Let's Encrypt 验证支持"
}

# 运行主函数
main "$@"
