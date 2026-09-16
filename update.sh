#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - UPDATE v1.3.0
#  - Tambah/hapus akun tanpa restart Xray (Xray API)
#  - Check Users Login, Lock/Unlock, Recovery
#  - Limit IP (auto banned), Limit Bandwidth (kuota)
#  - Set Reduce/Time (durasi banned)
# =====================================================
GRN='\e[32m'; RED='\e[31m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
[[ ! -f /etc/autoscript/domain ]] && echo -e "${RED}Script belum terinstall. Jalankan install.sh dulu.${NC}" && exit 1

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
# Cassanova Tunneling - shared library
R='\e[31m'; G='\e[32m'; Y='\e[33m'; B='\e[34m'; C='\e[36m'; P='\e[35m'; W='\e[1;97m'; O='\e[38;5;208m'; N='\e[0m'
BGB='\e[44m'; BG='\e[41m'
CFG=/usr/local/etc/xray/config.json
ASD=/etc/autoscript
API=127.0.0.1:10085
PROTOS="vless vmess trojan"
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
  [[ "$u" != trial* ]] && echo "$line $(date +%F)" >> $ASD/db/$p.trash
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
  local today p u exp
  today=$(date +%F)
  for p in $PROTOS; do
    while read -r u exp _; do
      [[ -n "$u" && "$exp" < "$today" ]] && remove_account $p "$u"
    done < <(cat $ASD/db/$p.db)
  done
  trash_prune
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
recent_ips(){
  local LOG=/var/log/xray/access.log since
  [[ -f $LOG ]] || return 0
  since=$(date -d "-$1 min" '+%Y/%m/%d %H:%M:%S')
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
usage_collect
COUNTS=$(recent_ips 2 | awk '{c[$1]++} END{for(u in c) print u, c[u]}')

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
      if (( used >= q * 1073741824 )); then xray_del $p "$u"; db_set $p "$u" 6 quota; continue; fi
    fi
    # limit IP
    if [[ "$ipl" =~ ^[0-9]+$ ]] && (( ipl > 0 )); then
      n=$(echo "$COUNTS" | awk -v u="$p.$u" '$1==u{print $2}')
      if [[ -n "$n" ]] && (( n > ipl )); then
        xray_del $p "$u"; db_set $p "$u" 6 "banned:$(( now + BANMIN*60 ))"
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
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }
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

mk_link(){ # net(ws|up|grpc) tls(1|0)  -> pakai variabel ID & REM
  local port sec path t qs j tlsv
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

show_account(){ # user id exp
  local ipl q CITY ISP L2="${B}────────────────────────────────────${N}"
  REM=$1; ID=$2
  local exp=$3
  ipl=$(db_field $PROTO "$REM" 4); q=$(db_field $PROTO "$REM" 5)
  CITY=$(jq -r '.city // "-"' $ASD/ipinfo.json 2>/dev/null)
  ISP=$(jq -r '.org // "-"' $ASD/ipinfo.json 2>/dev/null | sed 's/^AS[0-9]* //')
  row(){ printf " ${G}%-14s${N}: %b\n" "$1" "$2"; }
  sec(){ echo -e "$L2"; printf "${Y}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$L2"; }
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
  echo -e "$L2"
}

list_users(){
  header "LIST $UP USERS"
  printf " ${G}%-3s %-12s %-10s %-3s %-12s %s${N}\n" "NO" "USER" "EXPIRED" "IP" "USED/QUOTA" "ST"
  local i=0 u exp id ipl q st qd
  while read -r u exp id ipl q st; do
    [[ -z "$u" ]] && continue; i=$((i+1))
    [[ "$q" == 0 ]] && qd="$(hbytes $(usage_get $PROTO "$u"))/~" || qd="$(hbytes $(usage_get $PROTO "$u"))/${q}G"
    printf " %-3s %-12s %-10s %-3s %-12s %b\n" "$i" "$u" "$exp" "$([[ "$ipl" == 0 ]] && echo - || echo "$ipl")" "$qd" "$(st_label "$st")"
  done < "$DB"
  [[ $i == 0 ]] && echo -e " ${Y}Belum ada akun${N}"
  echo -e "$LINE"
  echo -e " ${G}Total : ${Y}$i${G} akun${N}"
  echo -e "$LINE"
}

pick_user(){ # hasil di variabel U (bisa ketik nomor atau username)
  local inp
  list_users
  read -rp "Nomor / Username : " inp
  if [[ "$inp" =~ ^[0-9]+$ ]]; then
    U=$(awk -v n="$inp" 'NF{i++; if(i==n){print $1; exit}}' "$DB")
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
  if [[ "$custom" == 1 ]]; then read -rp "UUID/Password : " id; else id=$(uuidgen); fi
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
  show_account "$u" "$id" "$exp"; pause
}

trial(){
  local u id m exp
  u="trial$(tr -dc a-z0-9 </dev/urandom | head -c4)"
  read -rp "Durasi trial (menit) [60] : " m; m=${m:-60}; num_ok "$m" || { msg "${R}Harus angka${N}"; return; }
  id=$(uuidgen); exp=$(date -d "+$m minutes" +%F)
  lock_db
  echo "$u $exp $id 1 0 active" >> "$DB"
  xray_add $PROTO "$u" "$id"
  unlock_db
  echo "/usr/local/sbin/m-xray $PROTO --delete $u" | at now + $m minutes >/dev/null 2>&1
  show_account "$u" "$id" "$m menit"; pause
}

delete(){
  pick_user || return
  lock_db; remove_account $PROTO "$U"; unlock_db
  echo -e "${G}User $U dihapus (bisa dipulihkan lewat Recovery)${N}"; pause
}

renew(){
  local d base today new st
  pick_user || return
  read -rp "Tambah masa aktif (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  lock_db
  base=$(db_field $PROTO "$U" 2); today=$(date +%F)
  [[ "$base" < "$today" ]] && base=$today
  new=$(date -d "$base +$d days" +%F)
  db_set $PROTO "$U" 2 "$new"
  rm -f $ASD/usage/$PROTO/$U
  st=$(db_field $PROTO "$U" 6)
  if [[ "$st" == "quota" ]]; then xray_add $PROTO "$U" "$(db_field $PROTO "$U" 3)"; db_set $PROTO "$U" 6 active; fi
  unlock_db
  echo -e "${G}User $U diperpanjang sampai $new (pemakaian kuota di-reset)${N}"; pause
}

modify_uuid(){
  local id st
  pick_user || return
  read -rp "UUID baru (kosongkan = acak) : " id; id=${id:-$(uuidgen)}
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
  data=$(recent_ips 5)
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
  pick_user || return
  lock_db
  [[ "$(db_field $PROTO "$U" 6)" == "active" ]] && xray_del $PROTO "$U"
  db_set $PROTO "$U" 6 locked
  unlock_db
  echo -e "${G}User $U dikunci${N}"; pause
}

unlock_user(){
  local st exp
  pick_user || return
  st=$(db_field $PROTO "$U" 6); exp=$(db_field $PROTO "$U" 2)
  [[ "$st" == "active" ]] && { msg "${Y}User $U sudah aktif${N}"; return; }
  [[ "$exp" < "$(date +%F)" ]] && { msg "${R}Akun sudah expired, gunakan Renew${N}"; return; }
  lock_db
  [[ "$st" == "quota" ]] && rm -f $ASD/usage/$PROTO/$U
  xray_add $PROTO "$U" "$(db_field $PROTO "$U" 3)"
  db_set $PROTO "$U" 6 active
  unlock_db
  echo -e "${G}User $U dibuka kembali${N}"; pause
}

recovery(){
  local i=0 u exp id ipl q st del d new line inp v names=()
  header "RECOVERY $UP"
  printf " ${G}%-3s %-16s %-12s${N}\n" "NO" "USERNAME" "DIHAPUS"
  while read -r u exp id ipl q st del; do
    [[ -z "$u" ]] && continue; i=$((i+1)); names+=("$u")
    printf " %-3s %-16s %-12s\n" "$i" "$u" "$del"
  done < <(tac "$TRASH" 2>/dev/null)
  [[ $i == 0 ]] && { echo -e " ${Y}Tidak ada akun yang bisa dipulihkan${N}"; pause; return; }
  echo -e "$LINE"
  echo -e " ${G}Total : ${Y}$i${G} akun${N}"
  echo -e "$LINE"
  read -rp "Nomor / Username : " inp
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
  show_account "$u" "$id" "$new"; pause
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
    11) header "CHECK CONFIG"; xray run -test -config $CFG; pause ;;
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

  top; echo -e "${B}│${N} ${BG}${W}$(center "$BRAND")${N} ${B}│${N}"; bot
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

set_bantime(){
  local o m
  while true; do
    clear
    echo -e "${B}════════════════════════════════════${N}"
    printf "${P}%*s${N}\n" $(( (36+${#BRAND})/2 )) "$BRAND"
    echo -e "${B}════════════════════════════════════${N}\n"
    echo -e "${G}Time Banned Active : ${O}$(cat $ASD/bantime 2>/dev/null || echo 15)m:0s${N}"
    echo -e "${Y}(lama akun dikunci otomatis saat melebihi Limit IP)${N}\n"
    echo -e "   ${C}1.)${N}  Set Time Banned"
    echo -e "   ${C}2.)${N}  Back to Menu"
    echo -e "   ${C}x.)${N}  Exit"
    echo -e "\n${B}════════════════════════════════════${N}\n"
    read -rp "$(echo -e "${G}Select From Options [1-2 or x] : ${N}")" o
    case $o in
      1) read -rp "Durasi banned (menit) : " m
         if [[ "$m" =~ ^[0-9]+$ ]] && (( m > 0 )); then echo "$m" > $ASD/bantime; echo -e "${G}Tersimpan${N}"; else echo -e "${R}Harus angka > 0${N}"; fi
         sleep 1 ;;
      2) return ;;
      x|X) clear; exit 0 ;;
    esac
  done
}

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
    5|6|8) coming ;;
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
printf "${P}%*s${N}\n" $(( (36+${#BRAND})/2 )) "$BRAND"
echo -e "${B}════════════════════════════════════${N}\n"
printf "${G}%-16s${N}: %b\n" \
  "SSH" "$(st ssh)" "DROPBEAR" "$(st dropbear)" "OPENVPN" "$(st openvpn)" \
  "SQUID" "$(st squid)" "NGINX" "$(st nginx)" "BADVPN" "$(st badvpn)" \
  "VMESS" "$(st xray)" "VLESS" "$(st xray)" "TROJAN" "$(st xray)" \
  "SlowDNS" "$(st slowdns)" "WEB" "$(st nginx)" \
  "HTTP" "$(port 80)" "HTTPS" "$(port 443)" "GUARD" "$( [[ -f /etc/cron.d/autoscript ]] && echo -e "${G}[ON]${N}" || echo -e "${R}[OFF]${N}")"
echo -e "\n${B}════════════════════════════════════${N}\n"
read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"
EOF

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
  awk -v l="$lim" 'NF && $1 !~ /^trial/ && $7>=l' /etc/autoscript/db/$p.trash > /etc/autoscript/db/.$p.trash \
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
}
NGX
sed -i "s/DOMAIN_HERE/$DOMAIN/" /etc/nginx/conf.d/xray.conf
if nginx -t >/dev/null 2>&1; then
  systemctl restart nginx
else
  echo -e "${RED}Config Nginx baru error, dikembalikan ke config lama:${NC}"; nginx -t
  cp -f /root/xray.conf.bak /etc/nginx/conf.d/xray.conf && systemctl restart nginx
fi

# perpanjangan SSL otomatis lewat webroot (nginx tidak perlu dimatikan)
ACF=/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf
[[ -f $ACF ]] && sed -i "s#^Le_Webroot=.*#Le_Webroot='/var/www/html'#" $ACF

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
5 0 * * * root /usr/local/sbin/m-xray vless --expire
* * * * * root /usr/local/sbin/xray-guard
EOF
chmod 644 /etc/cron.d/autoscript

# =====================================================
#  SELESAI
# =====================================================
echo -e "${GRN}[7/7] Restart Xray (sekali ini saja)...${NC}"
echo "v1.3.0" > /etc/autoscript/version
grep -q "menu info" /root/.profile || echo '[[ -t 1 ]] && /usr/local/sbin/menu info' >> /root/.profile
if xray run -test -config $CFG >/dev/null 2>&1; then
  systemctl restart xray
else
  echo -e "${RED}Config Xray tidak valid, cek: xray run -test -config $CFG${NC}"
fi

echo -e "${GRN}==============================================${NC}"
echo -e "${GRN}   UPDATE SELESAI - $(cat /etc/autoscript/version)${NC}"
echo -e "${GRN}==============================================${NC}"
echo -e " Ketik ${GRN}menu${NC} untuk membuka menu"
rm -f /root/update.sh
