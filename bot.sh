#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - MODUL SETUP BOT (Telegram)
# =====================================================
GRN='\e[32m'; RED='\e[31m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
ASD=/etc/autoscript
touch $ASD/bot
apt install -y zip unzip >/dev/null 2>&1

# helper notifikasi dipakai script lain (mis. saat create/expire)
cat > /usr/local/lib/autoscript/notify.sh <<'EOF'
# Header notif: nama script | domain | IP
_cas_head(){
  local I=/etc/autoscript/ipinfo.json ip isp
  ip=$(jq -r '.ip // "-"' $I 2>/dev/null)
  isp=$(jq -r '.org // "-"' $I 2>/dev/null | sed 's/^AS[0-9]* //')
  echo "<code>IP     : $ip
DOMAIN : $(cat /etc/autoscript/domain 2>/dev/null)
ISP    : $isp</code>"
}
# kirim pesan Telegram (HTML). Baris baru pakai newline asli, bukan %0A.
_cas_send(){
  local BOT_TOKEN CHAT_ID NOTIFY
  [[ -f /etc/autoscript/bot ]] || return 0
  . /etc/autoscript/bot
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || "$NOTIFY" != "on" ]] && return 0
  ( curl -s --max-time 15 -o /dev/null \
      --data-urlencode "chat_id=$CHAT_ID" \
      --data-urlencode "text=$(_cas_head)"$'\n'"$1" \
      --data-urlencode "parse_mode=HTML" \
      "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" ) >/dev/null 2>&1 &
  disown 2>/dev/null; return 0
}
# cas_notify "teks"      -> pesan singkat (event akun)
cas_notify(){ _cas_send "$1"; }
# cas_notify_raw "teks"  -> pesan panjang (akun penuh); sama-sama diberi header
cas_notify_raw(){ _cas_send "$1"; }
# cas_notify_quote "judul" "isi" -> judul dalam blockquote (tanda kutip), lalu isi
cas_notify_quote(){ _cas_send "<blockquote><b>$1</b>"$'\n'"$2</blockquote>"; }
EOF


# ---------- Laporan User Login (seperti bot Potato) ----------
cat > /usr/local/sbin/cas-report <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BOT_TOKEN=""; CHAT_ID=""
[[ -f $ASD/bot ]] && . $ASD/bot
[[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && { echo "Bot belum diatur"; exit 0; }
MIN=$(cat $ASD/report_interval 2>/dev/null); [[ "$MIN" =~ ^[0-9]+$ && $MIN -gt 0 ]] || MIN=60
IPV=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
ISP=$(jq -r '.org // "-"' $ASD/ipinfo.json 2>/dev/null | sed 's/^AS[0-9]* //')
DOMAIN=$(cat $ASD/domain)
HEAD="<code>IP     : $IPV
DOMAIN : $DOMAIN
ISP    : $ISP</code>"

send(){
  curl -s --max-time 20 -o /dev/null --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$1" --data-urlencode "parse_mode=HTML" \
    "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
}
# kirim per potongan (batas pesan Telegram ~4096 karakter)
send_section(){ # judul, isi(multiline), total
  local title=$1 body=$2 total=$3 chunk="" line part=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if (( ${#chunk} + ${#line} > 3300 )); then
      send "$HEAD"$'\n'"<blockquote><b>$title</b> (bag. $part)</blockquote>"$'\n'"$chunk"; chunk=""; part=$((part+1))
    fi
    chunk+="$line"$'\n'
  done <<< "$body"
  [[ $part -gt 1 ]] && title="$title (bag. $part)"
  send "$HEAD"$'\n'"<blockquote><b>$title</b></blockquote>"$'\n'"$chunk"$'\n'"<b>Total : $total</b>"
}

LOG=/var/log/xray/access.log
since=$(date -d "-$MIN min" '+%Y/%m/%d %H:%M:%S')
DATA=""
[[ -f $LOG ]] && DATA=$(awk -v s="$since" 'substr($0,1,19)>=s' $LOG \
  | sed -nE 's/.* from (tcp:|udp:)?(\[[^]]+\]|[0-9.]+):[0-9]+ accepted .*email: ([^ ]+).*/\3 \2/p')

sent=0
for p in vless vmess trojan; do
  body=""; total=0
  while read -r e conns ips; do
    [[ -z "$e" ]] && continue
    u=${e#*.}
    body+="$u $(hbytes $(usage_get $p "$u")) ${ips}IP | $conns"$'\n'; total=$((total+1))
  done < <(echo "$DATA" | awk -v p="$p." 'index($1,p)==1 { c[$1]++; k=$1" "$2; if(!(k in seen)){seen[k]=1; ip[$1]++} } END{ for(u in c) print u, c[u], ip[u] }' | sort -k2 -nr)
  (( total > 0 )) && { send_section "Users Login ${p^^}" "$body" "$total"; sent=1; }
done

# SSH: sesi aktif per user
if [[ -f $ASD/db/ssh.db ]]; then
  body=""; total=0
  while read -r cnt u; do
    grep -q "^$u " $ASD/db/ssh.db || continue
    body+="$u | $cnt sesi"$'\n'; total=$((total+1))
  done < <(ps -eo user=,comm= | awk '($2=="dropbear" || $2=="sshd") && $1!="root" && $1!="sshd" {print $1}' | sort | uniq -c)
  (( total > 0 )) && { send_section "Users Login SSH" "$body" "$total"; sent=1; }
fi
[[ $sent == 0 && "$1" == "--manual" ]] && send "$HEAD"$'\n'"Tidak ada user login dalam $MIN menit terakhir."
exit 0
EOF
chmod +x /usr/local/sbin/cas-report

# ---------- Menu Setup Bot ----------
cat > /usr/local/sbin/m-bot <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BRAND=$SCNAME
BOTF=$ASD/bot
LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }
msg(){ echo -e "$1"; sleep 2; }
load(){ BOT_TOKEN=""; CHAT_ID=""; NOTIFY="off"; [[ -f $BOTF ]] && . $BOTF; }
save(){ printf 'BOT_TOKEN="%s"\nCHAT_ID="%s"\nNOTIFY="%s"\n' "$BOT_TOKEN" "$CHAT_ID" "$NOTIFY" > $BOTF; chmod 600 $BOTF; }

test_bot(){ # cek token valid
  local r; r=$(curl -s --max-time 10 "https://api.telegram.org/bot$1/getMe")
  echo "$r" | grep -q '"ok":true'
}

make_bot(){
  header "MAKE BOT API & CHATID"
  echo -e " Buat bot di ${C}@BotFather${N}, salin tokennya."
  echo -e " Chat ID bisa dilihat dari ${C}@userinfobot${N}.\n"
  read -rp "BOT API Token : " t; [[ -z "$t" ]] && { msg "${R}Kosong${N}"; return; }
  if ! test_bot "$t"; then msg "${R}Token tidak valid / tidak bisa diakses${N}"; return; fi
  read -rp "Chat ID : " c; [[ ! "$c" =~ ^-?[0-9]+$ ]] && { msg "${R}Chat ID harus angka${N}"; return; }
  BOT_TOKEN="$t"; CHAT_ID="$c"; NOTIFY="on"; save
  curl -s --max-time 10 -o /dev/null --data-urlencode "chat_id=$c" \
    --data-urlencode "text=✅ Bot $BRAND berhasil terhubung." \
    "https://api.telegram.org/bot$t/sendMessage"
  msg "${G}Bot tersimpan & pesan tes dikirim. Cek Telegram Anda.${N}"
}

toggle_notify(){
  load; [[ -z "$BOT_TOKEN" ]] && { msg "${R}Buat bot dulu (menu 1)${N}"; return; }
  [[ "$NOTIFY" == "on" ]] && NOTIFY="off" || NOTIFY="on"; save
  msg "${G}Notifikasi otomatis: $NOTIFY${N}"
}

backup_now(){
  load; [[ -z "$BOT_TOKEN" ]] && { msg "${R}Buat bot dulu (menu 1)${N}"; return; }
  header "BACKUP VPS -> TELEGRAM"
  local f; f=$(/usr/local/sbin/cas-backup-make)
  echo -e " Mengirim $(basename "$f") ..."
  if curl -s --max-time 120 -o /dev/null -F chat_id="$CHAT_ID" -F document=@"$f" \
      -F parse_mode=HTML -F caption="$(/usr/local/sbin/cas-backup-caption)" \
      "https://api.telegram.org/bot$BOT_TOKEN/sendDocument"; then
    msg "${G}Backup terkirim ke Telegram${N}"
  else
    msg "${R}Gagal mengirim backup${N}"
  fi
}

# ubah interval menit -> baris cron (90 menit butuh 2 baris)
cron_write(){ # $1=menit  $2=file cron  $3=perintah
  local m=$1 f=$2 cmd=$3
  case $m in
    30)   echo "*/30 * * * * root $cmd" > "$f" ;;
    60)   echo "0 * * * * root $cmd" > "$f" ;;
    90)   { echo "0 0,3,6,9,12,15,18,21 * * * root $cmd";
            echo "30 1,4,7,10,13,16,19,22 * * * root $cmd"; } > "$f" ;;
    120)  echo "0 */2 * * * root $cmd" > "$f" ;;
    180)  echo "0 */3 * * * root $cmd" > "$f" ;;
    360)  echo "0 */6 * * * root $cmd" > "$f" ;;
    720)  echo "0 */12 * * * root $cmd" > "$f" ;;
    1440) echo "0 3 * * * root $cmd" > "$f" ;;
    *)    echo "0 * * * * root $cmd" > "$f" ;;
  esac
  chmod 644 "$f"
}
fmt_int(){ # tampilkan menit dalam bahasa manusia
  case $1 in 0) echo "OFF";; 30) echo "tiap 30 menit";; 60) echo "tiap 1 jam";;
    90) echo "tiap 1,5 jam";; 120) echo "tiap 2 jam";; 180) echo "tiap 3 jam";;
    360) echo "tiap 6 jam";; 720) echo "tiap 12 jam";; 1440) echo "tiap 24 jam (03:00)";;
    *) echo "tiap $1 menit";; esac
}

set_backup(){
  load; [[ -z "$BOT_TOKEN" ]] && { msg "${R}Buat bot dulu (menu 1)${N}"; return; }
  header "JADWAL AUTO BACKUP"
  local cur; cur=$(cat $ASD/backup_interval 2>/dev/null || echo 1440)
  echo -e " Jadwal sekarang : ${Y}$(fmt_int "$cur")${N}\n"
  echo -e " ${C}1.)${N} Tiap 1 jam"
  echo -e " ${C}2.)${N} Tiap 3 jam"
  echo -e " ${C}3.)${N} Tiap 6 jam"
  echo -e " ${C}4.)${N} Tiap 12 jam"
  echo -e " ${C}5.)${N} Tiap 24 jam (03:00)"
  echo -e " ${C}6.)${N} Matikan auto backup"
  echo -e " ${C}7.)${N} Backup sekarang"
  echo -e " ${C}8.)${N} Kembali\n"
  read -rp "Pilih : " o
  local m
  case $o in
    1) m=60 ;; 2) m=180 ;; 3) m=360 ;; 4) m=720 ;; 5) m=1440 ;;
    6) echo 0 > $ASD/backup_interval; rm -f /etc/cron.d/cas-backup; msg "${G}Auto backup dimatikan${N}"; return ;;
    7) backup_now; return ;;
    *) return ;;
  esac
  echo $m > $ASD/backup_interval
  cron_write "$m" /etc/cron.d/cas-backup /usr/local/sbin/cas-autobackup
  msg "${G}Auto backup dijalankan $(fmt_int $m)${N}"
}

set_report(){
  load; [[ -z "$BOT_TOKEN" ]] && { msg "${R}Buat bot dulu (menu 1)${N}"; return; }
  header "LAPORAN USER LOGIN"
  local cur; cur=$(cat $ASD/report_interval 2>/dev/null || echo 0)
  echo -e " Interval sekarang : ${Y}$(fmt_int "$cur")${N}\n"
  echo -e " ${C}1.)${N} Tiap 30 menit"
  echo -e " ${C}2.)${N} Tiap 1 jam"
  echo -e " ${C}3.)${N} Tiap 1,5 jam"
  echo -e " ${C}4.)${N} Tiap 2 jam"
  echo -e " ${C}5.)${N} Tiap 3 jam"
  echo -e " ${C}6.)${N} Tiap 6 jam"
  echo -e " ${C}7.)${N} Tiap 12 jam"
  echo -e " ${C}8.)${N} Tiap 24 jam"
  echo -e " ${C}9.)${N} Matikan laporan"
  echo -e " ${C}10.)${N} Kirim laporan sekarang"
  echo -e " ${C}11.)${N} Kembali\n"
  read -rp "Pilih : " o
  local m
  case $o in
    1) m=30 ;; 2) m=60 ;; 3) m=90 ;; 4) m=120 ;; 5) m=180 ;; 6) m=360 ;; 7) m=720 ;; 8) m=1440 ;;
    9) echo 0 > $ASD/report_interval; rm -f /etc/cron.d/cas-report; msg "${G}Laporan dimatikan${N}"; return ;;
    10) echo -e "${Y}Mengirim...${N}"; /usr/local/sbin/cas-report --manual; msg "${G}Laporan dikirim, cek Telegram${N}"; return ;;
    *) return ;;
  esac
  echo $m > $ASD/report_interval
  cron_write "$m" /etc/cron.d/cas-report /usr/local/sbin/cas-report
  msg "${G}Laporan user login dikirim $(fmt_int $m)${N}"
}

change_bot(){
  load; [[ -z "$BOT_TOKEN" ]] && { msg "${R}Belum ada bot, gunakan menu 1${N}"; return; }
  make_bot
}

while true; do
  load
  header "SETUP BOT"
  echo
  if [[ -n "$BOT_TOKEN" ]]; then
    echo -e " ${G}Your BOT API :${N}"
    echo -e "   ${O}${BOT_TOKEN:0:10}...${BOT_TOKEN: -6}${N}"
    echo -e " ${G}Your CHATID  :${N}"
    echo -e "   ${O}$CHAT_ID${N}"
    echo -e " ${G}Notifikasi   :${N} $([[ "$NOTIFY" == on ]] && echo -e "${G}ON${N}" || echo -e "${R}OFF${N}")"
  else
    echo -e " ${Y}Bot belum diatur${N}"
  fi
  echo -e "\n$LINE"
  echo -e " ${C}1.)${N}  Make BOT API & CHATID"
  echo -e " ${C}2.)${N}  Notification from BOT (on/off)"
  echo -e " ${C}3.)${N}  Backup VPS from BOT"
  echo -e " ${C}4.)${N}  Change BOT API & CHATID"
  echo -e " ${C}5.)${N}  Laporan User Login (interval)"
  echo -e " ${C}6.)${N}  Jadwal Auto Backup"
  echo -e " ${C}7.)${N}  Back to Menu"
  echo -e " ${C}x.)${N}  Exit"
  echo -e "$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-7 or x] : ${N}")" opt
  case $opt in
    1) make_bot ;;
    2) toggle_notify ;;
    3) backup_now ;;
    4) change_bot ;;
    5) set_report ;;
    6) set_backup ;;
    7) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
    *) msg "${R}Pilihan salah${N}" ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-bot

# backup otomatis harian ke Telegram (03:00) bila notifikasi on
# pembuat file backup: <domain>-<ip>-<jam_menit_detik>.zip
cat > /usr/local/sbin/cas-backup-make <<'EOF'
#!/bin/bash
D=$(cat /etc/autoscript/domain)
IP=$(jq -r '.ip // empty' /etc/autoscript/ipinfo.json 2>/dev/null); [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 ifconfig.me)
mkdir -p /root/backup
find /root/backup -name '*.zip' -mtime +3 -delete 2>/dev/null
f=/root/backup/${D}-${IP}-$(date +%H_%M_%S).zip
cd / && zip -rq "$f" FILES_HERE 2>/dev/null
echo "$f"
EOF
chmod +x /usr/local/sbin/cas-backup-make
sed -i "s#FILES_HERE#etc/autoscript usr/local/etc/xray/config.json etc/passwd etc/shadow etc/group etc/gshadow etc/nginx/conf.d/xray.conf#" /usr/local/sbin/cas-backup-make

# keterangan file backup (HTML)
cat > /usr/local/sbin/cas-backup-caption <<'EOF'
#!/bin/bash
I=/etc/autoscript/ipinfo.json
B="CASSANOVA TUNNELING"; D=$(cat /etc/autoscript/domain)
IP=$(jq -r '.ip // "-"' $I 2>/dev/null)
ISP=$(jq -r '.org // "-"' $I 2>/dev/null | sed 's/^AS[0-9]* //')
CITY=$(jq -r '.city // "-"' $I 2>/dev/null)
L="━━━━━━━━━━━━━━━━━━━━"
cat <<TXT
✨ <b>Backup VPS Created successfully</b> ✨
📦 <b>$B</b>
$L
<code>Domain :</code> $D
<code>IP     :</code> $IP
<code>ISP    :</code> $ISP
<code>City   :</code> $CITY
<code>Date   :</code> $(date +%F)
<code>Time   :</code> $(date +%H:%M:%S)
$L
<code>Restore :</code> menu → 6 FEATURES → 7 Restore
Upload file .zip ini ke folder /root VPS
TXT
EOF
chmod +x /usr/local/sbin/cas-backup-caption

cat > /usr/local/sbin/cas-autobackup <<'EOF'
#!/bin/bash
BOT_TOKEN=""; CHAT_ID=""; NOTIFY="off"
. /etc/autoscript/bot 2>/dev/null
[[ "$NOTIFY" != on || -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && exit 0
f=$(/usr/local/sbin/cas-backup-make)
curl -s --max-time 120 -o /dev/null -F chat_id="$CHAT_ID" -F document=@"$f" \
  -F parse_mode=HTML -F caption="$(/usr/local/sbin/cas-backup-caption)" \
  "https://api.telegram.org/bot$BOT_TOKEN/sendDocument"
EOF
chmod +x /usr/local/sbin/cas-autobackup
# jadwal auto backup: hormati pilihan buyer, jangan ditimpa saat update
BI=$(cat /etc/autoscript/backup_interval 2>/dev/null)
if [[ "$BI" == "0" ]]; then
  rm -f /etc/cron.d/cas-backup            # buyer mematikan auto backup
elif [[ -z "$BI" ]]; then
  echo 1440 > /etc/autoscript/backup_interval
  echo "0 3 * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup
  chmod 644 /etc/cron.d/cas-backup 2>/dev/null
elif [[ ! -s /etc/cron.d/cas-backup ]]; then
  # pengaturan ada tapi file cron hilang -> bangun ulang sesuai pilihan
  case $BI in
    60)   echo "0 * * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup ;;
    180)  echo "0 */3 * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup ;;
    360)  echo "0 */6 * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup ;;
    720)  echo "0 */12 * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup ;;
    *)    echo "0 3 * * * root /usr/local/sbin/cas-autobackup" > /etc/cron.d/cas-backup ;;
  esac
  chmod 644 /etc/cron.d/cas-backup 2>/dev/null
fi

echo -e "${GRN}Modul Setup Bot selesai.${NC}"
