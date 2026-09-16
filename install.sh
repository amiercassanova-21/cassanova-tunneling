#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - TAHAP 1
#  Xray (VLESS / VMESS / TROJAN WS) + Nginx + SSL + Menu
#  OS: Ubuntu 20.04 / 22.04 / 24.04
# =====================================================

RED='\e[31m'; GRN='\e[32m'; CYN='\e[36m'; NC='\e[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
. /etc/os-release
[[ "$ID" != "ubuntu" ]] && echo -e "${RED}Script ini hanya untuk Ubuntu${NC}" && exit 1

clear
echo -e "${CYN}==============================================${NC}"
echo -e "${CYN}      CASSANOVA TUNNELING - INSTALLER       ${NC}"
echo -e "${CYN}==============================================${NC}"
echo -e "Pastikan domain sudah diarahkan ke IP VPS ini"
echo -e "(Cloudflare: mode DNS only / awan abu-abu)\n"
read -rp "Masukkan domain : " DOMAIN
[[ -z "$DOMAIN" ]] && echo -e "${RED}Domain tidak boleh kosong${NC}" && exit 1
read -rp "Nama brand [CASSANOVA TUNNELING] : " BRAND
BRAND=${BRAND:-CASSANOVA TUNNELING}

export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/autoscript/db /var/log/xray /var/www/html
echo "$DOMAIN" > /etc/autoscript/domain
echo "$BRAND"  > /etc/autoscript/brand
echo "v1.2.1"  > /etc/autoscript/version
touch /etc/autoscript/db/vless.db /etc/autoscript/db/vmess.db /etc/autoscript/db/trojan.db

# ---------- Paket dasar ----------
echo -e "${GRN}[1/6] Install paket dasar...${NC}"
apt update -y
apt install -y curl wget jq nginx vnstat socat cron at uuid-runtime bc net-tools lsof unzip ca-certificates
timedatectl set-timezone Asia/Jakarta
systemctl enable --now vnstat atd cron

# ---------- BBR & Swap ----------
echo -e "${GRN}[2/6] Aktifkan BBR & swap...${NC}"
grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}
sysctl -p >/dev/null 2>&1
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
curl -s --max-time 10 ipinfo.io/json > /etc/autoscript/ipinfo.json

# ---------- Xray ----------
echo -e "${GRN}[3/6] Install Xray core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

cat > /usr/local/etc/xray/config.json <<'EOF'
{
  "log": { "access": "none", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "api": { "tag": "api", "services": ["StatsService", "HandlerService"] },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    { "tag": "api", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },
    { "tag": "vless-ws", "listen": "127.0.0.1", "port": 10001, "protocol": "vless",
      "settings": { "decryption": "none", "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } } },
    { "tag": "vmess-ws", "listen": "127.0.0.1", "port": 10002, "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } } },
    { "tag": "trojan-ws", "listen": "127.0.0.1", "port": 10003, "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } } }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": { "rules": [ { "type": "field", "inboundTag": ["api"], "outboundTag": "api" } ] }
}
EOF

# ---------- SSL ----------
echo -e "${GRN}[4/6] Membuat sertifikat SSL...${NC}"
systemctl stop nginx
curl -s https://get.acme.sh | sh -s email=admin@$DOMAIN
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file /etc/autoscript/xray.crt \
  --key-file /etc/autoscript/xray.key \
  --reloadcmd "systemctl reload nginx"
if [[ ! -s /etc/autoscript/xray.crt ]]; then
  echo -e "${RED}SSL gagal dibuat. Cek pointing domain lalu install ulang.${NC}"
  exit 1
fi

# ---------- Nginx ----------
echo -e "${GRN}[5/6] Konfigurasi Nginx...${NC}"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/conf.d/xray.conf <<'EOF'
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name DOMAIN_HERE;

    ssl_certificate     /etc/autoscript/xray.crt;
    ssl_certificate_key /etc/autoscript/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;

    location = /vless {
        if ($http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
    location = /vmess {
        if ($http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
    location = /trojan-ws {
        if ($http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
}
EOF
sed -i "s/DOMAIN_HERE/$DOMAIN/" /etc/nginx/conf.d/xray.conf
echo "<h1>OK</h1>" > /var/www/html/index.html

# ---------- Start service dasar ----------
nginx -t && systemctl restart nginx
systemctl restart xray
systemctl enable xray nginx >/dev/null 2>&1

# ---------- Pasang menu & fitur (update.sh) ----------
echo -e "${GRN}[6/6] Memasang menu & fitur...${NC}"
wget -qO /root/update.sh https://raw.githubusercontent.com/amiercassanova-21/cassanova-tunneling/main/update.sh
if [[ ! -s /root/update.sh ]]; then
  echo -e "${RED}Gagal mengunduh update.sh dari GitHub${NC}"
  exit 1
fi
bash /root/update.sh

clear
echo -e "${GRN}==============================================${NC}"
echo -e "${GRN}           INSTALASI SELESAI                  ${NC}"
echo -e "${GRN}==============================================${NC}"
echo -e " Domain : $DOMAIN"
echo -e " Ketik  : ${CYN}menu${NC} untuk membuka menu"
echo -e "${GRN}==============================================${NC}"
rm -f /root/install.sh
