#!/bin/bash
# =====================================================================
#  Modul Hysteria2 (apernet) - protokol MANDIRI, terpisah dari All Protocol.
#  Dipasang oleh update.sh (di-wget seperti ssh.sh / features.sh).
#  Auth pakai "command": baca DB langsung -> tambah/hapus user TANPA restart.
# =====================================================================
GRN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
ASD=/etc/autoscript
DOMAIN=$(cat $ASD/domain 2>/dev/null | tr -d '[:space:]')
CRT=$ASD/xray.crt; KEY=$ASD/xray.key
mkdir -p $ASD/db $ASD/usage/hy2 /etc/hysteria

# Port UDP HY2 (bisa diganti lewat berkas). Default 443: TCP 443 tetap milik
# nginx, UDP 443 terpisah - jadi tidak bentrok.
HYPORT=$(cat $ASD/hy2_port 2>/dev/null | tr -d '[:space:]'); [[ "$HYPORT" =~ ^[0-9]+$ ]] || HYPORT=443
echo "$HYPORT" > $ASD/hy2_port
# Secret untuk API trafficStats (lokal saja)
[[ -s $ASD/hy2_secret ]] || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' > $ASD/hy2_secret
SECRET=$(cat $ASD/hy2_secret)
STATSPORT=25413

# ---------- Bersihkan probe lama kalau ada (Tahap 1) ----------
if systemctl cat cas-hy2-probe >/dev/null 2>&1; then
  systemctl disable --now cas-hy2-probe >/dev/null 2>&1
  rm -f /etc/systemd/system/cas-hy2-probe.service /etc/hysteria/probe.yaml
  systemctl daemon-reload
fi

# ---------- Biner Hysteria2 resmi (idempoten) ----------
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  *) echo -e "${YEL}[HY2] Arsitektur $(uname -m) belum didukung, modul HY2 dilewati${NC}"; exit 0 ;;
esac
if [[ ! -x /usr/local/bin/hysteria ]]; then
  echo -e "${GRN}[HY2] Mengunduh biner Hysteria2...${NC}"
  TAG=$(curl -fsSL --max-time 20 https://api.github.com/repos/apernet/hysteria/releases/latest \
        | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | grep -oE 'app/v[0-9.]+')
  if [[ -n "$TAG" ]] && curl -fL --max-time 120 -o /usr/local/bin/hysteria \
        "https://github.com/apernet/hysteria/releases/download/${TAG}/hysteria-linux-${ARCH}"; then
    chmod +x /usr/local/bin/hysteria
  else
    echo -e "${YEL}[HY2] Gagal mengunduh biner (cek jaringan/GitHub). Modul HY2 dilewati.${NC}"; exit 0
  fi
fi

# ---------- Script auth (dipanggil hysteria tiap ada yang connect) ----------
# Kontrak apernet: command dipanggil dgn arg <addr> <auth> [tx]. Sukses = exit 0
# dan cetak id user ke stdout. Kita cocokkan <auth> (password) ke kolom 3 DB.
cat > /etc/hysteria/auth.sh <<'AUTH'
#!/bin/bash
ASD=/etc/autoscript
DB=$ASD/db/hy2.db
LOG=/var/log/cas-hy2-auth.log
addr="$1"; key="$2"
# jaga-jaga kalau versi biner mengirim lewat env/stdin, bukan argumen
[[ -z "$key" ]] && key="${HYSTERIA_AUTH_PAYLOAD:-}"
[[ -z "$key" && ! -t 0 ]] && read -r key
today=$(date +%F)
[[ -f "$DB" ]] || { echo "$(date '+%F %T') TOLAK addr=$addr (DB kosong)" >> "$LOG"; exit 1; }
line=$(awk -v k="$key" '$3==k{print; exit}' "$DB")
if [[ -z "$line" ]]; then echo "$(date '+%F %T') TOLAK addr=$addr (pass tidak dikenal)" >> "$LOG"; exit 1; fi
set -- $line
u=$1; exp=$2; st=$6
if [[ "$st" != active ]]; then echo "$(date '+%F %T') TOLAK $u (status=$st)" >> "$LOG"; exit 1; fi
if [[ "$exp" < "$today" ]]; then echo "$(date '+%F %T') TOLAK $u (expired $exp)" >> "$LOG"; exit 1; fi
echo "$(date '+%F %T') OK $u addr=$addr" >> "$LOG"
echo "$u"
exit 0
AUTH
chmod +x /etc/hysteria/auth.sh

# ---------- Config server ----------
cat > /etc/hysteria/config.yaml <<YAML
listen: :$HYPORT
tls:
  cert: $CRT
  key: $KEY
auth:
  type: command
  command: /etc/hysteria/auth.sh
trafficStats:
  listen: 127.0.0.1:$STATSPORT
  secret: $SECRET
masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN
    rewriteHost: true
YAML

# ---------- systemd ----------
cat > /etc/systemd/system/cas-hy2.service <<UNIT
[Unit]
Description=Cassanova Hysteria2
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable cas-hy2 >/dev/null 2>&1

# hanya (re)start kalau config valid, supaya layanan lama tidak ikut mati
if [[ -s "$CRT" && -s "$KEY" && -n "$DOMAIN" ]]; then
  systemctl restart cas-hy2
  sleep 1
  if systemctl is-active --quiet cas-hy2; then
    echo -e "${GRN}[HY2] Server Hysteria2 aktif di UDP $HYPORT${NC}"
  else
    echo -e "${YEL}[HY2] Server belum aktif, cek: journalctl -u cas-hy2 -n 30${NC}"
  fi
else
  echo -e "${YEL}[HY2] Domain/SSL belum siap, server HY2 belum dijalankan (menyusul otomatis)${NC}"
fi

# ---------- buka UDP port ----------
command -v ufw >/dev/null 2>&1 && ufw allow $HYPORT/udp >/dev/null 2>&1
iptables -C INPUT -p udp --dport $HYPORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $HYPORT -j ACCEPT 2>/dev/null

# =====================================================================
#  m-hy2 : menu manajemen akun Hysteria2 (mandiri)
# =====================================================================
cat > /usr/local/sbin/m-hy2 <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
[[ -f /usr/local/lib/autoscript/notify.sh ]] && . /usr/local/lib/autoscript/notify.sh
type cas_notify &>/dev/null || cas_notify(){ :; }
type cas_notify_raw &>/dev/null || cas_notify_raw(){ :; }
DB=$ASD/db/hy2.db
TRASH=$ASD/db/hy2.trash
DOMAIN=$(cat $ASD/domain 2>/dev/null | tr -d '[:space:]')
HYPORT=$(cat $ASD/hy2_port 2>/dev/null | tr -d '[:space:]'); [[ "$HYPORT" =~ ^[0-9]+$ ]] || HYPORT=443
STATSPORT=25413
SECRET=$(cat $ASD/hy2_secret 2>/dev/null)
touch "$DB" "$TRASH"
# Format DB: user exp pass iplimit quota status(active|locked)
LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }
msg(){ echo -e "$1"; sleep 2; }
cas_run(){ ( trap 'exit 130' INT; eval "$*" ); }
num_ok(){ [[ "$1" =~ ^[0-9]+$ ]]; }

# hentikan sesi user tertentu lewat API (best-effort, tak wajib berhasil)
hy_kick(){ curl -fsS --max-time 5 -H "Authorization: $SECRET" \
  -X POST "http://127.0.0.1:$STATSPORT/kick" --data "{\"$1\":true}" >/dev/null 2>&1; }

hf(){ awk -v u="$1" -v f="$2" '$1==u{print $f}' "$DB"; }
hset(){ awk -v u="$1" -v f="$2" -v v="$3" '$1==u{$f=v}1' "$DB" > "$DB.t" && mv "$DB.t" "$DB"; }
hy_exists(){ [[ -n "$(awk -v u="$1" '$1==u' "$DB")" ]]; }

mk_link(){ # user pass
  echo "hysteria2://${2}@${DOMAIN}:${HYPORT}/?sni=${DOMAIN}&insecure=0#${1}"
}

hy_remove(){ # user -> trash + kick
  local u=$1 line
  line=$(awk -v u="$u" '$1==u' "$DB"); [[ -z "$line" ]] && return 1
  is_trial "$u" || echo "$line $(date +%F)" >> "$TRASH"
  awk -v u="$u" '$1!=u' "$DB" > "$DB.t" && mv "$DB.t" "$DB"
  hy_kick "$u"
  rm -f $ASD/usage/hy2/$u
}

hy_expire(){
  local today u exp lim rest list=""; today=$(date +%F); lim=$(date -d "-120 days" +%F)
  while read -r u exp rest; do
    [[ -z "$u" ]] && continue
    if [[ "$exp" < "$today" ]]; then hy_remove "$u"; is_trial "$u" || list+="• HY2 <code>$u</code> (exp $exp)"$'\n'; fi
  done < <(cat "$DB")
  [[ -n "$list" ]] && cas_notify "⌛ Akun Kedaluwarsa" "<pre>$list</pre>Masuk daftar Recovery."
  awk -v l="$lim" 'NF && $1 !~ /trial/ && $NF>=l' "$TRASH" > "$TRASH.t" && mv "$TRASH.t" "$TRASH"
}

# ---- non-interaktif ----
if [[ "$1" == "--delete" && -n "$2" ]]; then lock_db; hy_remove "$2"; unlock_db; exit 0; fi
if [[ "$1" == "--expire" ]]; then lock_db; hy_expire; unlock_db; exit 0; fi
if [[ "$1" == "--link" && -n "$2" ]]; then
  p=$(hf "$2" 3); [[ -n "$p" ]] && mk_link "$2" "$p"; exit 0
fi

show_account(){ # user pass exp ipl quota [notif] [judul]
  local u=$1 p=$2 exp=$3 ipl=$4 q=$5 notif=$6 ntitle=${7:-"HY2 Dibuat"} IP link
  IP=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
  link=$(mk_link "$u" "$p")
  clear
  echo -e "$LINE"; echo -e "        ${G}HYSTERIA2 ACCOUNT${N}"; echo -e "$LINE"
  printf " ${G}%-14s${N}: %s\n" "Username" "$u" "Password" "$p" "Domain" "$DOMAIN" "IP" "$IP" \
    "Port (UDP)" "$HYPORT" "SNI" "$DOMAIN" \
    "Limit IP" "$([[ "$ipl" == 0 || -z "$ipl" ]] && echo Unlimited || echo "$ipl IP")" \
    "Kuota" "$([[ "$q" == 0 || -z "$q" ]] && echo Unlimited || echo "$q GB")" \
    "Expired On" "$exp"
  echo -e "$LINE"
  echo -e " ${G}Link Hysteria2:${N}"
  echo -e " ${C}$link${N}"
  echo -e "$LINE"
  echo -e " ${G}Convert Link:${N}"
  echo -e " ${G}Sing-box   :${N} ${C}https://singbox.cassanova.my.id/${N}"
  echo -e " ${G}Multi Akun :${N} ${C}https://multi.cassanova.my.id/${N}"
  echo -e "$LINE"
  echo -e " ${Y}Catatan: HY2 jalur UDP langsung ke VPS (bypass), bukan lewat IP Cloudflare.${N}"
  echo -e "$LINE"
  if [[ "$notif" == notif ]]; then
    local BR="────────────────────────────────"
    local body="<code>$BR
        HYSTERIA2 ACCOUNT
$BR
 Username      : $u
 Password      : $p
 Domain        : $DOMAIN
 IP            : $IP
 Port (UDP)    : $HYPORT
 SNI           : $DOMAIN
 Limit IP      : $([[ "$ipl" == 0 || -z "$ipl" ]] && echo Unlimited || echo "$ipl IP")
 Kuota         : $([[ "$q" == 0 || -z "$q" ]] && echo Unlimited || echo "$q GB")
 Expired On    : $exp
$BR</code>
<b>Link:</b> <code>$link</code>
<b>Convert Sing-box:</b> <code>https://singbox.cassanova.my.id/</code>
<b>Convert Multi:</b> <code>https://multi.cassanova.my.id/</code>"
    cas_notify_raw "<b>✅ $ntitle</b>"$'\n'"$body"
  fi
}

list_users(){ # $1 = all|active|inactive
  local f=${1:-all} title="LIST HY2 USERS"
  [[ $f == active ]] && title="HY2 USER AKTIF"
  [[ $f == inactive ]] && title="HY2 USER NONAKTIF"
  header "$title"
  printf " ${G}%-3s %-14s %-10s %-3s %-5s${N}\n" "NO" "USER" "EXPIRED" "IP" "ST"
  local i=0 u exp p ipl q st lab
  while read -r u exp p ipl q st; do
    [[ -z "$u" ]] && continue
    [[ $f == active && "$st" != active ]] && continue
    [[ $f == inactive && "$st" == active ]] && continue
    i=$((i+1))
    case $st in active) lab="${G}ON${N}";; *) lab="${R}$st${N}";; esac
    printf " %-3s %-14s %-10s %-3s %b\n" "$i" "$u" "$exp" "$([[ "$ipl" == 0 ]] && echo - || echo "$ipl")" "$lab"
  done < "$DB"
  LISTED=$i
  [[ $i == 0 ]] && echo -e " ${Y}Belum ada akun${N}"
  echo -e "$LINE"; echo -e " ${G}Total : ${Y}$i${G} akun${N}"; echo -e "$LINE"
}

pick_user(){
  local f=${1:-all} inp
  list_users "$f"
  [[ $LISTED == 0 ]] && { pause; return 1; }
  read -rp "Nomor / Username : " inp
  if [[ "$inp" =~ ^[0-9]+$ ]]; then
    U=$(awk -v n="$inp" 'NF{i++; if(i==n){print $1; exit}}' "$DB")
  else U=$inp; fi
  [[ -n "$U" ]] && hy_exists "$U" && return 0
  msg "${R}User tidak ditemukan${N}"; return 1
}

create(){
  header "CREATE HYSTERIA2"
  local u p d ipl q exp
  read -rp "Username : " u
  [[ ! "$u" =~ ^[a-zA-Z0-9_-]{3,20}$ ]] && { msg "${R}Username 3-20 karakter: huruf, angka, - dan _${N}"; return; }
  hy_exists "$u" && { msg "${R}Username $u sudah ada${N}"; return; }
  p=$(gen_id)
  read -rp "Masa aktif (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Limit IP (0 = unlimited) [0] : " ipl; ipl=${ipl:-0}; num_ok "$ipl" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Kuota GB (0 = unlimited) [0] : " q; q=${q:-0}; num_ok "$q" || { msg "${R}Harus angka${N}"; return; }
  exp=$(date -d "+$d days" +%F)
  lock_db
  echo "$u $exp $p $ipl $q active" >> "$DB"
  rm -f $ASD/usage/hy2/$u
  unlock_db
  show_account "$u" "$p" "$exp" "$ipl" "$q" notif; pause
}

renew(){
  pick_user || return
  local exp d st; st=$(hf "$U" 6)
  read -rp "Tambah berapa hari : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  local cur; cur=$(hf "$U" 2)
  # kalau sudah lewat, hitung dari hari ini
  [[ "$cur" < "$(date +%F)" ]] && cur=$(date +%F)
  exp=$(date -d "$cur +$d days" +%F)
  lock_db; hset "$U" 2 "$exp"; hset "$U" 6 active; unlock_db
  msg "${G}$U diperpanjang s.d. $exp${N}"
  cas_notify "🔄 Akun Diperpanjang" "<pre>HY2 : $U
Aktif s.d. : $exp</pre>"
}

delete(){
  pick_user || return
  echo; read -rp "$(echo -e " ${R}Hapus $U? (y/t) : ${N}")" y
  [[ "$y" != y ]] && { msg "${Y}Dibatalkan${N}"; return; }
  local dexp; dexp=$(hf "$U" 2)
  lock_db; hy_remove "$U"; unlock_db
  msg "${G}$U dihapus${N}"
  cas_notify "🗑 Akun Dihapus" "<pre>HY2 : $U</pre>Masuk daftar Recovery."
}

show_link(){
  pick_user || return
  local p exp ipl q; p=$(hf "$U" 3); exp=$(hf "$U" 2); ipl=$(hf "$U" 4); q=$(hf "$U" 5)
  show_account "$U" "$p" "$exp" "$ipl" "$q"; pause
}

recovery(){
  header "RECOVERY HY2 (maks 4 bulan)"
  [[ ! -s "$TRASH" ]] && { echo -e " ${Y}Kosong${N}"; pause; return; }
  nl -ba "$TRASH" | awk '{printf "  %s\n",$0}'
  echo -e "$LINE"
  local n line u exp p ipl q
  read -rp "Nomor yang mau dipulihkan (0=batal) : " n
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || return
  line=$(sed -n "${n}p" "$TRASH"); [[ -z "$line" ]] && return
  read -r u exp p ipl q _ <<< "$line"
  hy_exists "$u" && { msg "${R}$u sudah ada${N}"; return; }
  local nd; read -rp "Aktif berapa hari dari sekarang : " nd; num_ok "$nd" || { msg "${R}Harus angka${N}"; return; }
  exp=$(date -d "+$nd days" +%F)
  lock_db
  echo "$u $exp $p $ipl $q active" >> "$DB"
  awk -v ln="$n" 'NR!=ln' "$TRASH" > "$TRASH.t" && mv "$TRASH.t" "$TRASH"
  unlock_db
  show_account "$u" "$p" "$exp" "$ipl" "$q" notif "HY2 Dipulihkan"; pause
}

while true; do
  header "HYSTERIA2 MANAGER"
  echo -e " ${G}Server : ${Y}$(systemctl is-active cas-hy2 2>/dev/null)${N}   ${G}Port UDP : ${Y}$HYPORT${N}"
  echo -e "$LINE"
  echo -e " ${C}1.)${N} Create Account"
  echo -e " ${C}2.)${N} Renew Account"
  echo -e " ${C}3.)${N} Delete Account"
  echo -e " ${C}4.)${N} List Account"
  echo -e " ${C}5.)${N} Tampilkan Link Akun"
  echo -e " ${C}6.)${N} Recovery Account"
  echo -e " ${C}7.)${N} Kembali ke Menu"
  echo -e "$LINE"
  trap 'echo; exit 0' INT
  read -rp "$(echo -e "${G}Select [1-7] : ${N}")" o
  trap ':' INT
  case $o in
    1) cas_run "create" ;;
    2) cas_run "renew" ;;
    3) cas_run "delete" ;;
    4) cas_run "list_users; pause" ;;
    5) cas_run "show_link" ;;
    6) cas_run "recovery" ;;
    7) exit 0 ;;
    *) msg "${R}Pilihan salah${N}" ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-hy2

# ---------- cron: expire harian ----------
grep -q "m-hy2 --expire" /etc/cron.d/autoscript 2>/dev/null || \
  echo "10 0 * * * root /usr/local/sbin/m-hy2 --expire" >> /etc/cron.d/autoscript

# ---------- logrotate untuk log auth ----------
touch /var/log/cas-hy2-auth.log
if ! grep -q 'cas-hy2-auth.log' /etc/logrotate.d/cassanova 2>/dev/null; then
  cat > /etc/logrotate.d/cas-hy2 <<'LR'
/var/log/cas-hy2-auth.log {
    weekly
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
}
LR
fi

touch $ASD/db/hy2.db $ASD/db/hy2.trash
echo -e "${GRN}Modul Hysteria2 selesai.${NC}"
