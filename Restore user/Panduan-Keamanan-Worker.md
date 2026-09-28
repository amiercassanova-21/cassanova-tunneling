# Panduan Keamanan: Repo Private + Worker Delivery + Watermark

Tujuan: source SC tidak bisa dilihat/disalin publik, dan tiap SC terpasang punya
**watermark unik** (client·IP·exp·tanggal) — kalau bocor, ketahuan dari license siapa.

> **URUTAN ITU WAJIB.** Jangan jadikan repo private lebih dulu — install & updatesc
> semua buyer akan langsung mati. Ikuti langkah 1→5 berurutan.

Rahasia (GH_TOKEN) **hanya** dimasukkan ke Cloudflare Worker Secret. **Jangan pernah
kirim token ke chat / taruh di VPS / commit ke repo.**

---

## LANGKAH 1 — Deploy Worker baru (repo MASIH publik)

1. Buka **Cloudflare Dashboard → Workers & Pages → worker license Anda → Edit code**.
2. Ganti seluruh isinya dengan `worker.js` versi baru (v1.47.0) yang saya kirim.
3. **Save and Deploy**.

Belum bikin token pun tidak apa (langkah 2), tapi `/raw` baru berfungsi setelah token diset.

---

## LANGKAH 2 — Buat GitHub token (read-only) + pasang ke Worker Secret

**2a. Buat Fine-grained Personal Access Token:**
- GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
- Name: `cassanova-worker` · Expiration: 1 tahun (atau sesuai selera).
- **Repository access → Only select repositories →** pilih `cassanova-tunneling`.
- **Permissions → Repository permissions → Contents → Read-only**. (biarkan yang lain "No access")
- Generate → **salin token** (muncul sekali).

**2b. Pasang token sebagai Secret di Worker:**
- Cloudflare → Worker Anda → **Settings → Variables and Secrets → Add**.
- Type: **Secret** · Name: `GH_TOKEN` · Value: (tempel token) → **Save/Deploy**.
- (Opsional) tambah Secret/Variable `GH_REPO` = `amiercassanova-21/cassanova-tunneling`
  kalau nanti nama repo berubah. Default sudah benar, jadi boleh dilewati.

**2c. Uji /raw jalan** (dari komputer/VPS mana saja, ganti domain Worker Anda):
```bash
curl -s "https://license.cassanova.my.id/raw/version"
```
Harus keluar teks versi (mis. `v1.47.0`). Kalau keluar `GH_TOKEN belum diset` → ulangi 2b.
Kalau `gagal ambil file` → cek nama repo & permission token.

---

## LANGKAH 3 — Push v1.47.0 ke repo, lalu UJI di Test SC (repo masih publik)

1. Upload semua file dari `cassanova-tunneling-v1.47.0.zip` ke repo (branch main).
2. Di **Test SC** (139.59.125.252), jalankan `updatesc` → harus sukses ke v1.47.0.
   - Setelah update, cek BASE-nya sudah ke Worker:
     ```bash
     grep -n 'license_url' /usr/local/sbin/cas-update | head
     ```
3. **Uji install baru** di 1 VPS kosong (atau reinstall Test SC) pakai link install biasa.
   Harus jalan sampai selesai. Ini membuktikan alur `/raw` berfungsi penuh.
4. Cek watermark tertanam:
   ```bash
   grep -h 'cas-wm' /usr/local/sbin/m-xray /usr/local/sbin/menu 2>/dev/null | head
   ```
   Harus muncul baris `# cas-wm|<client>|<ip>|<exp>|<tanggal>`.

> Sampai langkah ini, repo MASIH publik → aman, tidak ada yang putus. Kalau ada
> masalah, tinggal perbaiki tanpa risiko.

---

## LANGKAH 4 — Migrasikan VPS produksi ke v1.47.0

Sebelum repo dijadikan private, **semua VPS produksi harus sudah v1.47.0** (karena
install lama masih menunjuk ke raw GitHub publik; kalau repo langsung diprivate,
updatesc mereka mati).

- Jalankan `updatesc` di tiap VPS produksi (atau tunggu auto-update kalau aktif).
- Cek versi di layar awal menu = **v1.47.0**.

> Kalau ada VPS yang belum sempat update saat repo sudah private: layanan &
> pengecekan lisensi harian TETAP jalan (itu lewat /check, tidak terpengaruh).
> Yang mati hanya updatesc-nya sampai dia dimigrasi. Jadi tidak fatal, tapi
> sebaiknya migrasikan dulu sebisanya.

---

## LANGKAH 5 — Jadikan repo PRIVATE

Setelah Test SC OK dan produksi sudah v1.47.0:

1. GitHub → repo `cassanova-tunneling` → **Settings → General → Danger Zone →
   Change repository visibility → Make private**.
2. Uji ulang di Test SC:
   ```bash
   updatesc
   ```
   Harus tetap sukses (sekarang lewat Worker + token).
3. Bukti publik sudah tertutup (harus 404 sekarang):
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     https://raw.githubusercontent.com/amiercassanova-21/cassanova-tunneling/main/update.sh
   ```
   → `404` = sukses (publik tidak bisa lagi baca source).
4. Sedangkan lewat Worker tetap bisa (untuk IP berlisensi):
   ```bash
   curl -s "https://license.cassanova.my.id/raw/version"
   ```

Selesai. Source sekarang private + tiap SC ber-watermark.

---

## Kalau ada masalah (rollback cepat)
- **Balikkan repo ke Public** (Settings → visibility) → semua kembali normal seperti
  sebelum perubahan (script v1.47.0 tetap jalan lewat Worker; install lama lewat raw
  GitHub juga jalan lagi).
- Cek log Worker real-time: Cloudflare → Worker → **Logs (Begin log stream)** saat
  menjalankan updatesc di Test SC, untuk melihat error `/raw`.

## Catatan
- Token GitHub **hanya** di Worker Secret. Jangan taruh di VPS/repo/chat.
- Watermark = komentar `# cas-wm|client|ip|exp|tanggal` di tiap file .sh terpasang.
  Ini menandai asal SC bila bocor. Bisa diperketat lagi nanti (disamarkan/di banyak titik).
- Rate limit GitHub API (token): 5000 request/jam — jauh lebih dari cukup.
- Channel beta tetap didukung (Worker menerima ?ref=beta).
