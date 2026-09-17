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
#  UPDATE SCRIPT
# =====================================================
cat > /usr/local/sbin/cas-update <<'EOF'
#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - AUTO UPDATE
#  cas-update            -> menu update (interaktif)
#  cas-update --check    -> cron: cek versi, auto update / kirim notif
#  cas-update --auto     -> jalankan update otomatis (aman + rollback)
# =====================================================
# jalankan dari salinan, karena file ini ikut ditimpa saat update
if [[ "$0" != /tmp/cas-update-run* ]]; then
  cp -f "$0" /tmp/cas-update-run.$$ && exec bash /tmp/cas-update-run.$$ "$@"
fi
trap 'rm -f /tmp/cas-update-run.$$' EXIT

ASD=/etc/autoscript
RAW=https://raw.githubusercontent.com/amiercassanova-21/cassanova-tunneling
BRANCH=$(cat $ASD/channel 2>/dev/null); BRANCH=${BRANCH:-main}
BASE=$RAW/$BRANCH
LOG=/var/log/cas-update.log
G='\e[32m'; R='\e[31m'; Y='\e[33m'; C='\e[36m'; P='\e[35m'; N='\e[0m'
AUTO=$(cat $ASD/autoupdate 2>/dev/null); AUTO=${AUTO:-off}
cur=$(cat $ASD/version 2>/dev/null)

fetch_latest(){ curl -s --max-time 15 "$BASE/version?t=$(date +%s)" | tr -d '[:space:]'; }
fetch_changelog(){ curl -s --max-time 15 "$BASE/changelog?t=$(date +%s)" | head -n 15; }
newer(){ [[ -n "$1" && "$1" != "$2" && "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -n1)" == "${1#v}" ]]; }

tg(){ # kirim pesan ke bot owner VPS (jika ada)
  local BOT_TOKEN CHAT_ID; [[ -f $ASD/bot ]] && . $ASD/bot
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s --max-time 15 -o /dev/null --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=🖥 <b>CASSANOVA TUNNELING</b> | $(cat $ASD/domain)"$'\n'"$1" \
    --data-urlencode "parse_mode=HTML" "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
}

do_update(){ # $1 = auto(1/0) ; return 0 sukses
  local auto=$1 latest=$2 tmp=/tmp/cas-upd bk
  exec 7>/run/cas-update.lock; flock -n 7 || { echo "Update lain sedang berjalan"; return 1; }
  mkdir -p $tmp /root/backup
  # 1) backup sebelum update (untuk rollback)
  bk=/root/backup/pre-update-${cur}-$(date +%F_%H%M).zip
  cd / && zip -rq "$bk" etc/autoscript usr/local/lib/autoscript usr/local/etc/xray/config.json \
    etc/nginx/conf.d usr/local/sbin/menu usr/local/sbin/m-xray usr/local/sbin/m-ssh usr/local/sbin/m-feature \
    usr/local/sbin/m-brand usr/local/sbin/m-bot usr/local/sbin/running usr/local/sbin/xray-guard \
    usr/local/sbin/cas-update usr/local/bin/ws-ssh.py etc/cron.d 2>/dev/null
  # 2) unduh & cek sintaks
  if ! wget -qO $tmp/update.sh "$BASE/update.sh?t=$(date +%s)" || [[ ! -s $tmp/update.sh ]] || ! bash -n $tmp/update.sh; then
    echo "Gagal unduh / file update rusak, update dibatalkan"; return 1
  fi
  # 3) jalankan update
  echo "=== $(date '+%F %T') update $cur -> ${latest:-?} (auto=$auto, channel=$BRANCH) ===" >> $LOG
  rm -f $ASD/pending-restart
  if [[ $auto == 1 ]]; then CAS_AUTO=1 bash $tmp/update.sh >> $LOG 2>&1; else bash $tmp/update.sh 2>&1 | tee -a $LOG; fi
  # 4) verifikasi, rollback bila gagal
  local ok=1
  xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 || ok=0
  nginx -t >/dev/null 2>&1 || ok=0
  if [[ $ok == 0 ]]; then
    echo "Verifikasi gagal → rollback ke $cur" | tee -a $LOG
    unzip -oq "$bk" -d / && nginx -t >/dev/null 2>&1 && systemctl reload nginx
    xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 && systemctl restart xray
    return 2
  fi
  echo "$(cat $ASD/version)" > $ASD/latest
  find /root/backup -name 'pre-update-*.zip' -mtime +7 -delete 2>/dev/null
  return 0
}

# ------------------ jalan pintas: updatesc ------------------
if [[ "$1" == "--quick" ]]; then
  latest=$(fetch_latest); [[ -n "$latest" ]] && echo "$latest" > $ASD/latest
  clear
  echo -e "${C}════════════════════════════════════${N}"
  echo -e "        ${P}UPDATE CASSANOVA TUNNELING${N}"
  echo -e "${C}════════════════════════════════════${N}"
  echo -e " Versi terpasang : ${Y}$cur${N}"
  echo -e " Versi terbaru   : $([[ -z "$latest" ]] && echo -e "${R}gagal dicek${N}" || echo -e "${G}$latest${N}")"
  echo -e "${C}════════════════════════════════════${N}"
  if newer "$latest" "$cur"; then
    echo -e " ${Y}Ada versi baru.${N}"
  else
    echo -e " ${G}Script sudah versi terbaru (akan install ulang).${N}"
  fi
  echo
  read -rp "$(echo -e " ${G}Lanjutkan update? (y/n) : ${N}")" y
  [[ "$y" != y && "$y" != Y ]] && { echo -e " ${Y}Update dibatalkan${N}"; exit 0; }
  do_update 0 "$latest"; rc=$?
  [[ $rc == 0 ]] && echo -e "\n ${G}Update selesai: $(cat $ASD/version)${N}"
  [[ $rc == 1 ]] && echo -e "\n ${R}Update gagal diunduh, tidak ada yang berubah${N}"
  [[ $rc == 2 ]] && echo -e "\n ${R}Update gagal diverifikasi, sudah dikembalikan ke $cur${N}"
  exit 0
fi

# ------------------ mode cron ------------------
if [[ "$1" == "--check" || "$1" == "--auto" ]]; then
  latest=$(fetch_latest); [[ -z "$latest" ]] && exit 0
  echo "$latest" > $ASD/latest
  newer "$latest" "$cur" || exit 0
  if [[ "$AUTO" == on ]]; then
    do_update 1 "$latest"; rc=$?
    new=$(cat $ASD/version)
    if [[ $rc == 0 ]]; then
      msg="✅ <b>Auto Update berhasil</b>"$'\n'"$cur → $new"
      [[ -s $ASD/pending-restart ]] && msg+=$'\n'"⏳ Restart layanan ($(sort -u $ASD/pending-restart | tr '\n' ' ')) dijadwalkan jam 04:00 agar koneksi user tidak putus."
      cl=$(fetch_changelog); [[ -n "$cl" ]] && msg+=$'\n\n'"📝 <b>Perubahan:</b>"$'\n'"$cl"
      tg "$msg"
    elif [[ $rc == 2 ]]; then
      tg "⚠️ <b>Auto Update gagal</b> ($cur → $latest)"$'\n'"Sudah dikembalikan otomatis ke $cur. Script tetap berjalan normal."
    fi
  fi
  # auto update OFF → diam saja (info update diumumkan owner lewat channel Telegram)
  exit 0
fi

# ------------------ menu interaktif ------------------
while true; do
  AUTO=$(cat $ASD/autoupdate 2>/dev/null); AUTO=${AUTO:-off}; cur=$(cat $ASD/version 2>/dev/null)
  clear
  echo -e "${C}════════════════════════════════════${N}"
  echo -e "           ${P}AUTO UPDATE${N}"
  echo -e "${C}════════════════════════════════════${N}"
  latest=$(fetch_latest); [[ -n "$latest" ]] && echo "$latest" > $ASD/latest
  echo -e " Versi terpasang : ${Y}$cur${N}"
  echo -e " Versi terbaru   : $([[ -z "$latest" ]] && echo -e "${R}gagal dicek${N}" || echo -e "${G}$latest${N}")"
  echo -e " Auto update     : $([[ $AUTO == on ]] && echo -e "${G}ON${N}" || echo -e "${R}OFF${N}")"
  [[ "$BRANCH" != main ]] && echo -e " Channel         : ${Y}$BRANCH (uji coba)${N}"
  if newer "$latest" "$cur"; then echo -e "\n ${Y}🔔 Ada update baru!${N}"; else echo -e "\n ${G}Script sudah versi terbaru${N}"; fi
  echo -e "${C}════════════════════════════════════${N}"
  echo -e " ${C}1.)${N} Update sekarang"
  echo -e " ${C}2.)${N} Auto update ON/OFF"
  echo -e " ${C}3.)${N} Lihat perubahan (changelog)"
  echo -e " ${C}4.)${N} Back to Menu"
  echo -e "${C}════════════════════════════════════${N}"
  read -rp "$(echo -e "${G}Select From Options [1-4] : ${N}")" o
  case $o in
    1) if ! newer "$latest" "$cur"; then read -rp "Sudah terbaru. Install ulang versi ini? (y/n) : " y; [[ "$y" != y ]] && continue; fi
       read -rp "Update sekarang? (y/n) : " y; [[ "$y" != y ]] && continue
       do_update 0 "$latest"; rc=$?
       [[ $rc == 0 ]] && echo -e "\n${G}Update selesai: $(cat $ASD/version)${N}"
       [[ $rc == 2 ]] && echo -e "\n${R}Update gagal diverifikasi, sudah dikembalikan ke $cur${N}"
       read -rp "Tekan Enter..." ;;
    2) if [[ $AUTO == on ]]; then
         read -rp "Matikan auto update? (y/n) : " y; [[ "$y" == y ]] && echo off > $ASD/autoupdate
       else
         echo -e "\n Jika ON, script akan update sendiri saat ada versi baru."
         echo -e " Update tidak memutus koneksi user. Bila perlu restart layanan,"
         echo -e " restart ditunda ke jam 04:00. Gagal update = otomatis rollback.\n"
         read -rp "Aktifkan auto update? (y/n) : " y; [[ "$y" == y ]] && echo on > $ASD/autoupdate
       fi ;;
    3) clear; echo -e "${P}CHANGELOG${N}\n"; fetch_changelog; echo; read -rp "Tekan Enter..." ;;
    4|x|X) exit 0 ;;
  esac
done
EOF
chmod +x /usr/local/sbin/cas-update

# perintah khusus owner: pindah channel (main = buyer, beta = uji coba)
# jalan pintas update dari terminal: ketik  updatesc
cat > /usr/local/sbin/updatesc <<'EOF'
#!/bin/bash
exec /usr/local/sbin/cas-update --quick
EOF
chmod +x /usr/local/sbin/updatesc

cat > /usr/local/sbin/cas-channel <<'EOF'
#!/bin/bash
case $1 in
  beta|main) echo "$1" > /etc/autoscript/channel; echo "Channel diset: $1"; /usr/local/sbin/cas-update --check ;;
  *) echo "Channel sekarang: $(cat /etc/autoscript/channel 2>/dev/null || echo main)"; echo "Pakai: cas-channel beta | cas-channel main" ;;
esac
EOF
chmod +x /usr/local/sbin/cas-channel

# cek update tiap jam, menit acak per VPS (agar 80+ VPS tidak serentak ke GitHub)
if [[ ! -f /etc/cron.d/cas-update ]] || grep -q '^17 \*/6' /etc/cron.d/cas-update; then
  echo "$((RANDOM % 60)) * * * * root /usr/local/sbin/cas-update --check" > /etc/cron.d/cas-update
  chmod 644 /etc/cron.d/cas-update
fi
[[ -f /etc/autoscript/autoupdate ]] || echo off > /etc/autoscript/autoupdate

# =====================================================
#  MENU FEATURES
# =====================================================
cat > /usr/local/sbin/m-feature <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BRAND=$SCNAME; DOMAIN=$(cat $ASD/domain); VER=$(cat $ASD/version)
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
  printf " ${G}%-14s${N}: %s\n" "Script" "$SCNAME" "Brand" "$(brand_txt)" "Version" "$VER" "OS" "$(. /etc/os-release; echo $PRETTY_NAME)" \
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
  echo -e " ${C}12.)${N} Auto Update"
  echo -e " ${C}13.)${N} Back to Menu"
  echo -e " ${C}x.)${N}  Exit"
  echo -e "$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-13 or x] : ${N}")" opt
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
    12) cas-update; exit 0 ;;
    13) exit 0 ;;
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
onoff(){ [[ "$(cat $ASD/$1 2>/dev/null)" == on ]] && echo -e "${G}ON${N}" || echo -e "${R}OFF${N}"; }
while true; do
  clear
  echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#SCNAME})/2 )) "$SCNAME"; echo -e "$LINE\n"
  echo -e "      ${G}With Brand Name${N} : $(onoff brand_uuid)"
  echo -e "      ${G}With User${N}       : $(onoff brand_user)"
  echo -e "      ${G}Brand Name${N}      : ${O}$(brand_txt)${N}\n"
  echo -e "      ${G}Brand Name for${N} ${O}[password/uuid]${N}"
  echo -e "      ${G}With User for${N}  ${O}[user trial]${N}"
  echo -e "\n$LINE"
  echo -e "      ${Y}Contoh jika ON:${N}"
  echo -e "      UUID/Pass  : $(brand_txt)-a1b2c3d4e5f6"
  echo -e "      User trial : $(brand_txt)-trialx9k2"
  echo -e "$LINE\n"
  echo -e " ${C}1.)${N} Set ON Brand Name"
  echo -e " ${C}2.)${N} Set ON With User"
  echo -e " ${C}3.)${N} Set OFF Brand Name"
  echo -e " ${C}4.)${N} Set OFF With User"
  echo -e " ${C}5.)${N} Change Brand Name"
  echo -e " ${C}6.)${N} Change Banner SSH"
  echo -e " ${C}7.)${N} Back to Menu"
  echo -e " ${C}x.)${N} Exit"
  echo -e "\n$LINE"
  read -rp "$(echo -e "${G}Select From Options [1-7 or x] : ${N}")" o
  case $o in
    1) echo on  > $ASD/brand_uuid; echo -e "${G}Brand Name ON${N}"; sleep 1 ;;
    2) echo on  > $ASD/brand_user; echo -e "${G}With User ON${N}"; sleep 1 ;;
    3) echo off > $ASD/brand_uuid; echo -e "${Y}Brand Name OFF${N}"; sleep 1 ;;
    4) echo off > $ASD/brand_user; echo -e "${Y}With User OFF${N}"; sleep 1 ;;
    5) read -rp "Brand baru (huruf/angka/-, maks 12) : " nb
       nb=$(echo "$nb" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-'); nb=${nb:0:12}
       [[ -z "$nb" ]] && { echo -e "${R}Brand tidak valid${N}"; sleep 2; continue; }
       echo "$nb" > $ASD/brand; echo -e "${G}Brand diganti: $nb${N}"; sleep 2 ;;
    6) echo -e "Ketik banner SSH (akhiri dengan baris berisi END):"
       : > /tmp/cas-banner
       while IFS= read -r l; do [[ "$l" == "END" ]] && break; echo "$l" >> /tmp/cas-banner; done
       cp /tmp/cas-banner $ASD/banner.txt; rm -f /tmp/cas-banner
       echo -e "${G}Banner diganti${N}"; sleep 2 ;;
    7) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-brand

echo -e "${GRN}Modul Features & Brand Name selesai.${NC}"
