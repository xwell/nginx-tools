# 增强版 Nginx 安装脚本

基于 swizzin 项目，整合了 kejilion 的优秀配置，提供高性能、高安全性的 nginx 反代解决方案。

## 功能特性

### 🚀 性能优化
- **HTTP/3 和 QUIC 支持** - 支持最新的网络协议
- **HTTP/2 优化** - 详细的 HTTP/2 参数调优
- **多线程池** - 提高并发处理能力
- **文件缓存** - 智能的文件缓存策略
- **连接优化** - reuseport、keepalive 等优化

### 🔒 安全增强
- **现代 SSL/TLS 配置** - 支持 TLS 1.2/1.3
- **安全头配置** - HSTS、X-Frame-Options 等
- **限流和限连接** - 防止 DDoS 攻击
- **IP 白名单** - 支持真实 IP 获取

### 📦 压缩优化
- **Gzip 压缩** - 标准压缩支持
- **Brotli 压缩** - 更高效的压缩算法（如果可用）
- **Zstd 压缩** - 最新压缩算法（如果可用）

### 🗄️ 缓存系统
- **代理缓存** - 反向代理缓存
- **FastCGI 缓存** - PHP 应用缓存
- **静态文件缓存** - 静态资源优化

## 安装使用

### 1. 安装增强版 Nginx

```bash
# 下载并运行安装脚本
wget https://raw.githubusercontent.com/xwell/nginx-tools/main/nginx-standalone-enhanced.sh
chmod +x nginx-standalone-enhanced.sh
sudo ./nginx-standalone-enhanced.sh
```

### 2. 申请 SSL 证书

```bash
# 下载并运行证书申请脚本
wget https://raw.githubusercontent.com/xwell/nginx-tools/main/letsencrypt-standalone-enhanced.sh
chmod +x letsencrypt-standalone-enhanced.sh
sudo ./letsencrypt-standalone-enhanced.sh
```

### 3. 合集脚本：nginx-suite-merged.sh（推荐）

提供菜单化管理与无交互模式，集成：
- 仅安装 Nginx（增强配置）
- 站点反向代理（签发/安装证书、生成站点、可选 Cloudflare Real-IP）
- 哪吒面板反向代理（gRPC + WebSocket，直连后端）

交互模式：
```bash
sudo ./nginx-suite-merged.sh
```

无交互模式（命令行参数或环境变量，二者等效，环境变量使用 SU_ 前缀）：

- 安装 Nginx
```bash
sudo ./nginx-suite-merged.sh --action=install
```

- 普通站点反代（后端 URL 直填）
```bash
sudo ./nginx-suite-merged.sh \
  --action=site \
  --hostname=example.com \
  --backend=http://127.0.0.1:8080 \
  --no-cf \
  --cdn-realip
```

- 普通站点反代（后端 IP + 端口）
```bash
sudo ./nginx-suite-merged.sh \
  --action=site \
  --hostname=example.com \
  --backend-ip=127.0.0.1 --backend-port=8080 \
  --cf --cf-email=you@example.com --cf-api=YOUR_CF_APIKEY \
  --cf-zone-exists=no --cf-zone=example.com \
  --cdn-realip
```

- 哪吒面板反代（gRPC + WS）
```bash
sudo ./nginx-suite-merged.sh \
  --action=nezha \
  --hostname=panel.example.com \
  --backend-ip=127.0.0.1 --backend-port=9000 \
  --no-cf \
  --cdn-realip
```

支持参数：
- `--action`: install | site | nezha
- `--hostname`: 站点域名
- `--backend`: 后端完整 URL（与 `--backend-ip/--backend-port` 二选一）
- `--backend-ip` 与 `--backend-port`: 后端地址与端口
- `--cf | --no-cf`: 是否使用 Cloudflare DNS 验证
- `--cf-email` 与 `--cf-api`: Cloudflare 账户邮箱与 API Key
- `--cf-zone-exists=yes|no`: 子域名 DNS 记录是否已存在（no 时需 `--cf-zone`）
- `--cf-zone`: 主域名（Zone），仅当 `--cf-zone-exists=no` 时必填
- `--cdn-realip | --no-cdn-realip`: 启用 Cloudflare 回源真实 IP
- `--nezha | --no-nezha`: 是否生成哪吒路由（对 action=site 也可用）

对应的环境变量（全大写）：
- `SU_ACTION, SU_HOSTNAME, SU_BACKEND, SU_BACKEND_IP, SU_BACKEND_PORT`
- `SU_USE_CF, SU_CF_EMAIL, SU_CF_API, SU_CF_ZONE, SU_CF_ZONE_EXISTS`
- `SU_ENABLE_CDN_REALIP, SU_ENABLE_NEZHA`

## 使用说明：letsencrypt-standalone-enhanced.sh

脚本作用：一键申请证书并生成 Nginx 反代站点。支持 Cloudflare DNS 验证、可选的 Cloudflare 回源真实 IP 配置、哪吒面板 gRPC + WebSocket 路由。

### 交互式运行
```bash
sudo ./letsencrypt-standalone-enhanced.sh
```
按提示输入：
- 域名（必填）
- 后端服务 URL（必填，如 http://127.0.0.1:8080）
- 是否使用 Cloudflare（可选；使用则需输入 CF 邮箱/API 等）
- 是否启用 Cloudflare 回源真实IP（可选）
- 是否启用哪吒 gRPC+WebSocket（可选）

完成后：
- 证书安装于 `/etc/nginx/ssl/<域名>/`
- 站点配置在 `/etc/nginx/sites-available/<域名>` 并已启用
- 自动重载 Nginx

### 无交互运行（命令行参数/环境变量）
支持用参数或环境变量预置，命令行优先。

- 核心参数
  - `--hostname=域名` 或 `LE_HOSTNAME`
  - `--backend=URL` 或 `LE_BACKEND`
- Cloudflare 开关与凭据
  - `--cf`/`--no-cf` 或 `USE_CF=yes|no`
  - `--cf-email=EMAIL` 或 `LE_CF_EMAIL`
  - `--cf-api=API_KEY` 或 `LE_CF_API`
  - `--cf-zone=ZONE` 或 `LE_CF_ZONE`
  - `--cf-zone-exists=yes|no` 或 `LE_CF_ZONEEXISTS=yes|no`
- 可选功能开关
  - `--cdn-realip`/`--no-cdn-realip` 或 `ENABLE_CDN_REALIP=yes|no`
  - `--nezha`/`--no-nezha` 或 `ENABLE_NEZHA=yes|no`（同时启用 gRPC + WebSocket）

示例（Cloudflare DNS 验证 + 开启回源与哪吒路由）
```bash
sudo ./letsencrypt-standalone-enhanced.sh \
  --hostname=test.example.com \
  --backend=http://127.0.0.1:9527 \
  --cf \
  --cf-email=you@example.com \
  --cf-api=YOUR_CF_API_KEY \
  --cf-zone=example.com \
  --cf-zone-exists=yes \
  --cdn-realip \
  --nezha
```

示例（不使用 Cloudflare，用 standalone 模式）
```bash
sudo ./letsencrypt-standalone-enhanced.sh \
  --hostname=test.example.com \
  --backend=http://127.0.0.1:8080 \
  --no-cf \
  --cdn-realip \
  --no-nezha
```

也可用环境变量（命令行省略时生效）
```bash
export LE_HOSTNAME=test.example.com
export LE_BACKEND=http://127.0.0.1:8080
export USE_CF=no
export ENABLE_CDN_REALIP=yes
export ENABLE_NEZHA=no
sudo ./letsencrypt-standalone-enhanced.sh
```

### 生成内容说明
- Nginx 站点：
  - 80: HTTP 到 HTTPS 的 301 跳转
  - 443: 自动根据支持启用 http2/http3（quic），并反代到提供的后端
- 证书：
  - key: `/etc/nginx/ssl/<域名>/key.pem`
  - fullchain: `/etc/nginx/ssl/<域名>/fullchain.pem`
  - chain: `/etc/nginx/ssl/<域名>/chain.pem`
- Cloudflare 回源真实 IP（可选）：
  - 生成并 include `snippets/cloudflare-realip.conf`
  - 安装 systemd timer 每周自动更新 CF IP 段
- 哪吒面板（可选）：
  - gRPC: `location ^~ /proto.NezhaService/ { grpc_pass grpc://dashboard; ... }`
  - WebSocket: `location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ { ... }`

### 注意事项
- 选择 Cloudflare 模式时，脚本将验证 `LE_CF_EMAIL/LE_CF_API`，并可选自动添加 A 记录（需 `LE_CF_ZONE` 或 `--cf-zone`）。
- standalone 模式会短暂停止 nginx（脚本自动处理）。
- 若 80/443 端口被占用，签发可能失败，请先释放或使用 Cloudflare DNS 模式。
- 站点监听不使用 reuseport，以避免与默认站点冲突。


## 配置结构

```
/etc/nginx/
├── nginx.conf                    # 主配置文件（增强版）
├── sites-available/              # 站点配置
├── sites-enabled/                # 启用的站点
├── snippets/                     # 配置片段
│   ├── ssl-params.conf          # SSL 参数配置
│   ├── proxy.conf               # 代理配置
│   ├── cache-control.conf       # 缓存控制
│   └── rate-limit.conf          # 限流配置
├── apps/                        # 应用配置
└── ssl/                         # SSL 证书目录
```

## 配置示例

### 基本代理配置

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;
    
    # SSL 配置
    ssl_certificate /etc/nginx/ssl/example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/example.com/key.pem;
    include snippets/ssl-params.conf;
    
    # 代理配置
    location / {
        include snippets/proxy.conf;
        proxy_pass http://127.0.0.1:8080;
    }
}
```

### 静态文件优化

```nginx
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
    proxy_pass http://127.0.0.1:8080;
    include snippets/proxy.conf;
    
    # 缓存配置
    proxy_cache my_proxy_cache;
    expires 30d;
    add_header Cache-Control "public, immutable";
}
```

### 限流配置

```nginx
# 在 server 块中使用
location /api/ {
    limit_req zone=api burst=20 nodelay;
    include snippets/proxy.conf;
    proxy_pass http://127.0.0.1:8080;
}

location /login {
    limit_req zone=login burst=5 nodelay;
    include snippets/proxy.conf;
    proxy_pass http://127.0.0.1:8080;
}
```

## 环境变量

### Let's Encrypt 脚本环境变量

```bash
# 域名
export LE_HOSTNAME="example.com"

# 是否应用到默认配置
export LE_DEFAULTCONF="no"

# Cloudflare 配置
export LE_CF_EMAIL="your-email@example.com"
export LE_CF_API="your-api-key"
export LE_CF_ZONE="example.com"
export LE_CF_ZONEEXISTS="no"
```

## 性能调优

### 1. 工作进程数
```nginx
worker_processes auto;  # 自动检测 CPU 核心数
```

### 2. 连接数限制
```nginx
events {
    worker_connections 2048;  # 根据服务器配置调整
}
```

### 3. 缓存大小
```nginx
proxy_cache_path /var/cache/nginx/proxy levels=1:2 keys_zone=my_proxy_cache:20m max_size=1g;
```

## 监控和日志

### 访问日志格式
```
$remote_addr - $remote_user [$time_local] "$request" 
$status $body_bytes_sent "$http_referer" 
"$http_user_agent" "$http_x_forwarded_for" 
rt=$request_time uct="$upstream_connect_time" 
uht="$upstream_header_time" urt="$upstream_response_time"
```

### 日志轮转
```bash
# 编辑 logrotate 配置
sudo nano /etc/logrotate.d/nginx
```

## 故障排除

### 1. 配置测试
```bash
sudo nginx -t
```

### 2. 重载配置
```bash
sudo systemctl reload nginx
```

### 3. 查看错误日志
```bash
sudo tail -f /var/log/nginx/error.log
```

### 4. 查看访问日志
```bash
sudo tail -f /var/log/nginx/access.log
```

## 与原始配置的对比

| 特性 | 原始 Swizzin | 增强版 | Kejilion |
|------|-------------|--------|----------|
| HTTP/3 支持 | ❌ | ✅ | ✅ |
| 代理缓存 | ❌ | ✅ | ✅ |
| 限流功能 | ❌ | ✅ | ✅ |
| 压缩优化 | 基础 | 增强 | 完整 |
| 安全头 | 基础 | 增强 | 完整 |
| 配置复杂度 | 简单 | 中等 | 复杂 |

## 更新日志

### v2.0.0 (增强版)
- 整合 kejilion 优秀配置
- 添加 HTTP/3 和 QUIC 支持
- 增强 SSL/TLS 配置
- 添加代理和 FastCGI 缓存
- 实现限流和限连接功能
- 优化压缩算法支持
- 增强安全头配置

## 许可证

基于原始 swizzin 项目，遵循相同的开源许可证。

## 贡献

欢迎提交 Issue 和 Pull Request 来改进这个项目。

## 支持

如果遇到问题，请检查：
1. nginx 配置语法：`nginx -t`
2. 错误日志：`tail -f /var/log/nginx/error.log`
3. 系统资源使用情况
4. 网络连接状态
