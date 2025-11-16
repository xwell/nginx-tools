#!/bin/bash
# Nginx 安装与站点反代管理脚本（集合版）
# 集成：nginx-standalone-enhanced.sh 与 letsencrypt-standalone-enhanced.sh（已内嵌）

set -e

# 颜色与日志
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
log_success(){ echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

require_root(){ if [ "${EUID}" -ne 0 ]; then log_error "请以 root 用户运行此脚本"; exit 1; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }

# 轻量 spinner 与静默执行
LOG_FILE="/var/log/nginx-standalone-enhanced.log"
SP_PID=""; SP_MSG=""
init_log(){ mkdir -p /var/log; : > "$LOG_FILE"; }
start_spinner(){ SP_MSG="$1"; { while true; do echo -ne "\r$SP_MSG ⏳   "; sleep 0.2; echo -ne "\r$SP_MSG ⏳.  "; sleep 0.2; echo -ne "\r$SP_MSG ⏳.. "; sleep 0.2; echo -ne "\r$SP_MSG ⏳..."; sleep 0.2; done; } & SP_PID=$!; }
stop_spinner_ok(){ if [ -n "$SP_PID" ]; then kill "$SP_PID" 2>/dev/null || true; wait "$SP_PID" 2>/dev/null || true; SP_PID=""; echo -ne "\r$SP_MSG ✅\n"; SP_MSG=""; fi }
stop_spinner_fail(){ if [ -n "$SP_PID" ]; then kill "$SP_PID" 2>/dev/null || true; wait "$SP_PID" 2>/dev/null || true; SP_PID=""; echo -ne "\r$SP_MSG ❌\n"; SP_MSG=""; fi }
run_quiet(){ local desc="$1"; shift; start_spinner "$desc"; if "$@" >>"$LOG_FILE" 2>&1; then stop_spinner_ok; return 0; else stop_spinner_fail; log_error "执行失败：$desc（详见 $LOG_FILE）"; return 1; fi }

# 通用交互
ask(){ local prompt="$1"; local default="${2:-n}"; local response; if [ "$default" = "y" ]; then prompt="$prompt [Y/n]: "; else prompt="$prompt [y/N]: "; fi; read -p "$prompt" -r response; response=${response:-$default}; [[ $response =~ ^[Yy]$ ]]; }

# -----------------------------
# 无交互参数解析（支持环境变量）
# -----------------------------
parse_args(){
  ACTION=${ACTION:-${SU_ACTION:-}}
  SU_HOSTNAME=${SU_HOSTNAME:-}
  SU_BACKEND=${SU_BACKEND:-}
  SU_BACKEND_IP=${SU_BACKEND_IP:-}
  SU_BACKEND_PORT=${SU_BACKEND_PORT:-}
  SU_USE_CF=${SU_USE_CF:-}
  SU_CF_EMAIL=${SU_CF_EMAIL:-}
  SU_CF_API=${SU_CF_API:-}
  SU_CF_ZONE=${SU_CF_ZONE:-}
  SU_CF_ZONE_EXISTS=${SU_CF_ZONE_EXISTS:-}
  SU_ENABLE_CDN_REALIP=${SU_ENABLE_CDN_REALIP:-}
  SU_ENABLE_NEZHA=${SU_ENABLE_NEZHA:-}

  while [ $# -gt 0 ]; do
    case "$1" in
      --action=*) ACTION="${1#*=}" ;;
      --hostname=*) SU_HOSTNAME="${1#*=}" ;;
      --backend=*) SU_BACKEND="${1#*=}" ;;
      --backend-ip=*) SU_BACKEND_IP="${1#*=}" ;;
      --backend-port=*) SU_BACKEND_PORT="${1#*=}" ;;
      --cf) SU_USE_CF="yes" ;;
      --no-cf) SU_USE_CF="no" ;;
      --cf-email=*) SU_CF_EMAIL="${1#*=}" ;;
      --cf-api=*) SU_CF_API="${1#*=}" ;;
      --cf-zone=*) SU_CF_ZONE="${1#*=}" ;;
      --cf-zone-exists=*) SU_CF_ZONE_EXISTS="${1#*=}" ;;
      --cdn-realip) SU_ENABLE_CDN_REALIP="yes" ;;
      --no-cdn-realip) SU_ENABLE_CDN_REALIP="no" ;;
      --nezha) SU_ENABLE_NEZHA="yes" ;;
      --no-nezha) SU_ENABLE_NEZHA="no" ;;
      --help)
        cat << USAGE
用法: $0 [--action=install|site|nezha|cleanup]
           [--hostname=域名]
           [--backend=URL | --backend-ip=IP --backend-port=PORT]
           [--cf|--no-cf] [--cf-email=EMAIL] [--cf-api=KEY]
           [--cf-zone=ZONE] [--cf-zone-exists=yes|no]
           [--cdn-realip|--no-cdn-realip]
           [--nezha|--no-nezha]
cleanup 模式仅需 --hostname，自动删除旧站点配置/证书。
环境变量同名（前缀SU_）亦可，例如: SU_ACTION, SU_HOSTNAME ...
USAGE
        exit 0 ;;
    esac; shift
  done
}

# 非交互调度
run_noninteractive_if_requested(){
  if [ -z "$ACTION" ]; then return 0; fi
  case "$ACTION" in
    install)
      action_install_nginx
      exit 0
      ;;
    cleanup)
      local hostname
      hostname="${SU_HOSTNAME}"
      if [ -z "$hostname" ]; then log_error "--hostname 必填"; exit 1; fi
      cleanup_site "$hostname" "yes"
      exit 0
      ;;
    site|nezha)
      local hostname backend_url use_cf cf_email cf_api cf_zone cf_zone_exists enable_cdn_realip enable_nezha
      hostname="${SU_HOSTNAME}"
      if [ -z "$hostname" ]; then log_error "--hostname 必填"; exit 1; fi
      if [ -n "$SU_BACKEND" ]; then
        backend_url="$SU_BACKEND"
      else
        if [ -z "$SU_BACKEND_IP" ] || [ -z "$SU_BACKEND_PORT" ]; then
          log_error "请提供 --backend=URL 或 --backend-ip 与 --backend-port"; exit 1
        fi
        backend_url="http://${SU_BACKEND_IP}:${SU_BACKEND_PORT}"
      fi
      use_cf="${SU_USE_CF}"
      if [ "$use_cf" = "yes" ]; then
        cf_email="${SU_CF_EMAIL}"; cf_api="${SU_CF_API}"; cf_zone_exists="${SU_CF_ZONE_EXISTS:-yes}"; cf_zone="${SU_CF_ZONE}"
        if [ -z "$cf_email" ] || [ -z "$cf_api" ]; then log_error "--cf-email 与 --cf-api 必填"; exit 1; fi
        if [ "$cf_zone_exists" = "no" ] && [ -z "$cf_zone" ]; then log_error "当 --cf-zone-exists=no 时需提供 --cf-zone"; exit 1; fi
      else
        use_cf="no"
      fi
      enable_cdn_realip="${SU_ENABLE_CDN_REALIP:-no}"
      if [ "$ACTION" = "nezha" ]; then enable_nezha="yes"; else enable_nezha="${SU_ENABLE_NEZHA:-no}"; fi
      provision_site "$hostname" "$backend_url" "$use_cf" "$cf_email" "$cf_api" "$cf_zone" "${cf_zone_exists:-yes}" "$enable_cdn_realip" "$enable_nezha"
      exit 0
      ;;
    *)
      log_error "未知 --action: $ACTION"; exit 1;;
  esac
}

# -----------------------------
# NGINX 安装与基础配置（来自 nginx-standalone-enhanced）
# -----------------------------
detect_os(){ if [ -f /etc/os-release ]; then . /etc/os-release; OS=$NAME; VER=$VERSION_ID; elif type lsb_release >/dev/null 2>&1; then OS=$(lsb_release -si); VER=$(lsb_release -sr); else OS=$(uname -s); VER=$(uname -r); fi; echo "检测到系统: $OS $VER"; }

install_packages(){
  run_quiet "更新包列表..." env DEBIAN_FRONTEND=noninteractive apt-get -qq update
  run_quiet "安装 nginx 和增强包..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install nginx ssl-cert git curl wget
  if apt-cache show libnginx-mod-http-brotli >>"$LOG_FILE" 2>&1; then
    run_quiet "安装 brotli 压缩支持..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install libnginx-mod-http-brotli
  else
    log_warn "brotli 模块不可用，将使用 gzip 压缩"
  fi
  if apt-cache show libnginx-mod-http-zstd >>"$LOG_FILE" 2>&1; then
    run_quiet "安装 zstd 压缩支持..." env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install libnginx-mod-http-zstd
  else
    log_warn "zstd 模块不可用"
  fi
}

detect_nginx_env(){
  if id -u nginx >/dev/null 2>&1; then NGINX_USER="nginx"; elif id -u www-data >/dev/null 2>&1; then NGINX_USER="www-data"; else NGINX_USER=$(stat -c '%U' /var/log/nginx 2>/dev/null || echo "nobody"); fi
  local nginx_build_info; nginx_build_info=$(nginx -V 2>&1 || true)
  if echo "$nginx_build_info" | grep -qi -- "--with-http_v3"; then SUPPORT_HTTP3="yes"; else SUPPORT_HTTP3="no"; fi
  if echo "$nginx_build_info" | grep -qi -- "--with-http_v2"; then SUPPORT_HTTP2="yes"; else SUPPORT_HTTP2="no"; fi
}

handle_apache_conflict(){ if pgrep apache2 >/dev/null; then log_warn "检测到 Apache2 正在运行"; read -p "是否要卸载 Apache2？(y/n): " -n 1 -r; echo; if [[ $REPLY =~ ^[Yy]$ ]]; then log_info "卸载 Apache2..."; systemctl stop apache2; systemctl disable apache2; apt remove --purge -y apache2; log_success "Apache2 已卸载"; else log_info "禁用 Apache2..."; systemctl stop apache2; systemctl disable apache2; log_success "Apache2 已禁用"; fi; fi }

generate_ssl_params(){ log_info "生成 SSL 参数..."; mkdir -p /etc/nginx/ssl/; chmod 700 /etc/nginx/ssl; cd /etc/nginx/ssl; log_info "生成 DH 参数（这可能需要几分钟）..."; openssl dhparam -out dhparam.pem 2048 >>"$LOG_FILE" 2>&1 & DH_PID=$!; }

configure_nginx_main(){
  log_info "配置 nginx 主配置文件..."; cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup || true
  if [ "${SUPPORT_HTTP3}" = "yes" ]; then HTTP3_HTTP_BLOCK=$'\n    # HTTP/3 和 QUIC 支持\n    http3 on;\n    quic_gso on;\n    quic_retry on;\n    http3_max_concurrent_streams 512;\n    http3_stream_buffer_size 256k;\n    quic_active_connection_id_limit 8;\n'; else HTTP3_HTTP_BLOCK=""; fi
  if [ "${SUPPORT_HTTP2}" = "yes" ]; then HTTP2_HTTP_BLOCK=$'\n    # HTTP/2 优化\n    http2_max_concurrent_streams 512;\n    http2_recv_buffer_size 512k;\n    http2_body_preread_size 128k;\n    http2_chunk_size 16k;\n'; else HTTP2_HTTP_BLOCK=""; fi
  echo "user  ${NGINX_USER};" > /etc/nginx/nginx.conf
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
  awk -v h3="${HTTP3_HTTP_BLOCK}" -v h2="${HTTP2_HTTP_BLOCK}" ' { if ($0=="__HTTP3_BLOCK__") { printf "%s\n", h3; next } if ($0=="__HTTP2_BLOCK__") { printf "%s\n", h2; next } print } ' /etc/nginx/nginx.conf > /etc/nginx/nginx.conf.tmp && mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
}

configure_default_site(){
  log_info "配置默认站点..."; rm -rf /etc/nginx/sites-enabled/default
  if [ "${SUPPORT_HTTP3}" = "yes" ]; then LISTEN_QUIC_V4="    listen 443 quic reuseport default_server;"; LISTEN_QUIC_V6="    listen [::]:443 quic reuseport default_server;"; else LISTEN_QUIC_V4=""; LISTEN_QUIC_V6=""; fi
  if [ "${SUPPORT_HTTP2}" = "yes" ]; then LISTEN_SSL_HTTP2_PARAM=" http2"; else LISTEN_SSL_HTTP2_PARAM=""; fi
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
set_real_ip_from 172.0.0.0/8;
set_real_ip_from fd00::/8;

# 使用 X-Forwarded-For 头部获取真实 IP
real_ip_header X-Forwarded-For;

# 启用递归查找真实 IP
real_ip_recursive on;
EOF
}

create_config_files(){
  log_info "创建配置目录和文件..."; mkdir -p /etc/nginx/snippets/ /etc/nginx/apps/ /srv /var/cache/nginx/fastcgi /var/cache/nginx/proxy
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
  cat > /etc/nginx/snippets/cache-control.conf << 'EOF'
map "$upstream_http_cache_control$upstream_http_expires" $add_cache_control {
    default "public, max-age=2592000";
    "~."    "";
}
EOF
  cat > /etc/nginx/snippets/rate-limit.conf << 'EOF'
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=static:10m rate=30r/s;

limit_conn_zone $binary_remote_addr zone=perip:10m;
limit_conn_zone $server_name zone=perserver:10m;
EOF
}

wait_for_dhparam(){ if [ -n "$DH_PID" ]; then start_spinner "等待 DH 参数生成完成..."; if wait $DH_PID; then stop_spinner_ok; log_success "DH 参数生成完成"; else stop_spinner_fail; log_error "DH 参数生成失败（详见 $LOG_FILE）"; exit 1; fi; fi }

test_nginx_config(){ log_info "测试 nginx 配置..."; if nginx -t; then log_success "nginx 配置测试通过"; return 0; else log_error "nginx 配置测试失败"; return 1; fi }

restart_services(){ log_info "重启 nginx..."; systemctl restart nginx; systemctl enable nginx; log_success "增强版 nginx 安装完成！"; }

# -----------------------------
# 域名与证书（来自 letsencrypt-standalone-enhanced）
# -----------------------------
detect_nginx_features(){ local info; info=$(nginx -V 2>&1 || true); if echo "$info" | grep -qi -- "--with-http_v2"; then SUPPORT_HTTP2="yes"; else SUPPORT_HTTP2="no"; fi; if echo "$info" | grep -qi -- "--with-http_v3"; then SUPPORT_HTTP3="yes"; else SUPPORT_HTTP3="no"; fi }

ensure_cloudflare_realip_snippet(){ mkdir -p /etc/nginx/snippets; cat > /etc/nginx/snippets/cloudflare-realip.conf << 'EOF'
underscores_in_headers on;
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

install_cloudflare_realip_updater(){
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
  while read -r cidr; do [ -n "$cidr" ] && echo "set_real_ip_from $cidr;"; done < "$TMP_DIR/ips-v4"
  while read -r cidr6; do [ -n "$cidr6" ] && echo "set_real_ip_from $cidr6;"; done < "$TMP_DIR/ips-v6"
  echo 'real_ip_header CF-Connecting-IP;'
} > /etc/nginx/snippets/cloudflare-realip.conf.new
mv /etc/nginx/snippets/cloudflare-realip.conf.new /etc/nginx/snippets/cloudflare-realip.conf
if nginx -t >/dev/null 2>&1; then systemctl reload nginx || true; fi
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

check_nginx(){ if ! command -v nginx &>/dev/null; then log_error "nginx 未安装，请先执行 ‘仅安装nginx’"; exit 1; fi; if ! systemctl is-active --quiet nginx; then log_warn "nginx 未运行，尝试启动..."; systemctl start nginx || true; fi }

get_server_ip(){ local ip=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p'); if [ -z "$ip" ]; then ip=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "无法获取IP"); fi; echo "$ip"; }

validate_cloudflare_api(){ local email="$1"; local api_key="$2"; local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user" -H "X-Auth-Email: $email" -H "X-Auth-Key: $api_key" -H "Content-Type: application/json"); if echo "$response" | grep -q '"success":false'; then log_error "Cloudflare API 验证失败:"; echo "$response"; return 1; fi; return 0; }

add_cloudflare_record(){ local hostname="$1" ip="$2" email="$3" api_key="$4" zone="$5"; local zoneid=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone" -H "X-Auth-Email: $email" -H "X-Auth-Key: $api_key" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1); if [ -z "$zoneid" ]; then log_error "无法找到域名 $zone 的 zone ID"; return 1; fi; local addrecord=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records" -H "X-Auth-Email: $email" -H "X-Auth-Key: $api_key" -H "Content-Type: application/json" --data "{\"id\":\"$zoneid\",\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"proxied\":true}"); if echo "$addrecord" | grep -q '"success":false'; then log_error "添加 DNS 记录失败:"; echo "$addrecord"; return 1; else log_success "DNS 记录已添加: $hostname -> $ip"; return 0; fi }

install_acme(){ if [ ! -f /root/.acme.sh/acme.sh ]; then log_info "安装 acme.sh..."; curl https://get.acme.sh | sh; log_success "acme.sh 安装完成"; else log_info "acme.sh 已安装"; fi }
set_default_ca(){ log_info "设置默认证书颁发机构为 Let's Encrypt..."; /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt || { log_warn "无法设置默认 CA，尝试升级 acme.sh..."; /root/.acme.sh/acme.sh --upgrade || { log_error "无法升级 acme.sh"; exit 1; }; /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt || { log_error "无法设置默认证书颁发机构"; exit 1; }; log_success "acme.sh 升级成功"; } }

create_enhanced_site_config(){
  local hostname="$1" backend_url="$2" enable_cdn_realip="${3:-no}" enable_nezha_grpc="${4:-no}" enable_nezha_ws="${5:-no}"
  log_info "创建增强版站点配置..."
  local listen_ssl_v4="listen 443 ssl;" listen_ssl_v6="listen [::]:443 ssl;" listen_quic_v4="" listen_quic_v6=""
  if [ "${SUPPORT_HTTP2}" = "yes" ]; then listen_ssl_v4="listen 443 ssl http2;"; listen_ssl_v6="listen [::]:443 ssl http2;"; fi
  if [ "${SUPPORT_HTTP3}" = "yes" ]; then listen_quic_v4="listen 443 quic;"; listen_quic_v6="listen [::]:443 quic;"; fi
  local backend_authority backend_host backend_port; backend_authority=$(echo "$backend_url" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1); backend_host=$(echo "$backend_authority" | cut -d: -f1); backend_port=$(echo "$backend_authority" | awk -F: '{print $2}')
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
    }

    # 安全配置
    location ~ /\.ht { deny all; }
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
EOF
  ln -sf /etc/nginx/sites-available/${hostname} /etc/nginx/sites-enabled/
  log_success "站点配置已创建: /etc/nginx/sites-available/${hostname}"
}

install_certificate(){ local hostname="$1" backend_url="$2"; log_info "安装证书..."; mkdir -p /etc/nginx/ssl/${hostname}; chmod 700 /etc/nginx/ssl; /root/.acme.sh/acme.sh --force --install-cert -d "$hostname" --key-file /etc/nginx/ssl/${hostname}/key.pem --fullchain-file /etc/nginx/ssl/${hostname}/fullchain.pem --ca-file /etc/nginx/ssl/${hostname}/chain.pem --reloadcmd "systemctl reload nginx"; create_enhanced_site_config "$hostname" "$backend_url"; log_success "证书安装完成"; }

# -----------------------------
# 高阶操作封装
# -----------------------------
ensure_base_installed(){ if ! have nginx; then log_warn "尚未安装 nginx，将先执行安装"; action_install_nginx; fi }

provision_site(){
  local hostname="$1" backend_url="$2" use_cf="$3" cf_email="$4" cf_api="$5" cf_zone="$6" cf_zone_exists="$7" enable_cdn_realip="$8" enable_nezha="$9"
  check_nginx
  local ip; ip=$(get_server_ip); log_info "服务器 IP: $ip"
  install_acme; set_default_ca; detect_nginx_features
  systemctl stop nginx || true
  if [ "$use_cf" = "yes" ]; then
    if [[ $hostname =~ (\.cf$|\.ga$|\.gq$|\.ml$|\.tk$) ]]; then log_error "Cloudflare 不支持以下 TLD 的 API 调用: .cf, .ga, .gq, .ml, .tk"; exit 1; fi
    if [ -z "$cf_email" ] || [ -z "$cf_api" ]; then log_error "Cloudflare 邮箱/API Key 不能为空"; exit 1; fi
    if ! validate_cloudflare_api "$cf_email" "$cf_api"; then exit 1; fi
    export CF_Key="$cf_api"; export CF_Email="$cf_email"
    if [ "$cf_zone_exists" = "no" ] && [ -n "$cf_zone" ]; then add_cloudflare_record "$hostname" "$ip" "$cf_email" "$cf_api" "$cf_zone" || true; fi
    log_info "申请证书 (Cloudflare DNS 模式)..."; /root/.acme.sh/acme.sh --force --issue --dns dns_cf -d "$hostname"
  else
    if ! command -v socat >/dev/null 2>&1; then log_info "安装 socat..."; apt-get -qq update; apt-get -y -qq install socat; fi
    log_info "申请证书 (standalone 模式)..."; /root/.acme.sh/acme.sh --force --issue --standalone -d "$hostname"
  fi
  systemctl start nginx || true

  local ENABLE_NEZHA_GRPC="no" ENABLE_NEZHA_WS="no"
  if [ "$enable_cdn_realip" = "yes" ]; then ensure_cloudflare_realip_snippet; install_cloudflare_realip_updater; fi
  if [ "$enable_nezha" = "yes" ]; then ENABLE_NEZHA_GRPC="yes"; ENABLE_NEZHA_WS="yes"; fi

  install_certificate "$hostname" "$backend_url"
  create_enhanced_site_config "$hostname" "$backend_url" "$enable_cdn_realip" "$ENABLE_NEZHA_GRPC" "$ENABLE_NEZHA_WS"
  if nginx -t; then log_success "nginx 配置测试通过"; systemctl reload nginx; else log_error "nginx 配置测试失败，请检查配置"; exit 1; fi
  log_success "站点已配置完成：$hostname -> $backend_url"
}

cleanup_site(){
  local hostname="$1" assume_yes="${2:-no}"
  if [ -z "$hostname" ]; then log_error "域名不能为空"; return 1; fi
  check_nginx
  if [ "$assume_yes" != "yes" ]; then
    if ! ask "确认要删除旧域名 ${hostname} 的 nginx 配置与证书？" "n"; then
      log_warn "已取消清理 $hostname"
      return 0
    fi
  fi

  local removed_any="no" config_changed="no"
  if [ -e "/etc/nginx/sites-enabled/${hostname}" ]; then
    rm -f "/etc/nginx/sites-enabled/${hostname}"
    log_info "已移除 /etc/nginx/sites-enabled/${hostname}"
    removed_any="yes"
    config_changed="yes"
  fi
  if [ -f "/etc/nginx/sites-available/${hostname}" ]; then
    rm -f "/etc/nginx/sites-available/${hostname}"
    log_info "已删除 /etc/nginx/sites-available/${hostname}"
    removed_any="yes"
    config_changed="yes"
  fi

  local ssl_dir="/etc/nginx/ssl/${hostname}"
  if [ -d "$ssl_dir" ]; then
    rm -rf "$ssl_dir"
    log_info "已删除证书目录 $ssl_dir"
    removed_any="yes"
  fi

  local acme_removed="no"
  if [ -x /root/.acme.sh/acme.sh ]; then
    if [ -d "/root/.acme.sh/${hostname}" ] || [ -d "/root/.acme.sh/${hostname}_ecc" ]; then
      if /root/.acme.sh/acme.sh --remove -d "$hostname" >>"$LOG_FILE" 2>&1; then
        log_info "acme.sh 自动续签任务已删除"
        acme_removed="yes"
        removed_any="yes"
      else
        log_warn "删除 acme.sh 条目失败，请手动检查 /root/.acme.sh/${hostname}"
      fi
    fi
  fi

  if [ "$config_changed" = "yes" ]; then
    if nginx -t; then
      systemctl reload nginx
      log_success "nginx 配置已重新加载"
    else
      log_error "nginx 配置测试失败，请手动检查后再 reload"
      return 1
    fi
  fi

  if [ "$removed_any" = "yes" ] || [ "$acme_removed" = "yes" ]; then
    log_success "已清理旧域名 $hostname 的相关文件"
  else
    log_warn "未找到与 $hostname 相关的配置或证书，可能已提前删除"
  fi
}

# -----------------------------
# 菜单操作
# -----------------------------
action_install_nginx(){
  log_info "开始安装增强版 nginx..."; init_log; detect_os; handle_apache_conflict; generate_ssl_params; install_packages; detect_nginx_env; wait_for_dhparam; configure_nginx_main; configure_default_site; create_config_files; if test_nginx_config; then restart_services; else log_error "配置测试失败，请检查配置后重试"; exit 1; fi
}

action_site_reverse_proxy(){
  ensure_base_installed
  local hostname backend host port backend_url use_cf_ans use_cf="no" enable_cdn_realip_ans enable_cdn_realip="no"
  read -p "请输入域名(必填): " hostname; [ -z "$hostname" ] && { log_error "域名不能为空"; return 1; }
  read -p "请输入后端IP(如 127.0.0.1): " host; [ -z "$host" ] && { log_error "后端IP不能为空"; return 1; }
  read -p "请输入后端端口(如 8080): " port; [ -z "$port" ] && { log_error "端口不能为空"; return 1; }
  backend_url="http://$host:$port"
  read -p "证书申请是否使用 Cloudflare DNS? [y/N]: " -r use_cf_ans; case "$use_cf_ans" in y|Y) use_cf="yes";; esac
  local cf_email cf_api cf_zone cf_zone_exists="yes"
  if [ "$use_cf" = "yes" ]; then
    read -p "Cloudflare 邮箱: " cf_email
    read -p "Cloudflare API Key: " cf_api
    if ask "此子域名DNS记录已存在？"; then
      cf_zone_exists="yes"
    else
      cf_zone_exists="no"
      read -p "主域名(Zone，例如 example.com): " cf_zone
    fi
  fi
  read -p "启用 Cloudflare 回源真实IP? [y/N]: " -r enable_cdn_realip_ans; case "$enable_cdn_realip_ans" in y|Y) enable_cdn_realip="yes";; esac
  provision_site "$hostname" "$backend_url" "$use_cf" "$cf_email" "$cf_api" "$cf_zone" "$cf_zone_exists" "$enable_cdn_realip" "no"
}

action_nezha_reverse_proxy(){
  ensure_base_installed
  local hostname backend host port backend_url use_cf_ans use_cf="no" enable_cdn_realip_ans enable_cdn_realip="no"
  read -p "请输入域名(必填): " hostname; [ -z "$hostname" ] && { log_error "域名不能为空"; return 1; }
  read -p "请输入哪吒面板后端IP(如 127.0.0.1): " host; [ -z "$host" ] && { log_error "后端IP不能为空"; return 1; }
  read -p "请输入哪吒面板后端端口(如 9000): " port; [ -z "$port" ] && { log_error "端口不能为空"; return 1; }
  backend_url="http://$host:$port"
  read -p "证书申请是否使用 Cloudflare DNS? [y/N]: " -r use_cf_ans; case "$use_cf_ans" in y|Y) use_cf="yes";; esac
  local cf_email cf_api cf_zone cf_zone_exists="yes"
  if [ "$use_cf" = "yes" ]; then
    read -p "Cloudflare 邮箱: " cf_email
    read -p "Cloudflare API Key: " cf_api
    if ask "此子域名DNS记录已存在？"; then
      cf_zone_exists="yes"
    else
      cf_zone_exists="no"
      read -p "主域名(Zone，例如 example.com): " cf_zone
    fi
  fi
  read -p "启用 Cloudflare 回源真实IP? [y/N]: " -r enable_cdn_realip_ans; case "$enable_cdn_realip_ans" in y|Y) enable_cdn_realip="yes";; esac
  provision_site "$hostname" "$backend_url" "$use_cf" "$cf_email" "$cf_api" "$cf_zone" "$cf_zone_exists" "$enable_cdn_realip" "yes"
}

action_cleanup_site(){
  ensure_base_installed
  local hostname
  read -p "请输入需要清理的旧域名(必填): " hostname
  [ -z "$hostname" ] && { log_error "域名不能为空"; return 1; }
  cleanup_site "$hostname"
}

self_update(){
  local url="https://raw.githubusercontent.com/xwell/nginx-tools/main/nginx-suite.sh"
  log_info "从 $url 获取最新脚本..."
  if curl -fsSL "$url" -o /tmp/nginx-suite.sh.new; then
    chmod +x /tmp/nginx-suite.sh.new
    mv /tmp/nginx-suite.sh.new "$0"
    log_success "更新成功。请重新运行脚本。"
    exit 0
  else
    log_warn "在线更新失败，请检查网络或仓库地址。"
  fi
}

main_menu(){

  clear

  echo "nginx安装与管理脚本"

  echo "--- https://github.com/xwell/nginx-tools ---"

  echo "1.  仅安装nginx"

  echo "2.  站点反向代理-IP+端口"

  echo "3.  哪吒面板反向代理"

  echo "-------------------------"

  echo "4.  清理旧域名配置"

  echo "5.  更新脚本"

  echo "-------------------------"

  echo "0.  退出脚本"

  echo

  read -p "请输入选择 [0-5]: " sel

  case "$sel" in

    1) require_root; action_install_nginx; read -p "按回车返回菜单..." _ ;;

    2) require_root; action_site_reverse_proxy; read -p "按回车返回菜单..." _ ;;

    3) require_root; action_nezha_reverse_proxy; read -p "按回车返回菜单..." _ ;;

    4) require_root; action_cleanup_site; read -p "按回车返回菜单..." _ ;;

    5) require_root; self_update; read -p "按回车返回菜单..." _ ;;

    0) exit 0 ;;

    *) echo "无效选择"; sleep 1 ;;

  esac

}



require_root
parse_args "$@"
run_noninteractive_if_requested
while true; do main_menu; done
