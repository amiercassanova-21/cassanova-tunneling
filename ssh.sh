#!/bin/bash
# =====================================================
#  CASSANOVA TUNNELING - MODUL SSH
#  Dropbear + SSH WebSocket + BadVPN UDP + menu SSH
# =====================================================
GRN='\e[32m'; RED='\e[31m'; NC='\e[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}Jalankan sebagai root!${NC}" && exit 1
export DEBIAN_FRONTEND=noninteractive
ASD=/etc/autoscript
mkdir -p $ASD/db $ASD/usage/ssh

type svc_restart &>/dev/null || svc_restart(){ systemctl restart "$1"; }
fh(){ cat "$@" 2>/dev/null | md5sum | cut -d' ' -f1; }
H_DB=$(fh /etc/default/dropbear); H_BV=$(fh /etc/systemd/system/badvpn.service); H_WS=$(fh /usr/local/bin/ws-ssh.py /etc/systemd/system/ws-ssh.service)

echo -e "${GRN}[SSH 1/5] Paket...${NC}"
apt install -y dropbear stunnel4 cmake make gcc git build-essential fail2ban >/dev/null 2>&1

# ---------- Dropbear ----------
echo -e "${GRN}[SSH 2/5] Dropbear...${NC}"
cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=143
DROPBEAR_EXTRA_ARGS="-p 109"
DROPBEAR_BANNER="/etc/autoscript/banner.txt"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
[[ -s $ASD/banner.txt ]] || echo -e "\nCASSANOVA TUNNELING\n" > $ASD/banner.txt
grep -q '^/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
grep -q '^/usr/sbin/nologin' /etc/shells || echo '/usr/sbin/nologin' >> /etc/shells
systemctl enable dropbear >/dev/null 2>&1
if ! systemctl is-active --quiet dropbear; then systemctl start dropbear
elif [[ "$(fh /etc/default/dropbear)" != "$H_DB" ]]; then svc_restart dropbear; fi

# ---------- BadVPN UDP ----------
echo -e "${GRN}[SSH 3/5] BadVPN UDP...${NC}"
if [[ ! -f /usr/bin/badvpn-udpgw ]]; then
  git clone https://github.com/ambrop72/badvpn.git /tmp/badvpn >/dev/null 2>&1
  mkdir -p /tmp/badvpn/build && cd /tmp/badvpn/build
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 && make >/dev/null 2>&1
  cp udpgw/badvpn-udpgw /usr/bin/ 2>/dev/null
  cd /root; rm -rf /tmp/badvpn
fi
if [[ -f /usr/bin/badvpn-udpgw ]]; then
  cat > /etc/systemd/system/badvpn.service <<'EOF'
[Unit]
Description=BadVPN UDPGW
After=network.target
[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable badvpn >/dev/null 2>&1
  if ! systemctl is-active --quiet badvpn; then systemctl start badvpn
  elif [[ "$(fh /etc/systemd/system/badvpn.service)" != "$H_BV" ]]; then svc_restart badvpn; fi
else
  echo -e "${RED}BadVPN gagal dikompilasi (dilewati)${NC}"
fi

# ---------- SSH WebSocket (proxy python) ----------
echo -e "${GRN}[SSH 4/5] SSH WebSocket...${NC}"
cat > /usr/local/bin/ws-ssh.py <<'PYEOF'
#!/usr/bin/env python3
# SSH WebSocket proxy - terima metode apa pun (GET/PATCH/HEAD dll) & path apa pun
import socket, threading, select, sys
LISTEN='127.0.0.1'; LPORT=int(sys.argv[1]) if len(sys.argv)>1 else 8088
TARGET='127.0.0.1'; TPORT=143
RESP=b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
def handle(c):
    s=None
    try:
        c.settimeout(15)
        c.recv(16384)
        c.sendall(RESP)
        c.settimeout(None)
        s=socket.create_connection((TARGET,TPORT))
        buf=b''; synced=False
        while True:
            r,_,_=select.select([c,s],[],[])
            for x in r:
                d=x.recv(16384)
                if not d: return
                if x is c:
                    if not synced:
                        # buang sisa payload (mis. split "HTTP/ 1") sampai data SSH dimulai
                        buf+=d; i=buf.find(b'SSH-')
                        if i<0:
                            if len(buf)>65536: return
                            continue
                        d=buf[i:]; buf=b''; synced=True
                    s.sendall(d)
                else:
                    c.sendall(d)
    except Exception:
        pass
    finally:
        for x in (c,s):
            try:
                if x: x.close()
            except Exception: pass
def main():
    srv=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    srv.bind((LISTEN,LPORT)); srv.listen(500)
    while True:
        c,_=srv.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
main()
PYEOF
chmod +x /usr/local/bin/ws-ssh.py
cat > /etc/systemd/system/ws-ssh.service <<'EOF'
[Unit]
Description=SSH WebSocket
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-ssh.py 8088
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable ws-ssh >/dev/null 2>&1
if ! systemctl is-active --quiet ws-ssh; then systemctl start ws-ssh
elif [[ "$(fh /usr/local/bin/ws-ssh.py /etc/systemd/system/ws-ssh.service)" != "$H_WS" ]]; then svc_restart ws-ssh; fi

# tambahkan lokasi WS SSH ke Nginx (port 80/443 -> /ssh-ws)
NG=/etc/nginx/conf.d/xray.conf
if [[ -f $NG ]] && ! grep -q "ssh-ws" $NG; then
  sed -i '/# ---- WebSocket ----/i\    location = /ssh-ws { proxy_pass http://127.0.0.1:8088; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_read_timeout 3600s; }' $NG
  nginx -t >/dev/null 2>&1 && systemctl reload nginx
fi
# path "/" (dan path lain yang tidak dipakai Xray) + header Upgrade websocket -> SSH WS
if [[ -f $NG ]] && ! grep -q "cas-ssh-root" $NG; then
  sed -i '/# ---- WebSocket ----/i\    location / { # cas-ssh-root\n        if ($http_upgrade ~* "websocket") { proxy_pass http://127.0.0.1:8088; }\n    }' $NG
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx; else sed -i '/cas-ssh-root/,+2d' $NG; nginx -t && systemctl reload nginx; fi
fi

# ---------- Menu SSH ----------
echo -e "${GRN}[SSH 5/5] Menu SSH...${NC}"
cat > /usr/local/sbin/m-ssh <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
[[ -f /usr/local/lib/autoscript/notify.sh ]] && . /usr/local/lib/autoscript/notify.sh
DB=$ASD/db/ssh.db
TRASH=$ASD/db/ssh.trash
DOMAIN=$(cat $ASD/domain)
touch "$DB" "$TRASH"
# Format DB: user exp ipl status(active|locked|banned:epoch)
LINE="${B}════════════════════════════════════${N}"
header(){ clear; echo -e "$LINE"; printf "${P}%*s${N}\n" $(( (36+${#1})/2 )) "$1"; echo -e "$LINE"; }
bar(){ echo -e "$LINE"; printf "${BGB}${W}%*s%*s${N}\n" $(( (36+${#1})/2 )) "$1" $(( 36-(36+${#1})/2 )) ""; echo -e "$LINE"; }
pause(){ echo; read -rp "$(echo -e "${P}Press Enter for Back to Manage${N}")"; }
msg(){ echo -e "$1"; sleep 2; }
num_ok(){ [[ "$1" =~ ^[0-9]+$ ]]; }

# ---- non-interaktif ----
if [[ "$2" == "--delete" && -n "$3" ]]; then lock_db; ssh_remove "$3"; unlock_db; exit 0; fi
if [[ "$2" == "--expire" ]]; then lock_db; ssh_expire; unlock_db; exit 0; fi

sf(){ awk -v u="$1" -v f="$2" '$1==u{print $f}' "$DB"; }
sset(){ awk -v u="$1" -v f="$2" -v v="$3" '$1==u{$f=v}1' "$DB" > "$DB.t" && mv "$DB.t" "$DB"; }
exists(){ id "$1" &>/dev/null; }

ssh_remove(){ # user -> trash + hapus akun sistem
  local u=$1 line
  line=$(awk -v u="$u" '$1==u' "$DB"); [[ -z "$line" ]] && return 1
  is_trial "$u" || echo "$line $(date +%F)" >> "$TRASH"
  userdel -f "$u" 2>/dev/null
  awk -v u="$u" '$1!=u' "$DB" > "$DB.t" && mv "$DB.t" "$DB"
  rm -f $ASD/usage/ssh/$u
}
ssh_expire(){
  local today u exp lim list=""; today=$(date +%F); lim=$(date -d "-120 days" +%F)
  while read -r u exp _; do
    if [[ -n "$u" && "$exp" < "$today" ]]; then ssh_remove "$u"; is_trial "$u" || list+="• SSH <code>$u</code> (exp $exp)"$'\n'; fi
  done < <(cat "$DB")
  [[ -n "$list" ]] && cas_notify "⏰ <b>Akun Expired</b> (masuk Recovery)"$'\n'"$list"
  awk -v l="$lim" 'NF && $1 !~ /trial/ && $NF>=l' "$TRASH" > "$TRASH.t" && mv "$TRASH.t" "$TRASH"
}

show_account(){ # user pass exp ipl
  local u=$1 p=$2 exp=$3 ipl=$4 IP
  IP=$(jq -r '.ip // "-"' $ASD/ipinfo.json 2>/dev/null)
  clear
  echo -e "$LINE"; echo -e "          ${G}SSH ACCOUNT${N}"; echo -e "$LINE"
  printf " ${G}%-14s${N}: %s\n" "Username" "$u" "Password" "$p" "Host/Domain" "$DOMAIN" "IP" "$IP" \
    "Port OpenSSH" "22" "Port Dropbear" "143, 109" "Port SSH WS" "80, 443 (path /ssh-ws)" \
    "Port SSL/TLS" "443" "BadVPN UDP" "7100-7900" \
    "Limit IP" "$([[ "$ipl" == 0 ]] && echo Unlimited || echo "$ipl IP")" "Expired On" "$exp"
  echo -e "$LINE"
  echo -e " ${G}Payload WS (contoh):${N}"
  echo -e " GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Upgrade: websocket[crlf][crlf]"
  echo -e " ${G}Path WS :${N} / atau /ssh-ws (metode GET/PATCH, header Upgrade: websocket)"
  echo -e "$LINE"
  echo -e " ${G}Format OVPN/HTTP Custom:${N} $DOMAIN:22@$u:$p"
  echo -e "$LINE"
}

list_users(){ # $1 = all | active | inactive
  local f=${1:-all} title="LIST SSH USERS"
  [[ $f == active ]] && title="SSH USER AKTIF"
  [[ $f == inactive ]] && title="SSH USER TERKUNCI"
  header "$title"
  printf " ${G}%-3s %-14s %-10s %-3s %-6s${N}\n" "NO" "USER" "EXPIRED" "IP" "ST"
  local i=0 u exp ipl st lab
  while read -r u exp ipl st; do
    [[ -z "$u" ]] && continue
    [[ $f == active && "$st" != active ]] && continue
    [[ $f == inactive && "$st" == active ]] && continue
    i=$((i+1))
    case $st in active) lab="${G}ON${N}";; locked) lab="${R}LOCK${N}";; banned:*) lab="${Y}BAN${N}";; *) lab="$st";; esac
    printf " %-3s %-14s %-10s %-3s %b\n" "$i" "$u" "$exp" "$([[ "$ipl" == 0 ]] && echo - || echo "$ipl")" "$lab"
  done < "$DB"
  LISTED=$i
  if [[ $i == 0 ]]; then
    case $f in active) echo -e " ${Y}Tidak ada user aktif${N}";; inactive) echo -e " ${Y}Tidak ada user yang terkunci${N}";; *) echo -e " ${Y}Belum ada akun${N}";; esac
  fi
  echo -e "$LINE"; echo -e " ${G}Total : ${Y}$i${G} akun${N}"; echo -e "$LINE"
}

pick_user(){ # $1 = all | active | inactive
  local f=${1:-all} inp
  list_users "$f"
  [[ $LISTED == 0 ]] && { pause; return 1; }
  read -rp "Nomor / Username : " inp
  if [[ "$inp" =~ ^[0-9]+$ ]]; then
    U=$(awk -v n="$inp" -v f="$f" 'NF{ if(f=="active" && $4!="active") next; if(f=="inactive" && $4=="active") next; i++; if(i==n){print $1; exit} }' "$DB")
  else
    U=$inp
  fi
  [[ -n "$U" && -n "$(awk -v u="$U" '$1==u' "$DB")" ]] && return 0
  msg "${R}User tidak ditemukan${N}"; return 1
}

create(){
  local u p d ipl exp
  header "CREATE SSH"
  read -rp "Username : " u
  [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{2,20}$ ]] && { msg "${R}Username: huruf kecil/angka, 3-21 karakter${N}"; return; }
  exists "$u" && { msg "${R}Username sudah ada di sistem${N}"; return; }
  read -rp "Password : " p; [[ -z "$p" ]] && { msg "${R}Password kosong${N}"; return; }
  read -rp "Masa aktif (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Limit IP (0 = unlimited) [0] : " ipl; ipl=${ipl:-0}; num_ok "$ipl" || { msg "${R}Harus angka${N}"; return; }
  exp=$(date -d "+$d days" +%F)
  useradd -e "$exp" -s /bin/false -M "$u" 2>/dev/null
  echo -e "$p\n$p" | passwd "$u" >/dev/null 2>&1
  lock_db; echo "$u $exp $ipl active" >> "$DB"; unlock_db
  cas_notify "🆕 <b>SSH Dibuat</b>"$'\n'"User: <code>$u</code>"$'\n'"Expired: $exp"$'\n'"Limit IP: $ipl"
  show_account "$u" "$p" "$exp" "$ipl"; pause
}

trial(){
  local u p m exp
  u=$(gen_trial_user); p=$(tr -dc a-z0-9 </dev/urandom | head -c6)
  b=$(brand_txt); [[ "$(cat $ASD/brand_uuid 2>/dev/null)" == on && -n "$b" ]] && p="${b}-${p}"
  read -rp "Durasi trial (menit) [60] : " m; m=${m:-60}; num_ok "$m" || { msg "${R}Harus angka${N}"; return; }
  exp=$(date -d "+$m minutes" +%F)
  useradd -s /bin/false -M "$u" 2>/dev/null; echo -e "$p\n$p" | passwd "$u" >/dev/null 2>&1
  lock_db; echo "$u $exp 1 active" >> "$DB"; unlock_db
  echo "/usr/local/sbin/m-ssh ssh --delete $u" | at now + $m minutes >/dev/null 2>&1
  show_account "$u" "$p" "$m menit" 1; pause
}

delete(){ pick_user || return; lock_db; ssh_remove "$U"; unlock_db; cas_notify "🗑 <b>SSH Dihapus</b>"$'\n'"User: <code>$U</code>"; echo -e "${G}User $U dihapus${N}"; pause; }

renew(){
  local d base today new
  pick_user || return
  read -rp "Tambah masa aktif (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  base=$(sf "$U" 2); today=$(date +%F); [[ "$base" < "$today" ]] && base=$today
  new=$(date -d "$base +$d days" +%F)
  lock_db; sset "$U" 2 "$new"; chage -E "$(date -d "$new" +%Y-%m-%d)" "$U" 2>/dev/null
  usermod -U "$U" 2>/dev/null; [[ "$(sf "$U" 4)" != active ]] && sset "$U" 4 active
  unlock_db
  cas_notify "🔄 <b>SSH Diperpanjang</b>"$'\n'"User: <code>$U</code>"$'\n'"+$d hari → $new"
  echo -e "${G}User $U diperpanjang sampai $new${N}"; pause
}

modify_pass(){
  local p
  pick_user || return
  read -rp "Password baru : " p; [[ -z "$p" ]] && { msg "${R}Password kosong${N}"; return; }
  echo -e "$p\n$p" | passwd "$U" >/dev/null 2>&1
  echo -e "${G}Password $U diganti${N}"; pause
}

check_login(){
  header "SSH LOGIN AKTIF"
  local out; out=$(ps aux | grep -E "sshd:|dropbear" | grep -v grep)
  local i=0 u
  while read -r u; do
    [[ -z "$u" ]] && continue; i=$((i+1))
    printf " %-3s ${Y}%s${N}\n" "$i." "$u"
  done < <(echo "$out" | grep -oE '[a-z_][a-z0-9_-]*@' | tr -d '@' | sort | uniq -c | awk '{print $2" ("$1" sesi)"}')
  [[ $i == 0 ]] && echo -e " ${Y}Tidak ada sesi aktif${N}"
  echo -e "$LINE"; pause
}

lock_user(){ pick_user active || return; lock_db; usermod -L "$U" 2>/dev/null; pkill -u "$U" 2>/dev/null; sset "$U" 4 locked; unlock_db; cas_notify "🔒 <b>SSH Dikunci</b>"$'\n'"User: <code>$U</code>"; echo -e "${G}User $U dikunci${N}"; pause; }
unlock_user(){
  pick_user inactive || return
  [[ "$(sf "$U" 2)" < "$(date +%F)" ]] && { msg "${R}Akun expired, gunakan Renew${N}"; return; }
  lock_db; usermod -U "$U" 2>/dev/null; sset "$U" 4 active; unlock_db; cas_notify "🔓 <b>SSH Dibuka</b>"$'\n'"User: <code>$U</code>"; echo -e "${G}User $U dibuka${N}"; pause
}

recovery(){
  local i=0 u exp ipl st del inp new d names=()
  header "RECOVERY SSH"
  printf " ${G}%-3s %-14s %-12s${N}\n" "NO" "USERNAME" "DIHAPUS"
  while read -r u exp ipl st del; do [[ -z "$u" ]] && continue; i=$((i+1)); names+=("$u"); printf " %-3s %-14s %-12s\n" "$i" "$u" "$del"; done < <(tac "$TRASH" 2>/dev/null)
  [[ $i == 0 ]] && { echo -e " ${Y}Kosong${N}"; pause; return; }
  echo -e "$LINE"; echo -e " ${G}Total : ${Y}$i${G} akun${N}"; echo -e "$LINE"
  read -rp "Nomor / Username : " inp
  if [[ "$inp" =~ ^[0-9]+$ ]] && (( inp>=1 && inp<=i )); then u=${names[$((inp-1))]}; else u=$inp; fi
  local line; line=$(awk -v u="$u" '$1==u' "$TRASH" | tail -n1)
  [[ -z "$line" ]] && { msg "${R}Tidak ada di recovery${N}"; return; }
  exists "$u" && { msg "${R}Username sudah dipakai${N}"; return; }
  read -r u exp ipl st del <<< "$line"; ipl=${ipl:-0}
  read -rp "Password : " p; [[ -z "$p" ]] && { msg "${R}Password kosong${N}"; return; }
  read -rp "Masa aktif baru (hari) : " d; num_ok "$d" || { msg "${R}Harus angka${N}"; return; }
  read -rp "Limit IP (0 = unlimited) [$ipl] : " v; v=${v:-$ipl}; num_ok "$v" && ipl=$v
  new=$(date -d "+$d days" +%F)
  useradd -e "$new" -s /bin/false -M "$u" 2>/dev/null; echo -e "$p\n$p" | passwd "$u" >/dev/null 2>&1
  lock_db; echo "$u $new $ipl active" >> "$DB"; awk -v u="$u" '$1!=u' "$TRASH" > "$TRASH.t" && mv "$TRASH.t" "$TRASH"; unlock_db
  cas_notify "♻️ <b>SSH Dipulihkan</b>"$'\n'"User: <code>$u</code>"$'\n'"Expired: $new"
  show_account "$u" "$p" "$new" "$ipl"; pause
}

edit_limit(){ # all(0/1)
  local v st
  if [[ $1 == 1 ]]; then list_users; else pick_user || return; fi
  read -rp "Limit IP (0 = unlimited) : " v; num_ok "$v" || { msg "${R}Harus angka${N}"; return; }
  lock_db
  if [[ $1 == 1 ]]; then awk -v v="$v" 'NF{$3=v}1' "$DB" > "$DB.t" && mv "$DB.t" "$DB"; else sset "$U" 3 "$v"; fi
  unlock_db; echo -e "${G}Tersimpan${N}"; pause
}

while true; do
  header "SSH-DROPBEAR-OPENVPN"
  echo -e "\n ${C}1.)${N}  Create"
  echo -e " ${C}2.)${N}  Trial"
  echo -e " ${C}3.)${N}  Delete"
  echo -e " ${C}4.)${N}  Renew/Extend"
  echo -e " ${C}5.)${N}  Modify Password"
  echo -e " ${C}6.)${N}  Check Users Login"
  echo -e " ${C}7.)${N}  List Users"
  bar "LOCK & UNLOCK"
  echo -e " ${C}8.)${N}  Lock"
  echo -e " ${C}9.)${N}  Unlock"
  bar "UTILITIES"
  echo -e " ${C}10.)${N} Recovery"
  echo -e " ${C}11.)${N} Edit Limit IP"
  echo -e " ${C}12.)${N} Edit Limit IP All"
  echo -e " ${C}13.)${N} Back to Menu"
  echo -e " ${C}x.)${N}  Exit"
  echo -e "$LINE\n"
  read -rp "$(echo -e "${G}Select From Options [1-13 or x] : ${N}")" opt
  case $opt in
    1) create ;;
    2) trial ;;
    3) delete ;;
    4) renew ;;
    5) modify_pass ;;
    6) check_login ;;
    7) list_users; pause ;;
    8) lock_user ;;
    9) unlock_user ;;
    10) recovery ;;
    11) edit_limit 0 ;;
    12) edit_limit 1 ;;
    13) exit 0 ;;
    x|X) clear; kill -TERM $PPID 2>/dev/null; exit 0 ;;
    *) msg "${R}Pilihan salah${N}" ;;
  esac
done
EOF
chmod +x /usr/local/sbin/m-ssh

# ---------- Limit IP SSH di guard ----------
cat > /usr/local/lib/autoscript/ssh-guard.sh <<'EOF'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh
[[ -f /usr/local/lib/autoscript/notify.sh ]] && . /usr/local/lib/autoscript/notify.sh
DB=$ASD/db/ssh.db
[[ -f $DB ]] || exit 0
BANMIN=$(cat $ASD/bantime 2>/dev/null || echo 15)
now=$(date +%s)
sset(){ awk -v u="$1" -v f="$2" -v v="$3" '$1==u{$f=v}1' "$DB" > "$DB.t" && mv "$DB.t" "$DB"; }
while read -r u exp ipl st; do
  [[ -z "$u" ]] && continue
  if [[ "$st" == banned:* ]]; then
    (( now >= ${st#banned:} )) && { usermod -U "$u" 2>/dev/null; sset "$u" 4 active; }
    continue
  fi
  [[ "$st" != active || ! "$ipl" =~ ^[0-9]+$ || "$ipl" -eq 0 ]] && continue
  n=$(ps aux | grep -E "sshd:|dropbear" | grep -v grep | grep -oE "$u@|$u\b" | wc -l)
  if (( n > ipl )); then usermod -L "$u" 2>/dev/null; pkill -u "$u" 2>/dev/null; sset "$u" 4 "banned:$(( now + BANMIN*60 ))"
    cas_notify "🚫 <b>Multi Login</b>"$'\n'"SSH <code>$u</code> $n sesi (limit $ipl)"$'\n'"Banned ${BANMIN} menit"; fi
done < <(cat "$DB")
EOF
chmod +x /usr/local/lib/autoscript/ssh-guard.sh
grep -q "ssh-guard" /etc/cron.d/autoscript || echo "* * * * * root /usr/local/lib/autoscript/ssh-guard.sh" >> /etc/cron.d/autoscript
grep -q "m-ssh ssh --expire" /etc/cron.d/autoscript || echo "5 0 * * * root /usr/local/sbin/m-ssh ssh --expire" >> /etc/cron.d/autoscript

touch $ASD/db/ssh.db $ASD/db/ssh.trash
echo -e "${GRN}Modul SSH selesai.${NC}"
