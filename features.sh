#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - MODUL FEATURES + BRAND NAME
# =====================================================
GRN='\e[32m'; RED='\e[31m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
export DEBIAN_FRONTEND=noninteractive
ASD=/etc/autoscript
apt install -y speedtest-cli zip unzip >/dev/null 2>&1

# =====================================================
#  MENU FEATURES
# =====================================================
cat > /usr/local/sbin/m-feature <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BRAND=$(cat $ASD/brand); DOMAIN=$(cat $ASD/domain); VER=$(cat $ASD/version)
LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
bar(){ echo -e "$LINE"; printf "${BGB}${W}%*s%*s${N}\n" $(( (36+${#1})/2 )) "$1" $(( 36-(36+${#1})/2 )) ""; echo -e "$LINE"; }
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }
msg(){ echo -e "$1"; sleep 2; }
num_ok(){ [[ "$1" =~ ^[0-9]+$ ]]; }

check_bandwidth(){ header "CHECK BANDWIDTH"; command -v vnstat >/dev/null && vnstat || echo "vnstat belum siap"; pause; }

set_reboot(){
  header "AUTO REBOOT"
  local cur o h
  cur=$(grep -oE '[0-9]+:[0-9]+' /etc/cron.d/cas-reboot 2>/dev/null | head -1)
  echo -e " Jadwal sekarang : ${Y}${cur:-belum diatur}${N}\n"
  echo -e " ${C}1.)${N} Set jam auto reboot (harian)"
  echo -e " ${C}2.)${N} Matikan auto reboot"
  echo -e " ${C}3.)${N} Kembali"
  echo; read -rp "Pilih : " o
  case $o in
    1) read -rp "Jam (0-23) : " h; num_ok "$h" && (( h<24 )) || { msg "${R}Jam salah${N}"; return; }
       echo "0 $h * * * root /sbin/reboot" > /etc/cron.d/cas-reboot; chmod 644 /etc/cron.d/cas-reboot
       msg "${G}Auto reboot diset tiap jam $h:00${N}" ;;
    2) rm -f /etc/cron.d/cas-reboot; msg "${G}Auto reboot dimatikan${N}" ;;
  esac
}

reboot_now(){ header "REBOOT VPS"; read -rp "Yakin reboot sekarang? (y/t) : " y; [[ "$y" == y ]] && { echo -e "${Y}Rebooting...${N}"; reboot; }; }

speed_vps(){ header "SPEEDTEST VPS"; command -v speedtest-cli >/dev/null && speedtest-cli --simple || echo "speedtest-cli tidak tersedia"; pause; }

backup_vps(){
  header "BACKUP CONFIGURATION"
  local f
  if [[ -x /usr/local/sbin/cas-backup-make ]]; then f=$(/usr/local/sbin/cas-backup-make)
  else mkdir -p /root/backup; f=/root/backup/${DOMAIN}-$(date +%H_%M_%S).zip; cd / && zip -rq "$f" etc/autoscript usr/local/etc/xray/config.json etc/passwd etc/shadow etc/group etc/gshadow etc/nginx/conf.d/xray.conf 2>/dev/null; fi
  echo -e " ${G}File backup:${N} $f"
  if [[ -f $ASD/bot ]]; then
    . $ASD/bot
    [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]] && curl -s --max-time 120 -o /dev/null -F chat_id="$CHAT_ID" -F document=@"$f" -F parse_mode=HTML -F caption="$(/usr/local/sbin/cas-backup-caption 2>/dev/null)" "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" && echo -e " ${G}Juga dikirim ke Telegram${N}"
  fi
  pause
}

restore_vps(){
  header "RESTORE CONFIGURATION"
  local list=() f i=0 n
  while IFS= read -r f; do list+=("$f"); done < <(ls -1t /root/backup/*.zip /root/*.zip 2>/dev/null)
  [[ ${#list[@]} == 0 ]] && { echo -e " ${Y}Tidak ada file .zip di /root/backup atau /root${N}"; echo -e " Upload file backup dari Telegram ke /root dulu."; pause; return; }
  for f in "${list[@]}"; do i=$((i+1)); printf " ${C}%-3s${N} %s\n" "$i." "$(basename "$f")"; done
  echo; read -rp "Nomor file : " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#list[@]} )) || { msg "${R}Nomor salah${N}"; return; }
  f=${list[$((n-1))]}
  read -rp "Restore $(basename "$f")? Config sekarang akan ditimpa (y/t) : " y
  [[ "$y" != y ]] && return
  unzip -oq "$f" -d / && systemctl restart xray nginx dropbear 2>/dev/null
  msg "${G}Restore selesai${N}"
}

start_stop(){
  header "START / STOP SERVICE"
  local svc=(xray nginx dropbear ws-ssh badvpn)
  local i=1 s
  for s in "${svc[@]}"; do
    printf " ${C}%s.)${N} %-10s [%b]\n" "$i" "$s" "$(systemctl is-active --quiet $s && echo "${G}ON${N}" || echo "${R}OFF${N}")"
    i=$((i+1))
  done
  echo; read -rp "Nomor service (toggle on/off) : " n
  num_ok "$n" && (( n>=1 && n<=${#svc[@]} )) || { msg "${R}Salah${N}"; return; }
  s=${svc[$((n-1))]}
  if systemctl is-active --quiet "$s"; then systemctl stop "$s"; msg "${Y}$s dimatikan${N}"; else systemctl start "$s"; msg "${G}$s dinyalakan${N}"; fi
}

security_syn(){
  header "SECURITY SYN / OPTIMASI"
  cat > /etc/sysctl.d/99-cassanova.conf <<SYS
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_synack_retries=2
net.core.somaxconn=4096
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  sysctl --system >/dev/null 2>&1
  systemctl restart fail2ban 2>/dev/null
  msg "${G}Proteksi SYN flood & optimasi TCP diterapkan${N}"
}

change_domain(){
  header "CHANGE DOMAIN VPS"
  echo -e " Domain sekarang : ${Y}$DOMAIN${N}"
  echo -e " ${R}PERINGATAN:${N} semua akun harus dibuat ulang link-nya,"
  echo -e " dan SSL untuk domain baru harus diterbitkan.\n"
  read -rp "Domain baru : " nd
  [[ -z "$nd" ]] && { msg "${R}Kosong${N}"; return; }
  read -rp "Yakin ganti ke $nd? (y/t) : " y; [[ "$y" != y ]] && return
  systemctl stop nginx
  /root/.acme.sh/acme.sh --issue -d "$nd" --standalone -k ec-256 --force 2>/dev/null
  /root/.acme.sh/acme.sh --install-cert -d "$nd" --ecc \
    --fullchain-file $ASD/xray.crt --key-file $ASD/xray.key --reloadcmd "systemctl reload nginx" 2>/dev/null
  if [[ -s $ASD/xray.crt ]]; then
    echo "$nd" > $ASD/domain
    sed -i "s/server_name .*/server_name $nd;/" /etc/nginx/conf.d/xray.conf
    systemctl restart nginx; msg "${G}Domain diganti ke $nd${N}"
  else
    systemctl start nginx; msg "${R}SSL domain baru gagal. Pastikan domain sudah pointing ke IP VPS.${N}"
  fi
}

info_system(){
  header "INFORMATION SYSTEM"
  local IP; IP=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
  printf " ${G}%-14s${N}: %s\n" "Brand" "$BRAND" "Version" "$VER" "OS" "$(. /etc/os-release; echo $PRETTY_NAME)" \
    "Kernel" "$(uname -r)" "Domain" "$DOMAIN" "IP" "$IP" \
    "CPU" "$(nproc) core" "RAM" "$(free -m|awk '/Mem:/{print $2"M"}')" \
    "Uptime" "$(uptime -p|sed 's/up //')" "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "$LINE"
  local cv=$(grep -c . $ASD/db/vless.db) cm=$(grep -c . $ASD/db/vmess.db) ct=$(grep -c . $ASD/db/trojan.db) cs=$(grep -c . $ASD/db/ssh.db 2>/dev/null)
  printf " ${G}%-14s${N}: %s\n" "Akun VLESS" "$cv" "Akun VMESS" "$cm" "Akun TROJAN" "$ct" "Akun SSH" "$cs"
  echo -e "$LINE"; pause
}

coming(){ echo -e "\n${Y}Fitur ini dibuat di tahap berikutnya.${N}"; sleep 2; }

while true; do
  header "FEATURES"
  echo -e "\n ${C}1.)${N}  Check Bandwidth"
  echo -e " ${C}2.)${N}  Set Date Auto Reboot"
  echo -e " ${C}3.)${N}  Reboot VPS"
  echo -e " ${C}4.)${N}  Speed VPS"
  echo -e " ${C}5.)${N}  Check All Service"
  bar "BACKUP & RESTORE"
  echo -e " ${C}6.)${N}  Backup Configuration VPS"
  echo -e " ${C}7.)${N}  Restore Configuration VPS"
  bar "SYSTEM"
  echo -e " ${C}8.)${N}  Start/Stop Service"
  echo -e " ${C}9.)${N}  Security SYN & Optimasi"
  echo -e " ${C}10.)${N} Change Domain VPS"
  echo -e " ${C}11.)${N} Information System"
  echo -e " ${C}12.)${N} Back to Menu"
  echo -e " ${C}x.)${N}  Exit"
  echo -e "$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-12 or x] : ${N}")" opt
  case $opt in
    1) check_bandwidth ;;
    2) set_reboot ;;
    3) reboot_now ;;
    4) speed_vps ;;
    5) running ;;
    6) backup_vps ;;
    7) restore_vps ;;
    8) start_stop ;;
    9) security_syn ;;
    10) change_domain ;;
    11) info_system ;;
    12) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
    *) msg "${R}Pilihan salah${N}" ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-feature

# =====================================================
#  SET BRAND NAME
# =====================================================
cat > /usr/local/sbin/m-brand <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
while true; do
  BRAND=$(cat $ASD/brand)
  header "SET BRAND NAME"
  echo -e "\n Brand sekarang : ${O}$BRAND${N}\n"
  echo -e " ${C}1.)${N} Ganti nama brand"
  echo -e " ${C}2.)${N} Ganti banner login SSH"
  echo -e " ${C}3.)${N} Back to Menu"
  echo -e " ${C}x.)${N} Exit"
  echo -e "\n$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-3 or x] : ${N}")" o
  case $o in
    1) read -rp "Nama brand baru : " nb
       [[ -z "$nb" ]] && { echo -e "${R}Kosong${N}"; sleep 1; continue; }
       echo "$nb" > $ASD/brand
       # perbarui baris pertama banner (nama brand)
       printf '\n%s\n\n' "$nb" > $ASD/banner.txt
       echo -e "${G}Brand diganti ke: $nb${N}"; sleep 2 ;;
    2) echo -e "Ketik banner (akhiri dengan baris berisi END):"
       : > /tmp/cas-banner
       while IFS= read -r l; do [[ "$l" == "END" ]] && break; echo "$l" >> /tmp/cas-banner; done
       cp /tmp/cas-banner $ASD/banner.txt; rm -f /tmp/cas-banner
       echo -e "${G}Banner diganti${N}"; sleep 2 ;;
    3) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-brand

echo -e "${GRN}Modul Features & Brand Name selesai.${NC}"
