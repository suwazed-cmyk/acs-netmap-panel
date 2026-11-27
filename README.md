# ACS NETMAP Panel: GenieACS + VPN MikroTik

Paket untuk menjalankan **GenieACS di VPS** yang bisa mengelola dan memberi perintah (Summon) ke ONT di **banyak router MikroTik**, walaupun semua router memakai **subnet lokal yang sama** (misalnya semua `10.0.0.0/24`).

```
ONT ─ OLT ─ MikroTik router A ═══ VPN L2TP / WireGuard / ZeroTier ═══╗
ONT ─ OLT ─ MikroTik router B ═══ VPN L2TP / WireGuard / ZeroTier ═══╬══ VPS (GenieACS + Panel)
ONT ─ OLT ─ MikroTik router C ═══ VPN L2TP / WireGuard / ZeroTier ═══╝        ▲
                                                Remote Winbox: IP_VPS:20001
```

## Fitur

- **VPN L2TP** dari setiap MikroTik ke VPS, atau **WireGuard** (semua RouterOS v7) dan **ZeroTier** (RouterOS v7 ARM/ARM64)
- **IP virtual (NETMAP)** per router: ONT `10.0.0.25` di router A terlihat di GenieACS sebagai `10.100.1.25`, di router B sebagai `10.100.2.25`
- **Patch GenieACS** agar Summon memakai IP virtual
- **Panel web**:
  - Akun VPN dan **script MikroTik siap salin**, mengikuti nama panel Anda
  - **Tes koneksi** bertahap, status **tersambung/terputus**, dan **riwayat uptime** 24 jam / 7 hari / 30 hari
  - **Port forwarding** untuk remote Winbox / WebFig / web ONT lewat IP publik VPS
  - Halaman **GenieACS** (status layanan, patch, jumlah ONT per router) dan **ZeroTier** (controller lengkap: jaringan, rentang IP, perangkat, rute; pemilih jaringan untuk membuka dan mengelola semua jaringan di controller, Network ID + tombol salin, ganti nama langsung di kartu, QR Network ID)
  - **Notifikasi Telegram** saat VPN putus, dikirim ke grup bertopik
  - **Laporan kesehatan VPS** ke Telegram (CPU, RAM, disk, layanan, router) dengan interval hari yang bisa diatur, plus peringatan disk/RAM/layanan mati
  - **Keamanan login**: logout otomatis saat diam (bisa diatur), blokir salah password bertingkat, notifikasi blokir ke Telegram, daftar sesi aktif
  - **Domain Cloudflare + HTTPS** otomatis, termasuk subdomain untuk GenieACS dan add-on (Panel ACS, Bilingku)
  - **Log aktivitas** dan **nama panel** yang bisa diganti
  - **Alamat tanpa port**: panel dibuka di port 80/443 (`http://IP-VPS` atau `https://domain`)
  - Menu **Add-on** dengan tombol **Install** dan progres 0–100%:
    - **ZeroTier** (add-on sistem, hanya paket zerotier-one; menu ZeroTier baru muncul setelah dipasang)
    - **WireGuard** (add-on sistem, hanya paket wireguard-tools; menu WireGuard baru muncul setelah dipasang)
    - **[Panel ACS](https://github.com/suwazed-cmyk/panel-acs)**: monitoring ONT, **history redaman**, nama pelanggan & label (tag GenieACS), router dikenali otomatis dari IP virtual. Node.js, tanpa PHP. Dibuka di `/acs`
    - **[Bilingku](https://github.com/suwazed-cmyk/bilingku)**: billing PPPoE & Hotspot MikroTik. Dibuka di `/billing`
- Script bantu: **`ringkasan.sh`** (alamat web dan port) dan **`cek.sh`** (tes semua layanan)

## Isi repo

| File | Fungsi |
|---|---|
| `install.sh` | **Installer satu perintah**: L2TP/IPsec, MongoDB, Node.js, GenieACS, patch, panel |
| `install-vpn-acs.sh` | Installer Panel VPN ACS saja (sudah berisi seluruh panel) |
| `genieacs-virtualip.sh` | Patch IP virtual untuk GenieACS v1.2.13–v1.2.16 |
| `ringkasan.sh` | Ringkasan semua layanan: alamat web, port, status, port firewall |
| `cek.sh` | Tes semua layanan: service, port, web menjawab, patch, sertifikat, DNS |
| `bersihkan.sh` | Menghapus pengaturan yang dipasang repo ini dari VPS |
| `panel/server.js`, `panel/public/index.html` | Kode sumber panel (untuk dibaca/diubah) |

## Yang dibutuhkan

| | Minimal | Disarankan |
|---|---|---|
| Virtualisasi | **KVM** (bukan OpenVZ/LXC) | KVM |
| OS | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 (64-bit) | **Ubuntu 22.04 / 24.04 LTS** |
| CPU | x86_64 atau arm64 | x86_64 dengan AVX |
| RAM | 1 GB (installer menambah swap 2 GB) | 2–4 GB |
| Disk | 25 GB SSD | 40 GB SSD/NVMe |
| IP | 1 IPv4 publik statis | 1 IPv4 publik statis |

MongoDB dipilih otomatis oleh installer:

| CPU | MongoDB |
|---|---|
| x86_64 dengan AVX, arm64 ARMv8.2+ | **8.0** (repo resmi MongoDB), semua OS di atas (Debian hanya x86_64) |
| x86_64 tanpa AVX | **4.4** di Ubuntu 20.04/22.04 dan Debian 11/12; Ubuntu 24.04 tidak bisa (pakai 22.04) |

Cek AVX: `grep -c avx /proc/cpuinfo` (0 = tanpa AVX). Banyak VPS murah menyembunyikan AVX; minta provider memakai CPU mode *host-passthrough*.

Selain VPS: MikroTik (RouterOS v6 atau v7) dengan akses Winbox, dan ONT yang mendukung TR-069.

## Gambaran pemasangan

| Tahap | Langkah | Hasil |
|---|---|---|
| **A. Pasang di VPS** | 1 | Satu perintah: L2TP/IPsec, MongoDB, Node.js, GenieACS, patch IP virtual, panel |
| **B. Buka port** | 7 | Port firewall provider terbuka |
| **C. Hubungkan router** | 8–11 | Router tersambung, ONT muncul di GenieACS, Summon berhasil |
| **D. Fitur opsional** | — | Telegram, domain + HTTPS, ZeroTier, WireGuard (bisa kapan saja, tidak wajib) |

Setelah setiap langkah, Anda bisa menjalankan `bash ringkasan.sh` (alamat web dan port) atau `bash cek.sh` (tes apakah semuanya berjalan).

---

## Instalasi inti

### 1. Pasang semuanya (satu perintah)
Login ke VPS sebagai **root**, lalu jalankan:
```bash
curl -fsSL https://raw.githubusercontent.com/suwazed-cmyk/acs-netmap-panel/main/install.sh | bash
```
Atau dari folder repo:
```bash
git clone https://github.com/suwazed-cmyk/acs-netmap-panel.git /root/acs-netmap-panel
bash /root/acs-netmap-panel/install.sh
```

Tidak ada pertanyaan selama pemasangan. Layar menampilkan **progress bar** per langkah (±10–15 menit di VPS 2 vCPU; paling lama saat membangun patch GenieACS):

```
 ✓ [1/10] Menyiapkan sistem (paket dasar, swap) (48d)
 ✓ [2/10] Mengambil source ACS NETMAP Panel (3d)
 ✓ [3/10] Memasang VPN L2TP/IPsec (21d)
 [████████████░░░░░░░░░░░░░░░░░░]  41%  ⠹ [4/10] Memasang MongoDB 8.0 (1m 05d)
```

Yang dipasang (semua dari sumber resmi, bukan script pihak ketiga):

| Komponen | Sumber | Catatan |
|---|---|---|
| VPN L2TP/IPsec | paket Ubuntu/Debian: `xl2tpd`, `strongswan` | PSK acak, jaringan VPN `192.168.42.0/24` (bisa diganti di panel) |
| MongoDB | repo resmi `repo.mongodb.org` | 8.0, atau 4.4 bila CPU tanpa AVX (lihat tabel di atas); hanya untuk lokal |
| Node.js 22 | rilis resmi `nodejs.org`, dicek SHA256 | dipasang ke `/usr/local` |
| GenieACS 1.2.16 | npm resmi, susunan sesuai dokumentasi GenieACS | `/opt/genieacs/genieacs.env`, log di `/var/log/genieacs`, JWT acak, **NBI hanya 127.0.0.1** |
| Patch IP virtual | `genieacs-virtualip.sh` (repo ini) | dibangun dari source GenieACS versi yang terpasang |
| Panel VPN ACS | `install-vpn-acs.sh` (repo ini) | password admin acak |
| Inform berkala | provision `vpnacs-inform` | ONT melapor tiap 300 detik (bisa diubah di menu GenieACS) |

Di akhir muncul ringkasan: **alamat panel, password admin, alamat GenieACS UI, URL ACS untuk ONT, dan PSK**. Ringkasan yang sama disimpan di **`/root/acs-netmap-info.txt`** (hanya root). Catat password admin, lalu hapus berkas itu bila sudah aman.

Log lengkap pemasangan: **`/var/log/acs-netmap-install.log`**. Bila satu langkah gagal, layar menampilkan keluaran terakhir langkah itu. Perbaiki penyebabnya lalu jalankan **perintah yang sama** lagi; langkah yang sudah selesai tidak diulang.

**VPS yang sudah terpasang** (cara lama dengan `vpnsetup.sh` dan `genie.sh`): installer mendeteksi L2TP, MongoDB, Node.js, GenieACS, dan patch yang sudah ada lalu **tidak mengubahnya**; hanya panel yang diperbarui dan password admin lama tetap dipakai.

**Tanpa SSH (user-data / cloud-init):** banyak provider punya kolom *User data* / *Startup script* saat membuat VPS. Isi dengan:
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/suwazed-cmyk/acs-netmap-panel/main/install.sh | bash
```
Setelah VPS menyala ±15 menit, login lalu baca `cat /root/acs-netmap-info.txt`.

Zona waktu panel diatur di **Pengaturan → Umum**. Zona waktu sistem bisa diganti dengan `timedatectl set-timezone Asia/Makassar` (WITA), `Asia/Jakarta` (WIB), atau `Asia/Jayapura` (WIT).

<details>
<summary>Perintah satu per satu (bila ingin memasang manual)</summary>

```bash
cd /root/acs-netmap-panel
bash install-vpn-acs.sh          # hanya panel (butuh L2TP, Node.js, GenieACS sudah ada)
bash genieacs-virtualip.sh       # hanya patch IP virtual (GenieACS 1.2.13–1.2.16)
bash genieacs-virtualip.sh status
```
</details>

### 7. Firewall provider
Jangan menyalakan `ufw` karena bentrok dengan aturan VPN (bila sudah menyala, installer membuka port yang dibutuhkan). Buka port berikut di firewall provider VPS (jika ada):

| Port | Protokol | Untuk |
|---|---|---|
| 22 | TCP | SSH |
| 1701 | UDP | VPN L2TP |
| 80, 443 | TCP | Panel VPN ACS (alamat tanpa port) |
| 8088 | TCP | Panel VPN ACS (cadangan) |
| 3000 | TCP | Web GenieACS |
| 20001-20999 | TCP | Port forwarding (remote Winbox / web ONT) |
| 500, 4500 | UDP | Hanya jika IPsec dinyalakan |
| 9993 | UDP | ZeroTier, hanya jika memakai ZeroTier |
| 51820 | UDP | WireGuard, hanya jika memakai WireGuard (port bisa diganti) |

Port 7547 dan 7557 **tidak perlu** dibuka: ONT menghubungi GenieACS lewat VPN. Panel dibuka di port 80/443; port 8088 tetap jalan sebagai cadangan.

Sekarang tes semua layanan:
```bash
bash cek.sh
```
Setiap pemeriksaan diberi tanda **[OK]**, **[PERINGATAN]**, atau **[GAGAL]**. Baris yang gagal disertai perintah untuk memperbaikinya. Komponen yang belum dipasang ditandai **[LEWATI]**.

### 8. Atur panel dan GenieACS (sekali di awal)
Buka `http://IP_VPS` lalu login dengan **password admin dari ringkasan instalasi** (`cat /root/acs-netmap-info.txt`). Jika port 80 dipakai program lain, buka `http://IP_VPS:8088`.

Menu **Pengaturan → Umum**:
1. **Nama panel** (opsional), misalnya `INET WIFI`. Dipakai di judul panel dan sebagai komentar aturan di MikroTik (`INET WIFI - ONT ke IP virtual`). Bisa diganti kapan saja; script baru otomatis membersihkan aturan dengan nama lama.
2. **Alamat VPS**: IP publik VPS (atau domain). Alamat ini dipakai di script MikroTik.
3. **Pakai IPsec**: biarkan mati (L2TP biasa), kecuali Anda memang butuh.
4. **Jaringan VPN (L2TP)**: tentukan **sekarang** (bawaan `192.168.42.0/24`). Mengganti belakangan berarti URL ACS di semua ONT ikut berubah.
5. **Password admin**: bisa diganti dengan password Anda sendiri. Instalasi lama yang masih memakai `Admin123` mendapat peringatan di dashboard sampai diganti.

Menu **GenieACS**: pastikan **Patch IP virtual** berstatus **Aktif** dan keempat layanan **Berjalan**. Kartu ini juga menampilkan rentang IP virtual yang dipakai GenieACS. Kolom **Rentang tambahan** hanya perlu diisi jika Anda punya ONT dengan IP virtual buatan sendiri di luar panel.

Buka **GenieACS UI** di `http://IP_VPS:3000`. Pada pemasangan baru muncul *initialization wizard*: buat akun admin dan biarkan semua pilihan dicentang (Users, Presets, Provisions, Overview, Device page). Pada VPS lama yang dipasang dengan `genie.sh`, centang **Users saja** agar konfigurasi yang sudah ada tidak tertimpa.

### 9. Tambah router
Panel → **Tambah router**:
1. **Jalur ke VPS**: pilih **L2TP** (semua MikroTik). Jalur **ZeroTier** dibahas di [Fitur opsional E](#e-router-lewat-zerotier), **WireGuard** di [Fitur opsional F](#f-router-lewat-wireguard).
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
- Jika HTTPS dipilih, panel dibuka lewat `https://domain` (atau `https://domain:8088`), dan alamat http/IP dialihkan otomatis. Sertifikat diperpanjang otomatis oleh certbot.
- Record harus **DNS only** (awan abu-abu). Proxy Cloudflare (awan oranye) tidak bisa meneruskan L2TP dan Winbox; panel mengaturnya otomatis.

**Subdomain layanan:** di halaman yang sama, bagian **Subdomain layanan** membuat record DNS otomatis untuk **GenieACS** (bawaan `acs`, misalnya `http://acs.domainanda.com:3000`). Link di panel ikut diperbarui, dan namanya bisa diganti kapan saja. Pakai subdomain ini untuk GenieACS, **jangan domain panel**: domain panel yang ber-HTTPS membuat browser memaksa https di port lain.

**Subdomain add-on:** setelah Panel ACS atau Bilingku terpasang, keduanya ikut muncul di **Subdomain layanan** (bawaan `ont` dan `billing`, misalnya `https://billing.domainanda.com`). Syaratnya **Alamat panel** (port web 80/443) aktif, karena add-on dibuka lewat panel tanpa port. Bila HTTPS aktif, sertifikat diperluas otomatis ke subdomain baru. Tombol **Buka** di Dashboard dan halaman Add-on langsung memakai subdomain; alamat lama (`/acs/`, `/billing/`) tetap bisa dipakai.

### C. Alamat tanpa port (80/443)
Panel **langsung memakai port 80/443** setelah instal:
- **Tanpa domain:** `http://IP-VPS` (port 80).
- **Dengan domain + HTTPS:** `https://domain` (port 443). Port 80 tetap melayani perpanjangan sertifikat dan mengalihkan ke https.
- Subdomain `acs.` ikut dibuka tanpa port bila diaktifkan dari **Pengaturan → Umum → Alamat tanpa port** (sertifikat diperluas otomatis).
- Port **8088 tetap jalan** sebagai cadangan, dan script MikroTik lama tetap berfungsi.

Penting:
- **Segera ganti password `Admin123`.** Selama masih bawaan, panel menampilkan peringatan merah di setiap halaman.
- Buka TCP **80** dan **443** di firewall provider.
- Jika port 80/443 sudah dipakai program lain (misalnya nginx/apache), panel tetap berjalan di port 8088. `bash cek.sh` memberi tahu program mana yang memakainya.
- **Port bisa diganti** di **Pengaturan → Umum → Alamat panel** (misalnya 8000/8443 bila 80/443 dipakai aplikasi lain). Alamat panel ikut memakai nomor port itu. **Kembalikan bawaan** = 80/443, **Matikan** = hanya port 8088.

### D. Menu Add-on
Menu **Add-on**: cari add-on, klik untuk melihat detail dan fiturnya, lalu **Install**. Panel menampilkan progres langkah demi langkah (0–100%) beserta log. Add-on yang terpasang tampil di bagian **Terpasang** (dan kartu **Aplikasi** di Dashboard) dengan tombol **Buka**; Perbarui, Periksa, Ubah alamat, dan Lepas ada di menu ⋯. Aplikasi (Panel ACS, Bilingku) tidak lagi ditaruh di menu samping.

| Add-on | Isi | Dibuka di |
|---|---|---|
| **ZeroTier** | Controller ZeroTier di VPS (lihat bagian E) | menu ZeroTier |
| **WireGuard** | Jalur VPN UDP untuk semua RouterOS v7 (lihat bagian F) | menu WireGuard |
| **Panel ACS** | Monitoring ONT dari GenieACS: daftar perangkat per router, history redaman (tiap 15 menit, disimpan 90 hari), redaman memburuk 24 jam, peta lokasi | `/acs` |
| **Bilingku** | Billing PPPoE & Hotspot. Router bisa diambil langsung dari panel utama: cukup isi user/password API. Versi PHP lama ikut ter-update ke Node.js lewat **Update**; data, login admin, dan template tetap | `/billing` |

- Panel ACS dan Bilingku memakai **Node.js**, tanpa PHP (bila Node di VPS lebih lama dari 22.13, Node 22 khusus add-on dipasang otomatis di `/opt/addons/.node`; Node milik GenieACS tidak diubah). Keduanya memakai database **SQLite** di `/opt/addons/<nama>/data` yang tetap aman saat **Update**.
- Path (`/acs`, `/billing`) bisa diganti di kartu add-on.
- Router di Panel ACS dikelompokkan menurut **router di panel utama** (berdasarkan IP virtual ONT), bukan tag GenieACS. Tag GenieACS dipakai untuk **nama pelanggan** (`nama:Budi_Santoso`) dan **label** bebas (ODP, paket, VIP).
- History redaman butuh provision GenieACS: Panel ACS → **Settings → History Redaman → Pasang provision**.

### E. Router lewat ZeroTier
Router **ARM/ARM64 dengan RouterOS v7** bisa tersambung ke VPS lewat ZeroTier, bukan L2TP. Router MIPS (hAP lite, hEX, RB951) tetap memakai L2TP. Kedua jalur bisa dipakai bersamaan.

**Di VPS:**
1. Panel → menu **Add-on → ZeroTier → Install**. Yang dipasang hanya paket resmi `zerotier-one` (±10 MB, beberapa detik). Tidak ada web tambahan, database, atau port baru.
2. Panel → menu **ZeroTier** → **Buat jaringan**: isi nama dan rentang IP (panel menyarankan rentang yang tidak bentrok, misalnya `172.27.0.0/24`), lalu centang **Langsung hubungkan VPS**.
3. Buka UDP **9993** di firewall provider.

Rentang ZeroTier tidak boleh bentrok dengan `192.168.42.0/24`, `10.100.0.0/14`, subnet ONT, atau `172.17.0.0/16`; panel menolaknya otomatis.

**Di setiap MikroTik (sekali):** pasang paket ZeroTier.
1. Cek versi dan arsitektur di Winbox → **System → Resources** (harus RouterOS **7.x** dan arsitektur **arm** atau **arm64**).
2. Unduh **Extra packages** dengan versi dan arsitektur yang sama dari [mikrotik.com/download](https://mikrotik.com/download), lalu ekstrak.
3. Seret file `zerotier-7.x-arm.npk` (atau `-arm64.npk`) ke Winbox → **Files**.
4. **System → Reboot**. Setelah menyala, `zerotier` muncul di **System → Packages**.

**Tambah router:** panel → **Tambah router** → jalur **ZeroTier**.
- Jika MikroTik **sudah bergabung** ke jaringan (terlihat di menu ZeroTier), pilih dari daftar **Perangkat ZeroTier**. Nama perangkat yang diisi di menu ZeroTier ikut dipakai sebagai nama router.
- Jika **belum bergabung** (biasanya), biarkan "Pilih nanti" → **Simpan** → tab **Script MikroTik** → tempel di New Terminal. Di akhir, script **melaporkan Node ID MikroTik ke panel** sehingga router terpilih otomatis dalam beberapa detik. MikroTik harus bisa membuka alamat panel (`http(s)://alamat-VPS`) lewat internet. Jika gagal, pilih manual di tab **Ringkasan** → **Pilih router yang bergabung**.

Panel otomatis menyetujui router, memberi IP ZeroTier, dan memasang route ke IP virtual.

Semua pengelolaan ada di menu **ZeroTier** (tidak perlu web lain):
- **Jaringan:** buat, hubungkan, lepas, dan hapus. Ubah **nama**, akses **Private/Public** (Private sangat disarankan), **rentang IP**, **pool IP otomatis**, dan **DNS**.
- **Ganti rentang IP** kapan saja: IP VPS, router, dan perangkat lain dipindah otomatis ke rentang baru dan rute ikut diperbarui (tercatat di Log aktivitas). Jika IP VPS berubah, router ZeroTier diberi tanda **Pasang ulang script ZeroTier**.
- **Perangkat:** cari & saring (online, offline, menunggu), **setujui / cabut izin**, **ubah IP**, beri **nama & catatan**, lihat IP asli, latensi, dan versi ZeroTier, serta **hapus** perangkat.
- **Rute jaringan:** rute IP virtual tiap router dan URL ACS dibuat otomatis oleh panel.

**Pindah dari ZTNET:** jika dulu memakai ZTNET, menu ZeroTier menampilkan tombol **Pindahkan & lepas ZTNET**. Nama dan catatan perangkat disalin ke panel, lalu ZTNET dihapus (opsional beserta database PostgreSQL-nya). Jaringan, perangkat, dan IP tidak berubah karena tersimpan di controller ZeroTier.

URL ACS di ONT tetap `http://192.168.42.1:7547`. Status, riwayat, notifikasi Telegram, tes koneksi, dan port forwarding berlaku untuk semua jalur.

### F. Router lewat WireGuard
Jalur VPN UDP yang ringan dan cepat untuk **semua router RouterOS v7** (ARM, MIPS, x86). Tidak perlu paket tambahan di MikroTik. Cocok untuk koneksi yang kurang stabil. L2TP, WireGuard, dan ZeroTier bisa dipakai bersamaan.

**Di VPS:**
1. Panel → menu **Add-on → WireGuard → Install**. Yang dipasang hanya paket `wireguard-tools`; modul WireGuard sudah ada di kernel Ubuntu 22.04. Panel membuat kunci VPS, interface `wg0` (`10.66.0.1/24`), dan membuka port UDP **51820** di firewall VPS (iptables, dan UFW bila aktif).
2. Buka UDP **51820** di firewall provider VPS (bila ada).

**Tambah router:** panel → **Tambah router** → jalur **WireGuard** → **Simpan** → tab **Script MikroTik** → tempel di New Terminal. Panel membuat kunci khusus router itu dan IP WireGuard (mulai `10.66.0.2`). Router tersambung dalam beberapa detik.

Menu **WireGuard** menampilkan endpoint, public key VPS, rentang IP, serta setiap router dengan **handshake terakhir**, endpoint, dan data masuk/keluar. Router dianggap tersambung bila handshake kurang dari 3 menit (script memakai keepalive 25 detik).
- **Pengaturan WireGuard:** ganti **port UDP** atau **rentang IP**. Router WireGuard diberi tanda **Pasang ulang script WireGuard** karena script lama tidak lagi cocok.
- **Buat kunci WireGuard baru** (menu ⋯ di detail router) bila kunci router mungkin bocor.
- **Ubah jalur VPN** (menu ⋯ di detail router): pindah L2TP ↔ WireGuard ↔ ZeroTier. Akses jalur lama di VPS langsung dicabut, lalu panel menampilkan script jalur baru dan script untuk menghapus jalur lama di MikroTik.

### H. ONT terlihat offline padahal hidup
Penyebab paling umum: **inform berkala ONT** terlalu jarang (misalnya 1 jam atau 1 hari) atau mati. ONT hanya melapor saat menyala/tersambung, sehingga GenieACS menandainya offline beberapa menit kemudian, walaupun ONT tetap hidup. Ini tidak terkait jalur VPN.

Menu **GenieACS → Inform berkala ONT** menampilkan sebaran interval semua ONT. Klik **Perbaiki semua ONT** (bawaan tiap 4 menit): panel memasang provision `vpnacs-inform` + preset di GenieACS yang menyalakan inform berkala di setiap ONT. Berlaku saat ONT melapor berikutnya.

### G. Keamanan login & laporan kesehatan VPS
**Pengaturan → Keamanan:**
- **Logout otomatis** setelah diam 15 menit, 30 menit, **1 jam** (bawaan), 4 jam, atau 12 jam. Yang dihitung hanya aktivitas nyata (klik, ketik, gulir, pindah halaman); penyegaran otomatis tidak memperpanjang sesi. Satu menit sebelumnya muncul peringatan dengan tombol **Tetap masuk**.
- **Blokir salah password bertingkat** per IP: 5 kali salah diblokir **5 menit**, diulang **30 menit**, lalu **24 jam**. Tersimpan walau panel di-restart; bisa dibuka manual. Notifikasi Telegram dikirim saat ada IP diblokir.
- **Sesi aktif**: daftar perangkat yang sedang login (browser/HP, IP, terakhir aktif) dengan tombol **Keluarkan**. Mengganti password admin otomatis mengeluarkan semua perangkat lain.

**Pengaturan → Notifikasi Telegram → Laporan kesehatan VPS:** laporan berkala (bawaan **tiap 7 hari jam 08:00**, interval 1–30 hari) berisi CPU, RAM, swap, disk, uptime, status layanan (panel, VPN, GenieACS, add-on), dan ringkasan router. **Peringatan langsung** bila disk/RAM di atas 90% atau ada layanan mati (diulang paling sering 6 jam sekali, dan ada pesan saat normal lagi). Dashboard menampilkan kartu **Kesehatan VPS**.

---

## Pemakaian sehari-hari

| Menu | Kegunaan |
|---|---|
| **Dashboard** | Jumlah router tersambung/terputus, uptime tiap router (24 jam, 7 hari, 30 hari), daftar **Perlu perhatian**, alamat GenieACS |
| **Router** | Daftar router. Detail router punya tab **Ringkasan**, **Port Forwarding**, **Script MikroTik**, dan **Riwayat** |
| **GenieACS** | Status layanan, patch IP virtual, jumlah ONT per router, alamat GenieACS UI |
| **ZeroTier** | Controller ZeroTier: jaringan, rentang IP, perangkat, rute |
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
| Install add-on gagal atau berhenti | Memori habis, internet VPS putus, atau apt sedang dipakai | Klik **Install** lagi (langkah yang sudah selesai dilewati), lalu **Periksa**. Log lengkap: `/opt/vpn-acs/jobs/` |
| Panel/GenieACS tidak bisa dibuka dari HP/PC | Port belum dibuka di firewall provider | Buka port di [langkah 7](#7-firewall-provider). Jika `cek.sh` OK, masalahnya di firewall provider |
| Lupa password panel | — | `bash install-vpn-acs.sh password` lalu Enter (kembali ke `Admin123`) |
| Router tetap **Menunggu pemasangan** / **Terputus** | UDP 1701 tertutup, Alamat VPS salah, atau script belum ditempel | Klik **Tes koneksi**. Di MikroTik cek **Interfaces → l2tp-acs** dan **Log** |
| ONT tidak muncul di GenieACS | URL ACS salah, Periodic Inform mati, atau router belum tersambung | Cek [langkah 10](#10-atur-ont). Tes koneksi harus lolos langkah **Jaringan ONT** |
| Summon gagal, `ConnectionRequestURL` berisi IP asli | Patch belum aktif, atau ONT belum Inform ulang setelah patch | `bash genieacs-virtualip.sh status`, tunggu Inform berikutnya (maks. 5 menit) |
| Router diberi tanda "IP virtual di luar patch GenieACS" | Panel gagal memperbarui `genieacs.env` | Buka menu **GenieACS** di panel, lalu cek `journalctl -u vpn-acs -n 50` |
| Router WireGuard tetap Terputus (handshake belum pernah) | Port UDP WireGuard tertutup di firewall provider, script belum dipasang, atau alamat VPS salah | Buka UDP 51820 di firewall provider; di MikroTik cek **WireGuard → Peers → wg-acs** (Last Handshake). `bash cek.sh` memeriksa port dan handshake |
| Router ZeroTier tidak muncul di "Pilih router yang bergabung" | Paket zerotier belum terpasang, VPS belum dihubungkan, atau UDP 9993 tertutup | Cek [Fitur opsional E](#e-router-lewat-zerotier). Di MikroTik: **ZeroTier → Interfaces → zt-acs** |
| Notifikasi Telegram tidak masuk | Bot bukan admin, topik salah, atau token dipakai webhook lain | **Kirim pesan tes** di panel, lalu **Hapus webhook** jika ditawarkan |
| Domain gagal: "Domain tidak ditemukan di akun Cloudflare ini" / "Token tidak boleh membaca domain ini" | Token belum punya izin **Zone → Zone → Read** | Edit token di Cloudflare, tambahkan izin itu |
| Browser memaksa `https://` saat membuka GenieACS | Domain panel ber-HTTPS dipakai untuk port lain | Pakai subdomain `acs` ([Fitur opsional B](#b-domain-cloudflare--https)) |

Log lengkap:
```bash
journalctl -u vpn-acs -n 50 --no-pager
journalctl -u xl2tpd -n 50 --no-pager
journalctl -u genieacs-cwmp -n 50 --no-pager
journalctl -u zerotier-one -n 50 --no-pager
```

---

## Update dari GitHub
Panel memeriksa pembaruan otomatis tiap 12 jam. Jika ada versi baru, muncul tanda **pembaruan** di bawah menu samping dan di Dashboard:
- **Panel:** Pengaturan → Umum → **Pembaruan panel** → **Perbarui**. Panel menjalankan `git pull` dan installer di folder repo, menyala ulang beberapa detik, lalu muat ulang halaman. (Tombol ini tersedia setelah sekali update lewat SSH dengan installer versi terbaru.)
- **Add-on:** menu Add-on menandai add-on yang punya versi baru; klik **Perbarui**. **Periksa pembaruan** untuk mengecek saat itu juga.

Update manual lewat SSH tetap bisa:
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

Jika GenieACS di-update, jalankan ulang `bash genieacs-virtualip.sh`.

## Perintah berguna
```bash
bash ringkasan.sh                    # alamat web, port, dan status semua layanan
bash cek.sh                          # tes apakah semua layanan benar-benar berjalan
bash install-vpn-acs.sh password     # ganti/reset password admin panel (Enter = Admin123)
bash install-vpn-acs.sh uninstall    # hapus panel (akun VPN tetap)
bash genieacs-virtualip.sh status    # cek patch IP virtual
bash genieacs-virtualip.sh rollback  # kembali ke GenieACS asli
zerotier-cli info                    # cek ZeroTier di VPS
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
