#!/usr/bin/env bash
# =============================================================
# flvx 裸机一键部署脚本（不依赖 Docker）
# 适用：Ubuntu 20.04+ / Debian 11+ / CentOS 8+ / Fedora 38+
# 架构：amd64 / arm64
# 用法： sudo ./install-baremetal.sh
# =============================================================
set -euo pipefail

# ---------- 可配置项（也可交互输入） ----------
INSTALL_DIR="/opt/flvx"
REPO_URL="https://github.com/Sagit-chu/flvx.git"
REPO_BRANCH="main"
BACKEND_PORT=6365
FRONTEND_PORT=80             # nginx 监听端口，80 占用就改成 6366
GOMOD_PROXY="https://goproxy.cn,direct"   # Go 模块代理
NPM_REGISTRY="https://registry.npmmirror.com"  # npm 镜像
GH_PROXY=""                  # 例：https://ghfast.top  留空=直连
SERVICE_NAME="flvx-panel"
NGINX_CONF_NAME="flvx.conf"

# ---------- 颜色 ----------
C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_C='\033[0;36m'; C_0='\033[0m'
log(){ echo -e "${C_C}[$(date +%H:%M:%S)]${C_0} $*"; }
ok(){  echo -e "${C_G}[OK]${C_0} $*"; }
warn(){echo -e "${C_Y}[!]${C_0} $*"; }
err(){ echo -e "${C_R}[X]${C_0} $*" >&2; }

# ---------- root 检查 ----------
[[ $EUID -ne 0 ]] && { err "请用 root 或 sudo 执行"; exit 1; }

# ---------- OS / ARCH 检测 ----------
detect_os(){
  if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID=$ID; OS_VER=$VERSION_ID
  else err "无法识别操作系统（缺 /etc/os-release）"; exit 1; fi
  case "$(uname -m)" in
    x86_64)   ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) err "不支持的架构：$(uname -m)"; exit 1 ;;
  esac
  log "系统：$OS_ID $OS_VER  架构：$ARCH"
}

# ---------- 包管理器封装 ----------
pkg_install(){
  case "$OS_ID" in
    ubuntu|debian) apt-get update -y >/dev/null; apt-get install -y "$@" ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null; then dnf install -y "$@"
      else yum install -y "$@"; fi ;;
    *) err "不支持的发行版：$OS_ID"; exit 1 ;;
  esac
}

# ---------- 工具链安装 ----------
install_go(){
  if command -v go >/dev/null && go version | grep -qE 'go1\.(2[5-9]|[3-9])'; then
    ok "已安装 $(go version)"; return
  fi
  local ver="1.25.0"
  local url="https://go.dev/dl/go${ver}.linux-${ARCH}.tar.gz"
  [[ -n "$GH_PROXY" ]] && url="${GH_PROXY}/${url}"
  log "安装 Go ${ver} ..."
  rm -rf /usr/local/go
  curl -fsSL "$url" | tar -C /usr/local -xz
  grep -q '/usr/local/go/bin' /etc/profile || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
  export PATH=$PATH:/usr/local/go/bin
  go version
}

install_node(){
  if command -v node >/dev/null && [[ "$(node -v | cut -dv -f2 | cut -d. -f1)" -ge 20 ]]; then
    ok "已安装 $(node -v)"; return
  fi
  log "安装 Node.js 20.x ..."
  case "$OS_ID" in
    ubuntu|debian)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs ;;
    *)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      dnf install -y nodejs ;;
  esac
  node -v
}

install_pnpm(){
  if ! command -v pnpm >/dev/null; then
    npm install -g pnpm --registry="$NPM_REGISTRY"
  fi
  npm config set registry "$NPM_REGISTRY"
  pnpm config set registry "$NPM_REGISTRY"
  ok "pnpm $(pnpm -v)"
}

install_nginx(){
  if ! command -v nginx >/dev/null; then
    log "安装 nginx ..."
    pkg_install nginx
  fi
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

install_build_deps(){
  pkg_install curl ca-certificates git wget tar gzip \
              build-essential gcc make     # debian/ubuntu
  # centos 系若没 build-essential，补一下
  command -v gcc >/dev/null || pkg_install gcc gcc-c++ make
}

# ---------- 源码拉取 / 更新 ----------
fetch_source(){
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "已有源码，执行 git pull ..."
    git -C "$INSTALL_DIR" fetch --all
    git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
  else
    log "克隆源码到 $INSTALL_DIR ..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
}

# ---------- 编译后端 ----------
build_backend(){
  log "编译后端 paneld ..."
  cd "$INSTALL_DIR/go-backend"
  export GOPROXY="$GOMOD_PROXY"
  export CGO_ENABLED=1            # sqlite 驱动 modernc 是纯 Go，但留 CGO 兼容
  go mod download
  go build -trimpath -ldflags="-s -w" -o paneld ./cmd/paneld
  [[ -f paneld ]] && ok "后端二进制：$(ls -lh paneld | awk '{print $5}')" || { err "后端编译失败"; exit 1; }
}

# ---------- 构建前端 ----------
build_frontend(){
  log "构建前端 ..."
  cd "$INSTALL_DIR/vite-frontend"
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
  pnpm build
  [[ -d dist ]] && ok "前端产物：dist/（$(du -sh dist | awk '{print $1}')）" || { err "前端构建失败"; exit 1; }
}

# ---------- 环境文件 ----------
gen_env(){
  local envfile="$INSTALL_DIR/.env"
  if [[ -f "$envfile" ]]; then
    warn ".env 已存在，保留不动（如需重置请先删除）"
    return
  fi
  local jwt; jwt=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
  cat > "$envfile" <<EOF
# flvx 裸机部署环境变量
DB_TYPE=sqlite
DB_PATH=$INSTALL_DIR/data/gost.db
JWT_SECRET=$jwt
SERVER_ADDR=:$BACKEND_PORT
TZ=Asia/Shanghai
FLUX_VERSION=baremetal
EOF
  chmod 600 "$envfile"
  ok ".env 已生成（JWT_SECRET 已随机化）"
}

# ---------- systemd ----------
gen_systemd(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=flvx panel (baremetal, no docker)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/go-backend/paneld
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
StandardOutput=append:/var/log/flvx-panel.log
StandardError=append:/var/log/flvx-panel.log

[Install]
WantedBy=multi-user.target
EOF
  : > /var/log/flvx-panel.log
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  ok "systemd 服务已创建：$SERVICE_NAME"
}

# ---------- nginx 反代 ----------
gen_nginx(){
  local root="$INSTALL_DIR/vite-frontend/dist"
  local conf="/etc/nginx/conf.d/${NGINX_CONF_NAME}"
  # 兼容 sites-enabled 的发行版
  [[ -d /etc/nginx/sites-enabled && ! -d /etc/nginx/conf.d ]] && conf="/etc/nginx/sites-enabled/${NGINX_CONF_NAME}"
  cat > "$conf" <<EOF
server {
    listen $FRONTEND_PORT;
    server_name _;
    root $root;
    index index.html;
    client_max_body_size 64m;

    # PWA / SW 不缓存
    location ~* (sw\\.js|service-worker\\.js|workbox-.*\\.js|manifest\\.webmanifest)\$ {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        try_files \$uri =404;
    }
    # 静态资源
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    # HTML 不缓存
    location ~* \\.(?:htm|html)\$ {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        try_files \$uri \$uri/ /index.html;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    # 流式诊断接口（关闭缓冲）
    location = /api/v1/tunnel/diagnose/stream {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_buffering off; proxy_cache off;
        proxy_read_timeout 120s; proxy_send_timeout 120s;
        proxy_pass http://127.0.0.1:$BACKEND_PORT/api/v1/tunnel/diagnose/stream;
    }
    location = /api/v1/forward/diagnose/stream {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_buffering off; proxy_cache off;
        proxy_read_timeout 120s; proxy_send_timeout 120s;
        proxy_pass http://127.0.0.1:$BACKEND_PORT/api/v1/forward/diagnose/stream;
    }
    # 通用 API
    location ^~ /api/v1/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s; proxy_send_timeout 120s;
        proxy_pass http://127.0.0.1:$BACKEND_PORT/api/v1/;
    }
    # 流量上报
    location /flow/upload { proxy_pass http://127.0.0.1:$BACKEND_PORT/flow/upload; }
    location /flow/config { proxy_pass http://127.0.0.1:$BACKEND_PORT/flow/config; }
    # WebSocket
    location /system-info {
        proxy_pass http://127.0.0.1:$BACKEND_PORT/system-info;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s; proxy_send_timeout 3600s;
        proxy_set_header Host \$host;
    }
}
EOF
  nginx -t || { err "nginx 配置语法错误"; exit 1; }
  systemctl reload nginx
  ok "nginx 配置已生成并 reload：$conf"
}

# ---------- 防火墙提示 ----------
firewall_hint(){
  if command -v ufw >/dev/null; then
    ufw allow "$FRONTEND_PORT/tcp" >/dev/null 2>&1 && warn "ufw 已放行 $FRONTEND_PORT"
  elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port="$FRONTEND_PORT/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && warn "firewalld 已放行 $FRONTEND_PORT"
  fi
  warn "云服务器请同时在安全组放行 $FRONTEND_PORT 与节点通信端口"
}

# ---------- 启动 ----------
start_services(){
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "后端已启动（端口 $BACKEND_PORT）"
  else
    err "后端启动失败，查看日志：journalctl -u $SERVICE_NAME -n 50"
    exit 1
  fi
  # 健康检查
  if curl -fsS "http://127.0.0.1:$BACKEND_PORT/flow/test" >/dev/null 2>&1; then
    ok "后端健康检查通过"
  else
    warn "健康检查 /flow/test 未通过，可能还在初始化，稍等再试"
  fi
}

# ---------- 菜单 ----------
show_menu(){
  cat <<EOF
 ${C_C}=============== flvx 裸机部署 ===============${C_0}
1) 安装（首次部署）
2) 更新（git pull + 重新编译 + 重启）
3) 卸载（停止服务并清理）
4) 查看状态
5) 退出
EOF
}

do_install(){
  detect_os
  install_build_deps
  install_go
  install_node
  install_pnpm
  install_nginx
  fetch_source
  build_backend
  build_frontend
  gen_env
  gen_systemd
  gen_nginx
  firewall_hint
  start_services
  echo
  ok "部署完成！访问：http://<服务器IP>:$FRONTEND_PORT"
  echo "   后端 API： http://<服务器IP>:$BACKEND_PORT"
  echo "   日志：     tail -f /var/log/flvx-panel.log"
  echo "   管理：     systemctl {status|restart|stop} $SERVICE_NAME"
}

do_update(){
  detect_os
  fetch_source
  build_backend
  build_frontend
  systemctl restart "$SERVICE_NAME"
  ok "更新完成"
}

do_uninstall(){
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/nginx/conf.d/${NGINX_CONF_NAME}" /etc/nginx/sites-enabled/${NGINX_CONF_NAME}
  systemctl daemon-reload
  systemctl reload nginx 2>/dev/null || true
  warn "已停止服务并移除 systemd / nginx 配置"
  read -rp "是否同时删除源码与数据目录 $INSTALL_DIR ？[y/N] " del
  [[ "$del" =~ ^[Yy]$ ]] && rm -rf "$INSTALL_DIR" && ok "已删除 $INSTALL_DIR"
}

do_status(){
  systemctl status "$SERVICE_NAME" --no-pager -l | head -n 20
  echo
  nginx -t 2>&1 | head -n 5
}

# ---------- 入口 ----------
if [[ $# -ge 1 ]]; then
  case "$1" in
    install|update|uninstall|status) "do_$1" ;;
    *) show_menu; exit 1 ;;
  esac
else
  show_menu
  read -rp "请选择 [1-5]：" c
  case "$c" in
    1) do_install ;;
    2) do_update ;;
    3) do_uninstall ;;
    4) do_status ;;
    5) exit 0 ;;
    *) err "无效选项"; exit 1 ;;
  esac
fi
