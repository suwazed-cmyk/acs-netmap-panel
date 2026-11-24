# ACS NETMAP Panel: GenieACS + VPN MikroTik

Paket untuk menjalankan **GenieACS di VPS** yang bisa mengelola dan memberi perintah (Summon) ke ONT di **banyak router MikroTik**, walaupun semua router memakai **subnet lokal yang sama** (misalnya semua `10.0.0.0/24`).

```
ONT ─ OLT ─ MikroTik router A ═══ VPN L2TP / ZeroTier ═══╗
ONT ─ OLT ─ MikroTik router B ═══ VPN L2TP / ZeroTier ═══╬══ VPS (GenieACS + Panel)
ONT ─ OLT ─ MikroTik router C ═══ VPN L2TP / ZeroTier ═══╝        ▲
                                                Remote Winbox: IP_VPS:20001
```

## Fitur

- **VPN L2TP** dari setiap MikroTik ke VPS, atau **ZeroTier** untuk router RouterOS v7 ARM/ARM64
- **IP virtual (NETMAP)** per router: ONT `10.0.0.25` di router A terlihat di GenieACS sebagai `10.100.1.25`, di router B sebagai `10.100.2.25`
- **Patch GenieACS** agar Summon memakai IP virtual
- **Panel web**:
  - Akun VPN dan **script MikroTik siap salin**, mengikuti nama panel Anda
  - **Tes koneksi** bertahap, status **tersambung/terputus**, dan **riwayat uptime** 24 jam / 7 hari / 30 hari
  - **Port forwarding** untuk remote Winbox / WebFig / web ONT lewat IP publik VPS
  - Halaman **GenieACS** (status layanan, patch, jumlah ONT per router) dan **ZeroTier** (anggota jaringan)
  - **Notifikasi Telegram** saat VPN putus, dikirim ke grup bertopik
  - **Domain Cloudflare + HTTPS** otomatis, termasuk subdomain untuk GenieACS dan ZTNET
  - **Log aktivitas** dan **nama panel** yang bisa diganti
  - **Alamat tanpa port**: panel dibuka di port 80/443 (`http://IP-VPS` atau `https://domain`)
  - Menu **Add-on** dengan tombol **Install** dan progres 0–100%:
    - **ZeroTier + ZTNET** (add-on sistem; menu ZeroTier baru muncul setelah dipasang)
    - **[Panel ACS](https://github.com/suwazed-cmyk/panel-acs)**: monitoring ONT, **history redaman** seperti SmartOLT, peta lokasi. Dibuka di `/acs`
    - **[Bilingku](https://github.com/suwazed-cmyk/bilingku)**: billing PPPoE & Hotspot MikroTik. Dibuka di `/billing`
- Script bantu: **`ringkasan.sh`** (alamat web dan port) dan **`cek.sh`** (tes semua layanan)

## Isi repo

| File | Fungsi |
|---|---|
| `install-vpn-acs.sh` | Installer Panel VPN ACS (sudah berisi seluruh panel) |
| `genieacs-virtualip.sh` | Patch IP virtual untuk GenieACS v1.2.13 |
| `pasang-ztnet.sh` | Memasang ZeroTier + ZTNET tanpa Docker, web di port 3300 (opsional) |
| `ringkasan.sh` | Ringkasan semua layanan: alamat web, port, status, port firewall |
| `cek.sh` | Tes semua layanan: service, port, web menjawab, patch, sertifikat, DNS |
| `bersihkan.sh` | Menghapus pengaturan yang dipasang repo ini dari VPS |
| `panel/server.js`, `panel/public/index.html` | Kode sumber panel (untuk dibaca/diubah) |

## Yang dibutuhkan

| | Minimal | Disarankan |
|---|---|---|
| Virtualisasi | **KVM** (bukan OpenVZ/LXC) | KVM |
| OS | **Ubuntu 22.04 LTS 64-bit** | Ubuntu 22.04 LTS 64-bit |
| CPU / RAM | 1 vCPU / 2 GB | 2 vCPU / 4 GB |
| Disk | 25 GB SSD | 40 GB SSD/NVMe |
| IP | 1 IPv4 publik statis | 1 IPv4 publik statis |

Jangan pakai Ubuntu 24.04: MongoDB 4.4 dari `genie.sh` kemungkinan gagal terpasang.

Selain VPS: MikroTik (RouterOS v6 atau v7) dengan akses Winbox, dan ONT yang mendukung TR-069.

## Gambaran pemasangan

| Tahap | Langkah | Hasil |
|---|---|---|
| **A. Siapkan VPS** | 1–2 | VPS siap, repo terunduh |
| **B. Pasang layanan** | 3–7 | L2TP, GenieACS, patch IP virtual, panel berjalan, port terbuka |
| **C. Hubungkan router** | 8–11 | Router tersambung, ONT muncul di GenieACS, Summon berhasil |
| **D. Fitur opsional** | — | Telegram, domain + HTTPS, ZeroTier (bisa kapan saja, tidak wajib) |

Setelah setiap langkah, Anda bisa menjalankan `bash ringkasan.sh` (alamat web dan port) atau `bash cek.sh` (tes apakah semuanya berjalan).

---

## Instalasi inti

### 1. Persiapan VPS
```bash
apt update && apt upgrade -y
timedatectl set-timezone Asia/Makassar
apt install -y curl wget git nano openssl iputils-ping

# swap 2 GB
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# cek: harus kvm, Ubuntu 22.04, dan kernel tanpa kata "cloud"
systemd-detect-virt
lsb_release -a
uname -r
```
Ganti `Asia/Makassar` dengan zona waktu Anda (`Asia/Jakarta` untuk WIB, `Asia/Jayapura` untuk WIT).

### 2. Ambil repo ini
```bash
cd /root
git clone https://github.com/suwazed-cmyk/acs-netmap-panel.git
cd acs-netmap-panel
```

### 3. Server VPN L2TP
```bash
wget -O /root/vpnsetup.sh https://raw.githubusercontent.com/beryindo/genieacs/refs/heads/main/vpnsetup.sh
bash /root/vpnsetup.sh
systemctl status xl2tpd --no-pager | head -5
```
Status harus `active (running)`.

### 4. GenieACS
`genie.sh` mengunduh `libssl1.1` dari `ftp.debian.org`, yang sering macet. Baris `sed` di bawah mengganti sumbernya ke server Ubuntu:
```bash
wget -O /root/genie.sh https://raw.githubusercontent.com/beryindo/genieacs/refs/heads/main/genie.sh
sed -i 's#https://ftp.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb#http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb#; s#dpkg -i libssl1.1_1.1.1w-0+deb11u1_amd64.deb#dpkg -i libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb#' /root/genie.sh
grep -n "libssl" /root/genie.sh
bash /root/genie.sh
```
Ketik `y` saat ditanya. Cek: `systemctl status mongod genieacs-cwmp genieacs-ui --no-pager | grep -E "●|Active"`

**Perbaikan keamanan (wajib):** ganti kunci login GenieACS UI dan tutup NBI dari internet.
```bash
sed -i "s/^GENIEACS_UI_JWT_SECRET=.*/GENIEACS_UI_JWT_SECRET=$(openssl rand -hex 32)/" /opt/genieacs/genieacs.env
grep -q '^GENIEACS_NBI_INTERFACE=' /opt/genieacs/genieacs.env \
  && sed -i 's/^GENIEACS_NBI_INTERFACE=.*/GENIEACS_NBI_INTERFACE=127.0.0.1/' /opt/genieacs/genieacs.env \
  || echo 'GENIEACS_NBI_INTERFACE=127.0.0.1' >> /opt/genieacs/genieacs.env
systemctl restart genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui
```

### 5. Patch IP virtual GenieACS
```bash
cd /root/acs-netmap-panel
bash genieacs-virtualip.sh
```
Di akhir muncul ringkasan. Cek patch: `bash genieacs-virtualip.sh status`

Rentang IP virtual tidak perlu diatur di sini. Setelah panel terpasang, **panel mengatur rentangnya sendiri** mengikuti IP virtual setiap router: rentang otomatis `10.100.0.0/14` ditambah IP virtual yang Anda isi sendiri (misalnya `172.16.10.0/24`). Lihat menu **GenieACS** di panel.

### 6. Panel VPN ACS
```bash
cd /root/acs-netmap-panel
bash install-vpn-acs.sh
```
Saat ditanya password admin, tekan **Enter** untuk memakai password bawaan **`Admin123`**, atau ketik password sendiri (minimal 8 karakter).

Di akhir instalasi muncul **ringkasan**: alamat web panel dan GenieACS, URL ACS untuk ONT, status layanan, dan port yang harus dibuka.

### 7. Firewall provider
Jangan menyalakan `ufw` karena bentrok dengan aturan VPN. Buka port berikut di firewall provider VPS (jika ada):

| Port | Protokol | Untuk |
|---|---|---|
| 22 | TCP | SSH |
| 1701 | UDP | VPN L2TP |
| 8088 | TCP | Panel VPN ACS |
| 3000 | TCP | Web GenieACS |
| 20001-20999 | TCP | Port forwarding (remote Winbox / web ONT) |
| 500, 4500 | UDP | Hanya jika IPsec dinyalakan |
| 3300 | TCP | Web ZTNET, hanya jika memakai ZeroTier |
| 9993 | UDP | ZeroTier, hanya jika memakai ZeroTier |

Port 7547 dan 7557 **tidak perlu** dibuka: ONT menghubungi GenieACS lewat VPN. HTTPS panel memakai port 8088 yang sama dan tidak butuh port 80/443.

Sekarang tes semua layanan:
```bash
bash cek.sh
```
Setiap pemeriksaan diberi tanda **[OK]**, **[PERINGATAN]**, atau **[GAGAL]**. Baris yang gagal disertai perintah untuk memperbaikinya. Komponen yang belum dipasang ditandai **[LEWATI]**.

### 8. Atur panel dan GenieACS (sekali di awal)
Buka `http://IP_VPS:8088` lalu login.

Menu **Pengaturan → Umum**:
1. **Nama panel** (opsional), misalnya `INET WIFI`. Dipakai di judul panel dan sebagai komentar aturan di MikroTik (`INET WIFI - ONT ke IP virtual`). Bisa diganti kapan saja; script baru otomatis membersihkan aturan dengan nama lama.
2. **Alamat VPS**: IP publik VPS (atau domain). Alamat ini dipakai di script MikroTik.
3. **Pakai IPsec**: biarkan mati (L2TP biasa), kecuali Anda memang butuh.
4. **Jaringan VPN (L2TP)**: tentukan **sekarang** (bawaan `192.168.42.0/24`). Mengganti belakangan berarti URL ACS di semua ONT ikut berubah.
5. **Password admin**: ganti jika masih `Admin123`. Selama belum diganti, dashboard menampilkan peringatan.

Menu **GenieACS**: pastikan **Patch IP virtual** berstatus **Aktif** dan keempat layanan **Berjalan**. Kartu ini juga menampilkan rentang IP virtual yang dipakai GenieACS. Kolom **Rentang tambahan** hanya perlu diisi jika Anda punya ONT dengan IP virtual buatan sendiri di luar panel.

Buka **GenieACS UI** di `http://IP_VPS:3000`. Jika muncul *initialization wizard*, buat akun admin dan centang **Users saja** agar konfigurasi dari repo beryindo tidak tertimpa.

### 9. Tambah router
Panel → **Tambah router**:
1. **Jalur ke VPS**: pilih **L2TP** (semua MikroTik). Jalur **ZeroTier** dibahas di [Fitur opsional E](#e-router-lewat-zerotier).
2. **Nama router**, misalnya `Nangahale`.
3. **Subnet ONT di MikroTik**: lihat di Winbox → IP → DHCP Server → Networks, misalnya `10.0.0.0/24`.
4. **IP virtual**: kosongkan agar dipilih otomatis (`10.100.x.0/24`), atau isi sendiri dengan IP private apa saja (misalnya `172.16.10.0/24`). GenieACS di VPS ikut menyesuaikan otomatis. Tidak boleh sama dengan router lain.
5. **Simpan**.

Lalu buka tab **Script MikroTik** → **Salin** → di Winbox buka **New Terminal** → klik kanan **Paste** → Enter. Script aman dijalankan ulang.

Status router berubah dari **Menunggu pemasangan** menjadi **Tersambung** dalam 1 menit. Klik **Tes koneksi**: hasilnya tampil bertahap di popup, dan langkah yang gagal disertai saran perbaikan.

### 10. Atur ONT
Di setiap ONT (lewat web ONT atau OLT):
- **URL ACS**: `http://192.168.42.1:7547`. Alamat `.1` mengikuti Jaringan VPN yang dipilih di langkah 8; lihat juga di dashboard → kartu VPS.
- **Periodic Inform**: aktif, 300 detik
- **ACS username/password**: kosong

URL ini sama untuk semua router, baik lewat L2TP maupun ZeroTier.

### 11. Uji akhir
1. ONT muncul di **GenieACS UI → Devices** (tunggu sampai 5 menit).
2. Parameter `ConnectionRequestURL` ONT berisi **IP virtual** (`10.100.x.x`), bukan IP asli.
3. Klik **Summon** di GenieACS: harus berhasil.
4. Menu **GenieACS** di panel menampilkan jumlah ONT per router.
5. `bash cek.sh` tidak ada yang **GAGAL**.

Selesai. Fitur di bawah ini opsional.

---

## Fitur opsional

### A. Notifikasi Telegram
Menu **Pengaturan → Notifikasi Telegram**:
1. Buat bot lewat **@BotFather** (`/newbot`) dan salin token-nya.
2. Buat grup Telegram → aktifkan **Topik (Topics)** → buat topik, misalnya `🔴 VPN`.
3. Masukkan bot ke grup, jadikan **admin**, lalu kirim pesan apa saja di topik tujuan.
4. Di panel: tempel token → **Deteksi grup & topik**. Jika bot pernah dipakai aplikasi lain, panel menawarkan **Hapus webhook**.
5. Pilih grup dan topik → atur jeda → **Kirim pesan tes** → **Simpan**.

Aturan pengiriman:
- Hanya dikirim saat status **berubah**. Putus yang lebih singkat dari **jeda** (bawaan 3 menit) tidak dilaporkan.
- Banyak router putus bersamaan digabung jadi **satu pesan**.
- Opsional: pesan **tersambung lagi** (beserta lama putus), **pengingat** jika masih putus, dan **jam tenang** (pesan tanpa bunyi).
- Router berstatus **Menunggu pemasangan** tidak dikirim notifikasi.

### B. Domain Cloudflare + HTTPS
Menu **Pengaturan → Domain & HTTPS**. Isi domain (misalnya `vpn.domainanda.com`) dan **API Token** Cloudflare:
1. Cloudflare → My Profile → API Tokens → **Create Token** → template **Edit zone DNS**.
2. **Tambahkan izin Zone → Zone → Read** (tanpa ini pencarian domain gagal).
3. Batasi ke domain Anda. Jangan pakai Global API Key.

Panel memeriksa token → domain → izin DNS → IP VPS → membuat record A (**DNS only**) → memastikan domain mengarah ke VPS → (opsional) menerbitkan sertifikat **Let's Encrypt** → menerapkan. **Jika satu langkah gagal, semua dibatalkan** dan pengaturan tetap seperti semula.

Setelah berhasil:
- Alamat VPS di script MikroTik otomatis memakai domain. MikroTik lama tidak wajib diubah karena domain dan IP sama-sama mengarah ke VPS.
- Jika HTTPS dipilih, panel dibuka lewat `https://domain:8088`, dan alamat http/IP dialihkan otomatis. Sertifikat diperpanjang otomatis oleh certbot.
- Record harus **DNS only** (awan abu-abu). Proxy Cloudflare (awan oranye) tidak bisa meneruskan L2TP dan Winbox; panel mengaturnya otomatis.

**Subdomain layanan:** di halaman yang sama, bagian **Subdomain layanan** membuat record DNS otomatis untuk **GenieACS** (bawaan `acs`, misalnya `http://acs.domainanda.com:3000`) dan **ZTNET** (bawaan `zt`, misalnya `http://zt.domainanda.com:3300`). Link di panel ikut diperbarui, dan namanya bisa diganti kapan saja. Pakai subdomain ini untuk GenieACS dan ZTNET, **jangan domain panel**: domain panel yang ber-HTTPS membuat browser memaksa https di port lain.

### C. Alamat tanpa port (80/443)
Menu **Pengaturan → Umum → Alamat tanpa port**. Setelah aktif:
- **Tanpa domain:** panel dibuka di `http://IP-VPS` (port 80).
- **Dengan domain + HTTPS:** panel dibuka di `https://domain` (port 443). Port 80 tetap melayani perpanjangan sertifikat dan mengalihkan ke https.
- Subdomain `acs.` dan `zt.` ikut dibuka tanpa port (`https://acs.domain`, `https://zt.domain`). Sertifikat diperluas otomatis.
- Port **8088 tetap jalan** sebagai cadangan, dan script MikroTik lama tetap berfungsi.

Syarat:
- **Password admin bukan `Admin123`**. Ganti dulu di Pengaturan, karena panel jadi lebih mudah ditemukan.
- Port 80/443 tidak dipakai program lain (misalnya nginx/apache). Panel memeriksa dan menolak bila bentrok.
- Buka TCP **80** dan **443** di firewall provider.

### D. Menu Add-on
Menu **Add-on** di panel → **Install**. Panel menampilkan progres langkah demi langkah (0–100%) beserta log. Add-on bisa **Update** dan **Lepas** dari menu yang sama.

| Add-on | Isi | Dibuka di |
|---|---|---|
| **ZeroTier** | ZeroTier + ZTNET (lihat bagian E) | menu ZeroTier, ZTNET port 3300 |
| **Panel ACS** | Monitoring ONT dari GenieACS: daftar perangkat per router, history redaman (tiap 15 menit, disimpan 90 hari), redaman memburuk 24 jam, peta lokasi | `/acs` |
| **Bilingku** | Billing PPPoE & Hotspot. Router bisa diambil langsung dari panel utama: cukup isi user/password API | `/billing` |

- Panel ACS dan Bilingku memakai PHP (dipasang otomatis) dan database **SQLite**. Datanya di `/opt/addons/<nama>/data` dan tetap aman saat **Update**.
- Path (`/acs`, `/billing`) bisa diganti di kartu add-on.
- Router di Panel ACS dikelompokkan menurut **router di panel utama** (berdasarkan IP virtual ONT), bukan tag GenieACS. Tag GenieACS dipakai untuk **area** (tag ke-1) dan **nama pelanggan** (tag ke-2).
- History redaman butuh provision GenieACS: Panel ACS → **Settings → History Redaman → Pasang provision**.

### E. Router lewat ZeroTier
Router **ARM/ARM64 dengan RouterOS v7** bisa tersambung ke VPS lewat ZeroTier, bukan L2TP. Router MIPS (hAP lite, hEX, RB951) tetap memakai L2TP. Kedua jalur bisa dipakai bersamaan.

**Di VPS:**
1. Jika memakai domain, buat dulu subdomain `zt` di [Fitur opsional B](#b-domain-cloudflare--https) agar alamat ZTNET langsung benar.
2. Pasang ZeroTier + ZTNET (web pengelola ZeroTier, port **3300**, tanpa Docker): panel → menu **Add-on → ZeroTier → Install**. Atau lewat terminal:
   ```bash
   cd /root/acs-netmap-panel
   bash pasang-ztnet.sh
   ```
   Script ini memeriksa Node.js dan RAM (menawarkan swap 2 GB bila perlu), memindahkan port ZTNET ke 3300 agar tidak bentrok dengan GenieACS (3000), lalu menjalankan installer resmi ZTNET. Saat ditanya alamat, isi subdomain Anda, misalnya `zt.domainanda.com`. Saat ditanya kirim laporan error, jawab `No`.
3. Buka web ZTNET (alamatnya ada di ringkasan) dan **segera daftar**: akun pertama menjadi admin.
4. Di ZTNET: **Networks → Create Network**, lalu atur rentang IPv4, misalnya `172.27.0.0/24`. Rentang ini tidak boleh bentrok dengan `192.168.42.0/24`, `10.100.0.0/14`, subnet ONT, atau `172.17.0.0/16`.
5. Panel → menu **ZeroTier** → pilih jaringan → **Hubungkan VPS**. Halaman ini juga menampilkan semua anggota jaringan beserta statusnya.
6. Buka UDP **9993** dan TCP **3300** di firewall provider.

**Di setiap MikroTik (sekali):** pasang paket ZeroTier.
1. Cek versi dan arsitektur di Winbox → **System → Resources** (harus RouterOS **7.x** dan arsitektur **arm** atau **arm64**).
2. Unduh **Extra packages** dengan versi dan arsitektur yang sama dari [mikrotik.com/download](https://mikrotik.com/download), lalu ekstrak.
3. Seret file `zerotier-7.x-arm.npk` (atau `-arm64.npk`) ke Winbox → **Files**.
4. **System → Reboot**. Setelah menyala, `zerotier` muncul di **System → Packages**.

**Tambah router:** panel → **Tambah router** → jalur **ZeroTier**.
- Jika MikroTik **sudah bergabung** ke jaringan (terlihat di ZTNET), pilih dari daftar **Perangkat ZeroTier**. Daftar memakai nama perangkat dari ZTNET, dan nama router terisi otomatis.
- Jika **belum bergabung** (biasanya), biarkan "Pilih nanti" → **Simpan** → tab **Script MikroTik** → tempel di New Terminal. Di akhir, script **melaporkan Node ID MikroTik ke panel** sehingga router terpilih otomatis dalam beberapa detik. MikroTik harus bisa membuka alamat panel (`http(s)://alamat-VPS:8088`) lewat internet. Jika gagal, pilih manual di tab **Ringkasan** → **Pilih router yang bergabung**.

Panel otomatis menyetujui router, memberi IP ZeroTier, dan memasang route ke IP virtual. Nama perangkat dari ZTNET juga tampil di tabel **Anggota jaringan** di menu ZeroTier.

Pengelolaan ZeroTier dari menu **ZeroTier** di panel (tanpa membuka ZTNET):
- **Ubah** nama jaringan dan akses **Private/Public**. Private sangat disarankan: dengan Public, siapa pun yang tahu Network ID bisa masuk ke jaringan GenieACS.
- Di tabel **Anggota jaringan**: **Setujui** / **Cabut** izin perangkat dan **Ubah IP** ZeroTier-nya. Route IP virtual router ikut diperbarui otomatis.

**Mengganti rentang IP di ZTNET belakangan** boleh: panel memeriksa ulang jaringan setiap 5 menit dan setiap halaman ZeroTier dibuka, lalu menyesuaikan rentang, IP VPS, IP router, dan route secara otomatis (tercatat di Log aktivitas). Jika IP ZeroTier VPS ikut berubah, router ZeroTier diberi tanda **Pasang ulang script ZeroTier**. Rentang baru yang bentrok dengan jaringan lain ditolak dan ditampilkan sebagai peringatan.

URL ACS di ONT tetap `http://192.168.42.1:7547`. Status, riwayat, notifikasi Telegram, tes koneksi, dan port forwarding berlaku untuk kedua jalur.

---

## Pemakaian sehari-hari

| Menu | Kegunaan |
|---|---|
| **Dashboard** | Jumlah router tersambung/terputus, uptime tiap router (24 jam, 7 hari, 30 hari), daftar **Perlu perhatian**, alamat GenieACS dan ZTNET |
| **Router** | Daftar router. Detail router punya tab **Ringkasan**, **Port Forwarding**, **Script MikroTik**, dan **Riwayat** |
| **GenieACS** | Status layanan, patch IP virtual, jumlah ONT per router, alamat GenieACS UI |
| **ZeroTier** | Jaringan yang dipakai, anggota jaringan, alamat ZTNET |
| **Pengaturan** | Umum (nama panel, VPS, jaringan VPN, password), Notifikasi Telegram, Domain & HTTPS |
| **Panduan** | Ringkasan cara pakai, langsung di panel |
| **Log aktivitas** | Semua perubahan di panel selama 90 hari (password dan token tidak dicatat) |

**Remote router / ONT (port forwarding):** buka router → tab **Port Forwarding** → **Tambah** → pilih layanan (Winbox, WebFig, SSH, Web ONT, atau lainnya). Untuk Winbox, isi **Connect To** dengan `IP_VPS:20001` (port sesuai yang tampil). Layanan web bisa langsung diklik dan terbuka di tab baru. Port ini terbuka ke internet, jadi pastikan password perangkat kuat.

**Riwayat:** tab **Riwayat** mencatat setiap putus (kapan dan berapa lama) serta grafik 30 hari, disimpan 90 hari. Router baru berstatus **Menunggu pemasangan** sampai MikroTik tersambung pertama kali.

---

## Kalau ada masalah

Jalankan dulu `bash cek.sh`. Sebagian besar masalah langsung terlihat di sana.

| Gejala | Kemungkinan penyebab | Solusi |
|---|---|---|
| Panel/GenieACS tidak bisa dibuka dari HP/PC | Port belum dibuka di firewall provider | Buka port di [langkah 7](#7-firewall-provider). Jika `cek.sh` OK, masalahnya di firewall provider |
| Lupa password panel | — | `bash install-vpn-acs.sh password` lalu Enter (kembali ke `Admin123`) |
| Router tetap **Menunggu pemasangan** / **Terputus** | UDP 1701 tertutup, Alamat VPS salah, atau script belum ditempel | Klik **Tes koneksi**. Di MikroTik cek **Interfaces → l2tp-acs** dan **Log** |
| ONT tidak muncul di GenieACS | URL ACS salah, Periodic Inform mati, atau router belum tersambung | Cek [langkah 10](#10-atur-ont). Tes koneksi harus lolos langkah **Jaringan ONT** |
| Summon gagal, `ConnectionRequestURL` berisi IP asli | Patch belum aktif, atau ONT belum Inform ulang setelah patch | `bash genieacs-virtualip.sh status`, tunggu Inform berikutnya (maks. 5 menit) |
| Router diberi tanda "IP virtual di luar patch GenieACS" | Panel gagal memperbarui `genieacs.env` | Buka menu **GenieACS** di panel, lalu cek `journalctl -u vpn-acs -n 50` |
| Router ZeroTier tidak muncul di "Pilih router yang bergabung" | Paket zerotier belum terpasang, VPS belum dihubungkan, atau UDP 9993 tertutup | Cek [Fitur opsional E](#e-router-lewat-zerotier). Di MikroTik: **ZeroTier → Interfaces → zt-acs** |
| Notifikasi Telegram tidak masuk | Bot bukan admin, topik salah, atau token dipakai webhook lain | **Kirim pesan tes** di panel, lalu **Hapus webhook** jika ditawarkan |
| Domain gagal: "Domain tidak ditemukan di akun Cloudflare ini" / "Token tidak boleh membaca domain ini" | Token belum punya izin **Zone → Zone → Read** | Edit token di Cloudflare, tambahkan izin itu |
| Browser memaksa `https://` saat membuka GenieACS/ZTNET | Domain panel ber-HTTPS dipakai untuk port lain | Pakai subdomain `acs`/`zt` ([Fitur opsional B](#b-domain-cloudflare--https)) |

Log lengkap:
```bash
journalctl -u vpn-acs -n 50 --no-pager
journalctl -u xl2tpd -n 50 --no-pager
journalctl -u genieacs-cwmp -n 50 --no-pager
journalctl -u ztnet -n 50 --no-pager
```

---

## Update dari GitHub
Repo ini dulu bernama `suwazed-panel`. Jika VPS Anda masih memakai folder lama `/root/suwazed-panel`, pindahkan sekali saja:
```bash
mv /root/suwazed-panel /root/acs-netmap-panel
cd /root/acs-netmap-panel
git remote set-url origin https://github.com/suwazed-cmyk/acs-netmap-panel.git
```
Panel, GenieACS, dan data router tidak terpengaruh karena terpasang di `/opt`.

Update rutin:
```bash
cd /root/acs-netmap-panel
git pull
bash install-vpn-acs.sh          # data router & password admin tetap tersimpan
bash cek.sh
```
Setelah update, tekan **Ctrl+F5** di browser agar tampilan panel baru termuat. Add-on (Panel ACS, Bilingku) di-update dari menu **Add-on → Update**.

Jika GenieACS di-update, jalankan ulang `bash genieacs-virtualip.sh`. ZTNET di-update dengan menjalankan ulang `bash pasang-ztnet.sh` (port 3300 tetap).

## Perintah berguna
```bash
bash ringkasan.sh                    # alamat web, port, dan status semua layanan
bash cek.sh                          # tes apakah semua layanan benar-benar berjalan
bash install-vpn-acs.sh password     # ganti/reset password admin panel (Enter = Admin123)
bash install-vpn-acs.sh uninstall    # hapus panel (akun VPN tetap)
bash genieacs-virtualip.sh status    # cek patch IP virtual
bash genieacs-virtualip.sh rollback  # kembali ke GenieACS asli
bash pasang-ztnet.sh status          # cek ZeroTier + ZTNET
```

## Backup
```bash
mongodump --db genieacs --out /root/backup-genieacs-$(date +%F)
mkdir -p /root/backup-vpnacs-$(date +%F) && cp /opt/vpn-acs/*.json /opt/vpn-acs/*.ini /root/backup-vpnacs-$(date +%F)/ 2>/dev/null
```
Isinya: `data.json` (router, akun VPN, pengaturan), `history.json` (riwayat uptime), `activity.json` (log aktivitas), dan `cloudflare.ini` (token, jika memakai domain).

File-file ini berisi password VPN dan token: **jangan** di-commit ke GitHub.

---

## Membersihkan / menghapus

### Di VPS
```bash
cd /root/acs-netmap-panel
bash bersihkan.sh
```
Pilihan menu:
1. **Hapus semua port forwarding saja** (VPN dan router tetap jalan)
2. **Hapus Panel VPN ACS** + akun VPN router + route IP virtual + aturan firewall panel, dan kembalikan xl2tpd ke bawaan `vpnsetup.sh`
3. **Kembalikan GenieACS asli** (hapus patch IP virtual)
4. **Kembalikan parameter GenieACS** dari backup lama (`/root/backup-parameter-*`), jika pernah dibuat
5. **Hapus semua** (2 + 3, parameter ditanyakan)

Atau langsung: `bash bersihkan.sh portforward|panel|genieacs|parameter|semua`. Setiap pilihan meminta konfirmasi (ketik `YA`) dan membackup data penting ke `/root` dulu. Server VPN (xl2tpd/IPsec), GenieACS, MongoDB, dan data ONT tidak dihapus.

### Di setiap MikroTik
Script hapus yang tepat ada di panel: buka router → tab **Script MikroTik** → pilih **Hapus**. Script itu sudah memakai nama panel Anda dan nama-nama lama.

Contoh jika nama panel `VPN ACS` (ganti dengan nama panel Anda):
```
/interface l2tp-client remove [find where name="l2tp-acs"]
:do { /zerotier interface remove [find where name="zt-acs"] } on-error={}
/ip route remove [find where comment="VPN ACS"]
/ip firewall nat remove [find where comment~"^VPN ACS - "]
/ip firewall filter remove [find where comment~"^VPN ACS - "]
:put "Pengaturan VPN ACS sudah dihapus."
```
