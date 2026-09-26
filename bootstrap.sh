#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - BOOTSTRAP INSTALL (tanpa domain)
#  Dijalankan lewat: bash <(curl -fsSL <link-install>)
#  Worker mengirim script ini dengan CAS_LICENSE & CAS_KEY sudah terisi.
# =====================================================
set -e
RED='\e[31m'; GRN='\e[32m'; YEL='\e[33m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1

: "${CAS_LICENSE:=https://license.cassanova.my.id}"
# CAS_KEY wajib untuk install biasa. Untuk install TRIAL (CAS_TRIAL=1) key kosong
# dan akan diambil otomatis dari server setelah IP terdeteksi.
if [[ -z "${CAS_KEY:-}" && "${CAS_TRIAL:-}" != "1" ]]; then
  echo -e "${RED}Link install tidak sah (CAS_KEY kosong)${NC}"; exit 1
fi
RAW="https://raw.githubusercontent.com/amiercassanova-21/cassanova-tunneling/main"

echo -e "${GRN}=== CASSANOVA TUNNELING INSTALLER ===${NC}"
echo -e "Menyiapkan paket dasar..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y curl socat cron jq >/dev/null 2>&1

# 1) Deteksi IP publik VPS
IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 ifconfig.me 2>/dev/null)
[[ -z "$IP" ]] && echo -e "${RED}Gagal deteksi IP VPS${NC}" && exit 1
echo -e " IP VPS   : ${GRN}$IP${NC}"

# 1b) Mode TRIAL: minta lisensi trial untuk IP ini (sekali per IP)
if [[ -z "${CAS_KEY:-}" && "${CAS_TRIAL:-}" == "1" ]]; then
  echo -e "Meminta lisensi ${YEL}TRIAL${NC} untuk IP $IP ..."
  TR=$(curl -fsS --max-time 15 -G "$CAS_LICENSE/trial" --data-urlencode "ip=$IP" 2>/dev/null)
  if [[ "$(echo "$TR" | jq -r '.ok' 2>/dev/null)" != "true" ]]; then
    er=$(echo "$TR" | jq -r '.error // "gagal"' 2>/dev/null)
    case "$er" in
      trial_used)         echo -e "${RED}IP ini sudah pernah memakai trial.${NC} Hubungi admin untuk berlangganan." ;;
      already_licensed)   echo -e "${YEL}IP ini sudah punya lisensi aktif.${NC} Pakai link install biasa." ;;
      trial_off)          echo -e "${RED}Link trial sedang dinonaktifkan.${NC} Hubungi admin." ;;
      trial_link_expired) echo -e "${RED}Masa berlaku link trial sudah habis.${NC} Hubungi admin." ;;
      *)                  echo -e "${RED}Trial tidak tersedia: $er${NC}" ;;
    esac
    exit 1
  fi
  CAS_KEY=$(echo "$TR" | jq -r '.key')
  TRDAYS=$(echo "$TR" | jq -r '.days')
  echo -e " Trial    : ${GRN}aktif ${TRDAYS} hari${NC}"
fi

# 2) Cek lisensi
LIC=$(curl -fsS --max-time 15 -G "$CAS_LICENSE/check" --data-urlencode "ip=$IP" 2>/dev/null)
if ! echo "$LIC" | grep -q '"licensed":true'; then
  echo -e "${RED}IP $IP tidak berlisensi atau masa aktif habis.${NC}"
  echo -e "Hubungi admin untuk mendaftarkan IP ini."
  exit 1
fi
CLIENT=$(echo "$LIC" | jq -r '.client // "client"')
EXP=$(echo "$LIC" | jq -r '.exp // "-"')
echo -e " Lisensi  : ${GRN}OK${NC} (client: $CLIENT, exp: $EXP)"

# 3) Provision subdomain acak
PROV=$(curl -fsS --max-time 20 -G "$CAS_LICENSE/provision" \
  --data-urlencode "key=$CAS_KEY" --data-urlencode "ip=$IP" 2>/dev/null)
SUB=$(echo "$PROV" | jq -r '.sub // empty')
if [[ -z "$SUB" ]]; then
  echo -e "${RED}Gagal membuat subdomain: $PROV${NC}"; exit 1
fi
echo -e " Domain   : ${GRN}$SUB${NC} (otomatis)"
mkdir -p /etc/autoscript
echo "$SUB" > /etc/autoscript/domain
echo "$CAS_LICENSE" > /etc/autoscript/license_url
echo "$CAS_KEY" > /etc/autoscript/license_key
chmod 600 /etc/autoscript/license_key

# 4) Pasang acme.sh + hook DNS-01 ke Worker, terbitkan SSL
echo -e "Menerbitkan SSL untuk $SUB ..."
curl -fsSL https://get.acme.sh | sh -s email=admin@"$SUB" >/dev/null 2>&1
export CAS_LICENSE
curl -fsSL "$RAW/acme-hook.sh" -o /root/.acme.sh/dnsapi/dns_cas.sh 2>/dev/null || {
  mkdir -p /root/.acme.sh/dnsapi
  curl -fsSL "$RAW/acme-hook.sh" -o /root/.acme.sh/dnsapi/dns_cas.sh
}
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
# tunggu DNS subdomain propagasi sebentar
sleep 5
if CAS_LICENSE="$CAS_LICENSE" /root/.acme.sh/acme.sh --issue --dns dns_cas -d "$SUB" -k ec-256 --dnssleep 20 >/tmp/acme.log 2>&1; then
  /root/.acme.sh/acme.sh --install-cert -d "$SUB" --ecc \
    --fullchain-file /etc/autoscript/xray.crt \
    --key-file /etc/autoscript/xray.key >/dev/null 2>&1
  echo -e " SSL      : ${GRN}OK${NC}"
else
  echo -e "${RED}SSL gagal. Log:${NC}"; tail -n 15 /tmp/acme.log; exit 1
fi

# 5) Jalankan installer utama (mode non-interaktif: domain sudah ada)
echo -e "Memasang Cassanova Tunneling..."
export CAS_DOMAIN="$SUB" CAS_NODOMAIN=1
curl -fsSL "$RAW/install.sh" -o /root/install.sh
bash /root/install.sh

echo -e "${GRN}=== INSTALL SELESAI ===${NC}"
echo -e "Domain : $SUB"
echo -e "Ketik  : ${GRN}menu${NC}"
