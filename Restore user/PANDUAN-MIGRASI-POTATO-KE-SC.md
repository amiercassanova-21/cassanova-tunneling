# Panduan Migrasi Akun: Potato → SC Cassanova

Panduan ini memindahkan **semua akun** (aktif + recovery) dari VPS **Potato**
ke VPS **SC Cassanova** Anda. Sudah teruji berhasil (519 akun: 410 vless + 109 vmess).

> **Aman:** proses di Potato hanya **MEMBACA** database (tidak mengubah apa pun),
> jadi Potato tetap jalan normal selama migrasi. Yang berubah hanya di VPS SC.

---

## Ringkasan Alur

1. **Di Potato** — jalankan exporter → menghasilkan file `potato-migrate.tsv`.
2. **Salin** file itu dari Potato ke VPS SC (perintah `scp`).
3. **Di SC** — backup dulu → jalankan importer (dry-run → uji 3 → penuh).

Yang Anda butuhkan:
- Akses **root** ke VPS Potato (SSH / Termius).
- Akses **root** ke VPS SC.
- IP kedua VPS.

---

## LANGKAH 1 — Di VPS POTATO (export)

Login ke Potato, lalu tempel blok ini untuk membuat exporter:

```bash
cat > /root/potato-export.sh <<'SCRIPT'
#!/bin/bash
# Jalankan di VPS POTATO. Hanya MEMBACA potato.db -> tulis TSV untuk migrasi.
set -u
DB="${1:-/usr/sbin/potatonc/potato.db}"
OUT="${2:-/root/potato-migrate.tsv}"
[ -f "$DB" ] || { echo "potato.db tidak ditemukan: $DB"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || apt-get install -y sqlite3 >/dev/null 2>&1
: > "$OUT"
q(){ sqlite3 -noheader -separator $'\t' "$DB" "$1" >> "$OUT"; }
q "SELECT 'vless',username,uuid,date_exp,limit_ip,max_bw,use_bw,status,status_lock FROM account_vlesses;"
q "SELECT 'vmess',username,uuid,date_exp,limit_ip,max_bw,use_bw,status,status_lock FROM account_vmesses;"
q "SELECT 'trojan',username,uuid,date_exp,limit_ip,max_bw,use_bw,status,status_lock FROM account_trojans;"
q "SELECT 'ssh',username,password,date_exp,limit_ip,max_bw,use_bw,status,status_lock FROM account_sshs;"
echo "OK -> $OUT"
echo "Total akun: $(grep -c . "$OUT")"
awk -F'\t' '{c[$1]++} END{for(p in c) printf "  %-7s %d\n", p, c[p]}' "$OUT"
echo "Status:"; awk -F'\t' '{s[$8]++} END{for(x in s) printf "  %-10s %d\n", x, s[x]}' "$OUT"
SCRIPT
chmod +x /root/potato-export.sh && echo "exporter dibuat."
```

Lalu jalankan:

```bash
bash /root/potato-export.sh
```

**Cek path database Potato** kalau muncul "potato.db tidak ditemukan".
Cari dengan:
```bash
find / -name potato.db 2>/dev/null
```
Kalau letaknya beda, jalankan dengan path itu, contoh:
```bash
bash /root/potato-export.sh /usr/sbin/potatonc/potato.db
```

Hasil akhir: file **`/root/potato-migrate.tsv`** + ringkasan jumlah akun.

---

## LANGKAH 2 — Salin file Potato → SC

Jalankan ini **di VPS POTATO** (ganti `IP_SC` dengan IP VPS SC Anda):

```bash
scp /root/potato-migrate.tsv root@IP_SC:/root/potato-migrate.tsv
```

- Kalau muncul pertanyaan fingerprint, ketik **`yes`**.
- Masukkan **password root VPS SC**.
- Berhasil kalau muncul: `potato-migrate.tsv 100% ...`.

> Alternatif tanpa scp: buka file `/root/potato-migrate.tsv` di Potato, salin
> isinya, lalu tempel ke file baru di SC. Tapi `scp` jauh lebih mudah.

---

## LANGKAH 3 — Di VPS SC (import)

### 3a. Buat importer

Login ke VPS SC, tempel blok ini:

```bash
cat > /root/cas-import.sh <<'SCRIPT'
#!/bin/bash
# Jalankan di VPS SC. Impor akun hasil export Potato ke SC.
# DEFAULT = DRY-RUN (hanya menampilkan rencana, tidak mengubah apa pun).
. /usr/local/lib/autoscript/lib.sh 2>/dev/null || { echo "lib.sh SC tidak ditemukan - jalankan di VPS SC"; exit 1; }
TSV="${1:?pakai: cas-import.sh <file.tsv> [--commit] [--limit N] [--proto p1,p2]}"
[ -f "$TSV" ] || { echo "file tidak ada: $TSV"; exit 1; }
COMMIT=0; LIMIT=0; ONLY=""
shift || true
while [ $# -gt 0 ]; do case "$1" in
  --commit) COMMIT=1;;
  --limit) LIMIT="${2:-0}"; shift;;
  --proto) ONLY="${2:-}"; shift;;
esac; shift; done
today=$(date +%F)
nadd=0 nrec=0 nskip=0 done=0
MODE="DRY-RUN (tidak mengubah apa pun)"; [ "$COMMIT" = 1 ] && MODE="COMMIT (menulis perubahan)"
echo "== Impor Potato -> SC | mode: $MODE =="
while IFS=$'\t' read -r proto user secret exp ipl maxbw usebw status slock; do
  [ -z "${proto:-}" ] || [ -z "${user:-}" ] && continue
  [ -n "$ONLY" ] && case ",$ONLY," in *",$proto,"*) ;; *) continue;; esac
  [ "$LIMIT" -gt 0 ] && [ "$done" -ge "$LIMIT" ] && break
  q=0; case "$maxbw" in ''|*[!0-9]*) maxbw=0;; esac
  [ "$maxbw" -gt 0 ] && q=$(( (maxbw + 1073741823) / 1073741824 ))
  case "$ipl" in ''|*[!0-9]*) ipl=0;; esac
  st=active; [ "$slock" = "LOCKED" ] && st=locked
  rec=0; [ "$status" = "RECOVERY" ] && rec=1
  if [ "$proto" = "ssh" ]; then
    if id "$user" >/dev/null 2>&1; then nskip=$((nskip+1)); echo "SKIP ssh    $user (user sistem sudah ada)"; continue; fi
    if [ "$rec" = 1 ]; then
      echo "REC  ssh    $user -> trash (exp $exp)"; nrec=$((nrec+1))
      [ "$COMMIT" = 1 ] && echo "$user $exp $ipl active $today" >> "$ASD/db/ssh.trash"
    else
      echo "ADD  ssh    $user exp=$exp ip=$ipl st=$st"; nadd=$((nadd+1)); done=$((done+1))
      if [ "$COMMIT" = 1 ]; then
        useradd -e "$exp" -s /bin/false -M "$user" >/dev/null 2>&1
        echo "$user:$secret" | chpasswd >/dev/null 2>&1
        grep -qx "$user $exp $ipl $st" "$ASD/db/ssh.db" 2>/dev/null || echo "$user $exp $ipl $st" >> "$ASD/db/ssh.db"
      fi
    fi
    continue
  fi
  case "$proto" in vless|vmess|trojan) ;; *) continue;; esac
  if [ -n "$(db_get "$proto" "$user" 2>/dev/null)" ]; then nskip=$((nskip+1)); echo "SKIP $proto $user (sudah ada di SC)"; continue; fi
  if [ "$rec" = 1 ]; then
    echo "REC  $proto $user -> trash (exp $exp)"; nrec=$((nrec+1))
    [ "$COMMIT" = 1 ] && echo "$user $exp $secret $ipl $q active $today" >> "$ASD/db/$proto.trash"
  else
    echo "ADD  $proto $user exp=$exp ip=$ipl q=${q}GB st=$st"; nadd=$((nadd+1)); done=$((done+1))
    if [ "$COMMIT" = 1 ]; then
      lock_db
      echo "$user $exp $secret $ipl $q $st" >> "$ASD/db/$proto.db"
      xray_add "$proto" "$user" "$secret"
      unlock_db
    fi
  fi
done < "$TSV"
echo "-----------------------------------------"
echo "Aktif ditambah : $nadd"
echo "Ke Recovery    : $nrec"
echo "Dilewati       : $nskip"
if [ "$COMMIT" = 1 ]; then
  if xray run -test -config "$CFG" >/dev/null 2>&1; then echo "Config Xray VALID."; else echo "PERINGATAN: config Xray tidak valid, cek: xray run -test -config $CFG"; fi
else
  echo "(DRY-RUN. Tambah --commit untuk menerapkan. Disarankan uji dulu: --commit --limit 3)"
fi
SCRIPT
chmod +x /root/cas-import.sh && echo "importer dibuat."
```

### 3b. BACKUP dulu (WAJIB, biar bisa balik)

```bash
cp -a /etc/autoscript/db /root/db.bak && cp -a /usr/local/etc/xray/config.json /root/config.json.bak && echo "BACKUP OK"
```

### 3c. Dry-run (aman, tidak mengubah apa pun)

```bash
bash /root/cas-import.sh /root/potato-migrate.tsv
```
Cek angka di akhir: total akun cocok, "Dilewati 0".

### 3d. Uji 3 akun dulu

```bash
bash /root/cas-import.sh /root/potato-migrate.tsv --commit --limit 3
```
Cek lewat `menu` → list akun, pastikan 3 akun masuk & bisa dipakai konek.

### 3e. Impor penuh

```bash
bash /root/cas-import.sh /root/potato-migrate.tsv --commit
```
Selesai. Akun aktif → aktif, akun expired → masuk Recovery.

---

## KALAU MAU BATAL / BALIK SEPERTI SEMULA

### Cara 1 — Restore dari backup (paling gampang, kalau sudah backup di 3b)

```bash
rm -rf /etc/autoscript/db && cp -a /root/db.bak /etc/autoscript/db && cp -a /root/config.json.bak /usr/local/etc/xray/config.json && systemctl restart xray && echo "RESTORE OK"
```

### Cara 2 — Undo (kalau lupa backup)

Buat skrip undo:

```bash
cat > /root/cas-import-undo.sh <<'SCRIPT'
#!/bin/bash
. /usr/local/lib/autoscript/lib.sh 2>/dev/null || { echo "lib.sh SC tidak ditemukan - jalankan di VPS SC"; exit 1; }
TSV="${1:?pakai: cas-import-undo.sh <file.tsv> [--commit] [--proto p1,p2]}"
[ -f "$TSV" ] || { echo "file tidak ada: $TSV"; exit 1; }
COMMIT=0; ONLY=""
shift || true
while [ $# -gt 0 ]; do case "$1" in
  --commit) COMMIT=1;;
  --proto) ONLY="${2:-}"; shift;;
esac; shift; done
MODE="DRY-RUN (tidak mengubah apa pun)"; [ "$COMMIT" = 1 ] && MODE="COMMIT (menghapus)"
echo "== Undo impor Potato | mode: $MODE =="
ndel=0 ndelr=0 nmiss=0
trash_del(){ local f="$1" u="$2"; [ -f "$f" ] || return 0
  awk -v u="$u" 'BEGIN{done=0}{ if(!done && $1==u){done=1; next} print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
while IFS=$'\t' read -r proto user secret exp ipl maxbw usebw status slock; do
  [ -z "${proto:-}" ] || [ -z "${user:-}" ] && continue
  [ -n "$ONLY" ] && case ",$ONLY," in *",$proto,"*) ;; *) continue;; esac
  rec=0; [ "$status" = "RECOVERY" ] && rec=1
  if [ "$proto" = "ssh" ]; then
    if [ "$rec" = 1 ]; then echo "DEL-REC ssh $user"; ndelr=$((ndelr+1)); [ "$COMMIT" = 1 ] && trash_del "$ASD/db/ssh.trash" "$user"
    else if id "$user" >/dev/null 2>&1; then echo "DEL ssh $user"; ndel=$((ndel+1))
        if [ "$COMMIT" = 1 ]; then userdel "$user" >/dev/null 2>&1
          awk -v u="$user" '$1!=u' "$ASD/db/ssh.db" > "$ASD/db/.ssh.tmp" && mv "$ASD/db/.ssh.tmp" "$ASD/db/ssh.db"; fi
      else echo "-   ssh $user (tidak ada)"; nmiss=$((nmiss+1)); fi; fi
    continue; fi
  case "$proto" in vless|vmess|trojan) ;; *) continue;; esac
  if [ "$rec" = 1 ]; then echo "DEL-REC $proto $user"; ndelr=$((ndelr+1)); [ "$COMMIT" = 1 ] && trash_del "$ASD/db/$proto.trash" "$user"
  else if [ -n "$(db_get "$proto" "$user" 2>/dev/null)" ]; then echo "DEL $proto $user"; ndel=$((ndel+1))
      if [ "$COMMIT" = 1 ]; then lock_db; xray_del "$proto" "$user"; db_del "$proto" "$user"; unlock_db; fi
    else echo "-   $proto $user (tidak ada di SC)"; nmiss=$((nmiss+1)); fi; fi
done < "$TSV"
echo "-----------------------------------------"
echo "Akun aktif dihapus : $ndel"; echo "Baris recovery hapus: $ndelr"; echo "Dilewati (tak ada) : $nmiss"
if [ "$COMMIT" = 1 ]; then
  if xray run -test -config "$CFG" >/dev/null 2>&1; then echo "Config Xray VALID."; else echo "PERINGATAN: config Xray tidak valid"; fi
else echo "(DRY-RUN. Tambah --commit untuk benar-benar menghapus.)"; fi
SCRIPT
chmod +x /root/cas-import-undo.sh && echo "undo dibuat."
```

Jalankan (dry-run dulu, lalu commit):
```bash
bash /root/cas-import-undo.sh /root/potato-migrate.tsv
bash /root/cas-import-undo.sh /root/potato-migrate.tsv --commit
```

---

## Catatan Penting

- **Selalu export ulang dari Potato saat mau pindah beneran.** File TSV cepat basi
  karena akun di Potato terus berubah (daftar baru, perpanjang, expired).
- **Uji di VPS tes dulu**, jangan langsung di VPS produksi.
- Konversi kuota: byte Potato → GB SC (dibulatkan ke atas). `0` = unlimited.
- Status: `AKTIF` → akun aktif · `RECOVERY` → masuk Recovery · `LOCKED` → terkunci.
- Akun yang **sudah ada** di SC otomatis **dilewati** (tidak dobel).
- Filter opsional: `--proto vless` (protokol tertentu) · `--limit N` (N akun pertama).

---
*Dokumen ini dibuat untuk Cassanova Tunneling. Simpan baik-baik.*
