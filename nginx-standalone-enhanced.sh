#!/bin/bash
# 增强版独立 nginx 安装脚本
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

# 简洁日志与进度展示
LOG_FILE="/var/log/nginx-standalone-enhanced.log"
SP_PID=""
SP_MSG=""

init_log() {
    mkdir -p /var/log
    : > "$LOG_FILE"
}

start_spinner() {
    SP_MSG="$1"
    { while true; do
        echo -ne "\r$SP_MSG ⏳   "
        sleep 0.2
        echo -ne "\r$SP_MSG ⏳.  "
        sleep 0.2
        echo -ne "\r$SP_MSG ⏳.. "
        sleep 0.2
        echo -ne "\r$SP_MSG ⏳..."
        sleep 0.2
    done; } &
    SP_PID=$!
}

stop_spinner_ok() {
    if [ -n "$SP_PID" ]; then
        kill "$SP_PID" 2>/dev/null || true
        wait "$SP_PID" 2>/dev/null || true
        SP_PID=""
        echo -ne "\r$SP_MSG ✅\n"
        SP_MSG=""
    fi
}

stop_spinner_fail() {
    if [ -n "$SP_PID" ]; then
        kill "$SP_PID" 2>/dev/null || true
        wait "$SP_PID" 2>/dev/null || true
        SP_PID=""
        echo -ne "\r$SP_MSG ❌\n"
        SP_MSG=""
    fi
}

run_quiet() {
    # 用法: run_quiet "描述" command args...
    local desc="$1"; shift
    start_spinner "$desc"
    if "$@" >>"$LOG_FILE" 2>&1; then
        stop_spinner_ok
        return 0
    else
        stop_spinner_fail
        log_error "执行失败：$desc（详见 $LOG_FILE）"
        return 1
    fi
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

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    echo "检测到系统: $OS $VER"
}

# 安装包函数
install_packages() {
    run_quiet "更新包列表..." env DEBIAN_FRONTEND=noninteractive apt-get -qq update
    
    run_quiet "安装 nginx 和增强包..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install nginx ssl-cert git curl wget
    
    # 安装 brotli 支持（如果可用）
    if apt-cache show libnginx-mod-http-brotli >>"$LOG_FILE" 2>&1; then
        run_quiet "安装 brotli 压缩支持..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install libnginx-mod-http-brotli
    else
        log_warn "brotli 模块不可用，将使用 gzip 压缩"
    fi
    
    # 安装 zstd 支持（如果可用）
    if apt-cache show libnginx-mod-http-zstd >>"$LOG_FILE" 2>&1; then
        run_quiet "安装 zstd 压缩支持..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install libnginx-mod-http-zstd
    else
        log_warn "zstd 模块不可用"
    fi
}

# 检测 nginx 运行用户与特性
detect_nginx_env() {
    # 检测运行用户
    if id -u nginx >/dev/null 2>&1; then
        NGINX_USER="nginx"
    elif id -u www-data >/dev/null 2>&1; then
        NGINX_USER="www-data"
    else
        # 兜底：尝试从日志目录拥有者推断；否则使用 nobody
        NGINX_USER=$(stat -c '%U' /var/log/nginx 2>/dev/null || echo "nobody")
    fi

    # 检测是否支持 HTTP/3/QUIC（编译参数包含 --with-http_v3）
    local nginx_build_info
    nginx_build_info=$(nginx -V 2>&1 || true)
    if echo "$nginx_build_info" | grep -qi -- "--with-http_v3"; then
        SUPPORT_HTTP3="yes"
    else
        SUPPORT_HTTP3="no"
    fi

    # 检测是否支持 HTTP/2（编译参数包含 --with-http_v2）
    if echo "$nginx_build_info" | grep -qi -- "--with-http_v2"; then
        SUPPORT_HTTP2="yes"
    else
        SUPPORT_HTTP2="no"
    fi
}

# 检查并处理 Apache 冲突
handle_apache_conflict() {
    if pgrep apache2 > /dev/null; then
        log_warn "检测到 Apache2 正在运行"
        read -p "是否要卸载 Apache2？(y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "卸载 Apache2..."
            systemctl stop apache2
            systemctl disable apache2
            apt remove --purge -y apache2
            log_success "Apache2 已卸载"
        else
            log_info "禁用 Apache2..."
            systemctl stop apache2
            systemctl disable apache2
            log_success "Apache2 已禁用"
        fi
    fi
}

# 生成 SSL 参数
generate_ssl_params() {
    log_info "生成 SSL 参数..."
    mkdir -p /etc/nginx/ssl/
    chmod 700 /etc/nginx/ssl
    cd /etc/nginx/ssl
    
    # 在后台生成 dhparam
    log_info "生成 DH 参数（这可能需要几分钟）..."
    openssl dhparam -out dhparam.pem 2048 >>"$LOG_FILE" 2>&1 &
    DH_PID=$!
}

# 配置 nginx 主配置
configure_nginx_main() {
    log_info "配置 nginx 主配置文件..."
    
    # 备份原始配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    
    # 创建增强版主配置
    if [ "${SUPPORT_HTTP3}" = "yes" ]; then
        HTTP3_HTTP_BLOCK="
    # HTTP/3 和 QUIC 支持
    http3 on;
    quic_gso on;
    quic_retry on;    
    http3_max_concurrent_streams 512;
    http3_stream_buffer_size 256k;
    quic_active_connection_id_limit 8;
"
    else
        HTTP3_HTTP_BLOCK=""
    fi

    if [ "${SUPPORT_HTTP2}" = "yes" ]; then
        HTTP2_HTTP_BLOCK="
    # HTTP/2 优化
    http2_max_concurrent_streams 512;
    http2_recv_buffer_size 512k;
    http2_body_preread_size 128k;    
    http2_chunk_size 16k;
"
    else
        HTTP2_HTTP_BLOCK=""
    fi

    # 先写入需要变量展开的第一行
    echo "user  ${NGINX_USER};" > /etc/nginx/nginx.conf
    # 其余内容用占位符写入，避免 $ 被 shell 展开
    cat >> /etc/nginx/nginx.conf << 'EOF'
worker_processes  auto;

# 加载模块（如果可用）
# load_module /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so;
# load_module /usr/lib/nginx/modules/ngx_http_brotli_static_module.so;
# load_module /usr/lib/nginx/modules/ngx_http_zstd_filter_module.so;
# load_module /usr/lib/nginx/modules/ngx_http_zstd_static_module.so;

error_log  /var/log/nginx/error.log error;
pid        /var/run/nginx.pid;

# 性能优化
worker_rlimit_nofile 65535;
thread_pool default threads=16 max_queue=65536;

events {
    multi_accept on;
    worker_connections 2048;
    use epoll;
}

http {
    server_tokens off;
__HTTP3_BLOCK__
__HTTP2_BLOCK__


    # SSL 优化
    ssl_prefer_server_ciphers on;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:30m;
    ssl_session_timeout 1h;
    ssl_buffer_size 32k;
    
    # 现代 SSL 密码套件
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256;

    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy "no-referrer";
    add_header Permissions-Policy "geolocation=(), microphone=()";
    add_header Vary "Accept-Encoding" always;

    # 哈希表优化
    server_names_hash_max_size 1024;
    server_names_hash_bucket_size 128;
    types_hash_max_size 2048;
    types_hash_bucket_size 128;
    variables_hash_max_size 1024;
    variables_hash_bucket_size 128;
    proxy_headers_hash_max_size 1024;
    proxy_headers_hash_bucket_size 128;

    # 文件缓存
    open_file_cache max=2000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # 限流和限连接
    limit_req_zone $binary_remote_addr zone=general:50m rate=50r/s;
    limit_req zone=general burst=150 nodelay;
    limit_req_status 429;

    limit_conn_zone $binary_remote_addr zone=addr:20m;
    limit_conn addr 200;
    limit_conn_status 429;
    
    limit_rate_after 100m;
    limit_rate 50m;

    # FastCGI 缓存
    fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2 keys_zone=my_cache:20m max_size=1g inactive=30m;
    fastcgi_cache_key "$request_method$host$request_uri$is_args$args$http_accept_encoding";
    fastcgi_cache_methods GET HEAD;
    fastcgi_cache_bypass $http_cookie;
    fastcgi_no_cache $http_cookie;
    fastcgi_cache_valid 200 301 302 304 120m;
    fastcgi_cache_valid 404 10m;
    fastcgi_cache_valid 500 502 503 504 400 403 429 0;
    fastcgi_cache_lock on;
    fastcgi_cache_lock_timeout 5s;
    fastcgi_cache_background_update on;
    
    fastcgi_buffering on;
    fastcgi_buffer_size 128k;
    fastcgi_buffers 16 4m;
    fastcgi_busy_buffers_size 8m;
    fastcgi_keep_conn on;
    fastcgi_intercept_errors on; 
    fastcgi_hide_header X-Powered-By;

    # 代理缓存
    proxy_cache_path /var/cache/nginx/proxy levels=1:2 keys_zone=my_proxy_cache:20m max_size=1g inactive=30m;
    proxy_cache_key "$request_method$host$request_uri$is_args$args$http_accept_encoding";
    proxy_cache_methods GET HEAD;
    proxy_cache_valid 200 301 302 304 120m;
    proxy_cache_valid 404 10m;
    proxy_cache_valid 500 502 503 504 400 403 429 0;
    proxy_cache_lock on;
    proxy_cache_lock_timeout 5s;
    proxy_cache_background_update on;

    proxy_buffering on;
    proxy_buffer_size 128k;
    proxy_buffers 16 4m;
    proxy_busy_buffers_size 8m;
    proxy_socket_keepalive on;
    proxy_intercept_errors on;
    proxy_hide_header X-Powered-By;
    
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # 详细日志格式
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" '
                      'rt=$request_time uct="$upstream_connect_time" '
                      'uht="$upstream_header_time" urt="$upstream_response_time"';
    
    access_log  /var/log/nginx/access.log main buffer=512k flush=10s;
    
    # 性能优化
    sendfile        on;
    tcp_nopush     on;
    tcp_nodelay    on;

    # 压缩配置
    gzip on;
    gzip_static on;
    gzip_comp_level 4;
    gzip_buffers 8 256k;
    gzip_min_length 50;
    gzip_types text/plain text/css text/javascript
            application/javascript application/json
            application/xml text/xml
            application/rss+xml application/atom+xml
            image/svg+xml
            font/woff font/woff2
            application/wasm;

    # Brotli 压缩（如果模块可用）
    # brotli on;
    # brotli_static on;
    # brotli_comp_level 4;
    # brotli_buffers 8 256k;
    # brotli_min_length 50;
    # brotli_window 1024k;
    # brotli_types text/plain text/css text/javascript
    #         application/javascript application/json
    #         application/xml text/xml
    #         application/rss+xml application/atom+xml
    #         image/svg+xml
    #         font/woff font/woff2
    #         application/wasm;

    # Zstd 压缩（如果模块可用）
    # zstd on;
    # zstd_static on;
    # zstd_comp_level 4;
    # zstd_buffers 8 256k;
    # zstd_min_length 50;
    # zstd_types text/plain text/css text/javascript
    #         application/javascript application/json
    #         application/xml text/xml
    #         application/rss+xml application/atom+xml
    #         image/svg+xml
    #         font/woff font/woff2
    #         application/wasm;

    # 连接优化
    reset_timedout_connection on;
    client_header_buffer_size 4k;
    client_body_buffer_size 256k;
    large_client_header_buffers 8 16k;
    output_buffers 8 1024k;

    # 超时配置
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 60s;
    keepalive_timeout 120s;
    keepalive_requests 8000;

    fastcgi_connect_timeout 300s;
    fastcgi_send_timeout 300s;
    fastcgi_read_timeout 300s;

    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;

    # 包含站点配置
    include /etc/nginx/sites-enabled/*;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    # 将占位符替换为实际 HTTP/2/3 片段
    awk -v h3="${HTTP3_HTTP_BLOCK}" -v h2="${HTTP2_HTTP_BLOCK}" '
      { if ($0=="__HTTP3_BLOCK__") { printf "%s\n", h3; next }
        if ($0=="__HTTP2_BLOCK__") { printf "%s\n", h2; next }
        print }
    ' /etc/nginx/nginx.conf > /etc/nginx/nginx.conf.tmp && mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
}

# 配置默认站点
configure_default_site() {
    log_info "配置默认站点..."
    
    # 删除默认配置
    rm -rf /etc/nginx/sites-enabled/default
    
    # 依据是否支持 HTTP/3 设置 listen 行
    if [ "${SUPPORT_HTTP3}" = "yes" ]; then
        LISTEN_QUIC_V4="    listen 443 quic reuseport default_server;"
        LISTEN_QUIC_V6="    listen [::]:443 quic reuseport default_server;"
    else
        LISTEN_QUIC_V4=""
        LISTEN_QUIC_V6=""
    fi

    # 依据是否支持 HTTP/2 设置参数
    if [ "${SUPPORT_HTTP2}" = "yes" ]; then
        LISTEN_SSL_HTTP2_PARAM=" http2"
    else
        LISTEN_SSL_HTTP2_PARAM=""
    fi

    # 创建默认站点配置
    cat > /etc/nginx/sites-enabled/default << EOF
# 默认服务器 - 处理无效请求
server {
    listen 80 reuseport default_server;
    listen [::]:80 reuseport default_server;
    listen 443 ssl${LISTEN_SSL_HTTP2_PARAM} reuseport default_server;
    listen [::]:443 ssl${LISTEN_SSL_HTTP2_PARAM} reuseport default_server;
$( [ -n "${LISTEN_QUIC_V4}" ] && echo "${LISTEN_QUIC_V4}" )
$( [ -n "${LISTEN_QUIC_V6}" ] && echo "${LISTEN_QUIC_V6}" )
    
    server_name _;

    # SSL 证书配置
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    # 返回 444 状态码以丢弃无效请求
    return 444;
}

# 信任 Docker 网络的 IP 地址范围
set_real_ip_from 172.0.0.0/8;  # Docker 网络的 IP 范围
set_real_ip_from fd00::/8;     # Docker 的 IPv6 范围

# 使用 X-Forwarded-For 头部获取真实 IP
real_ip_header X-Forwarded-For;

# 启用递归查找真实 IP
real_ip_recursive on;
EOF
}

# 创建配置目录和文件
create_config_files() {
    log_info "创建配置目录和文件..."
    
    # 创建配置目录
    mkdir -p /etc/nginx/snippets/
    mkdir -p /etc/nginx/apps/
    mkdir -p /srv
    mkdir -p /var/cache/nginx/fastcgi
    mkdir -p /var/cache/nginx/proxy
    
    # 创建增强版 SSL 参数配置
    cat > /etc/nginx/snippets/ssl-params.conf << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256;
ssl_ecdh_curve secp384r1;
ssl_session_cache shared:SSL:30m;
ssl_session_timeout 1h;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 127.0.0.1 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header X-Frame-Options SAMEORIGIN always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer";
add_header Permissions-Policy "geolocation=(), microphone=()";
ssl_dhparam /etc/nginx/ssl/dhparam.pem;
EOF

    # 创建增强版代理配置
    cat > /etc/nginx/snippets/proxy.conf << 'EOF'
client_max_body_size 1000m;
client_body_buffer_size 256k;

# 超时配置
send_timeout 300s;
proxy_read_timeout 300s;
proxy_send_timeout 300s;
proxy_connect_timeout 300s;

# 基本代理配置
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;

# HTTP 版本和连接
proxy_http_version 1.1;
proxy_set_header Connection "";

# 缓存配置
proxy_cache_bypass $cookie_session;
proxy_no_cache $cookie_session;

# 缓冲配置
proxy_buffering on;
proxy_buffer_size 128k;
proxy_buffers 16 4m;
proxy_busy_buffers_size 8m;

# 错误处理
proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
proxy_intercept_errors on;

# WebSocket 支持
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

# 隐藏服务器信息
proxy_hide_header X-Powered-By;
proxy_hide_header Server;
EOF

    # 创建缓存控制映射
    cat > /etc/nginx/snippets/cache-control.conf << 'EOF'
map "$upstream_http_cache_control$upstream_http_expires" $add_cache_control {
    default "public, max-age=2592000";
    "~."    "";
}
EOF

    # 创建限流配置
    cat > /etc/nginx/snippets/rate-limit.conf << 'EOF'
# 限流配置
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=static:10m rate=30r/s;

# 限连接配置
limit_conn_zone $binary_remote_addr zone=perip:10m;
limit_conn_zone $server_name zone=perserver:10m;
EOF
}

# 等待 dhparam 生成完成
wait_for_dhparam() {
    if [ ! -z "$DH_PID" ]; then
        start_spinner "等待 DH 参数生成完成..."
        if wait $DH_PID; then
            stop_spinner_ok
            log_success "DH 参数生成完成"
        else
            stop_spinner_fail
            log_error "DH 参数生成失败（详见 $LOG_FILE）"
            exit 1
        fi
    fi
}

# 测试配置
test_nginx_config() {
    log_info "测试 nginx 配置..."
    if nginx -t; then
        log_success "nginx 配置测试通过"
        return 0
    else
        log_error "nginx 配置测试失败"
        return 1
    fi
}

# 重启服务
restart_services() {
    log_info "重启 nginx..."
    systemctl restart nginx
    systemctl enable nginx
    
    log_success "增强版 nginx 安装完成！"
    echo
    log_info "配置信息："
    log_info "  默认网站根目录: /srv"
    log_info "  nginx 配置文件: /etc/nginx/nginx.conf"
    log_info "  SSL 证书目录: /etc/nginx/ssl/"
    log_info "  配置片段目录: /etc/nginx/snippets/"
    log_info "  应用配置目录: /etc/nginx/apps/"
    echo
    log_info "新增功能："
    log_info "  ✓ HTTP/3 和 QUIC 支持"
    log_info "  ✓ 增强的 SSL 配置"
    log_info "  ✓ 代理和 FastCGI 缓存"
    log_info "  ✓ 限流和限连接"
    log_info "  ✓ 压缩优化 (gzip/brotli/zstd)"
    log_info "  ✓ 安全头配置"
    log_info "  ✓ 性能优化"
    echo
    log_info "使用说明："
    log_info "  1. 将应用配置放在 /etc/nginx/apps/ 目录"
    log_info "  2. 使用 include snippets/proxy.conf 进行代理配置"
    log_info "  3. 使用 include snippets/ssl-params.conf 进行 SSL 配置"
    log_info "  4. 使用 include snippets/rate-limit.conf 进行限流配置"
}

# 主函数
main() {
    log_info "开始安装增强版 nginx..."
    init_log
    
    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
    
    detect_os
    handle_apache_conflict
    generate_ssl_params
    install_packages
    detect_nginx_env
    wait_for_dhparam
    configure_nginx_main
    configure_default_site
    create_config_files
    
    if test_nginx_config; then
        restart_services
    else
        log_error "配置测试失败，请检查配置后重试"
        exit 1
    fi
}

# 运行主函数
main "$@"
