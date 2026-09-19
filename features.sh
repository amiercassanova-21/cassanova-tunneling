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
  # simpan 3 backup pre-update terbaru (cukup untuk mundur beberapa versi)
  ls -1t /root/backup/pre-update-*.zip 2>/dev/null | tail -n +4 | xargs -r rm -f
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

# jalan pintas ganti domain dari terminal: ketik  adddomain
cat > /usr/local/sbin/adddomain <<'EOF'
#!/bin/bash
exec /usr/local/sbin/m-feature --domain
EOF
chmod +x /usr/local/sbin/adddomain
ln -sf /usr/local/sbin/adddomain /usr/local/sbin/addomain 2>/dev/null

# jalan pintas: ketik  backup  -> buat backup baru (+ kirim Telegram bila bot aktif)
cat > /usr/local/sbin/backup <<'EOF'
#!/bin/bash
BOT_TOKEN=""; CHAT_ID=""
. /etc/autoscript/bot 2>/dev/null
echo "Membuat backup..."
f=$(/usr/local/sbin/cas-backup-make)
[[ -s "$f" ]] || { echo "Gagal membuat backup"; exit 1; }
echo "Backup dibuat : $f"
if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
  echo "Mengirim ke Telegram..."
  if curl -s --max-time 120 -o /dev/null -F chat_id="$CHAT_ID" -F document=@"$f" \
      -F parse_mode=HTML -F caption="$(/usr/local/sbin/cas-backup-caption)" \
      "https://api.telegram.org/bot$BOT_TOKEN/sendDocument"; then
    echo "Terkirim ke Telegram"
  else
    echo "Gagal kirim ke Telegram (file tetap tersimpan di VPS)"
  fi
else
  echo "Bot belum diatur, backup hanya tersimpan di VPS"
fi
EOF
chmod +x /usr/local/sbin/backup

# jalan pintas: ketik  restore  -> buka menu restore
cat > /usr/local/sbin/restore <<'EOF'
#!/bin/bash
exec /usr/local/sbin/m-feature --restore "$1"
EOF
chmod +x /usr/local/sbin/restore

# daftar semua perintah cepat: ketik  cmd  (atau perintah)
cat > /usr/local/sbin/cmd <<'EOF'
#!/bin/bash
G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; P='\033[0;35m'; B='\033[0;34m'; N='\033[0m'
L="${B}════════════════════════════════════${N}"
clear
echo -e "$L"; printf "${P}%*s${N}\n" 28 "DAFTAR PERINTAH CEPAT"; echo -e "$L"
r(){ printf " ${C}%-22s${N} %s\n" "$1" "$2"; }
echo -e "\n ${Y}UMUM${N}"
r "menu"              "buka menu utama"
r "cmd"               "tampilkan daftar ini"
r "updatesc"          "update script ke versi terbaru"
r "renewsc"           "cek ulang lisensi setelah diperpanjang"
r "adddomain"         "ganti / pasang domain baru"
echo -e "\n ${Y}BACKUP${N}"
r "backup"            "buat backup baru (+ kirim ke Telegram)"
r "restore"           "buka menu restore backup"
r "restore <link>"    "restore langsung dari link, tanpa upload"
echo -e "\n ${Y}AKUN XRAY (vless / vmess / trojan)${N}"
r "addvless"          "buat akun VLESS baru"
r "renewvless <kode>" "perpanjang akun (kuota ikut direset)"
r "delvless <kode>"   "hapus akun (masuk daftar recovery)"
r "recoveryvless <kode>" "pulihkan akun yang sudah dihapus"
echo
echo -e " ${Y}<kode>${N} = username ${Y}atau${N} UUID/Password akun"
echo -e " Ganti ${C}vless${N} dengan ${C}vmess${N} / ${C}trojan${N} sesuai protokol."
echo -e " Bisa juga dipisah spasi, contoh: ${C}renew vmess budi${N}"
echo -e "$L"
EOF
chmod +x /usr/local/sbin/cmd
ln -sf /usr/local/sbin/cmd /usr/local/sbin/perintah 2>/dev/null

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
  { echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; echo "$((RANDOM % 60)) * * * * root /usr/local/sbin/cas-update --check"; } > /etc/cron.d/cas-update
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

# ---- baca ringkasan isi file backup tanpa mengekstraknya ----
restore_info(){ # $1 = file zip -> set RB_DOMAIN RB_IP RB_DATE RB_ACC
  local f="$1" p c
  RB_DOMAIN=$(unzip -p "$f" etc/autoscript/domain 2>/dev/null | tr -d '[:space:]')
  RB_IP=$(unzip -p "$f" etc/autoscript/ipinfo.json 2>/dev/null | jq -r '.ip // empty' 2>/dev/null)
  RB_DATE=$(unzip -l "$f" 2>/dev/null | awk '$NF=="etc/autoscript/domain"{print $2" "$3; exit}')
  RB_ACC=""
  for p in vless vmess trojan ssh; do
    c=$(unzip -p "$f" etc/autoscript/db/$p.db 2>/dev/null | grep -c .)
    RB_ACC+="${p^^} ${c:-0}  "
  done
}

# ---- proses restore satu file backup (ringkasan -> kode konfirmasi -> jalan) ----
restore_do(){ # $1 = file zip
  local f="$1" code inp RD IP dip exp
  [[ -s "$f" ]] || { msg "${R}File backup tidak ditemukan${N}"; return 1; }
  unzip -tq "$f" >/dev/null 2>&1 || { msg "${R}File rusak atau bukan zip yang benar${N}"; return 1; }
  unzip -l "$f" 2>/dev/null | grep -q 'etc/autoscript/' \
    || { msg "${R}Ini bukan file backup Cassanova Tunneling${N}"; return 1; }

  restore_info "$f"
  header "KONFIRMASI RESTORE"
  printf " ${G}%-9s${N}: ${O}%s${N}\n" "File"    "$(basename "$f")"
  printf " ${G}%-9s${N}: ${O}%s${N}\n" "Domain"  "${RB_DOMAIN:-"-"}"
  printf " ${G}%-9s${N}: ${O}%s${N}\n" "IP asal" "${RB_IP:-"-"}"
  printf " ${G}%-9s${N}: ${O}%s${N}\n" "Dibuat"  "${RB_DATE:-"-"}"
  printf " ${G}%-9s${N}: ${O}%s${N}\n" "Akun"    "${RB_ACC:-"-"}"
  echo -e "$LINE"
  echo -e " ${R}Config VPS ini akan DITIMPA oleh isi backup di atas.${N}"
  code=$(head -c 400 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' | head -c 6)
  [[ ${#code} -eq 6 ]] || code=$(date +%s%N | md5sum | LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' | head -c 6)
  [[ ${#code} -eq 6 ]] || code="RESTOR"
  echo -e " Ketik kode ini untuk melanjutkan : ${Y}${code}${N}"
  echo -e " ${Y}(salah / kosong = dibatalkan)${N}"
  echo; read -rp "$(echo -e " ${G}Kode : ${N}")" inp
  [[ "$inp" != "$code" ]] && { msg "${Y}Kode tidak sama, restore dibatalkan${N}"; return 1; }

  echo -e "\n${G}Mengembalikan data...${N}"
  unzip -oq "$f" -d / || { msg "${R}Gagal extract backup${N}"; return 1; }

  # Backup membawa ipinfo.json dari VPS asal, dan file itulah yang dipakai
  # untuk cek lisensi. Tanpa ditulis ulang, VPS ini ikut terkunci.
  curl -s --max-time 10 ipinfo.io/json > $ASD/ipinfo.new 2>/dev/null
  if jq -e '.ip' $ASD/ipinfo.new >/dev/null 2>&1; then
    mv -f $ASD/ipinfo.new $ASD/ipinfo.json
  else
    rm -f $ASD/ipinfo.new
    IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
    [[ -n "$IP" ]] && printf '{"ip":"%s"}\n' "$IP" > $ASD/ipinfo.json
  fi
  IP=$(jq -r '.ip // empty' $ASD/ipinfo.json 2>/dev/null)
  echo -e " ${G}IP VPS ini dicatat ulang : ${Y}${IP:-gagal dideteksi}${N}"

  echo -e " ${G}Menyegarkan status lisensi...${N}"
  /usr/local/sbin/menu license >/dev/null 2>&1

  systemctl restart xray nginx cas-dropbear ws-ssh badvpn 2>/dev/null

  # SSL untuk domain hasil restore: ditandai perlu diterbitkan, lalu dicoba
  # sekarang. Kalau pointing belum diarahkan ke VPS ini, cron menyelesaikan
  # sendiri tiap 10 menit sehingga buyer cukup mengubah A record saja.
  RD=$(cat $ASD/domain 2>/dev/null)
  rm -f $ASD/ssl_try $ASD/ssl_last $ASD/ssl_wait $ASD/ssl_orange; : > $ASD/ssl_pending
  echo -e " ${G}Menyiapkan SSL untuk ${Y}${RD:-"-"}${G}...${N}"
  /usr/local/sbin/cas-ssl-pending >/dev/null 2>&1

  dip=$(getent hosts "$RD" 2>/dev/null | awk '{print $1}' | head -1)
  header "RESTORE SELESAI"
  printf " ${G}%-20s${N}: ${O}%s${N}\n" "Domain hasil restore" "${RD:-"-"}"
  printf " ${G}%-20s${N}: ${O}%s${N}\n" "IP VPS ini"           "${IP:-"-"}"
  printf " ${G}%-20s${N}: ${O}%s${N}\n" "Pointing sekarang"    "${dip:-"tidak resolve"}"
  echo -e "$LINE"
  if [[ -n "$RD" && "$dip" == "$IP" && ! -f $ASD/ssl_pending ]]; then
    echo -e " ${G}Pointing sudah benar dan SSL sudah diperbarui.${N}"
    echo -e " ${G}Tidak ada lagi yang perlu dilakukan. VPS siap dipakai.${N}"
  elif [[ -n "$RD" && "$dip" == "$IP" ]]; then
    echo -e " ${Y}Pointing sudah benar, tetapi SSL belum berhasil diterbitkan.${N}"
    echo -e " Dicoba ulang otomatis tiap 10 menit. Log: /var/log/cas-ssl.log"
  else
    echo -e " ${Y}LANGKAH TERAKHIR (cukup ini saja):${N}\n"
    echo -e "  Di Cloudflare, arahkan A record"
    echo -e "  ${C}${RD:-domain}${N}  ke  ${C}${IP:-IP VPS ini}${N}"
    echo -e "  Wajib ${Y}ABU-ABU${N} (DNS only / proxy OFF)\n"
    echo -e " Setelah itu tidak perlu mengetik apa pun lagi."
    echo -e " SSL diterbitkan otomatis maksimal 10 menit setelah pointing benar."
    exp=$(openssl x509 -in $ASD/xray.crt -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$exp" ]]; then
      echo -e " Sertifikat dari backup masih berlaku sampai ${G}$(date -d "$exp" +%F 2>/dev/null || echo "$exp")${N},"
      echo -e " jadi koneksi bisa langsung dipakai begitu pointing berubah."
    fi
  fi
  echo -e "$LINE"
  pause
}

# ---- restore langsung dari link (tanpa upload manual ke VPS) ----
restore_url(){ # $1 = link http/https
  local u="$1" f base
  header "RESTORE DARI LINK"
  [[ "$u" =~ ^https?://[^[:space:]]+$ ]] \
    || { msg "${R}Link tidak valid. Harus mulai dengan http:// atau https://${N}"; return 1; }
  mkdir -p /root/backup
  base=$(basename "${u%%\?*}"); [[ "$base" == *.zip ]] || base="backup-$(date +%F_%H%M%S).zip"
  f=/root/backup/$base
  echo -e " Sumber : ${C}$u${N}"
  echo -e " Simpan : ${C}$f${N}\n"
  if ! curl -fL --max-time 600 --retry 2 -o "$f" "$u"; then
    rm -f "$f"; msg "${R}Gagal mengunduh dari link tersebut${N}"; return 1
  fi
  echo -e "\n ${G}Unduhan selesai (${Y}$(du -h "$f" 2>/dev/null | cut -f1)${G})${N}"
  restore_do "$f"
}

restore_vps(){
  header "RESTORE CONFIGURATION"
  local list=() f i=0 n mode=${1:-normal} url
  if [[ "$mode" == "pre" ]]; then
    # daftar backup pre-update (untuk mundur ke versi sebelumnya)
    while IFS= read -r f; do list+=("$f"); done < <(ls -1t /root/backup/pre-update-*.zip 2>/dev/null)
    [[ ${#list[@]} == 0 ]] && { echo -e " ${Y}Belum ada backup pre-update${N}"; pause; return; }
    echo -e " ${Y}Backup otomatis sebelum update (untuk mundur versi)${N}\n"
  else
    # daftar backup biasa saja, pre-update disembunyikan agar tidak membingungkan
    while IFS= read -r f; do list+=("$f"); done < <(ls -1t /root/backup/*.zip /root/*.zip 2>/dev/null | grep -v '/pre-update-')
    if [[ ${#list[@]} == 0 ]]; then
      echo -e " ${Y}Tidak ada file backup di /root/backup atau /root${N}"
      echo -e " Upload file backup ke /root lewat SFTP, atau pakai link.\n"
      echo -e " ${C}l${N}   Restore dari link (tempel URL)"
      echo -e " ${C}p${N}   Lihat backup pre-update (mundur versi)"
      echo; read -rp "Pilihan : " n
      [[ "$n" == l || "$n" == L ]] && { echo; read -rp "Tempel link : " url; restore_url "$url"; return; }
      [[ "$n" == p || "$n" == P ]] && { restore_vps pre; return; }
      return
    fi
  fi
  for f in "${list[@]}"; do i=$((i+1)); printf " ${C}%-3s${N} %s\n" "$i." "$(basename "$f")"; done
  echo
  if [[ "$mode" == "normal" ]]; then
    echo -e " ${C}l${N}   Restore dari link (tempel URL)"
    echo -e " ${C}p${N}   Lihat backup pre-update (mundur versi)"
  fi
  echo; read -rp "Nomor file : " n
  if [[ "$mode" == "normal" ]]; then
    [[ "$n" == l || "$n" == L ]] && { echo; read -rp "Tempel link : " url; restore_url "$url"; return; }
    [[ "$n" == p || "$n" == P ]] && { restore_vps pre; return; }
  fi
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#list[@]} )) || { msg "${R}Nomor salah${N}"; return; }
  restore_do "${list[$((n-1))]}"
}

start_stop(){
  header "START / STOP SERVICE"
  local svc=(xray nginx cas-dropbear ws-ssh badvpn cek-akun)
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
  local IP; IP=$(jq -r '.ip // empty' $ASD/ipinfo.json 2>/dev/null)
  [[ -z "$IP" ]] && IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
  echo -e " Domain sekarang : ${Y}$DOMAIN${N}"
  echo -e " IP VPS ini      : ${Y}$IP${N}"
  echo -e ""
  echo -e " ${Y}SYARAT:${N}"
  echo -e " 1. Domain sudah di-pointing (A record) ke ${Y}$IP${N}"
  echo -e " 2. Di Cloudflare wajib ${Y}DNS only (awan ABU-ABU)${N}"
  echo -e " 3. Tunggu 1-5 menit setelah pointing"
  echo -e ""
  echo -e " ${R}PERINGATAN:${N} semua akun harus dibuat ulang link-nya."
  echo -e ""
  read -rp "Domain baru (kosong=batal) : " nd
  [[ -z "$nd" ]] && { msg "${Y}Dibatalkan${N}"; return; }
  # validasi format domain
  if ! [[ "$nd" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
    msg "${R}Format domain tidak valid${N}"; return
  fi
  # cek pointing dulu (hindari SSL gagal & nginx mati sia-sia)
  echo -e "\n${G}Mengecek pointing domain...${N}"
  local dip; dip=$(getent hosts "$nd" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -z "$dip" ]]; then
    msg "${R}Domain $nd belum bisa diresolve. Cek pointing DNS dulu.${N}"; return
  fi
  if [[ "$dip" != "$IP" ]]; then
    echo -e " ${Y}Domain mengarah ke : $dip${N}"
    echo -e " ${Y}IP VPS ini         : $IP${N}"
    echo -e " ${R}Tidak cocok!${N} Jika pakai Cloudflare, pastikan mode ${Y}DNS only (abu-abu)${N}."
    read -rp "Tetap lanjut? (y/t) : " f; [[ "$f" != y ]] && { msg "${Y}Dibatalkan${N}"; return; }
  else
    echo -e " ${G}Pointing benar ke IP VPS ini${N}"
  fi
  read -rp "Yakin ganti domain ke $nd? (y/t) : " y; [[ "$y" != y ]] && { msg "${Y}Dibatalkan${N}"; return; }

  # backup cert lama agar bisa dikembalikan jika gagal
  cp -f $ASD/xray.crt /tmp/old.crt 2>/dev/null
  cp -f $ASD/xray.key /tmp/old.key 2>/dev/null

  echo -e "\n${G}Menerbitkan SSL untuk $nd ...${N}"
  systemctl stop nginx
  /root/.acme.sh/acme.sh --issue -d "$nd" --standalone -k ec-256 --force >/tmp/acme-chg.log 2>&1
  /root/.acme.sh/acme.sh --install-cert -d "$nd" --ecc \
    --fullchain-file $ASD/xray.crt --key-file $ASD/xray.key >/dev/null 2>&1

  if [[ -s $ASD/xray.crt ]] && openssl x509 -in $ASD/xray.crt -noout -text 2>/dev/null | grep -q "$nd"; then
    echo "$nd" > $ASD/domain
    sed -i "s/server_name .*/server_name $nd;/" /etc/nginx/conf.d/xray.conf
    systemctl restart nginx
    msg "${G}Domain berhasil diganti ke $nd${N}"
    cas_notify_quote "CHANGE DOMAIN" "Domain: <code>$nd</code>" 2>/dev/null || true
  else
    # kembalikan cert lama
    cp -f /tmp/old.crt $ASD/xray.crt 2>/dev/null
    cp -f /tmp/old.key $ASD/xray.key 2>/dev/null
    systemctl start nginx
    echo -e "\n${R}SSL gagal diterbitkan.${N} Penyebab umum:"
    echo -e " - Domain belum pointing ke $IP"
    echo -e " - Cloudflare masih ORANGE (harus abu-abu / DNS only)"
    echo -e " - Port 80 tertutup firewall"
    echo -e "\nDetail log:"; tail -n 8 /tmp/acme-chg.log 2>/dev/null
    msg "${R}Domain TIDAK diganti (tetap $DOMAIN)${N}"
  fi
  rm -f /tmp/old.crt /tmp/old.key
}

info_system(){
  header "INFORMATION SYSTEM"
  local IP; IP=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
  printf " ${G}%-14s${N}: %s\n" "Script" "$SCNAME" "Brand" "$(brand_txt)" "Version" "$VER" "OS" "$(. /etc/os-release; echo $PRETTY_NAME)" \
    "Kernel" "$(uname -r)" "Domain" "$DOMAIN" "IP" "$IP" \
    "Cek Akun" "https://$DOMAIN/cek" \
    "CPU" "$(nproc) core" "RAM" "$(free -m|awk '/Mem:/{print $2"M"}')" \
    "Uptime" "$(uptime -p|sed 's/up //')" "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "$LINE"
  local cv=$(grep -c . $ASD/db/vless.db) cm=$(grep -c . $ASD/db/vmess.db) ct=$(grep -c . $ASD/db/trojan.db) cs=$(grep -c . $ASD/db/ssh.db 2>/dev/null)
  printf " ${G}%-14s${N}: %s\n" "Akun VLESS" "$cv" "Akun VMESS" "$cm" "Akun TROJAN" "$ct" "Akun SSH" "$cs"
  echo -e "$LINE"; pause
}

coming(){ echo -e "\n${Y}Fitur ini dibuat di tahap berikutnya.${N}"; sleep 2; }

# mode non-interaktif: adddomain
if [[ "$1" == "--domain" ]]; then change_domain; exit 0; fi
if [[ "$1" == "--restore" ]]; then if [[ -n "$2" ]]; then restore_url "$2"; else restore_vps; fi; exit 0; fi

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


# =====================================================
#  HALAMAN CEK AKUN PELANGGAN (read-only, port lokal 8099)
# =====================================================
echo -e "${GRN}[FEAT] Halaman cek akun pelanggan...${NC}"
cat > /usr/local/sbin/cekakun.py <<'CEKAKUNPY_EOF'
#!/usr/bin/env python3
# Cassanova Tunneling - Halaman Cek Akun Pelanggan (read-only)
# Kunci cek: UUID/password (Xray) atau username (SSH). Tidak pernah menulis data.
import json, os, re, time, html
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from collections import defaultdict

ASD = os.environ.get("CAS_ASD", "/etc/autoscript")
PROTOS = ("vless", "vmess", "trojan")
LIMIT_N, LIMIT_WIN = 15, 60          # 15 permintaan / 60 detik per IP
_hits = defaultdict(list)

def rate_ok(ip):
    now = time.time()
    q = _hits[ip] = [t for t in _hits[ip] if now - t < LIMIT_WIN]
    if len(q) >= LIMIT_N:
        return False
    q.append(now)
    return True

def rd(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default

def hbytes(n):
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.2f} {u}" if u != "B" else f"{int(n)} B"
        n /= 1024

def days_left(exp):
    try:
        y, m, d = (int(x) for x in exp.split("-"))
        import datetime
        return (datetime.date(y, m, d) - datetime.date.today()).days
    except Exception:
        return None

def usage_of(proto, user):
    try:
        return int(rd(f"{ASD}/usage/{proto}/{user}", "0") or 0)
    except Exception:
        return 0

def find_xray(key):
    """Cari akun Xray berdasarkan UUID / password (kolom ke-3)."""
    key = key.strip()
    for p in PROTOS:
        try:
            with open(f"{ASD}/db/{p}.db") as f:
                for line in f:
                    c = line.split()
                    if len(c) >= 6 and c[2] == key:
                        return {
                            "proto": p.upper(), "user": c[0], "exp": c[1],
                            "iplimit": c[3], "quota_gb": c[4], "status": c[5],
                            "used": usage_of(p, c[0]),
                        }
        except FileNotFoundError:
            continue
    return None

def find_ssh(user):
    """Cari akun SSH berdasarkan username (data minimal)."""
    user = user.strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", user or ""):
        return None
    try:
        with open(f"{ASD}/db/ssh.db") as f:
            for line in f:
                c = line.split()
                if len(c) >= 4 and c[0] == user:
                    return {"proto": "SSH", "user": c[0], "exp": c[1],
                            "iplimit": c[2], "quota_gb": "0", "status": c[3],
                            "used": usage_of("ssh", c[0])}
    except FileNotFoundError:
        return None
    return None

def build(acc):
    dl = days_left(acc["exp"])
    q = acc.get("quota_gb", "0")
    try:
        qn = int(q)
    except Exception:
        qn = 0
    out = {
        "found": True,
        "proto": acc["proto"],
        "user": acc["user"],
        "exp": acc["exp"],
        "days_left": dl,
        "status": acc["status"],
        "iplimit": acc["iplimit"] if acc["iplimit"] not in ("0", "") else "Unlimited",
        "used": hbytes(acc["used"]),
        "quota": "Unlimited" if qn == 0 else f"{qn} GB",
    }
    if qn > 0:
        pct = min(100, round(acc["used"] / (qn * 1073741824) * 100, 1))
        out["quota_pct"] = pct
    return out

PAGE = """<!DOCTYPE html><html lang="id"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cek Akun - __BRAND__</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1420;color:#e8edf7;
min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}
.card{width:100%;max-width:440px;background:#161d2e;border:1px solid #243049;border-radius:16px;
padding:24px;box-shadow:0 12px 40px rgba(0,0,0,.4)}
h1{font-size:18px;text-align:center;letter-spacing:.5px;margin-bottom:4px;color:#7dd3fc}
.sub{text-align:center;font-size:12px;color:#8b98b0;margin-bottom:20px}
label{display:block;font-size:12px;color:#8b98b0;margin:14px 0 6px}
select,input{width:100%;padding:12px 14px;background:#0f1420;border:1px solid #2a3654;
border-radius:10px;color:#e8edf7;font-size:14px;outline:none}
select:focus,input:focus{border-color:#3b82f6}
button{width:100%;margin-top:18px;padding:13px;background:#2563eb;border:0;border-radius:10px;
color:#fff;font-size:15px;font-weight:600;cursor:pointer}
button:active{background:#1d4ed8}
button:disabled{opacity:.6}
.res{margin-top:20px;display:none}
.row{display:flex;justify-content:space-between;padding:11px 0;border-bottom:1px solid #223049;font-size:14px}
.row:last-child{border-bottom:0}
.k{color:#8b98b0}
.v{font-weight:600;text-align:right}
.badge{display:inline-block;padding:3px 10px;border-radius:99px;font-size:12px;font-weight:600}
.ok{background:#064e3b;color:#6ee7b7}.bad{background:#4c1d24;color:#fca5a5}.warn{background:#4a3a09;color:#fcd34d}
.bar{height:7px;background:#223049;border-radius:99px;overflow:hidden;margin-top:8px}
.bar>i{display:block;height:100%;background:#3b82f6}
.err{margin-top:18px;padding:12px;background:#4c1d24;color:#fca5a5;border-radius:10px;font-size:13px;display:none}
.foot{margin-top:18px;text-align:center;font-size:11px;color:#5c6880}
</style></head><body>
<div class="card">
<h1>__BRAND__</h1>
<div class="sub">Cek Masa Aktif Akun</div>
<label>Jenis Akun</label>
<select id="t" onchange="lbl()">
<option value="xray">VLESS / VMESS / TROJAN</option>
<option value="ssh">SSH / OpenVPN</option>
</select>
<label id="l">UUID atau Password akun</label>
<input id="k" placeholder="Tempel UUID / password di sini" autocomplete="off">
<button id="b" onclick="go()">CEK AKUN</button>
<div class="err" id="e"></div>
<div class="res" id="r"></div>
<div class="foot">Powered by Cassanova Tunneling</div>
</div>
<script>
function lbl(){document.getElementById('l').textContent=
 document.getElementById('t').value==='ssh'?'Username SSH':'UUID atau Password akun';
 document.getElementById('k').placeholder=
 document.getElementById('t').value==='ssh'?'Ketik username':'Tempel UUID / password di sini';}
function esc(s){return String(s).replace(/[<>&]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]))}
async function go(){
 var k=document.getElementById('k').value.trim(),t=document.getElementById('t').value;
 var e=document.getElementById('e'),r=document.getElementById('r'),b=document.getElementById('b');
 e.style.display='none';r.style.display='none';
 if(!k){e.textContent='Isi dulu kolomnya.';e.style.display='block';return}
 b.disabled=true;b.textContent='MENGECEK...';
 try{
  var q=await fetch('/cek/api?t='+encodeURIComponent(t)+'&k='+encodeURIComponent(k));
  var d=await q.json();
  if(!d.found){e.textContent=d.error||'Akun tidak ditemukan. Periksa lagi UUID/username Anda.';e.style.display='block'}
  else{
   var st=d.status==='on'?'<span class="badge ok">AKTIF</span>':
        (d.status==='lock'?'<span class="badge warn">TERKUNCI</span>':'<span class="badge bad">'+esc(d.status).toUpperCase()+'</span>');
   var dl=d.days_left;
   var sisa=dl===null?'-':(dl<0?'<span class="badge bad">EXPIRED</span>':(dl===0?'<span class="badge warn">habis hari ini</span>':dl+' hari lagi'));
   var h='<div class="row"><span class="k">Username</span><span class="v">'+esc(d.user)+'</span></div>'
    +'<div class="row"><span class="k">Protokol</span><span class="v">'+esc(d.proto)+'</span></div>'
    +'<div class="row"><span class="k">Status</span><span class="v">'+st+'</span></div>'
    +'<div class="row"><span class="k">Masa Aktif</span><span class="v">'+esc(d.exp)+'</span></div>'
    +'<div class="row"><span class="k">Sisa</span><span class="v">'+sisa+'</span></div>'
    +'<div class="row"><span class="k">Limit IP</span><span class="v">'+esc(d.iplimit)+'</span></div>'
    +'<div class="row"><span class="k">Kuota</span><span class="v">'+esc(d.used)+' / '+esc(d.quota)+'</span></div>';
   if(d.quota_pct!==undefined)h+='<div class="bar"><i style="width:'+d.quota_pct+'%"></i></div>';
   r.innerHTML=h;r.style.display='block';
  }
 }catch(x){e.textContent='Gagal menghubungi server. Coba lagi.';e.style.display='block'}
 b.disabled=false;b.textContent='CEK AKUN';
}
document.getElementById('k').addEventListener('keydown',function(ev){if(ev.key==='Enter')go()});
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path.rstrip("/")
        if path.endswith("/api"):
            ip = self.headers.get("X-Real-IP") or self.client_address[0]
            if not rate_ok(ip):
                return self._send(429, json.dumps({"found": False,
                    "error": "Terlalu sering mengecek. Tunggu 1 menit."}), "application/json")
            q = parse_qs(u.query)
            key = (q.get("k", [""])[0] or "").strip()
            typ = (q.get("t", ["xray"])[0] or "xray").strip()
            if not key or len(key) > 80:
                return self._send(200, json.dumps({"found": False,
                    "error": "Data tidak valid."}), "application/json")
            acc = find_ssh(key) if typ == "ssh" else find_xray(key)
            if not acc:
                return self._send(200, json.dumps({"found": False,
                    "error": "Akun tidak ditemukan."}), "application/json")
            return self._send(200, json.dumps(build(acc)), "application/json")
        brand = rd(f"{ASD}/brand", "CASSANOVA") or "CASSANOVA"
        page = PAGE.replace("__BRAND__", html.escape(brand.upper()))
        self._send(200, page, "text/html; charset=utf-8")

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8099), H).serve_forever()
CEKAKUNPY_EOF
chmod +x /usr/local/sbin/cekakun.py

cat > /etc/systemd/system/cek-akun.service <<'CEKSVC_EOF'
[Unit]
Description=Cassanova Cek Akun Pelanggan
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/cekakun.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
CEKSVC_EOF
systemctl daemon-reload
systemctl enable cek-akun >/dev/null 2>&1
systemctl restart cek-akun >/dev/null 2>&1

echo -e "${GRN}Modul Features & Brand Name selesai.${NC}"
