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
echo "v1.0.0"  > /etc/autoscript/version
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

# ---------- Menu ----------
echo -e "${GRN}[6/6] Memasang menu...${NC}"

# ===== MENU UTAMA =====
cat > /usr/local/sbin/menu <<'EOF'
#!/bin/bash
R='\e[31m'; G='\e[32m'; Y='\e[33m'; B='\e[34m'; C='\e[36m'; P='\e[35m'; O='\e[38;5;208m'; N='\e[0m'; BG='\e[41m'
BRAND=$(cat /etc/autoscript/brand); DOMAIN=$(cat /etc/autoscript/domain); VER=$(cat /etc/autoscript/version)
W=44
center(){ local t="$1"; local l=$(( (W-${#t})/2 )); local r=$(( W-${#t}-l )); printf "%*s%s%*s" $l "" "$t" $r ""; }
top(){ echo -e "${B}┌$(printf '─%.0s' $(seq 1 $((W+2))))┐${N}"; }
bot(){ echo -e "${B}└$(printf '─%.0s' $(seq 1 $((W+2))))┘${N}"; }
row(){ printf "${B}│${N} ${G}%-8s${N}: %s\n" "$1" "$2"; }
sep(){ echo -e "${B}│${N} ${P}$(printf '─%.0s' $(seq 1 36))${N}"; }
st(){ systemctl is-active --quiet "$1" && echo -e "${Y}ON${N}" || echo -e "${R}OFF${N}"; }

dashboard(){
  clear
  . /etc/os-release
  local I=/etc/autoscript/ipinfo.json
  local CITY=$(jq -r '.city // "-"' $I 2>/dev/null)
  local ISP=$(jq -r '.org // "-"' $I 2>/dev/null | sed 's/^AS[0-9]* //')
  local IP=$(jq -r '.ip // "-"' $I 2>/dev/null)
  local RAM=$(free -m | awk '/Mem:/{print $2"M"}')
  local SWAP=$(free -m | awk '/Swap:/{print $2"M"}')
  local UP=$(uptime -p | sed 's/up //')
  local V=$(vnstat --oneline 2>/dev/null) F
  if [[ "$V" == 1\;* ]]; then IFS=';' read -ra F <<< "$V"; else F=(- - - - - - - - - - - -); fi

  top; echo -e "${B}│${N} ${BG}${G}$(center "$BRAND")${N} ${B}│${N}"; bot
  top
  row "OS" "$PRETTY_NAME"; row "RAM" "$RAM"; row "SWAP" "$SWAP"
  row "CITY" "$CITY"; row "ISP" "$ISP"
  printf "${B}│${N} ${G}%-8s${N}: ${C}%s${N}\n" "IP" "$IP"
  printf "${B}│${N} ${G}%-8s${N}: ${C}%s${N}\n" "DOMAIN" "$DOMAIN"
  row "UPTIME" "$UP"
  sep
  row "MONTH" "${F[10]}   [$(date +%B)]"; row "RX" "${F[8]}"; row "TX" "${F[9]}"
  sep
  row "DAY" "${F[5]}   [$(date +%A)]"; row "RX" "${F[3]}"; row "TX" "${F[4]}"
  row "TRAFFIC" "${F[6]}"
  bot
  local S="GOOD"; systemctl is-active --quiet xray && systemctl is-active --quiet nginx || S="ERROR"
  top
  echo -e "${B}│${N} XRAY : $(st xray) ${B}│${N} NGINX : $(st nginx) ${B}│${N} SSH : $(st ssh) ${B}│${N} ${G}$S${N}"
  bot
}

accounts(){
  local c1=$(grep -c . /etc/autoscript/db/vmess.db)
  local c2=$(grep -c . /etc/autoscript/db/vless.db)
  local c3=$(grep -c . /etc/autoscript/db/trojan.db)
  echo -e "      ${B}┌──────────────────────────────────┐${N}"
  echo -e "                ${G}LIST ACCOUNTS${N}"
  printf  "        ${G}%-14s${N}: ${Y}%-4s${N}${G}ACCOUNT${N}\n" "SSH/OPENVPN" "0" "VMESS" "$c1" "VLESS" "$c2" "TROJAN" "$c3"
  echo -e "      ${B}└──────────────────────────────────┘${N}"
}

version_box(){
  echo -e "    ${B}┌──────────────────────────────────────┐${N}"
  printf  "    ${B}│${N} ${G}%-12s${N}: ${O}%s${N}\n" "Version" "$VER" "Brand" "$BRAND" "Client Name" "$(hostname)" "Expiry In" "Lifetime"
  echo -e "    ${B}└──────────────────────────────────────┘${N}"
}

coming(){ echo -e "\n${Y}Fitur ini dibuat di tahap berikutnya.${N}"; sleep 2; }

if [[ "$1" == "info" ]]; then
  dashboard; accounts; version_box
  echo -e "\n          ${G}to access use ${C}menu${G} command${N}\n"
  exit 0
fi

while true; do
  dashboard; version_box
  top
  printf "${B}│${N} ${C}%-4s${N} %-18s ${C}%-4s${N} %-16s\n" "1.)" "SSH" "6.)" "FEATURES"
  printf "${B}│${N} ${C}%-4s${N} %-18s ${C}%-4s${N} %-16s\n" "2.)" "VMESS" "7.)" "SET REDUCE/TIME"
  printf "${B}│${N} ${C}%-4s${N} %-18s ${C}%-4s${N} %-16s\n" "3.)" "VLESS" "8.)" "SET BRAND NAME"
  printf "${B}│${N} ${C}%-4s${N} %-18s ${C}%-4s${N} %-16s\n" "4.)" "TROJAN" "9.)" "CHECK SERVICES"
  printf "${B}│${N} ${C}%-4s${N} %-18s ${C}%-4s${N} %-16s\n" "5.)" "SETUP BOT" "x.)" "EXIT"
  bot
  echo
  read -rp "$(echo -e "${G}Select From Options [1-9 or x] : ${N}")" opt
  case $opt in
    1) coming ;;
    2) m-xray vmess ;;
    3) m-xray vless ;;
    4) m-xray trojan ;;
    5|6|7|8) coming ;;
    9) running ;;
    x|X) clear; exit 0 ;;
    *) echo -e "${R}Pilihan salah${N}"; sleep 1 ;;
  esac
done
EOF

# ===== MENU XRAY (VLESS/VMESS/TROJAN) =====
cat > /usr/local/sbin/m-xray <<'EOF'
#!/bin/bash
R='\e[31m'; G='\e[32m'; Y='\e[33m'; B='\e[34m'; C='\e[36m'; P='\e[35m'; N='\e[0m'; BGB='\e[44m'
PROTO=$1
CFG=/usr/local/etc/xray/config.json
DB=/etc/autoscript/db/$PROTO.db
DOMAIN=$(cat /etc/autoscript/domain)
TAG="$PROTO-ws"
case $PROTO in
  vless)  WSPATH=/vless ;;
  vmess)  WSPATH=/vmess ;;
  trojan) WSPATH=/trojan-ws ;;
  *) echo "Usage: m-xray vless|vmess|trojan"; exit 1 ;;
esac
UP=${PROTO^^}

add_client(){
  local u=$1 id=$2 c
  case $PROTO in
    vless)  c=$(jq -nc --arg id "$id" --arg e "$u" '{id:$id,email:$e}') ;;
    vmess)  c=$(jq -nc --arg id "$id" --arg e "$u" '{id:$id,alterId:0,email:$e}') ;;
    trojan) c=$(jq -nc --arg id "$id" --arg e "$u" '{password:$id,email:$e}') ;;
  esac
  jq --arg t "$TAG" --argjson c "$c" '(.inbounds[]|select(.tag==$t).settings.clients) += [$c]' $CFG > /tmp/xr.json && mv /tmp/xr.json $CFG
}
del_client(){
  jq --arg t "$TAG" --arg e "$1" '(.inbounds[]|select(.tag==$t).settings.clients) |= map(select(.email!=$e))' $CFG > /tmp/xr.json && mv /tmp/xr.json $CFG
}
delete_user(){ del_client "$1"; sed -i "/^$1 /d" "$DB"; systemctl restart xray; }
exists(){ grep -q "^$1 " "$DB"; }

# ---- mode non-interaktif (cron / at) ----
if [[ "$2" == "--delete" && -n "$3" ]]; then delete_user "$3"; exit 0; fi
if [[ "$2" == "--expire" ]]; then
  today=$(date +%F); changed=0
  while read -r u exp id; do
    [[ -z "$u" ]] && continue
    if [[ "$exp" < "$today" ]]; then del_client "$u"; sed -i "/^$u /d" "$DB"; changed=1; fi
  done < <(cat "$DB")
  [[ $changed == 1 ]] && systemctl restart xray
  exit 0
fi

header(){
  clear
  echo -e "${B}════════════════════════════════════${N}"
  printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"
  echo -e "${B}════════════════════════════════════${N}"
}
bar(){ echo -e "${B}════════════════════════════════════${N}"; printf "${BGB}${G}%*s%*s${N}\n" $(( (36+${#1})/2 )) "$1" $(( 36-(36+${#1})/2 )) ""; echo -e "${B}════════════════════════════════════${N}"; }
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }

show_account(){
  local u=$1 id=$2 exp=$3 tls ntls
  case $PROTO in
    vless)
      tls="vless://$id@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&sni=$DOMAIN&path=%2Fvless#$u"
      ntls="vless://$id@$DOMAIN:80?encryption=none&security=none&type=ws&host=$DOMAIN&path=%2Fvless#$u" ;;
    vmess)
      local j1 j2
      j1=$(jq -nc --arg ps "$u" --arg a "$DOMAIN" --arg id "$id" --arg p "$WSPATH" '{v:"2",ps:$ps,add:$a,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$a,path:$p,tls:"tls",sni:$a}')
      j2=$(jq -nc --arg ps "$u" --arg a "$DOMAIN" --arg id "$id" --arg p "$WSPATH" '{v:"2",ps:$ps,add:$a,port:"80",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$a,path:$p,tls:""}')
      tls="vmess://$(echo -n "$j1" | base64 -w0)"
      ntls="vmess://$(echo -n "$j2" | base64 -w0)" ;;
    trojan)
      tls="trojan://$id@$DOMAIN:443?security=tls&type=ws&host=$DOMAIN&sni=$DOMAIN&path=%2Ftrojan-ws#$u"
      ntls="trojan://$id@$DOMAIN:80?security=none&type=ws&host=$DOMAIN&path=%2Ftrojan-ws#$u" ;;
  esac
  clear
  echo -e "${B}════════════════════════════════════${N}"
  echo -e "          ${G}$UP ACCOUNT${N}"
  echo -e "${B}════════════════════════════════════${N}"
  echo -e " Remarks   : ${Y}$u${N}"
  echo -e " Domain    : $DOMAIN"
  echo -e " Port TLS  : 443"
  echo -e " Port HTTP : 80"
  echo -e " ID/Pass   : $id"
  echo -e " Network   : ws"
  echo -e " Path      : $WSPATH"
  echo -e " Expired   : ${Y}$exp${N}"
  echo -e "${B}════════════════════════════════════${N}"
  echo -e " ${G}Link TLS :${N}\n$tls\n"
  echo -e " ${G}Link HTTP :${N}\n$ntls"
  echo -e "${B}════════════════════════════════════${N}"
}

ask_user_new(){
  read -rp "Username : " u
  [[ ! "$u" =~ ^[a-zA-Z0-9_-]+$ ]] && echo -e "${R}Username hanya huruf, angka, - dan _${N}" && return 1
  exists "$u" && echo -e "${R}Username sudah ada${N}" && return 1
  return 0
}

create(){
  local custom=$1
  ask_user_new || { sleep 2; return; }
  if [[ "$custom" == 1 ]]; then read -rp "UUID/Password : " id; else id=$(uuidgen); fi
  [[ -z "$id" ]] && echo -e "${R}UUID kosong${N}" && sleep 2 && return
  read -rp "Masa aktif (hari) : " d
  [[ ! "$d" =~ ^[0-9]+$ ]] && echo -e "${R}Harus angka${N}" && sleep 2 && return
  exp=$(date -d "+$d days" +%F)
  add_client "$u" "$id" && echo "$u $exp $id" >> "$DB"
  systemctl restart xray
  show_account "$u" "$id" "$exp"; pause
}

trial(){
  u="trial$(tr -dc a-z0-9 </dev/urandom | head -c4)"
  read -rp "Durasi trial (menit) [60] : " m; m=${m:-60}
  [[ ! "$m" =~ ^[0-9]+$ ]] && echo -e "${R}Harus angka${N}" && sleep 2 && return
  id=$(uuidgen); exp=$(date -d "+$m minutes" "+%F")
  add_client "$u" "$id" && echo "$u $exp $id" >> "$DB"
  systemctl restart xray
  echo "/usr/local/sbin/m-xray $PROTO --delete $u" | at now + $m minutes >/dev/null 2>&1
  show_account "$u" "$id" "$m menit"; pause
}

list_users(){
  header "LIST $UP USERS"
  printf " ${G}%-4s %-18s %-12s${N}\n" "NO" "USERNAME" "EXPIRED"
  local i=0
  while read -r u exp id; do
    [[ -z "$u" ]] && continue; i=$((i+1))
    printf " %-4s %-18s %-12s\n" "$i" "$u" "$exp"
  done < "$DB"
  [[ $i == 0 ]] && echo -e " ${Y}Belum ada akun${N}"
  echo -e "${B}════════════════════════════════════${N}"
}

delete(){
  list_users; read -rp "Username yang dihapus : " u
  exists "$u" || { echo -e "${R}User tidak ditemukan${N}"; sleep 2; return; }
  delete_user "$u"; echo -e "${G}User $u dihapus${N}"; pause
}

renew(){
  list_users; read -rp "Username : " u
  exists "$u" || { echo -e "${R}User tidak ditemukan${N}"; sleep 2; return; }
  read -rp "Tambah masa aktif (hari) : " d
  [[ ! "$d" =~ ^[0-9]+$ ]] && echo -e "${R}Harus angka${N}" && sleep 2 && return
  base=$(awk -v u="$u" '$1==u{print $2}' "$DB"); today=$(date +%F)
  [[ "$base" < "$today" ]] && base=$today
  new=$(date -d "$base +$d days" +%F)
  awk -v u="$u" -v n="$new" '$1==u{$2=n}1' "$DB" > /tmp/db && mv /tmp/db "$DB"
  echo -e "${G}User $u diperpanjang sampai $new${N}"; pause
}

modify_uuid(){
  list_users; read -rp "Username : " u
  exists "$u" || { echo -e "${R}User tidak ditemukan${N}"; sleep 2; return; }
  read -rp "UUID baru (kosongkan = acak) : " id; id=${id:-$(uuidgen)}
  del_client "$u"; add_client "$u" "$id"
  awk -v u="$u" -v n="$id" '$1==u{$3=n}1' "$DB" > /tmp/db && mv /tmp/db "$DB"
  systemctl restart xray
  exp=$(awk -v u="$u" '$1==u{print $2}' "$DB")
  show_account "$u" "$id" "$exp"; pause
}

coming(){ echo -e "\n${Y}Fitur ini dibuat di tahap berikutnya.${N}"; sleep 2; }

while true; do
  header "$UP"
  echo -e "\n ${C}1.)${N}  Create"
  echo -e " ${C}2.)${N}  Create [Custom UUID]"
  echo -e " ${C}3.)${N}  Trial"
  echo -e " ${C}4.)${N}  Delete"
  echo -e " ${C}5.)${N}  Renew/Extend"
  echo -e " ${C}6.)${N}  Modify UUID"
  echo -e " ${C}7.)${N}  Check Users Login"
  echo -e " ${C}8.)${N}  List Users"
  bar "LOCK & UNLOCK"
  echo -e " ${C}9.)${N}  Lock"
  echo -e " ${C}10.)${N} Unlock"
  bar "UTILITIES"
  echo -e " ${C}11.)${N} Check Config"
  echo -e " ${C}12.)${N} Recovery"
  echo -e " ${C}13.)${N} Edit Limit IP"
  echo -e " ${C}14.)${N} Edit Limit IP All"
  echo -e " ${C}15.)${N} Edit Limit Bandwidth"
  echo -e " ${C}16.)${N} Edit Limit All Bandwidth"
  echo -e " ${C}17.)${N} Back to Menu"
  echo -e " ${C}x.)${N}  Exit"
  echo -e "${B}════════════════════════════════════${N}\n"
  read -rp "$(echo -e "${G}Select From Options [1-17 or x] : ${N}")" opt
  case $opt in
    1) create 0 ;;
    2) create 1 ;;
    3) trial ;;
    4) delete ;;
    5) renew ;;
    6) modify_uuid ;;
    8) list_users; pause ;;
    11) header "CHECK CONFIG"; xray run -test -config $CFG; pause ;;
    7|9|10|12|13|14|15|16) coming ;;
    17) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
    *) echo -e "${R}Pilihan salah${N}"; sleep 1 ;;
  esac
done
EOF

# ===== CHECK SERVICES =====
cat > /usr/local/sbin/running <<'EOF'
#!/bin/bash
R='\e[31m'; G='\e[32m'; B='\e[34m'; P='\e[35m'; N='\e[0m'
BRAND=$(cat /etc/autoscript/brand)
st(){ systemctl is-active --quiet "$1" 2>/dev/null && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}"; }
port(){ ss -tln 2>/dev/null | grep -q ":$1 " && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}"; }
clear
echo -e "${B}════════════════════════════════════${N}"
printf "${P}%*s${N}\n" $(( (36+${#BRAND})/2 )) "$BRAND"
echo -e "${B}════════════════════════════════════${N}\n"
printf "${G}%-16s${N}: %b\n" \
  "SSH" "$(st ssh)" "DROPBEAR" "$(st dropbear)" "OPENVPN" "$(st openvpn)" \
  "SQUID" "$(st squid)" "NGINX" "$(st nginx)" "BADVPN" "$(st badvpn)" \
  "VMESS" "$(st xray)" "VLESS" "$(st xray)" "TROJAN" "$(st xray)" \
  "SlowDNS" "$(st slowdns)" "WEB" "$(st nginx)" \
  "HTTP" "$(port 80)" "HTTPS" "$(port 443)"
echo -e "\n${B}════════════════════════════════════${N}\n"
read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"
EOF

chmod +x /usr/local/sbin/menu /usr/local/sbin/m-xray /usr/local/sbin/running

# ---------- Auto hapus akun expired (tiap 00:05) ----------
cat > /etc/cron.d/autoscript <<'EOF'
5 0 * * * root for p in vless vmess trojan; do /usr/local/sbin/m-xray $p --expire; done
EOF

# ---------- Tampilkan dashboard saat login ----------
grep -q "menu info" /root/.profile || echo '[[ -t 1 ]] && /usr/local/sbin/menu info' >> /root/.profile

# ---------- Start ----------
xray run -test -config /usr/local/etc/xray/config.json >/dev/null && echo -e "${GRN}Config Xray valid${NC}"
nginx -t && systemctl restart nginx
systemctl restart xray
systemctl enable xray nginx >/dev/null 2>&1

clear
echo -e "${GRN}==============================================${NC}"
echo -e "${GRN}           INSTALASI SELESAI                  ${NC}"
echo -e "${GRN}==============================================${NC}"
echo -e " Domain : $DOMAIN"
echo -e " Ketik  : ${CYN}menu${NC} untuk membuka menu"
echo -e "${GRN}==============================================${NC}"
rm -f /root/install.sh
