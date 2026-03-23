#!/bin/bash
# ============================================================
# UniEvent EC2 Bootstrap Script
# CE 308/408 Cloud Computing – Assignment 1
# Run as EC2 User Data (root). Amazon Linux 2023 assumed.
# ============================================================

set -euo pipefail
LOG=/var/log/unievent_bootstrap.log
exec > >(tee -a "$LOG") 2>&1

echo "=== UniEvent bootstrap started at $(date) ==="

# ── 1. System update ──────────────────────────────────────────────
dnf update -y
dnf install -y python3 python3-pip git nginx

# ── 2. Clone application from GitHub ─────────────────────────────
cd /opt
git clone https://github.com/Murtaza436/Assignment1_AWS_CE.git unievent
cd unievent/src

# ── 3. Python dependencies ────────────────────────────────────────
pip3 install flask boto3 requests gunicorn

# ── 4. Environment variables ──────────────────────────────────────
cat > /opt/unievent/src/.env <<'ENVEOF'
TICKETMASTER_API_KEY=	z4GY8GpPFrQgh0G7iJTDJlijAWBRJ212
S3_BUCKET_NAME=unievent-media-bucket
AWS_REGION=us-east-1
ENVEOF

# ── 5. Systemd service ────────────────────────────────────────────
cat > /etc/systemd/system/unievent.service <<'SVCEOF'
[Unit]
Description=UniEvent Flask Application
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/opt/unievent/src
EnvironmentFile=/opt/unievent/src/.env
ExecStart=/usr/local/bin/gunicorn --workers 4 --bind 127.0.0.1:5000 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# ── 6. Nginx reverse proxy ────────────────────────────────────────
cat > /etc/nginx/conf.d/unievent.conf <<'NGXEOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }

    location /static/ {
        alias /opt/unievent/src/static/;
        expires 7d;
    }

    # ALB / ELB health check
    location /health {
        proxy_pass http://127.0.0.1:5000/health;
    }
}
NGXEOF

# ── 7. Enable & start services ────────────────────────────────────
systemctl daemon-reload
systemctl enable unievent nginx
systemctl start unievent nginx

# ── 8. Cron: refresh events from API every 15 minutes ─────────────
(crontab -l 2>/dev/null; echo "*/15 * * * * curl -s http://localhost/api/events > /dev/null") | crontab -

echo "=== Bootstrap complete at $(date) ==="
