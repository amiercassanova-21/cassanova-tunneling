#!/bin/bash
# =====================================================================
#  CAS HY2 PROBE - Tahap 1: buktikan Hysteria2 (apernet) jalan di VPS ini
#  Aman: tidak menyentuh Xray/nginx/SSH. Bisa dibatalkan total dengan
#        perintah pembersih yang dicetak di akhir.
# =====================================================================
set -u
GRN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
say(){ echo -e "${GRN}[HY2]${NC} $*"; }
err(){ echo -e "${RED}[HY2]${NC} $*"; }

ASD=/etc/autoscript
DOMAIN=$(cat $ASD/domain 2>/dev/null | tr -d '[:space:]')
CRT=$ASD/xray.crt; KEY=$ASD/xray.key
PORT=443                       # UDP 443 (TCP 443 tetap milik nginx, tidak bentrok)
TESTPASS="hy2test-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"

[[ -z "$DOMAIN" ]] && { err "Domain belum diset ($ASD/domain kosong). Jalankan menu Change Domain dulu."; exit 1; }
[[ -s "$CRT" && -s "$KEY" ]] || { err "Sertifikat $CRT / $KEY tidak ada. Pastikan SSL sudah terbit."; exit 1; }

# --- arsitektur ---
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  *) err "Arsitektur $(uname -m) belum didukung probe ini."; exit 1 ;;
esac

# --- unduh biner resmi apernet (versi terbaru) ---
if [[ ! -x /usr/local/bin/hysteria ]]; then
  say "Mengambil versi terbaru Hysteria2..."
  TAG=$(curl -fsSL --max-time 20 https://api.github.com/repos/apernet/hysteria/releases/latest \
        | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | grep -oE 'app/v[0-9.]+')
  [[ -z "$TAG" ]] && { err "Gagal membaca versi terbaru dari GitHub."; exit 1; }
  URL="https://github.com/apernet/hysteria/releases/download/${TAG}/hysteria-linux-${ARCH}"
  say "Unduh $URL"
  curl -fL --max-time 120 -o /usr/local/bin/hysteria "$URL" || { err "Unduh biner gagal."; exit 1; }
  chmod +x /usr/local/bin/hysteria
fi
say "Biner: $(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version/{print $2}' | head -1)"

# --- config server minimal ---
mkdir -p /etc/hysteria
cat > /etc/hysteria/probe.yaml <<YAML
listen: :$PORT
tls:
  cert: $CRT
  key: $KEY
auth:
  type: password
  password: $TESTPASS
masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN
    rewriteHost: true
YAML

# --- unit sementara ---
cat > /etc/systemd/system/cas-hy2-probe.service <<UNIT
[Unit]
Description=CAS HY2 Probe (sementara)
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/probe.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl restart cas-hy2-probe
sleep 2

# --- buka UDP port di firewall kalau ada ufw/iptables ---
command -v ufw >/dev/null 2>&1 && ufw allow $PORT/udp >/dev/null 2>&1
iptables -C INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null

echo
if systemctl is-active --quiet cas-hy2-probe; then
  say "Server HY2 AKTIF di UDP $PORT"
else
  err "Server HY2 GAGAL start. Log:"; journalctl -u cas-hy2-probe -n 20 --no-pager; exit 1
fi
ss -lun 2>/dev/null | grep -q ":$PORT " && say "Port UDP $PORT terdengar" || err "Port UDP $PORT belum terdengar (cek firewall provider)"

LINK="hysteria2://${TESTPASS}@${DOMAIN}:${PORT}/?sni=${DOMAIN}&insecure=0#CAS-HY2-TEST"
echo
echo -e "${YEL}=================== LINK UJI HY2 ===================${NC}"
echo "$LINK"
echo -e "${YEL}===================================================${NC}"
echo " Impor link di atas ke app HY2 (v2rayNG/NekoBox/sing-box/Hysteria)."
echo " Kalau tersambung & bisa internetan = fondasi HY2 OK."
echo
echo -e "${YEL}Untuk membersihkan probe ini nanti:${NC}"
echo "  systemctl disable --now cas-hy2-probe; rm -f /etc/systemd/system/cas-hy2-probe.service /etc/hysteria/probe.yaml; systemctl daemon-reload; iptables -D INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null"
