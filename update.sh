#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - UPDATE
#  - Tambah/hapus akun tanpa restart Xray (Xray API)
#  - Check Users Login, Lock/Unlock, Recovery
#  - Limit IP (auto banned), Limit Bandwidth (kuota)
#  - Set Reduce/Time (durasi banned)
# =====================================================
SCVER="v1.20.0"   # diisi otomatis dari file 'version' saat rilis
GRN='\e[32m'; RED='\e[31m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
[[ ! -f /etc/autoscript/domain ]] && echo -e "${RED}Script belum terinstall. Jalankan install.sh dulu.${NC}" && exit 1

# ---- channel & snapshot (untuk update tanpa putus koneksi) ----
BRANCH=$(cat /etc/autoscript/channel 2>/dev/null); BRANCH=${BRANCH:-main}
BASE=https://raw.githubusercontent.com/amiercassanova-21/cassanova-tunneling/$BRANCH
export CAS_BASE=$BASE
XCFG=/usr/local/etc/xray/config.json
H_XRAY_OLD=$(md5sum $XCFG 2>/dev/null | cut -d' ' -f1)
H_NGX_OLD=$(cat /etc/nginx/conf.d/*.conf 2>/dev/null | md5sum | cut -d' ' -f1)
# restart aman: saat auto update, restart yang memutus koneksi ditunda ke jam 04:00
svc_restart(){
  if [[ "$CAS_AUTO" == 1 ]] && systemctl is-active --quiet "$1"; then
    echo "systemctl restart $1" | at 04:00 >/dev/null 2>&1
    echo "$1" >> /etc/autoscript/pending-restart
  else
    systemctl restart "$1"
  fi
}
export -f svc_restart

echo -e "${GRN}[1/7] Paket tambahan...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt install -y jq at logrotate uuid-runtime >/dev/null 2>&1
systemctl enable --now atd cron >/dev/null 2>&1
mkdir -p /usr/local/lib/autoscript /etc/autoscript/db /etc/autoscript/usage /var/log/xray

# =====================================================
#  LIBRARY
# =====================================================
echo -e "${GRN}[2/7] Library...${NC}"
cat > /usr/local/lib/autoscript/lib.sh <<'EOF'
# PATH lengkap: cron memakai PATH minimal, sedangkan xray ada di /usr/local/bin.
# Tanpa baris ini, xray-guard gagal diam-diam dari cron (kuota & limit IP tidak jalan).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
# Cassanova Tunneling - shared library
[[ -f /usr/local/lib/autoscript/notify.sh ]] && . /usr/local/lib/autoscript/notify.sh
type cas_notify &>/dev/null || cas_notify(){ :; }
type cas_notify_raw &>/dev/null || cas_notify_raw(){ :; }
type cas_notify_quote &>/dev/null || cas_notify_quote(){ :; }
R='\e[31m'; G='\e[32m'; Y='\e[33m'; B='\e[34m'; C='\e[36m'; P='\e[35m'; W='\e[1;97m'; O='\e[38;5;208m'; N='\e[0m'
BGB='\e[44m'; BG='\e[41m'
CFG=/usr/local/etc/xray/config.json
ASD=/etc/autoscript
API=127.0.0.1:10085
PROTOS="vless vmess trojan"
SCNAME="CASSANOVA TUNNELING"   # identitas script (tampil di depan, tidak bisa diubah buyer)

# ---- Brand Name ala Potato ----
# brand      : teks brand (huruf kecil/angka/-, maks 12)
# brand_uuid : on/off -> UUID/password acak diawali brand   (Brand Name for [password/uuid])
# brand_user : on/off -> username trial diawali brand       (With User for [user trial])
brand_txt(){ local b; b=$(cat $ASD/brand 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-'); echo "${b:0:12}"; }
gen_id(){ # UUID/password acak
  local b; b=$(brand_txt)
  if [[ "$(cat $ASD/brand_uuid 2>/dev/null)" == on && -n "$b" ]]; then
    echo "${b}-$(tr -dc a-z0-9 </dev/urandom | head -c 12)"
  else uuidgen; fi
}
gen_trial_user(){
  local b; b=$(brand_txt)
  if [[ "$(cat $ASD/brand_user 2>/dev/null)" == on && -n "$b" ]]; then
    echo "${b}-trial$(tr -dc a-z0-9 </dev/urandom | head -c4)"
  else echo "trial$(tr -dc a-z0-9 </dev/urandom | head -c4)"; fi
}
is_trial(){ [[ "$1" == *trial* ]]; }
# Format DB: user exp id limit_ip quota_gb status
# status: active | locked | quota | banned:<epoch>

proto_path(){ case $1 in vless) echo /vless ;; vmess) echo /vmess ;; trojan) echo /trojan-ws ;; esac; }

lock_db(){ exec 9>/run/autoscript.lock; flock -w 20 9; }
unlock_db(){ flock -u 9 2>/dev/null; exec 9>&-; }

db_get(){ awk -v u="$2" '$1==u' "$ASD/db/$1.db"; }
db_field(){ awk -v u="$2" -v f="$3" '$1==u{print $f}' "$ASD/db/$1.db"; }
db_set(){ awk -v u="$2" -v f="$3" -v v="$4" '$1==u{$f=v}1' "$ASD/db/$1.db" > "$ASD/db/.$1.tmp" && mv "$ASD/db/.$1.tmp" "$ASD/db/$1.db"; }
db_del(){ awk -v u="$2" '$1!=u' "$ASD/db/$1.db" > "$ASD/db/.$1.tmp" && mv "$ASD/db/.$1.tmp" "$ASD/db/$1.db"; }
user_exists(){ [[ -n "$(db_get $1 "$2")" ]]; }

make_client(){
  case $1 in
    vless)  jq -nc --arg id "$3" --arg e "$1.$2" '{id:$id,email:$e}' ;;
    vmess)  jq -nc --arg id "$3" --arg e "$1.$2" '{id:$id,alterId:0,email:$e}' ;;
    trojan) jq -nc --arg id "$3" --arg e "$1.$2" '{password:$id,email:$e}' ;;
  esac
}

# Tambah user ke config + Xray yang sedang jalan (tanpa restart)
xray_add(){ # proto user id  (ws + grpc + httpupgrade)
  local p=$1 e="$1.$2" c t
  c=$(make_client "$1" "$2" "$3")
  jq --arg p "$p-" --arg e "$e" --argjson c "$c" \
    '(.inbounds[]|select(.tag|startswith($p)).settings.clients) |= (map(select(.email!=$e)) + [$c])' \
    $CFG > $CFG.tmp && mv $CFG.tmp $CFG
  jq --arg p "$p-" --argjson c "$c" '{inbounds:[.inbounds[]|select(.tag|startswith($p))|.settings.clients=[$c]]}' $CFG > /tmp/cas-adu.json
  for t in $(jq -r --arg p "$p-" '.inbounds[]|select(.tag|startswith($p))|.tag' $CFG); do
    xray api rmu --server=$API -tag="$t" "$e" >/dev/null 2>&1
  done
  if ! xray api adu --server=$API /tmp/cas-adu.json >/dev/null 2>&1; then
    systemctl restart xray
  fi
  rm -f /tmp/cas-adu.json
}

# Hapus user dari config + Xray yang sedang jalan (tanpa restart)
xray_del(){ # proto user
  local p=$1 e="$1.$2" t had fail=0
  had=$(jq -r --arg p "$p-" --arg e "$e" '[.inbounds[]|select(.tag|startswith($p))|select(any(.settings.clients[]?; .email==$e))|.tag]|join(" ")' $CFG)
  jq --arg p "$p-" --arg e "$e" '(.inbounds[]|select(.tag|startswith($p)).settings.clients) |= map(select(.email!=$e))' \
    $CFG > $CFG.tmp && mv $CFG.tmp $CFG
  for t in $had; do
    xray api rmu --server=$API -tag="$t" "$e" >/dev/null 2>&1 || fail=1
  done
  [[ $fail == 1 ]] && systemctl restart xray
}

remove_account(){ # proto user  -> pindah ke trash (bisa di-recovery)
  local p=$1 u=$2 line st
  line=$(db_get $p "$u"); [[ -z "$line" ]] && return 1
  st=$(echo "$line" | awk '{print $6}')
  [[ "$st" == "active" ]] && xray_del $p "$u"
  is_trial "$u" || echo "$line $(date +%F)" >> $ASD/db/$p.trash
  db_del $p "$u"
  rm -f $ASD/usage/$p/$u
}

# hapus dari recovery akun yang sudah dihapus lebih dari 4 bulan (120 hari)
trash_prune(){
  local p lim; lim=$(date -d "-120 days" +%F)
  for p in $PROTOS; do
    [[ -f $ASD/db/$p.trash ]] || continue
    awk -v l="$lim" 'NF && $7>=l' $ASD/db/$p.trash > $ASD/db/.$p.trash && mv $ASD/db/.$p.trash $ASD/db/$p.trash
  done
}

expire_all(){
  local today p u exp list=""
  today=$(date +%F)
  for p in $PROTOS; do
    while read -r u exp _; do
      if [[ -n "$u" && "$exp" < "$today" ]]; then
        remove_account $p "$u"
        is_trial "$u" || list+="• ${p^^} <code>$u</code> (exp $exp)"$'\n'
      fi
    done < <(cat $ASD/db/$p.db)
  done
  trash_prune
  [[ -n "$list" ]] && cas_notify "⏰ <b>Akun Expired</b> (masuk Recovery)"$'\n'"$list"
}

# Kumpulkan pemakaian bandwidth per user (byte) dari Xray stats
usage_collect(){
  local name val e p u old
  xray api statsquery --server=$API -pattern "user>>>" -reset 2>/dev/null \
  | jq -r '.stat[]? | "\(.name) \(.value // 0)"' 2>/dev/null \
  | while read -r name val; do
      e=$(echo "$name" | awk -F'>>>' '{print $2}')
      [[ "$e" != *.* || -z "$val" || "$val" == "0" ]] && continue
      p=${e%%.*}; u=${e#*.}
      mkdir -p $ASD/usage/$p
      old=$(cat $ASD/usage/$p/$u 2>/dev/null || echo 0)
      echo $(( old + val )) > $ASD/usage/$p/$u
    done
}
usage_get(){ cat $ASD/usage/$1/$2 2>/dev/null || echo 0; }
hbytes(){ numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

# Output: "user ip" unik dari access log N menit terakhir
recent_ips(){ # $1 = rentang ke belakang dalam DETIK
  local LOG=/var/log/xray/access.log since
  [[ -f $LOG ]] || return 0
  since=$(date -d "@$(( $(date +%s) - ${1:-60} ))" '+%Y/%m/%d %H:%M:%S')
  tail -n 30000 $LOG | awk -v s="$since" 'substr($0,1,19)>=s' \
  | sed -nE 's/.* from (tcp:|udp:)?(\[[^]]+\]|[0-9.]+):[0-9]+ accepted .*email: ([^ ]+).*/\3 \2/p' \
  | sort -u
}
EOF

# =====================================================
#  GUARD (tiap menit): kuota, limit IP, auto unban
# =====================================================
cat > /usr/local/sbin/xray-guard <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
exec 8>/run/xray-guard.lock; flock -n 8 || exit 0
lock_db
now=$(date +%s)
BANMIN=$(cat $ASD/bantime 2>/dev/null || echo 15)
# berapa kali pelanggaran beruntun sebelum akun dikunci (default 2 = tahan rotasi IP seluler)
NEEDCONF=$(cat $ASD/ipconfirm 2>/dev/null); [[ "$NEEDCONF" =~ ^[1-9]$ ]] || NEEDCONF=2
usage_collect
COUNTS=$(recent_ips 60 | awk '{c[$1]++} END{for(u in c) print u, c[u]}')

for p in $PROTOS; do
  while read -r u exp id ipl q st; do
    [[ -z "$u" ]] && continue
    # auto unban
    if [[ "$st" == banned:* ]]; then
      if (( now >= ${st#banned:} )); then xray_add $p "$u" "$id"; db_set $p "$u" 6 active; fi
      continue
    fi
    [[ "$st" != "active" ]] && continue
    # kuota bandwidth
    if [[ "$q" =~ ^[0-9]+$ ]] && (( q > 0 )); then
      used=$(usage_get $p "$u")
      if (( used >= q * 1073741824 )); then xray_del $p "$u"; db_set $p "$u" 6 quota
        cas_notify "📛 <b>Kuota Habis</b>"$'\n'"${p^^} <code>$u</code> (${q}GB) dikunci"; continue; fi
    fi
    # limit IP (pakai konfirmasi beruntun: IP operator seluler sering berganti,
    # 1 perangkat bisa terbaca 2 IP sesaat. Kunci hanya jika pelanggaran menetap.)
    if [[ "$ipl" =~ ^[0-9]+$ ]] && (( ipl > 0 )); then
      n=$(echo "$COUNTS" | awk -v u="$p.$u" '$1==u{print $2}')
      SFILE=$ASD/ipstreak/$p.$u
      STREAK=0
      if [[ -z "$n" ]] || (( n <= ipl )); then
        rm -f "$SFILE"                       # aman -> hitungan beruntun direset
      else
        mkdir -p $ASD/ipstreak
        STREAK=$(( $(cat "$SFILE" 2>/dev/null || echo 0) + 1 ))
        echo "$STREAK" > "$SFILE"
      fi
      if [[ -n "$n" ]] && (( n > ipl )) && (( STREAK >= NEEDCONF )); then
        rm -f "$SFILE"
        xray_del $p "$u"; db_set $p "$u" 6 "banned:$(( now + BANMIN*60 ))"
        # daftar IP UNIK + waktu terakhir terlihat (bukan tiap baris log)
        iplist=$(tail -n 20000 /var/log/xray/access.log 2>/dev/null | sed -nE "s#^([0-9/]+ ([0-9:]+))[^ ]* from (tcp:|udp:)?(\\[[^]]+\\]|[0-9.]+):[0-9]+ accepted .*email: $p\\.$u\\b.*#\\4 \\2#p" | awk '{last[$1]=$2} END{for(i in last) print last[i]" "i}' | sort | tail -n 5)
        cas_notify_quote "Multi Login ${p^^}" "<pre>✓ $u
$iplist</pre><blockquote>Lock - $(date +%T)"$'\n'"Open - $(date -d "+$BANMIN min" +%T)</blockquote>"
      fi
    fi
  done < <(cat $ASD/db/$p.db)
done
unlock_db

# jaga access log tetap kecil (maks 50 MB)
LOG=/var/log/xray/access.log
[[ -f $LOG ]] && (( $(stat -c %s $LOG) > 52428800 )) && truncate -s 0 $LOG
exit 0
EOF

# =====================================================
#  MENU XRAY
# =====================================================
echo -e "${GRN}[3/7] Menu VLESS/VMESS/TROJAN...${NC}"
cat > /usr/local/sbin/m-xray <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
[[ -f /usr/local/lib/autoscript/notify.sh ]] && . /usr/local/lib/autoscript/notify.sh
PROTO=$1
case $PROTO in vless|vmess|trojan) ;; *) echo "Usage: m-xray vless|vmess|trojan"; exit 1 ;; esac
DB=$ASD/db/$PROTO.db
TRASH=$ASD/db/$PROTO.trash
DOMAIN=$(cat $ASD/domain)
WSPATH=$(proto_path $PROTO)
UP=${PROTO^^}

# ---- mode non-interaktif ----
if [[ "$2" == "--delete" && -n "$3" ]]; then lock_db; remove_account $PROTO "$3"; unlock_db; exit 0; fi
if [[ "$2" == "--expire" ]]; then lock_db; expire_all; unlock_db; exit 0; fi

LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
bar(){ echo -e "$LINE"; printf "${BGB}${W}%*s%*s${N}\n" $(( (36+${#1})/2 )) "$1" $(( 36-(36+${#1})/2 )) ""; echo -e "$LINE"; }
pause(){ echo; if [[ -n "$QUICK" ]]; then read -rp "$(echo -e "${P}Press Enter to Exit${N}")"; else read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; fi; }
msg(){ echo -e "$1"; sleep 2; }
num_ok(){ [[ "$1" =~ ^[0-9]+$ ]]; }

st_label(){
  case $1 in
    active)   echo -e "${G}ON${N}" ;;
    locked)   echo -e "${R}LOCK${N}" ;;
    quota)    echo -e "${R}QUOTA${N}" ;;
    banned:*) echo -e "${Y}BAN${N}" ;;
    *)        echo "$1" ;;
  esac
}

mk_link(){ # net(ws|up|grpc|reality) tls(1|0)  -> pakai variabel ID & REM
  local port sec path t qs j tlsv
  if [[ $1 == reality ]]; then
    local rp rd rpub rsid
    rp=$(cat $ASD/reality_port 2>/dev/null | tr -d '[:space:]')
    rd=$(cat $ASD/reality_dest 2>/dev/null | tr -d '[:space:]')
    rpub=$(cat $ASD/reality_pub 2>/dev/null | tr -d '[:space:]')
    rsid=$(cat $ASD/reality_sid 2>/dev/null | tr -d '[:space:]')
    echo "vless://$ID@$DOMAIN:$rp?encryption=none&security=reality&type=tcp&headerType=none&fp=chrome&sni=$rd&pbk=$rpub&sid=$rsid#$REM"
    return
  fi
  [[ $2 == 1 ]] && { port=443; sec=tls; tlsv=tls; } || { port=80; sec=none; tlsv=""; }
  case $1 in
    ws)   t=ws;          path=$WSPATH ;;
    up)   t=httpupgrade; path="/up$PROTO" ;;
    grpc) t=grpc;        path="$PROTO-grpc" ;;
  esac
  if [[ $PROTO == vmess ]]; then
    j=$(jq -nc --arg ps "$REM" --arg a "$DOMAIN" --arg id "$ID" --arg port "$port" --arg net "$t" --arg p "$path" \
         --arg tls "$tlsv" --arg ty "$([[ $1 == grpc ]] && echo gun || echo none)" \
         '{v:"2",ps:$ps,add:$a,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:$ty,host:$a,path:$p,tls:$tls,sni:(if $tls=="tls" then $a else "" end)}')
    echo "vmess://$(echo -n "$j" | base64 -w0)"; return
  fi
  if [[ $1 == grpc ]]; then
    qs="mode=gun&security=$sec"; [[ $PROTO == vless ]] && qs+="&encryption=none"; qs+="&type=grpc&serviceName=$path"
  else
    qs="path=${path//\//%2F}&security=$sec"; [[ $PROTO == vless ]] && qs+="&encryption=none"; qs+="&host=$DOMAIN&type=$t"
  fi
  [[ $2 == 1 ]] && qs+="&sni=$DOMAIN"
  echo "$PROTO://$ID@$DOMAIN:$port?$qs#$REM"
}

show_account(){ # user id exp [notif] [judul]  ; notif -> kirim ke Telegram (akun penuh)
  local ipl q CITY ISP notif=$4 ntitle=${5:-"$UP Dibuat"} L2="${B}────────────────────────────────────${N}"
  local idlabel="id"; [[ $PROTO == trojan ]] && idlabel="Password"
  REM=$1; ID=$2
  local exp=$3
  ipl=$(db_field $PROTO "$REM" 4); q=$(db_field $PROTO "$REM" 5)
  CITY=$(jq -r '.city // "-"' $ASD/ipinfo.json 2>/dev/null)
  ISP=$(jq -r '.org // "-"' $ASD/ipinfo.json 2>/dev/null | sed 's/^AS[0-9]* //')
  row(){ printf " ${G}%-14s${N}: %b\n" "$1" "$2"; }
  sec(){ echo -e "$L2"; printf "${Y}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$L2"; }
  if [[ "$notif" == notif || "$notif" == quote ]]; then
    local BR="────────────────────────────────"
    local info="Remarks       : $REM
CITY          : $CITY
ISP           : $ISP
Domain        : $DOMAIN
Port TLS      : 443,8443
Port none TLS : 80,8080
Port any      : 2052,2053,8880
$(printf '%-13s' "$idlabel") : $ID"
    [[ $PROTO == vless ]] && info+=$'\n'"Encryption    : none"
    [[ $PROTO == vmess ]] && info+=$'\n'"alterId       : 0"$'\n'"Security      : auto"
    info+=$'\n'"Network       : ws,grpc,upgrade
Path ws       : $WSPATH
serviceName   : $PROTO-grpc
Path upgrade  : /up$PROTO
Limit IP      : $([[ "$ipl" == 0 || -z "$ipl" ]] && echo Unlimited || echo "$ipl IP")
Kuota         : $([[ "$q" == 0 || -z "$q" ]] && echo Unlimited || echo "$q GB")
Expired On    : $exp"
    # tiap bagian dibungkus kotak sendiri supaya di Telegram bisa disalin satu per satu
    blk(){ printf '%s\n%s\n<code>%s</code>' "$BR" "$1" "$2"; }
    local rbl=""
    [[ $PROTO == vless && -s $ASD/reality_pub ]] && \
      rbl=$'\n'"$(blk "🛡 <b>$UP REALITY</b>" "$(mk_link reality 1)")"
    local body="📋 <b>RINCIAN AKUN</b>
<pre>$info</pre>
$(blk "🔐 <b>$UP WS TLS</b>"          "$(mk_link ws 1)")
$(blk "🔓 <b>$UP WS NON-TLS</b>"      "$(mk_link ws 0)")
$(blk "⚡ <b>$UP GRPC</b>"                "$(mk_link grpc 1)")
$(blk "🆙 <b>$UP UPGRADE TLS</b>"     "$(mk_link up 1)")
$(blk "🆙 <b>$UP UPGRADE NON-TLS</b>" "$(mk_link up 0)")$rbl
$BR
🔎 <b>CEK MASA AKTIF</b>
<code>https://$DOMAIN/cek</code>
Buka link di atas, pilih $UP, lalu tempel $idlabel akun ini
untuk melihat sisa masa aktif dan kuota.
$BR
<i>Ketuk tiap kotak untuk menyalin satu per satu.</i>"
    local icon="🆕"; [[ "$notif" == quote ]] && icon="♻️"
    cas_notify_raw "$icon <b>$ntitle</b>"$'\n'"$body"
  fi
  clear
  echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#UP}+8)/2 )) "$UP ACCOUNT"; echo -e "$LINE"
  row "Remarks" "${Y}$REM${N}"
  row "CITY" "$CITY"
  row "ISP" "$ISP"
  row "Domain" "$DOMAIN"
  row "Port TLS" "443,8443"
  row "Port none TLS" "80,8080"
  row "Port any" "2052,2053,8880"
  if [[ $PROTO == trojan ]]; then row "Password" "$ID"; else row "id" "$ID"; fi
  [[ $PROTO == vless ]] && row "Encryption" "none"
  [[ $PROTO == vmess ]] && { row "alterId" "0"; row "Security" "auto"; }
  row "Network" "ws,grpc,upgrade"
  row "Path ws" "$WSPATH"
  row "serviceName" "$PROTO-grpc"
  row "Path upgrade" "/up$PROTO"
  row "Limit IP" "$([[ "$ipl" == 0 || -z "$ipl" ]] && echo Unlimited || echo "$ipl IP")"
  row "Kuota" "$([[ "$q" == 0 || -z "$q" ]] && echo Unlimited || echo "$q GB")"
  row "Expired On" "${Y}$exp${N}"
  sec "$UP WS TLS";          mk_link ws 1
  sec "$UP WS NO TLS";       mk_link ws 0
  sec "$UP GRPC";            mk_link grpc 1
  sec "$UP Upgrade TLS";     mk_link up 1
  sec "$UP Upgrade NO TLS";  mk_link up 0
  if [[ $PROTO == vless && -s $ASD/reality_pub ]]; then sec "$UP REALITY"; mk_link reality 1; fi
  sec "CEK MASA AKTIF"
  echo -e " ${C}https://$DOMAIN/cek${N}"
  echo
  echo -e " ${G}Cara pakai (untuk pelanggan):${N}"
  echo -e " 1. Buka link di atas lewat browser HP"
  echo -e " 2. Pilih jenis akun: ${Y}$UP${N}"
  echo -e " 3. Tempel ${Y}$idlabel${N} akun ini di kolom isian"
  echo -e " Akan tampil sisa masa aktif, kuota & limit IP."
  echo -e "$L2"
}

check_config(){
  header "CHECK CONFIG & AKUN"
  local cfgout cfgok=1
  cfgout=$(xray run -test -config $CFG 2>&1) || cfgok=0
  printf " ${G}%-13s${N}: %b\n" "Config Xray" "$([[ $cfgok == 1 ]] && echo "${G}OK${N}" || echo "${R}ERROR${N}")"
  printf " ${G}%-13s${N}: %b\n" "Xray"  "$(systemctl is-active --quiet xray  && echo "${G}running${N}" || echo "${R}mati${N}")"
  printf " ${G}%-13s${N}: %b\n" "Nginx" "$(systemctl is-active --quiet nginx && echo "${G}running${N}" || echo "${R}mati${N}")"
  printf " ${G}%-13s${N}: %b\n" "Cek Akun" "${C}https://$DOMAIN/cek${N}"
  if [[ $cfgok == 0 ]]; then
    echo -e "$LINE"
    echo -e " ${R}Detail error:${N}"
    echo "$cfgout" | grep -v "^Xray \|^A unified\|\[Warning\]\|\[Info\]" | tail -5
  fi
  echo -e "$LINE"
  echo -e " ${G}Pilih akun untuk melihat detail:${N}"
  echo
  pick_user all || { pause; return; }
  local exp id ipl q st used pct left
  exp=$(db_field $PROTO "$U" 2); id=$(db_field $PROTO "$U" 3)
  ipl=$(db_field $PROTO "$U" 4); q=$(db_field $PROTO "$U" 5); st=$(db_field $PROTO "$U" 6)
  used=$(usage_get $PROTO "$U")
  local today0; today0=$(date -d "$(date +%F)" +%s)
  left=$(( ( $(date -d "$exp" +%s 2>/dev/null || echo "$today0") - today0 ) / 86400 ))
  local expinfo
  if [[ "$exp" < "$(date +%F)" ]]; then expinfo="${R}EXPIRED ($(( -left )) hari lalu)${N}"
  elif [[ $left -eq 0 ]]; then expinfo="${Y}habis hari ini${N}"
  else expinfo="($left hari lagi)"; fi
  header "DETAIL AKUN $UP"
  printf " ${G}%-13s${N}: %b\n" "Username" "${Y}$U${N}"
  printf " ${G}%-13s${N}: %b\n" "Protokol" "$UP"
  printf " ${G}%-13s${N}: %b\n" "Status" "$(st_label "$st")"
  printf " ${G}%-13s${N}: %b\n" "Expired" "${Y}$exp${N} $expinfo"
  printf " ${G}%-13s${N}: %b\n" "Limit IP" "$([[ "$ipl" == 0 || -z "$ipl" ]] && echo Unlimited || echo "$ipl IP")"
  if [[ "$q" == 0 || -z "$q" ]]; then
    printf " ${G}%-13s${N}: %b\n" "Kuota" "$(hbytes $used) / Unlimited"
  else
    pct=$(( used * 100 / (q * 1073741824) ))
    printf " ${G}%-13s${N}: %b\n" "Kuota" "$(hbytes $used) / ${q} GB (${pct}%)"
  fi
  printf " ${G}%-13s${N}: %b\n" "$([[ $PROTO == trojan ]] && echo Password || echo id)" "$id"
  echo -e "$LINE"
  echo -e " ${G}Pelanggan bisa cek sendiri di:${N}"
  echo -e " ${C}https://$DOMAIN/cek${N}"
  echo -e " (pilih $UP, tempel $([[ $PROTO == trojan ]] && echo Password || echo id) di atas)"
  echo -e "$LINE"
  pause
}

list_users(){ # $1 = all | active | inactive
  local f=${1:-all} title="LIST $UP USERS"
  [[ $f == active ]] && title="$UP USER AKTIF"
  [[ $f == inactive ]] && title="$UP USER TERKUNCI"
  header "$title"
  printf " ${G}%-3s %-12s %-10s %-3s %-12s %s${N}\n" "NO" "USER" "EXPIRED" "IP" "USED/QUOTA" "ST"
  local i=0 u exp id ipl q st qd
  while read -r u exp id ipl q st; do
    [[ -z "$u" ]] && continue
    [[ $f == active && "$st" != active ]] && continue
    [[ $f == inactive && "$st" == active ]] && continue
    i=$((i+1))
    [[ "$q" == 0 ]] && qd="$(hbytes $(usage_get $PROTO "$u"))/~" || qd="$(hbytes $(usage_get $PROTO "$u"))/${q}G"
    printf " %-3s %-12s %-10s %-3s %-12s %b\n" "$i" "$u" "$exp" "$([[ "$ipl" == 0 ]] && echo - || echo "$ipl")" "$qd" "$(st_label "$st")"
  done < "$DB"
  LISTED=$i
  if [[ $i == 0 ]]; then
    case $f in active) echo -e " ${Y}Tidak ada user aktif${N}";; inactive) echo -e " ${Y}Tidak ada user yang terkunci${N}";; *) echo -e " ${Y}Belum ada akun${N}";; esac
  fi
  echo -e "$LINE"
  echo -e " ${G}Total : ${Y}$i${G} akun${N}"
  echo -e "$LINE"
}

confirm_pick(){ # konfirmasi pilihan user (y/n)
  echo
  echo -e " ${G}You Choose ${Y}➤ ${O}$U${N}"
  echo
  local yn; read -rp "$(echo -e " ${G}Correct (y/n) ? ${N}")" yn
  [[ "$yn" == y || "$yn" == Y ]] && return 0
  msg " ${Y}Dibatalkan${N}"; return 1
}
done_box(){ # judul lalu pasangan label nilai
  local t=$1; shift
  echo; echo -e " ${G}$t${N}"; echo
  while (( $# >= 2 )); do printf " ${G}%-7s${N}: ${O}%s${N}\n" "$1" "$2"; shift 2; done
  echo
}

pick_user(){ # $1 = all | active | inactive ; hasil di variabel U
  local f=${1:-all} inp
  list_users "$f"
  [[ $LISTED == 0 ]] && { pause; return 1; }
  read -rp "Nomor / Username : " inp
  if [[ "$inp" =~ ^[0-9]+$ ]]; then
    U=$(awk -v n="$inp" -v f="$f" 'NF{ if(f=="active" && $6!="active") next; if(f=="inactive" && $6=="active") next; i++; if(i==n){print $1; exit} }' "$DB")
  else
    U=$inp
  fi
  [[ -n "$U" && -n "$(db_get $PROTO "$U")" ]] && return 0
  msg "${R}User tidak ditemukan${N}"; return 1
}

create(){
  local custom=$1 u id d ipl q exp
  header "CREATE $UP"
  read -rp "Username : " u
  [[ ! "$u" =~ ^[a-zA-Z0-9_-]{3,20}$ ]] && { msg "${R}Username 3-20 karakter: huruf, angka, - dan _${N}"; return; }
  user_exists $PROTO "$u" && { msg "${R}Username $u sudah ada di $UP${N}"; return; }
  if [[ "$custom" == 1 ]]; then read -rp "UUID/Password : " id; else id=$(gen_id); fi
  [[ -z "$id" || "$id" =~ [[:space:]] ]] && { msg "${R}UUID tidak valid${N}"; return; }
  read -rp "Masa aktif (hari) : " d;           num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Limit IP (0 = unlimited) [0] : " ipl; ipl=${ipl:-0}; num_ok "$ipl" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Kuota GB (0 = unlimited) [0] : " q;   q=${q:-0};     num_ok "$q"   || { msg "${R}Harus angka${N}"; return; }
  exp=$(date -d "+$d days" +%F)
  lock_db
  echo "$u $exp $id $ipl $q active" >> "$DB"
  xray_add $PROTO "$u" "$id"
  rm -f $ASD/usage/$PROTO/$u
  unlock_db
  show_account "$u" "$id" "$exp" notif; pause
}

trial(){
  local u id m exp
  u=$(gen_trial_user)
  read -rp "Durasi trial (menit) [60] : " m; m=${m:-60}; num_ok "$m" || { msg "${R}Harus angka${N}"; return; }
  id=$(gen_id); exp=$(date -d "+$m minutes" +%F)
  lock_db
  echo "$u $exp $id 1 0 active" >> "$DB"
  xray_add $PROTO "$u" "$id"
  unlock_db
  echo "/usr/local/sbin/m-xray $PROTO --delete $u" | at now + $m minutes >/dev/null 2>&1
  show_account "$u" "$id" "$m menit" notif; pause
}

delete(){
  if [[ -n "$PRESET_U" ]]; then U="$PRESET_U"; PRESET_U=""; echo -e " ${G}Akun : ${Y}$U${N}"; confirm_pick || return
  else pick_user || return; confirm_pick || return; fi
  local dexp=$(db_field $PROTO "$U" 2)
  lock_db; remove_account $PROTO "$U"; unlock_db
  cas_notify_quote "Delete User" "<pre>User    : $U
Expired : $dexp
Type    : $PROTO</pre>"
  done_box "DELETE Successfully" "USER" "$U" "STATUS" "DELETED (masuk Recovery)"; pause
}

renew(){
  local d base today new st
  if [[ -n "$PRESET_U" ]]; then U="$PRESET_U"; PRESET_U=""; echo -e " ${G}Akun : ${Y}$U${N}"
  else pick_user || return; confirm_pick || return; fi
  read -rp "Tambah masa aktif (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  lock_db
  base=$(db_field $PROTO "$U" 2); today=$(date +%F)
  [[ "$base" < "$today" ]] && base=$today
  new=$(date -d "$base +$d days" +%F)
  db_set $PROTO "$U" 2 "$new"
  # reset kuota: hapus catatan lokal + kosongkan counter di Xray agar benar-benar dari nol
  rm -f $ASD/usage/$PROTO/$U
  xray api statsquery --server=$API -pattern "user>>>$PROTO.$U>>>" -reset >/dev/null 2>&1
  st=$(db_field $PROTO "$U" 6)
  if [[ "$st" == "quota" ]]; then xray_add $PROTO "$U" "$(db_field $PROTO "$U" 3)"; db_set $PROTO "$U" 6 active; fi
  unlock_db
  cas_notify_quote "Renew/Extend User" "<pre>User       : $U
Added      : $d Days
Expires on : $new
Type       : $PROTO</pre>"
  done_box "RENEW Successfully" "USER" "$U" "ADDED" "$d Days" "EXPIRED" "$new"; pause
}

modify_uuid(){
  local id st
  pick_user || return
  read -rp "UUID baru (kosongkan = acak) : " id; id=${id:-$(gen_id)}
  [[ "$id" =~ [[:space:]] ]] && { msg "${R}UUID tidak valid${N}"; return; }
  lock_db
  db_set $PROTO "$U" 3 "$id"
  st=$(db_field $PROTO "$U" 6)
  [[ "$st" == "active" ]] && xray_add $PROTO "$U" "$id"
  unlock_db
  show_account "$U" "$id" "$(db_field $PROTO "$U" 2)"; pause
}

check_login(){
  local data u exp id ipl q st ips n found=0 no=0
  header "$UP LOGIN (5 MENIT)"
  data=$(recent_ips 300)
  while read -r u exp id ipl q st; do
    [[ -z "$u" ]] && continue
    ips=$(echo "$data" | awk -v u="$PROTO.$u" '$1==u{print $2}')
    [[ -z "$ips" ]] && continue
    n=$(echo "$ips" | grep -c .); found=1; no=$((no+1))
    printf " %-3s ${Y}%-14s${N} %s IP  (limit: %s)\n" "$no." "$u" "$n" "$([[ "$ipl" == 0 ]] && echo - || echo "$ipl")"
    echo "$ips" | sed 's/^/    - /'
  done < "$DB"
  [[ $found == 0 ]] && echo -e " ${Y}Tidak ada user online${N}"
  echo -e "$LINE"
  echo -e " ${G}Total online : ${Y}$no${G} akun${N}"
  echo -e "$LINE"; pause
}

lock_user(){
  pick_user active || return
  confirm_pick || return
  lock_db
  [[ "$(db_field $PROTO "$U" 6)" == "active" ]] && xray_del $PROTO "$U"
  db_set $PROTO "$U" 6 locked
  unlock_db
  cas_notify_quote "Lock $UP (Manual)" "<pre>User : $U
Lock : $(date +%T)</pre>"
  done_box "LOCK Successfully" "USER" "$U" "STATUS" "LOCK"; pause
}

unlock_user(){
  local st exp
  pick_user inactive || return
  confirm_pick || return
  st=$(db_field $PROTO "$U" 6); exp=$(db_field $PROTO "$U" 2)
  [[ "$st" == "active" ]] && { msg "${Y}User $U sudah aktif${N}"; return; }
  [[ "$exp" < "$(date +%F)" ]] && { msg "${R}Akun sudah expired, gunakan Renew${N}"; return; }
  lock_db
  [[ "$st" == "quota" ]] && rm -f $ASD/usage/$PROTO/$U
  xray_add $PROTO "$U" "$(db_field $PROTO "$U" 3)"
  db_set $PROTO "$U" 6 active
  unlock_db
  cas_notify_quote "Unlock $UP" "<pre>User : $U
Open : $(date +%T)</pre>"
  done_box "UNLOCKED Successfully" "USER" "$U" "STATUS" "UNLOCKED"; pause
}

recovery(){
  local i=0 u exp id ipl q st del d new line inp v names=() quiet=""
  [[ -n "$PRESET_U" ]] && quiet=1
  header "RECOVERY $UP"
  [[ -z "$quiet" ]] && printf " ${G}%-3s %-16s %-12s${N}\n" "NO" "USERNAME" "DIHAPUS"
  while read -r u exp id ipl q st del; do
    [[ -z "$u" ]] && continue; i=$((i+1)); names+=("$u")
    [[ -z "$quiet" ]] && printf " %-3s %-16s %-12s\n" "$i" "$u" "$del"
  done < <(tac "$TRASH" 2>/dev/null)
  [[ $i == 0 ]] && { echo -e " ${Y}Tidak ada akun yang bisa dipulihkan${N}"; pause; return; }
  if [[ -z "$quiet" ]]; then
    echo -e "$LINE"
    echo -e " ${G}Total : ${Y}$i${G} akun${N}"
    echo -e "$LINE"
  fi
  if [[ -n "$PRESET_U" ]]; then inp="$PRESET_U"; PRESET_U=""; echo -e " ${G}Akun : ${Y}$inp${N}"
  else read -rp "Nomor / Username : " inp; fi
  if [[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= i )); then u=${names[$((inp-1))]}; else u=$inp; fi
  line=$(awk -v u="$u" '$1==u' "$TRASH" | tail -n1)
  [[ -z "$line" ]] && { msg "${R}User tidak ada di recovery${N}"; return; }
  user_exists $PROTO "$u" && { msg "${R}Username $u masih aktif di $UP. Hapus/ubah akun itu dulu.${N}"; return; }
  read -r u exp id ipl q st del <<< "$line"
  ipl=${ipl:-0}; q=${q:-0}
  read -rp "Masa aktif baru (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Limit IP (0 = unlimited) [$ipl] : " v; v=${v:-$ipl}; num_ok "$v" || { msg "${R}Harus angka${N}"; return; }; ipl=$v
  read -rp "Kuota GB (0 = unlimited) [$q] : " v;   v=${v:-$q};   num_ok "$v" || { msg "${R}Harus angka${N}"; return; }; q=$v
  new=$(date -d "+$d days" +%F)
  lock_db
  echo "$u $new $id $ipl $q active" >> "$DB"
  awk -v u="$u" '$1!=u' "$TRASH" > "$TRASH.tmp" && mv "$TRASH.tmp" "$TRASH"
  xray_add $PROTO "$u" "$id"
  unlock_db
  show_account "$u" "$id" "$new" quote "$UP Dipulihkan"; pause
}

edit_field(){ # field(4=ip,5=quota) all(0/1)
  local f=$1 all=$2 label v st used
  [[ $f == 4 ]] && label="Limit IP (0 = unlimited)" || label="Kuota GB (0 = unlimited)"
  if [[ $all == 1 ]]; then list_users; else pick_user || return; fi
  read -rp "$label : " v; num_ok "$v" || { msg "${R}Harus angka${N}"; return; }
  lock_db
  if [[ $all == 1 ]]; then
    awk -v f="$f" -v v="$v" 'NF{$f=v}1' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
    TARGETS=$(awk '{print $1}' "$DB")
  else
    db_set $PROTO "$U" "$f" "$v"; TARGETS=$U
  fi
  # buka otomatis akun yang terkunci kuota bila kuota baru mencukupi
  if [[ $f == 5 ]]; then
    for u in $TARGETS; do
      st=$(db_field $PROTO "$u" 6); used=$(usage_get $PROTO "$u")
      if [[ "$st" == "quota" ]] && { (( v == 0 )) || (( used < v * 1073741824 )); }; then
        xray_add $PROTO "$u" "$(db_field $PROTO "$u" 3)"; db_set $PROTO "$u" 6 active
      fi
    done
  fi
  unlock_db
  echo -e "${G}Berhasil disimpan${N}"; pause
}

# ---- perintah cepat dari terminal (addvless / renewvless <kode> / dst) ----
# $3 boleh username ATAU uuid/password akun
find_acc(){ # $1=kode  $2=file (default DB) -> cetak username
  local k="$1" f="${2:-$DB}"
  [[ -z "$k" || ! -s "$f" ]] && return 1
  awk -v k="$k" '$1==k{print $1; ok=1; exit} END{exit !ok}' "$f" && return 0
  awk -v k="$k" '$3==k{print $1; ok=1; exit} END{exit !ok}' "$f"
}
case "$2" in
  --add) QUICK=1; create 0; exit 0 ;;
  --renew|--del|--recovery)
    QUICK=1
    src="$DB"; [[ "$2" == "--recovery" ]] && src="$TRASH"
    if [[ -z "$3" ]]; then
      echo -e "${R}Kode akun belum diisi.${N}"
      echo -e "Contoh: ${G}${2#--}${PROTO} namaakun${N}  atau pakai UUID"
      exit 1
    fi
    PRESET_U=$(find_acc "$3" "$src")
    if [[ -z "$PRESET_U" ]]; then
      echo -e "${R}Akun '$3' tidak ditemukan di ${UP}$([[ "$2" == "--recovery" ]] && echo " (daftar recovery)")${N}"
      exit 1
    fi
    case "$2" in
      --renew)    renew ;;
      --del)      delete ;;
      --recovery) recovery ;;
    esac
    exit 0 ;;
esac


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
  echo -e "$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-17 or x] : ${N}")" opt
  case $opt in
    1) create 0 ;;
    2) create 1 ;;
    3) trial ;;
    4) delete ;;
    5) renew ;;
    6) modify_uuid ;;
    7) check_login ;;
    8) list_users; pause ;;
    9) lock_user ;;
    10) unlock_user ;;
    11) check_config ;;
    12) recovery ;;
    13) edit_field 4 0 ;;
    14) edit_field 4 1 ;;
    15) edit_field 5 0 ;;
    16) edit_field 5 1 ;;
    17) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
    *) msg "${R}Pilihan salah${N}" ;;
  esac
done
EOF

# =====================================================
#  MENU UTAMA
# =====================================================
echo -e "${GRN}[4/7] Menu utama...${NC}"
cat > /usr/local/sbin/menu <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BRAND=$(cat $ASD/brand); DOMAIN=$(cat $ASD/domain); VER=$(cat $ASD/version)
WD=44
center(){ local t="$1"; local l=$(( (WD-${#t})/2 )); local r=$(( WD-${#t}-l )); printf "%*s%s%*s" $l "" "$t" $r ""; }
top(){ echo -e "${B}┌$(printf '─%.0s' $(seq 1 $((WD+2))))┐${N}"; }
bot(){ echo -e "${B}└$(printf '─%.0s' $(seq 1 $((WD+2))))┘${N}"; }
row(){ printf "${B}│${N} ${G}%-8s${N}: %s\n" "$1" "$2"; }
sep(){ echo -e "${B}│${N} ${P}$(printf '─%.0s' $(seq 1 36))${N}"; }
st(){ systemctl is-active --quiet "$1" && echo -e "${Y}ON${N}" || echo -e "${R}OFF${N}"; }

dashboard(){
  clear
  . /etc/os-release
  local I=$ASD/ipinfo.json F V
  local CITY=$(jq -r '.city // "-"' $I 2>/dev/null)
  local ISP=$(jq -r '.org // "-"' $I 2>/dev/null | sed 's/^AS[0-9]* //')
  local IP=$(jq -r '.ip // "-"' $I 2>/dev/null)
  local RAM=$(free -m | awk '/Mem:/{print $2"M"}')
  local SWAP=$(free -m | awk '/Swap:/{print $2"M"}')
  local UPT=$(uptime -p | sed 's/up //')
  V=$(vnstat --oneline 2>/dev/null)
  if [[ "$V" == 1\;* ]]; then IFS=';' read -ra F <<< "$V"; else F=(- - - - - - - - - - - -); fi

  top; echo -e "${B}│${N} ${BG}${W}$(center "$SCNAME")${N} ${B}│${N}"; bot
  top
  row "OS" "$PRETTY_NAME"; row "RAM" "$RAM"; row "SWAP" "$SWAP"
  row "CITY" "$CITY"; row "ISP" "$ISP"
  printf "${B}│${N} ${G}%-8s${N}: ${C}%s${N}\n" "IP" "$IP"
  printf "${B}│${N} ${G}%-8s${N}: ${C}%s${N}\n" "DOMAIN" "$DOMAIN"
  row "UPTIME" "$UPT"
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
  local c1 c2 c3
  c1=$(grep -c . $ASD/db/vmess.db); c2=$(grep -c . $ASD/db/vless.db); c3=$(grep -c . $ASD/db/trojan.db)
  local cs; cs=$(grep -c . $ASD/db/ssh.db 2>/dev/null); [[ "$cs" =~ ^[0-9]+$ ]] || cs=0
  local row
  echo -e "      ${B}┌──────────────────────────────────┐${N}"
  echo -e "                ${G}LIST ACCOUNTS${N}"
  for row in "SSH/OPENVPN:$cs" "VMESS:$c1" "VLESS:$c2" "TROJAN:$c3"; do
    printf "        ${G}%-11s${N} : ${Y}%-3s${N} ${G}ACCOUNT${N}\n" "${row%%:*}" "${row##*:}"
  done
  echo -e "      ${B}└──────────────────────────────────┘${N}"
}

version_box(){
  echo -e "    ${B}┌──────────────────────────────────────┐${N}"
  local lclient lexp lleft
  lclient=$(cat $ASD/license_client 2>/dev/null); [[ -z "$lclient" ]] && lclient="$(hostname)"
  lexp=$(cat $ASD/license_exp 2>/dev/null)
  if [[ "$lexp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    lleft=$(( ( $(date -d "$lexp" +%s) - $(date +%s) ) / 86400 ))
    (( lleft < 0 )) && lleft=0
    lexp="$lexp (${lleft} hari)"
  else
    lexp="Lifetime"
  fi
  printf  "    ${B}│${N} ${G}%-12s${N}: ${O}%s${N}\n" "Version" "$VER" "Client Name" "$lclient" "Expiry In" "$lexp"
  echo -e "    ${B}└──────────────────────────────────────┘${N}"
}

# ---- Lisensi ----
CAS_SVC="xray cas-dropbear ws-ssh badvpn nginx"

lic_services_stop(){
  local sv
  for sv in $CAS_SVC; do systemctl stop "$sv" >/dev/null 2>&1; done
}
lic_services_start(){
  local sv
  for sv in $CAS_SVC; do systemctl start "$sv" >/dev/null 2>&1; done
}

# panggil: license_check [--enforce]
# --enforce: benar-benar stop/start layanan sesuai status (dipakai cron & renewsc)
license_check(){
  local enforce=0; [[ "$1" == "--enforce" ]] && enforce=1
  local url ip out out2
  url=$(cat $ASD/license_url 2>/dev/null); [[ -z "$url" ]] && return 0   # mode dev (tanpa lisensi)
  ip=$(jq -r '.ip // empty' $ASD/ipinfo.json 2>/dev/null)
  [[ -z "$ip" ]] && ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
  [[ -z "$ip" ]] && return 0
  out=$(curl -s --max-time 12 -G "$url/check" --data-urlencode "ip=$ip" 2>/dev/null)
  if [[ -z "$out" ]]; then
    # Server tak terjangkau. Tetap toleran terhadap gangguan sesaat, TAPI ada
    # batasnya: kalau gagal terus melewati masa tenggang, VPS tetap dikunci.
    # Tanpa batas ini, memblokir domain lisensi = pakai selamanya tanpa bayar.
    local gdays lastok now fails flimit
    gdays=$(cat $ASD/license_grace 2>/dev/null); [[ "$gdays" =~ ^[0-9]+$ ]] && (( gdays >= 1 )) || gdays=3
    now=$(date +%s)
    lastok=$(cat $ASD/license_ok_at 2>/dev/null); [[ "$lastok" =~ ^[0-9]+$ ]] || lastok=0
    (( lastok == 0 )) && { echo "$now" > $ASD/license_ok_at; return 0; }
    # hitungan kegagalan: tidak bisa dikelabui dengan memundurkan jam VPS
    fails=$(cat $ASD/license_fail 2>/dev/null); [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fails=$((fails+1)); echo "$fails" > $ASD/license_fail
    flimit=$(( gdays * 720 ))     # cron tiap 2 menit -> 720 kali per hari
    if (( fails >= flimit )) || (( now - lastok > gdays * 86400 )); then
      echo "expired" > $ASD/license_state
      if [[ $enforce == 1 ]]; then
        lic_services_stop
        cas_notify "⛔ <b>Layanan dihentikan</b>"$'\n'"Server lisensi tidak bisa dihubungi selama lebih dari $gdays hari."$'\n'"Pastikan VPS terhubung internet, lalu ketik <code>renewsc</code>. Bila perlu hubungi admin." 2>/dev/null
      fi
      return 1
    fi
    return 0
  fi

  if echo "$out" | grep -q '"licensed":true'; then
    echo "$out" | jq -r '.client // ""' > $ASD/license_client 2>/dev/null
    echo "$out" | jq -r '.exp // ""'    > $ASD/license_exp 2>/dev/null
    local prev=$(cat $ASD/license_state 2>/dev/null)
    echo "ok" > $ASD/license_state
    date +%s > $ASD/license_ok_at; echo 0 > $ASD/license_fail
    # kalau sebelumnya expired lalu kini aktif (baru diperpanjang) -> nyalakan lagi
    if [[ "$prev" == "expired" ]]; then lic_services_start; fi
    return 0
  fi

  if echo "$out" | grep -q '"licensed":false'; then
    # pengaman: cek sekali lagi sebelum benar-benar mematikan (hindari false-positive)
    sleep 3
    out2=$(curl -s --max-time 12 -G "$url/check" --data-urlencode "ip=$ip" 2>/dev/null)
    if ! echo "$out2" | grep -q '"licensed":false'; then return 0; fi
    echo "expired" > $ASD/license_state
    date +%s > $ASD/license_ok_at; echo 0 > $ASD/license_fail
    [[ $enforce == 1 ]] && lic_services_stop
    return 1
  fi
  return 0
}

license_gate(){
  # dipanggil di awal menu: kalau expired, tolak akses
  [[ "$(cat $ASD/license_state 2>/dev/null)" == "expired" ]] || return 0
  clear
  echo -e "${R}════════════════════════════════════${N}"
  echo -e "${R}        LISENSI TIDAK AKTIF         ${N}"
  echo -e "${R}════════════════════════════════════${N}"
  echo -e " Masa aktif lisensi VPS ini sudah habis."
  echo -e " Semua layanan VPN dinonaktifkan."
  echo -e ""
  echo -e " Hubungi admin untuk perpanjangan."
  echo -e " ${Y}Jika sudah diperpanjang, ketik: ${G}renewsc${N}"
  echo -e "${R}════════════════════════════════════${N}"
  echo; read -rp "Tekan Enter untuk keluar..."
  exit 0
}

coming(){ echo -e "\n${Y}Fitur ini dibuat di tahap berikutnya.${N}"; sleep 2; }

set_bantime(){
  local o m
  while true; do
    clear
    echo -e "${B}════════════════════════════════════${N}"
    printf "${P}%*s${N}\n" $(( (36+${#SCNAME})/2 )) "$SCNAME"
    echo -e "${B}════════════════════════════════════${N}\n"
    local cf; cf=$(cat $ASD/ipconfirm 2>/dev/null); [[ "$cf" =~ ^[1-9]$ ]] || cf=2
    echo -e "${G}Time Banned Active : ${O}$(cat $ASD/bantime 2>/dev/null || echo 15)m:0s${N}"
    echo -e "${G}Sensitivitas Lock  : ${O}${cf}x$([[ $cf == 1 ]] && echo " (ketat)" || echo " (toleran IP seluler)")${N}"
    echo -e "${Y}(lama akun dikunci otomatis saat melebihi Limit IP)${N}\n"
    echo -e "   ${C}1.)${N}  Set Time Banned"
    echo -e "   ${C}2.)${N}  Set Sensitivitas Lock IP"
    echo -e "   ${C}3.)${N}  Back to Menu"
    echo -e "   ${C}x.)${N}  Exit"
    echo -e "\n${B}════════════════════════════════════${N}\n"
    read -rp "$(echo -e "${G}Select From Options [1-3 or x] : ${N}")" o
    case $o in
      1) read -rp "Durasi banned (menit) : " m
         if [[ "$m" =~ ^[0-9]+$ ]] && (( m > 0 )); then echo "$m" > $ASD/bantime; echo -e "${G}Tersimpan${N}"; else echo -e "${R}Harus angka > 0${N}"; fi
         sleep 1 ;;
      2) clear
         echo -e "${B}════════════════════════════════════${N}"
         echo -e "${P}        SENSITIVITAS LOCK IP        ${N}"
         echo -e "${B}════════════════════════════════════${N}\n"
         echo -e " IP operator seluler sering berganti sendiri,"
         echo -e " sehingga 1 perangkat bisa terbaca 2 IP sesaat."
         echo -e " Akun baru dikunci bila pelanggaran menetap.\n"
         echo -e "   ${C}1.)${N} Ketat    - kunci begitu terdeteksi"
         echo -e "            ${Y}(risiko salah kunci di jaringan seluler)${N}"
         echo -e "   ${C}2.)${N} Normal   - kunci setelah 2x berturut-turut ${G}(disarankan)${N}"
         echo -e "   ${C}3.)${N} Longgar  - kunci setelah 3x berturut-turut"
         echo -e "            ${Y}(untuk pelanggan yang IP-nya sangat sering berubah)${N}\n"
         read -rp "Pilih [1-3] : " m
         if [[ "$m" =~ ^[1-3]$ ]]; then echo "$m" > $ASD/ipconfirm; echo -e "${G}Tersimpan${N}"
         else echo -e "${R}Pilihan salah${N}"; fi
         sleep 2 ;;
      3) return ;;
      x|X) clear; exit 0 ;;
    esac
  done
}

if [[ "$1" == "license" ]]; then
  license_check --enforce; exit 0
fi
if [[ "$1" == "renew" ]]; then
  echo -e "${G}Mengecek status lisensi...${N}"
  license_check --enforce
  if [[ "$(cat $ASD/license_state 2>/dev/null)" == "expired" ]]; then
    echo -e "${R}Lisensi masih belum aktif. Pastikan sudah diperpanjang admin.${N}"
  else
    echo -e "${G}Lisensi aktif. Semua layanan dinyalakan.${N}"
  fi
  exit 0
fi
if [[ "$1" == "info" ]]; then
  ( license_check --enforce >/dev/null 2>&1 & )
  dashboard; accounts; version_box
  echo -e "\n          ${G}to access use ${C}menu${G} command${N}\n"
  exit 0
fi

while true; do
  license_gate
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
    1) m-ssh ;;
    2) m-xray vmess ;;
    3) m-xray vless ;;
    4) m-xray trojan ;;
    5) m-bot ;;
    6) m-feature ;;
    8) m-brand ;;
    7) set_bantime ;;
    9) running ;;
    x|X) clear; exit 0 ;;
    *) echo -e "${R}Pilihan salah${N}"; sleep 1 ;;
  esac
done
EOF

# =====================================================
#  CHECK SERVICES
# =====================================================
cat > /usr/local/sbin/running <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
BRAND=$(cat $ASD/brand)
st(){ systemctl is-active --quiet "$1" 2>/dev/null && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}"; }
port(){ ss -tln 2>/dev/null | grep -q ":$1 " && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}"; }
clear
echo -e "${B}════════════════════════════════════${N}"
printf "${P}%*s${N}\n" $(( (36+${#SCNAME})/2 )) "$SCNAME"
echo -e "${B}════════════════════════════════════${N}\n"
printf "${G}%-16s${N}: %b\n" \
  "SSH" "$(st ssh)" "DROPBEAR" "$(st cas-dropbear)" "OPENVPN" "$(st openvpn)" \
  "SQUID" "$(st squid)" "NGINX" "$(st nginx)" "BADVPN" "$(st badvpn)" \
  "VMESS" "$(st xray)" "VLESS" "$(st xray)" "TROJAN" "$(st xray)" \
  "SlowDNS" "$(st slowdns)" "WEB" "$(st nginx)" \
  "HTTP" "$(port 80)" "HTTPS" "$(port 443)" "GUARD" "$( [[ -f /etc/cron.d/autoscript ]] && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}")"
echo -e "\n${B}════════════════════════════════════${N}\n"
read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"
EOF

cat > /usr/local/sbin/renewsc <<'RSC'
#!/bin/bash
exec /usr/local/sbin/menu renew
RSC
chmod +x /usr/local/sbin/renewsc

# jalan pintas per protokol: addvless, renewvless <kode>, delvless <kode>, recoveryvless <kode>
for _p in vless vmess trojan; do
  for _a in add renew del recovery; do
    cat > /usr/local/sbin/${_a}${_p} <<SC
#!/bin/bash
exec /usr/local/sbin/m-xray ${_p} --${_a} "\$1"
SC
    chmod +x /usr/local/sbin/${_a}${_p}
  done
  ln -sf /usr/local/sbin/del${_p} /usr/local/sbin/delete${_p} 2>/dev/null
done
# bentuk bersepasi: "add vless", "renew vless <kode>", "delete vless <kode>", "recovery vless <kode>"
for _c in add renew delete recovery; do
  _f=$_c; [[ $_c == delete ]] && _f=del
  cat > /usr/local/sbin/${_c} <<SC
#!/bin/bash
case "\$1" in
  vless|vmess|trojan) exec /usr/local/sbin/m-xray "\$1" --${_f} "\$2" ;;
  *) echo "Gunakan: ${_c} vless|vmess|trojan$([[ $_c == add ]] || echo ' <username/uuid>')"
     echo "   atau: ${_c}vless$([[ $_c == add ]] || echo ' <username/uuid>')"
     exit 1 ;;
esac
SC
  chmod +x /usr/local/sbin/${_c}
done
chmod +x /usr/local/sbin/menu /usr/local/sbin/m-xray /usr/local/sbin/running /usr/local/sbin/xray-guard

# =====================================================
#  MIGRASI DATA
# =====================================================
echo -e "${GRN}[5/7] Migrasi database akun...${NC}"
for p in vless vmess trojan; do
  touch /etc/autoscript/db/$p.db /etc/autoscript/db/$p.trash
  awk 'NF{ if(NF<4)$4=0; if(NF<5)$5=0; if(NF<6)$6="active"; print }' /etc/autoscript/db/$p.db > /etc/autoscript/db/.$p.tmp \
    && mv /etc/autoscript/db/.$p.tmp /etc/autoscript/db/$p.db
done
[[ -f /etc/autoscript/bantime ]] || echo 15 > /etc/autoscript/bantime
OLDB=$(cat /etc/autoscript/brand 2>/dev/null)
if [[ -z "$OLDB" || "$OLDB" == *" "* ]]; then echo "cassanova" > /etc/autoscript/brand; fi
[[ -f /etc/autoscript/brand_uuid ]] || echo off > /etc/autoscript/brand_uuid
[[ -f /etc/autoscript/brand_user ]] || echo off > /etc/autoscript/brand_user

# =====================================================
#  XRAY + NGINX
# =====================================================
echo -e "${GRN}[6/7] Konfigurasi Xray & Nginx...${NC}"
CFG=/usr/local/etc/xray/config.json
jq '.log.access="/var/log/xray/access.log" | .log.error="/var/log/xray/error.log" | .log.loglevel="warning"
    | .policy.levels["0"].statsUserUplink=true | .policy.levels["0"].statsUserDownlink=true' \
  $CFG > $CFG.tmp && mv $CFG.tmp $CFG

# email Xray dibuat per protokol (vless.nama, vmess.nama, trojan.nama)
for p in vless vmess trojan; do
  jq --arg t "$p-ws" --arg p "$p" \
    '(.inbounds[]|select(.tag==$t).settings.clients) |= map(if ((.email // "") | startswith($p + ".")) then . else .email = ($p + "." + (.email // "")) end)' \
    $CFG > $CFG.tmp && mv $CFG.tmp $CFG
  # recovery: buang akun trial & yang dihapus > 4 bulan
  lim=$(date -d "-120 days" +%F)
  awk -v l="$lim" 'NF && $1 !~ /trial/ && $7>=l' /etc/autoscript/db/$p.trash > /etc/autoscript/db/.$p.trash \
    && mv /etc/autoscript/db/.$p.trash /etc/autoscript/db/$p.trash
done
# data pemakaian lama (format per-nama) dihapus, mulai hitung ulang per protokol
find /etc/autoscript/usage -maxdepth 1 -type f -delete 2>/dev/null
mkdir -p /etc/autoscript/usage/vless /etc/autoscript/usage/vmess /etc/autoscript/usage/trojan

# tambah inbound gRPC & HTTPUpgrade (salin user dari inbound ws)
jq '
  reduce ["vless","vmess","trojan"][] as $p (.;
    ([.inbounds[]|select(.tag==($p+"-ws"))][0]) as $w
    | (if $p=="vless" then 0 elif $p=="vmess" then 1 else 2 end) as $i
    | (if any(.inbounds[]; .tag==($p+"-grpc")) then . else
        .inbounds += [ $w | .tag=($p+"-grpc") | .port=(10011+$i)
                         | .streamSettings={network:"grpc",grpcSettings:{serviceName:($p+"-grpc")}} ] end)
    | (if any(.inbounds[]; .tag==($p+"-up")) then . else
        .inbounds += [ $w | .tag=($p+"-up") | .port=(10021+$i)
                         | .streamSettings={network:"httpupgrade",httpupgradeSettings:{path:("/up"+$p)}} ] end)
  )' $CFG > $CFG.tmp && mv $CFG.tmp $CFG

# =====================================================
#  VLESS REALITY (TCP langsung, tanpa nginx & tanpa SSL)
# =====================================================
cat > /usr/local/sbin/cas-reality <<'EOF'
#!/bin/bash
# Kelola inbound VLESS Reality.
#   cas-reality            -> pasang/segarkan inbound (tanpa restart)
#   cas-reality --restart  -> pasang lalu restart xray
#   cas-reality --keys     -> cetak port, dest, publicKey, shortId
# Config baru hanya dipasang kalau lolos "xray run -test", jadi protokol lain
# tidak mungkin ikut mati karena Reality.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ASD=/etc/autoscript
CFG=/usr/local/etc/xray/config.json
LOG=/var/log/cas-reality.log
b64u(){ base64 -w0 | tr '+/' '-_' | tr -d '='; }

# --test <domain>: uji apakah domain itu layak jadi kamuflase, dengan
# menjalankan server + klien Reality sungguhan di localhost. Ini satu-satunya
# cara yang benar: situs bisa TLS 1.3 tapi tetap gagal kalau rantai
# sertifikatnya terlalu besar sehingga jabat tangan tidak selesai.
if [[ "$1" == "--test" ]]; then
  d="$2"
  [[ "$d" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || exit 2
  tk=$(mktemp -d) || exit 2
  xray x25519 > $tk/k.txt 2>/dev/null
  tp=$(grep -i '^PrivateKey' $tk/k.txt 2>/dev/null | sed 's/.*: *//')
  tu=$(grep -i 'PublicKey'   $tk/k.txt 2>/dev/null | sed 's/.*: *//')
  if [[ ${#tp} -ne 43 || ${#tu} -ne 43 ]]; then rm -rf $tk; exit 2; fi
  sp=$(( RANDOM % 8000 + 21000 )); cp=$(( sp + 1 ))
  cat > $tk/s.json <<J
{ "log":{"loglevel":"error"},
  "inbounds":[{"listen":"127.0.0.1","port":$sp,"protocol":"vless",
    "settings":{"clients":[{"id":"11111111-1111-1111-1111-111111111111"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"target":"$d:443","xver":0,"serverNames":["$d"],
        "privateKey":"$tp","shortIds":["","00aa9d24"]}}}],
  "outbounds":[{"protocol":"freedom"}] }
J
  cat > $tk/c.json <<J
{ "log":{"loglevel":"error"},
  "inbounds":[{"listen":"127.0.0.1","port":$cp,"protocol":"socks","settings":{"udp":false}}],
  "outbounds":[{"protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":$sp,
      "users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"$d","fingerprint":"chrome",
        "password":"$tu","shortId":"00aa9d24"}}}] }
J
  xray run -c $tk/s.json >/dev/null 2>&1 & spid=$!
  xray run -c $tk/c.json >/dev/null 2>&1 & cpid=$!
  sleep 3
  rc=1
  curl -s --max-time 12 -o /dev/null -x socks5h://127.0.0.1:$cp https://api.ipify.org && rc=0
  kill $spid $cpid >/dev/null 2>&1; wait $spid $cpid >/dev/null 2>&1
  rm -rf $tk
  exit $rc
fi

# --ensure: dipakai cron. Kalau inbound Reality hilang (mis. gagal sesaat saat
# update), dipasang ulang. Dibatasi 6 percobaan supaya tidak mencoba selamanya.
if [[ "$1" == "--ensure" ]]; then
  jq -e '[.inbounds[]|select(.tag=="vless-reality")]|length > 0' $CFG >/dev/null 2>&1 && { rm -f $ASD/reality_try; exit 0; }
  t=$(cat $ASD/reality_try 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] || t=0
  (( t >= 6 )) && exit 0
  echo $((t+1)) > $ASD/reality_try
  echo "$(date '+%F %T') inbound Reality tidak ada, coba pasang (percobaan $((t+1)))" >> $LOG
  exec "$0" --restart
fi

port=$(cat $ASD/reality_port 2>/dev/null | tr -d '[:space:]')
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || port=2087
dest=$(cat $ASD/reality_dest 2>/dev/null | tr -d '[:space:]')
[[ "$dest" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || dest=www.asus.com
echo "$port" > $ASD/reality_port; echo "$dest" > $ASD/reality_dest

# kunci dibuat sekali saja dan tidak pernah diganti saat update
if [[ ! -s $ASD/reality_priv || ! -s $ASD/reality_pub ]]; then
  k=$(mktemp)
  if openssl genpkey -algorithm X25519 -out "$k" 2>/dev/null; then
    openssl pkey -in "$k" -outform DER        2>/dev/null | tail -c 32 | b64u > $ASD/reality_priv
    openssl pkey -in "$k" -pubout -outform DER 2>/dev/null | tail -c 32 | b64u > $ASD/reality_pub
  fi
  rm -f "$k"
fi
priv=$(cat $ASD/reality_priv 2>/dev/null | tr -d '[:space:]')
pub=$(cat $ASD/reality_pub 2>/dev/null | tr -d '[:space:]')
sid=$(cat $ASD/reality_sid 2>/dev/null | tr -d '[:space:]')
[[ "$sid" =~ ^[0-9a-f]{8}$ ]] || { sid=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n'); echo "$sid" > $ASD/reality_sid; }

if [[ ${#priv} -ne 43 || ${#pub} -ne 43 ]]; then
  rm -f $ASD/reality_priv $ASD/reality_pub
  echo "Kunci Reality gagal dibuat, Reality dilewati." >&2; exit 1
fi
[[ "$1" == "--keys" ]] && { printf 'port=%s\ndest=%s\npub=%s\nsid=%s\n' "$port" "$dest" "$pub" "$sid"; exit 0; }

# WAJIB berakhiran .json: Xray menentukan format config dari akhiran nama file.
# Tanpa itu: "core: Failed to get format of ..." walau isinya benar.
tmp=$(mktemp --suffix=.json 2>/dev/null)
[[ -n "$tmp" && -f "$tmp" ]] || { tmp=/tmp/cas-reality.$$.json; : > "$tmp"; }
jq --argjson port "$port" --arg dest "$dest" --arg priv "$priv" --arg sid "$sid" '
  ([.inbounds[]|select(.tag=="vless-ws")][0].settings.clients // []) as $cl
  | .inbounds = [ .inbounds[] | select(.tag != "vless-reality") ]
  | .inbounds += [{
      tag: "vless-reality",
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: { clients: $cl, decryption: "none" },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          dest: ($dest + ":443"),
          xver: 0,
          serverNames: [ $dest ],
          privateKey: $priv,
          shortIds: [ "", $sid ]
        }
      },
      sniffing: { enabled: true, destOverride: ["http","tls"] }
    }]' $CFG > "$tmp" 2>/dev/null

if [[ ! -s "$tmp" ]] || ! jq -e . "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"; echo "Gagal menyusun config Reality, tidak ada yang diubah." >&2; exit 1
fi
# diuji sampai 2x: saat update berjalan pernah gagal sesaat padahal config benar
ok=0
for _try in 1 2; do
  if xray run -test -config "$tmp" >>$LOG 2>&1; then ok=1; break; fi
  echo "$(date '+%F %T') uji ke-$_try gagal" >> $LOG
  sleep 2
done
if (( ok == 0 )); then
  cp -f "$tmp" /tmp/cas-reality-gagal.json 2>/dev/null
  rm -f "$tmp"
  echo "Config Reality tidak lolos uji Xray. Pesan aslinya ada di $LOG" >&2
  echo "Tidak ada yang diubah, protokol lain tetap normal." >&2
  exit 1
fi
rm -f $ASD/reality_try
if cmp -s "$tmp" "$CFG"; then rm -f "$tmp"; exit 0; fi      # tidak ada perubahan
cp -f "$CFG" "$CFG.bak-reality"
mv "$tmp" "$CFG"
if [[ "$1" == "--restart" ]]; then
  systemctl restart xray >/dev/null 2>&1; sleep 1
  if ! systemctl is-active --quiet xray; then
    cp -f "$CFG.bak-reality" "$CFG"; systemctl restart xray >/dev/null 2>&1
    echo "Xray gagal start dengan Reality, config sudah dikembalikan." >&2; exit 1
  fi
fi
exit 0
EOF
chmod +x /usr/local/sbin/cas-reality
rm -f /etc/autoscript/reality_try   # tiap update memberi 6 kesempatan baru bagi cron --ensure
# www.microsoft.com ternyata tidak bisa dipakai (rantai sertifikatnya terlalu
# besar, jabat tangan tidak selesai). VPS yang masih memakainya dipindahkan.
[[ "$(cat /etc/autoscript/reality_dest 2>/dev/null)" == "www.microsoft.com" ]] && echo "www.asus.com" > /etc/autoscript/reality_dest
/usr/local/sbin/cas-reality || echo -e "${RED}Reality dilewati (lihat pesan di atas), protokol lain tidak terpengaruh.${NC}"

DOMAIN=$(cat /etc/autoscript/domain)
cp -f /etc/nginx/conf.d/xray.conf /root/xray.conf.bak 2>/dev/null
cat > /etc/nginx/conf.d/xray.conf <<'NGX'
map $http_upgrade $cas_conn { default upgrade; '' close; }
server {
    listen 80;         listen [::]:80;
    listen 8080;       listen [::]:8080;
    listen 2052;       listen [::]:2052;
    listen 8880;       listen [::]:8880;
    listen 443 ssl http2;  listen [::]:443 ssl http2;
    listen 8443 ssl http2; listen [::]:8443 ssl http2;
    listen 2053 ssl http2; listen [::]:2053 ssl http2;
    server_name DOMAIN_HERE;

    ssl_certificate     /etc/autoscript/xray.crt;
    ssl_certificate_key /etc/autoscript/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $cas_conn;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # ---- WebSocket ----
    location = /vless     { if ($http_upgrade != "websocket") { return 404; } proxy_pass http://127.0.0.1:10001; }
    location = /vmess     { if ($http_upgrade != "websocket") { return 404; } proxy_pass http://127.0.0.1:10002; }
    location = /trojan-ws { if ($http_upgrade != "websocket") { return 404; } proxy_pass http://127.0.0.1:10003; }

    # ---- HTTPUpgrade ----
    location = /upvless   { proxy_pass http://127.0.0.1:10021; }
    location = /upvmess   { proxy_pass http://127.0.0.1:10022; }
    location = /uptrojan  { proxy_pass http://127.0.0.1:10023; }

    # ---- gRPC ----
    location ^~ /vless-grpc  { grpc_pass grpc://127.0.0.1:10011; grpc_set_header X-Real-IP $remote_addr; grpc_read_timeout 3600s; grpc_send_timeout 3600s; client_max_body_size 0; }
    location ^~ /vmess-grpc  { grpc_pass grpc://127.0.0.1:10012; grpc_set_header X-Real-IP $remote_addr; grpc_read_timeout 3600s; grpc_send_timeout 3600s; client_max_body_size 0; }
    location ^~ /trojan-grpc { grpc_pass grpc://127.0.0.1:10013; grpc_set_header X-Real-IP $remote_addr; grpc_read_timeout 3600s; grpc_send_timeout 3600s; client_max_body_size 0; }

    # Halaman cek akun pelanggan (read-only, service lokal 8099)
    location ^~ /cek {
        proxy_pass http://127.0.0.1:8099;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 20s;
    }
}
NGX
sed -i "s/DOMAIN_HERE/$DOMAIN/" /etc/nginx/conf.d/xray.conf
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
else
  echo -e "${RED}Config Nginx baru error, dikembalikan ke config lama:${NC}"; nginx -t
  cp -f /root/xray.conf.bak /etc/nginx/conf.d/xray.conf && systemctl reload nginx
fi

# IP asli pelanggan saat lewat Cloudflare (tanpa ini yang tercatat IP server Cloudflare)
CFR=/etc/nginx/conf.d/00-cloudflare-realip.conf
{
  echo "# Cloudflare real IP - dibuat otomatis"
  V4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 | grep -E '^[0-9./]+$')
  V6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 | grep -E '^[0-9a-f:./]+$')
  [[ -z "$V4" ]] && V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
  [[ -z "$V6" ]] && V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
  for r in $V4 $V6; do echo "set_real_ip_from $r;"; done
  echo "real_ip_header CF-Connecting-IP;"
} > $CFR
if nginx -t >/dev/null 2>&1; then systemctl reload nginx; else rm -f $CFR; fi

# perpanjangan SSL otomatis lewat webroot (nginx tidak perlu dimatikan)
ACF=/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf
[[ -f $ACF ]] && sed -i "s#^Le_Webroot=.*#Le_Webroot='/var/www/html'#" $ACF
# sertifikat hanya dipakai nginx (xray menerima trafik polos), jadi cukup reload
# nginx setelah acme.sh memperbarui: halus, koneksi user tidak terputus.
if [[ -f $ACF ]]; then
  RCB=$(printf '%s' 'systemctl reload nginx' | base64 -w0 2>/dev/null)
  if [[ -n "$RCB" ]]; then
    sed -i '/^Le_ReloadCmd=/d' $ACF
    echo "Le_ReloadCmd='__ACME_BASE64__START_${RCB}__ACME_BASE64__END_'" >> $ACF
  fi
fi

# ---- SSL untuk domain hasil restore (dipakai setelah restore backup) ----
# Kalau pointing domain belum diarahkan ke VPS ini, script ini diam saja dan
# dicoba lagi oleh cron tiap 10 menit. Begitu A record diubah ke IP VPS ini,
# SSL terbit sendiri tanpa buyer perlu mengetik apa pun.
# ---- peringatan masa aktif lisensi ke buyer (H-7, H-3, H-1, hari-H) ----
# Dikirim lewat bot milik buyer sendiri, terlepas dari setelan notifikasi
# akun, karena ini menyangkut hidup-matinya layanan mereka.
cat > /usr/local/sbin/cas-license-warn <<'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ASD=/etc/autoscript
[[ -s $ASD/license_url ]] || exit 0                     # mode dev, tanpa lisensi
EXP=$(cat $ASD/license_exp 2>/dev/null)
[[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || exit 0  # Lifetime / belum diketahui
[[ "$EXP" == "2099-12-31" ]] && exit 0

LEFT=$(( ( $(date -d "$EXP" +%s) - $(date -d "$(date +%F)" +%s) ) / 86400 ))
AMB=""
case $LEFT in 7) AMB=7 ;; 3) AMB=3 ;; 1) AMB=1 ;; 0) AMB=0 ;; esac
(( LEFT < 0 )) && AMB=x
[[ -z "$AMB" ]] && exit 0

# jangan kirim dua kali untuk ambang yang sama
[[ "$(cat $ASD/license_warned 2>/dev/null)" == "$EXP:$AMB" ]] && exit 0

BOT_TOKEN=""; CHAT_ID=""
. $ASD/bot 2>/dev/null
[[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && exit 0

case $AMB in
  7) SISA="habis <b>7 hari lagi</b>" ;;
  3) SISA="habis <b>3 hari lagi</b>" ;;
  1) SISA="habis <b>besok</b>" ;;
  0) SISA="<b>habis hari ini</b>" ;;
  x) SISA="<b>sudah habis</b> dan layanan sudah dihentikan" ;;
esac
IP=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
D=$(cat $ASD/domain 2>/dev/null)
L="━━━━━━━━━━━━━━━━━━━━"
TXT="⏳ <b>MASA AKTIF SCRIPT</b>
$L
<code>Domain  :</code> $D
<code>IP      :</code> $IP
<code>Berakhir:</code> $EXP
$L
Masa aktif script Anda $SISA.
Segera hubungi admin untuk perpanjangan agar
layanan VPN tidak terhenti.
$L
<i>Setelah diperpanjang admin, layanan aktif
otomatis dalam ±2 menit. Bila perlu ketik</i> <code>renewsc</code>"

if curl -s --max-time 20 -o /dev/null \
     --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "parse_mode=HTML" \
     --data-urlencode "text=$TXT" \
     "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"; then
  echo "$EXP:$AMB" > $ASD/license_warned
fi
EOF
chmod +x /usr/local/sbin/cas-license-warn

cat > /usr/local/sbin/cas-ssl-pending <<'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ASD=/etc/autoscript
LOG=/var/log/cas-ssl.log
[[ -f $ASD/ssl_pending ]] || exit 0
exec 9>/run/cas-ssl.lock
flock -n 9 || exit 0

tg(){ # $1 = teks
  local BOT_TOKEN="" CHAT_ID=""
  . $ASD/bot 2>/dev/null
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s --max-time 15 -o /dev/null \
    --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
}

D=$(cat $ASD/domain 2>/dev/null); [[ -z "$D" ]] && exit 0
IP=$(jq -r '.ip // empty' $ASD/ipinfo.json 2>/dev/null)
[[ -z "$IP" ]] && IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
[[ -z "$IP" ]] && exit 0
DIP=$(getent hosts "$D" 2>/dev/null | awk '{print $1}' | head -1)

# ---- pointing belum mengarah ke VPS ini: tunggu, jangan hitung sebagai percobaan ----
if [[ "$DIP" != "$IP" ]]; then
  W=$(cat $ASD/ssl_wait 2>/dev/null); [[ "$W" =~ ^[0-9]+$ ]] || W=0
  echo $((W+1)) > $ASD/ssl_wait
  # dalam 2 jam pertama, periksa apakah domain masih ORANGE (diproxy) di Cloudflare
  if (( W < 12 )) && [[ -n "$DIP" && ! -f $ASD/ssl_orange ]]; then
    if curl -sI --max-time 10 "http://$D" 2>/dev/null | grep -qi '^server:[[:space:]]*cloudflare'; then
      : > $ASD/ssl_orange
      echo "$(date '+%F %T') $D masih ORANGE (diproxy Cloudflare), SSL tidak bisa terbit" >> $LOG
      tg "⚠️ <b>Domain masih ORANGE di Cloudflare</b>"$'\n'"<code>Domain :</code> $D"$'\n'"<code>IP VPS :</code> $IP"$'\n'"Ubah awan jadi ABU-ABU (DNS only) dan arahkan ke IP di atas. SSL terbit sendiri setelah itu."
    fi
  fi
  exit 0
fi
rm -f $ASD/ssl_wait $ASD/ssl_orange

# ---- pointing sudah benar: terbitkan SSL ----
TRY=$(cat $ASD/ssl_try 2>/dev/null); [[ "$TRY" =~ ^[0-9]+$ ]] || TRY=0
(( TRY >= 20 )) && exit 0
# setelah 3 percobaan, beri jeda 30 menit agar tidak kena rate limit Let's Encrypt
NOW=$(date +%s); LAST=$(cat $ASD/ssl_last 2>/dev/null); [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
(( TRY >= 3 )) && (( NOW - LAST < 1800 )) && exit 0
echo "$NOW" > $ASD/ssl_last
TRY=$((TRY+1)); echo "$TRY" > $ASD/ssl_try
echo "=== $(date '+%F %T') percobaan $TRY terbitkan SSL $D ($IP) ===" >> $LOG

mkdir -p /var/www/html
[[ -x /root/.acme.sh/acme.sh ]] || curl -s https://get.acme.sh | sh -s email=admin@$D >>$LOG 2>&1
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >>$LOG 2>&1

ok=0
# 1) webroot: nginx tetap hidup, koneksi user tidak terputus
/root/.acme.sh/acme.sh --issue -d "$D" -w /var/www/html -k ec-256 --force >>$LOG 2>&1 && ok=1
# 2) standalone (nginx mati beberapa detik) hanya dipakai pada 3 percobaan pertama
if (( ok == 0 )) && (( TRY <= 3 )); then
  echo "webroot gagal, coba standalone" >> $LOG
  systemctl stop nginx >/dev/null 2>&1
  /root/.acme.sh/acme.sh --issue -d "$D" --standalone -k ec-256 --force >>$LOG 2>&1 && ok=1
  systemctl start nginx >/dev/null 2>&1
fi
if (( ok == 0 )); then
  echo "gagal menerbitkan SSL" >> $LOG
  (( TRY == 20 )) && tg "⚠️ <b>SSL belum bisa diterbitkan</b>"$'\n'"<code>Domain :</code> $D"$'\n'"Percobaan otomatis dihentikan setelah 20 kali."$'\n'"Cek /var/log/cas-ssl.log lalu jalankan: <code>adddomain</code>"
  exit 1
fi

/root/.acme.sh/acme.sh --install-cert -d "$D" --ecc \
  --fullchain-file $ASD/xray.crt --key-file $ASD/xray.key \
  --reloadcmd "systemctl reload nginx" >>$LOG 2>&1

if openssl x509 -in $ASD/xray.crt -noout -checkend 86400 >/dev/null 2>&1; then
  rm -f $ASD/ssl_pending $ASD/ssl_try $ASD/ssl_last $ASD/ssl_wait $ASD/ssl_orange
  systemctl reload nginx >/dev/null 2>&1
  echo "SSL berhasil" >> $LOG
  tg "✅ <b>SSL siap, VPS sudah bisa dipakai</b>"$'\n'"<code>Domain :</code> $D"$'\n'"<code>IP     :</code> $IP"$'\n'"Tidak ada lagi yang perlu dilakukan."
fi
EOF
chmod +x /usr/local/sbin/cas-ssl-pending

cat > /etc/logrotate.d/cassanova <<'EOF'
/var/log/cas-ssl.log /var/log/cas-update.log /var/log/cas-reality.log {
    weekly
    rotate 2
    maxsize 5M
    missingok
    notifempty
    compress
    copytruncate
}
EOF

cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 2
    maxsize 50M
    missingok
    notifempty
    compress
    copytruncate
}
EOF

cat > /etc/cron.d/autoscript <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
5 0 * * * root /usr/local/sbin/m-xray vless --expire
* * * * * root /usr/local/sbin/xray-guard
*/2 * * * * root /usr/local/sbin/menu license
*/10 * * * * root /usr/local/sbin/cas-ssl-pending
0 9 * * * root /usr/local/sbin/cas-license-warn
*/10 * * * * root /usr/local/sbin/cas-reality --ensure
EOF
chmod 644 /etc/cron.d/autoscript

# =====================================================
#  SELESAI
# =====================================================
echo -e "${GRN}[7/7] Menyelesaikan...${NC}"
echo "$SCVER" > /etc/autoscript/version
grep -q "menu info" /root/.profile || echo '[[ -t 1 ]] && /usr/local/sbin/menu info' >> /root/.profile
/usr/local/sbin/menu license >/dev/null 2>&1 || true

# ---- Modul SSH ----
echo -e "${GRN}[SSH] Memasang modul SSH...${NC}"
wget -qO /root/ssh.sh "$BASE/ssh.sh?t=$(date +%s)" && bash /root/ssh.sh; rm -f /root/ssh.sh

# ---- Modul Features + Brand Name ----
echo -e "${GRN}[FEATURES] Memasang modul Features & Brand Name...${NC}"
wget -qO /root/features.sh "$BASE/features.sh?t=$(date +%s)" && bash /root/features.sh; rm -f /root/features.sh

# ---- Modul Setup Bot ----
echo -e "${GRN}[BOT] Memasang modul Setup Bot...${NC}"
wget -qO /root/bot.sh "$BASE/bot.sh?t=$(date +%s)" && bash /root/bot.sh; rm -f /root/bot.sh
# Xray hanya di-restart kalau config-nya benar-benar berubah
if xray run -test -config $CFG >/dev/null 2>&1; then
  if [[ "$(md5sum $CFG | cut -d' ' -f1)" != "$H_XRAY_OLD" ]]; then
    echo -e "${GRN}Config Xray berubah → restart diperlukan${NC}"; svc_restart xray
  else
    echo -e "${GRN}Config Xray tidak berubah → tanpa restart (koneksi aman)${NC}"
  fi
else
  echo -e "${RED}Config Xray tidak valid, cek: xray run -test -config $CFG${NC}"
fi

echo -e "${GRN}==============================================${NC}"
echo -e "${GRN}   UPDATE SELESAI - $(cat /etc/autoscript/version)${NC}"
echo -e "${GRN}==============================================${NC}"
echo -e " Ketik ${GRN}menu${NC} untuk membuka menu"
echo -e " Ketik ${GRN}cmd${NC}  untuk melihat daftar perintah cepat"
rm -f /root/update.sh
