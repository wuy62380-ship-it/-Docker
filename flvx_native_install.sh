cat > /root/flvx_native_install.sh << 'EOF'
#!/bin/bash
# -------------------------------------------------------------
# FLVX 面板免 Docker 一键原生安装脚本 (完全修复版 - 专为直播中转优化)
# -------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 root 用户或使用 sudo 运行此脚本！"
  exit 1
fi

echo "🚀 开始进行 FLVX 面板纯原生免 Docker 闭环安装..."

# 1. 再次确保基础依赖与 Nginx 完好
echo "📦 正在配置系统组件与 Nginx..."
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y wget tar curl nginx nano
elif [ -f /etc/redhat-release ]; then
    yum install -y epel-release && yum update -y && yum install -y wget tar curl nginx nano
else
    echo "❌ 暂不支持的系统架构。"
    exit 1
fi

# 清理历史残留错误文件
cd /root
rm -f index.html

# 2. 安装高性能四层转发内核 Realm (物理级原生高并发，完美落地任何直播协议)
echo "⚙️ 正在下载并配置 Rust-Realm 转发核心..."
wget -q --show-progress https://github.com
if [ $? -ne 0 ]; then
    echo "❌ Realm 下载失败，请检查网络！"
    exit 1
fi
tar -zxvf realm-x86_64-unknown-linux-gnu.tar.gz > /dev/null
mv realm /usr/local/bin/
chmod +x /usr/local/bin/realm
rm -f realm-x86_64-unknown-linux-gnu.tar.gz
echo "✅ Realm 核心就位，当前版本：" && realm --version

# 3. 下载真正的 FLVX 面板 Go 编译版后端程序
echo "📥 正在建立工作目录并下载真正的 FLVX 后端..."
mkdir -p /opt/flvx && cd /opt/flvx
rm -f flvx-backend
wget -q --show-progress https://github.com -O flvx-backend
if [ $? -ne 0 ]; then
    echo "❌ 后端二进制程序下载失败！"
    exit 1
fi
chmod +x flvx-backend

# 覆盖创建干净的后台配置文件
cat > .env << 'INNER_EOF'
JWT_SECRET=LiveStreamSecret666
BACKEND_PORT=6365
DB_TYPE=sqlite
INNER_EOF

# 4. 配置 Systemd 进程守护 (保证推流长连接 24 小时不断流，挂了 5 秒内自动复活)
echo "🛡️ 正在配置 Systemd 后台服务守护..."
cat > /etc/systemd/system/flvx.service << 'INNER_EOF'
[Unit]
Description=FLVX High Performance Live Stream Transfer Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/flvx
ExecStart=/opt/flvx/flvx-backend
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
INNER_EOF

systemctl daemon-reload
systemctl enable flvx --now > /dev/null

# 5. 下载并部署前端 Web 静态资源
echo "🌐 正在下载并解压前端网页文件..."
cd /opt/flvx
wget -q --show-progress https://github.com
mkdir -p /var/www/flvx
tar -zxvf vite-frontend.tar.gz -C /var/www/flvx > /dev/null
rm -f vite-frontend.tar.gz

# 6. 配置 Nginx 网页端与 API 反向代理 (打通 80 端口，并针对直播长连接优化超时)
echo "🔧 正在自动配置 Nginx 代理规则..."
cat > /etc/nginx/conf.d/flvx.conf << 'INNER_EOF'
server {
    listen 80;
    server_name _; # 允许通过任意公网 IP 直接访问

    # 托管静态前端
    location / {
        root /var/www/flvx;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # 反向代理后端 API 接口
    location /api/ {
        proxy_pass http://127.0.0;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 直播长连接及 WebSocket 优化配置，防止断流
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
INNER_EOF

# 清理 Debian 默认欢迎页，并重载 Nginx
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# 7. 打印最终安装完成面板
SERVER_IP=$(curl -s ifconfig.me)
echo "=================================================================="
echo "🎉 恭喜！FLVX 免 Docker 纯原生高并发中转面板全部部署成功！"
echo "=================================================================="
echo "🌐 面板访问地址：http://${SERVER_IP}"
echo "👤 默认管理员账号：admin_user"
echo "🔑 默认管理员密码：admin_user"
echo "⚠️ 警告：为了直播流安全，登录后请立即前往后台修改默认密码！"
echo "=================================================================="
EOF
chmod +x /root/flvx_native_install.sh && /root/flvx_native_install.sh
