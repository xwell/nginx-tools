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

### 唯一脚本：`nginx-suite-merged.sh`

仓库现在以 `nginx-suite-merged.sh` 作为唯一维护入口，它已经覆盖：
- 增强版 Nginx 安装
- Let's Encrypt/acme.sh 证书签发与安装
- 普通站点反向代理
- 哪吒面板 gRPC + WebSocket 反代
- Cloudflare DNS 验证
- Cloudflare 回源真实 IP
- 旧域名配置与证书清理

### 下载与运行

```bash
wget https://raw.githubusercontent.com/xwell/nginx-tools/main/nginx-suite-merged.sh
chmod +x nginx-suite-merged.sh
sudo ./nginx-suite-merged.sh
```

### 交互模式

```bash
sudo ./nginx-suite-merged.sh
```

主菜单包含：
- 仅安装 Nginx
- 普通站点反向代理
- 哪吒面板反向代理
- 清理旧域名配置
- 在线更新脚本

站点反代和哪吒反代在交互模式下都支持两种后端输入方式：
- 直接输入完整后端 URL，例如 `http://127.0.0.1:8080` 或 `https://127.0.0.1:8443`
- 留空后再输入 IP + 端口

### 无交互模式

支持命令行参数或环境变量，二者等效，环境变量使用 `SU_` 前缀。

- 安装 Nginx
```bash
sudo ./nginx-suite-merged.sh --action=install
```

- 普通站点反代
```bash
sudo ./nginx-suite-merged.sh \
  --action=site \
  --hostname=example.com \
  --backend=http://127.0.0.1:8080 \
  --no-cf \
  --cdn-realip
```

- 普通站点反代，使用 IP + 端口写法
```bash
sudo ./nginx-suite-merged.sh \
  --action=site \
  --hostname=example.com \
  --backend-ip=127.0.0.1 \
  --backend-port=8080 \
  --cf \
  --cf-email=you@example.com \
  --cf-api=YOUR_CF_APIKEY \
  --cf-zone-exists=no \
  --cf-zone=example.com \
  --cdn-realip
```

- 哪吒面板反代
```bash
sudo ./nginx-suite-merged.sh \
  --action=nezha \
  --hostname=panel.example.com \
  --backend=http://127.0.0.1:9000 \
  --no-cf \
  --cdn-realip
```

- 清理旧域名配置
```bash
sudo ./nginx-suite-merged.sh \
  --action=cleanup \
  --hostname=old.example.com
```

### 参数说明

- `--action`: `install | site | nezha | cleanup`
- `--hostname`: 站点域名
- `--backend`: 后端完整 URL，支持 `http://` 或 `https://`
- `--backend-ip` 与 `--backend-port`: 后端地址与端口，与 `--backend` 二选一
- `--cf | --no-cf`: 是否使用 Cloudflare DNS 验证
- `--cf-email` 与 `--cf-api`: Cloudflare 账户邮箱与 API Key
- `--cf-zone-exists=yes|no`: 子域名 DNS 记录是否已存在，`no` 时需同时提供 `--cf-zone`
- `--cf-zone`: 主域名 Zone
- `--cdn-realip | --no-cdn-realip`: 启用或关闭 Cloudflare 回源真实 IP
- `--nezha | --no-nezha`: 是否生成哪吒路由，仅对 `--action=site` 额外生效

### 对应环境变量

- `SU_ACTION, SU_HOSTNAME, SU_BACKEND, SU_BACKEND_IP, SU_BACKEND_PORT`
- `SU_USE_CF, SU_CF_EMAIL, SU_CF_API, SU_CF_ZONE, SU_CF_ZONE_EXISTS`
- `SU_ENABLE_CDN_REALIP, SU_ENABLE_NEZHA`

### 清理旧域名

- 交互式：运行 `sudo ./nginx-suite-merged.sh`，在主菜单选择 `4. 清理旧域名配置`
- 无交互：运行 `sudo ./nginx-suite-merged.sh --action=cleanup --hostname=old.example.com`

脚本会自动：
1. 删除 `/etc/nginx/sites-enabled/<域名>` 与 `sites-available` 中对应配置
2. 删除 `/etc/nginx/ssl/<域名>/` 证书目录
3. 调用 `acme.sh --remove -d <域名>` 清理自动续签条目
4. 在配置发生变化时执行 `nginx -t && systemctl reload nginx`

### 仓库说明

- 仓库现在只维护 `nginx-suite-merged.sh`
- 安装、签证书、反代、哪吒面板和清理旧域名都通过这一份脚本完成
- 后续新增功能和修复也只会进入这一份脚本


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

### `nginx-suite-merged.sh` 环境变量

```bash
# 动作
export SU_ACTION="site"

# 站点与后端
export SU_HOSTNAME="example.com"
export SU_BACKEND="http://127.0.0.1:8080"

# Cloudflare 配置
export SU_USE_CF="yes"
export SU_CF_EMAIL="your-email@example.com"
export SU_CF_API="your-api-key"
export SU_CF_ZONE="example.com"
export SU_CF_ZONE_EXISTS="yes"

# 可选功能
export SU_ENABLE_CDN_REALIP="yes"
export SU_ENABLE_NEZHA="no"
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
