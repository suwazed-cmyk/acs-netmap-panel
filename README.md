# Suwazed Panel: GenieACS + VPN L2TP MikroTik

Paket untuk menjalankan **GenieACS di VPS** yang bisa memberi perintah (Summon) ke ONT di banyak router MikroTik, walaupun semua router memakai **subnet lokal yang sama**.

- **VPN L2TP** dari setiap MikroTik ke VPS (tanpa IPsec, atau dengan IPsec jika diinginkan)
- **IP virtual (NETMAP)** per router: ONT `10.0.0.25` di router A terlihat di GenieACS sebagai `10.100.1.25`
- **Patch GenieACS** agar Summon memakai IP virtual
- **Panel web** untuk membuat akun VPN, script MikroTik siap salin, tes koneksi, dan **port forwarding** (remote Winbox/web ONT lewat IP publik VPS)

```
ONT ─ OLT ─ MikroTik router ═══ VPN L2TP ═══ VPS (GenieACS + Panel)
                                               ▲
                     Remote Winbox: IP_VPS:20001
```

## Isi repo

| File | Fungsi |
|---|---|
| `install-vpn-acs.sh` | Installer Panel VPN ACS (sudah berisi seluruh panel) |
| `genieacs-virtualip.sh` | Patch IP virtual untuk GenieACS v1.2.13 |
| `bersihkan.sh` | Menghapus aturan/pengaturan yang dipasang repo ini dari VPS |
| `pasang-ztnet.sh` | Memasang ZTNET + ZeroTier controller tanpa Docker, web di port 3300 (opsional) |
| `panel/server.js`, `panel/public/index.html` | Kode sumber panel (untuk dibaca/diubah) |

## Rekomendasi VPS

| | Minimal | Disarankan |
|---|---|---|
| Virtualisasi | **KVM** (bukan OpenVZ/LXC) | KVM |
| OS | **Ubuntu 22.04 LTS 64-bit** | Ubuntu 22.04 LTS 64-bit |
| CPU / RAM | 1 vCPU / 2 GB | 2 vCPU / 4 GB |
| Disk | 25 GB SSD | 40 GB SSD/NVMe |
| IP | 1 IPv4 publik statis | 1 IPv4 publik statis |

Jangan pakai Ubuntu 24.04: MongoDB 4.4 dari `genie.sh` kemungkinan gagal terpasang.

---

## Instalasi

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

### 2. Ambil repo ini
```bash
cd /root
git clone https://github.com/suwazed-cmyk/suwazed-panel.git
cd suwazed-panel
```

### 3. Server VPN L2TP
```bash
wget -O /root/vpnsetup.sh https://raw.githubusercontent.com/beryindo/genieacs/refs/heads/main/vpnsetup.sh
bash /root/vpnsetup.sh
systemctl status xl2tpd --no-pager | head -5
```

### 4. GenieACS
`genie.sh` mengunduh `libssl1.1` dari `ftp.debian.org`, yang sering macet. Baris `sed` di bawah mengganti sumbernya ke server Ubuntu:
```bash
wget -O /root/genie.sh https://raw.githubusercontent.com/beryindo/genieacs/refs/heads/main/genie.sh
sed -i 's#https://ftp.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb#http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb#; s#dpkg -i libssl1.1_1.1.1w-0+deb11u1_amd64.deb#dpkg -i libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb#' /root/genie.sh
grep -n "libssl" /root/genie.sh
bash /root/genie.sh
```
Ketik `y` saat ditanya. Cek: `systemctl status mongod genieacs-cwmp genieacs-ui --no-pager | grep -E "●|Active"`
Perbaikan keamanan (wajib):
```bash
sed -i "s/^GENIEACS_UI_JWT_SECRET=.*/GENIEACS_UI_JWT_SECRET=$(openssl rand -hex 32)/" /opt/genieacs/genieacs.env
grep -q '^GENIEACS_NBI_INTERFACE=' /opt/genieacs/genieacs.env \
  && sed -i 's/^GENIEACS_NBI_INTERFACE=.*/GENIEACS_NBI_INTERFACE=127.0.0.1/' /opt/genieacs/genieacs.env \
  || echo 'GENIEACS_NBI_INTERFACE=127.0.0.1' >> /opt/genieacs/genieacs.env
systemctl restart genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui
```

### 5. Patch IP virtual GenieACS
Jika IP virtual memakai pilihan otomatis panel (10.100.x.x):
```bash
cd /root/suwazed-panel
bash genieacs-virtualip.sh
```
Jika juga memakai IP virtual sendiri (misalnya skema ZeroTier `10.20.x.x`):
```bash
cd /root/suwazed-panel
sed -i 's#^VIRTUAL_CIDR=.*#VIRTUAL_CIDR="10.100.0.0/14,10.20.0.0/16"#' genieacs-virtualip.sh
bash genieacs-virtualip.sh
```
Cek: `bash genieacs-virtualip.sh status`

### 6. Panel VPN ACS
```bash
cd /root/suwazed-panel
bash install-vpn-acs.sh
```
Buka `http://IP_VPS:8088` lalu login dengan password yang dibuat.

### 7. Firewall provider
Jangan menyalakan `ufw` (bentrok dengan aturan VPN). Buka di firewall provider jika ada:

| Port | Protokol | Untuk |
|---|---|---|
| 22 | TCP | SSH |
| 1701 | UDP | L2TP |
| 3000 | TCP | Web GenieACS |
| 8088 | TCP | Panel VPN ACS |
| 20001-20999 | TCP | Port forwarding / remote MikroTik |
| 3300 | TCP | Web ZTNET (jika memakai ZeroTier) |
| 9993 | UDP | ZeroTier (jika memakai ZeroTier) |
| 500, 4500 | UDP | Hanya jika IPsec dinyalakan |

Port 7547 dan 7557 **tidak perlu** dibuka ke publik. HTTPS panel memakai port yang sama (8088) dan tidak butuh port 80/443. VPS hanya perlu bisa keluar ke internet (Telegram, Cloudflare, Let's Encrypt).

### 8. Atur panel (sekali di awal)
Menu **Pengaturan**:
1. **Alamat VPS**: IP publik atau domain VPS → Simpan
2. **Pakai IPsec**: biarkan mati (L2TP biasa)
3. **Jaringan VPN (L2TP)**: tentukan **sekarang** (default `192.168.42.0/24`). Mengganti belakangan berarti URL ACS di semua ONT ikut berubah.
4. **Patch IP virtual GenieACS** harus berstatus **Aktif**
5. **Alamat GenieACS** (opsional): link GenieACS di dashboard. Kosongkan untuk otomatis (`http://alamat-VPS:3000`).

### 8b. Notifikasi Telegram (opsional)
Menu **Pengaturan → Notifikasi Telegram**:
1. Buat bot lewat **@BotFather** (`/newbot`) dan salin token-nya.
2. Buat grup Telegram → aktifkan **Topik (Topics)** → buat topik, misalnya `🔴 VPN`.
3. Masukkan bot ke grup dan jadikan **admin**, lalu kirim pesan apa saja di topik tujuan.
4. Di panel: tempel token → **Deteksi grup & topik**. Jika bot pernah dipakai aplikasi lain (webhook), panel menawarkan **Hapus webhook** (atau klik tombolnya) → → pilih grup dan topik → atur jeda → **Kirim pesan tes** → **Simpan**.

Aturan pengiriman:
- Hanya dikirim saat status **berubah**. Putus yang lebih singkat dari **jeda** (bawaan 3 menit) tidak dilaporkan.
- Banyak router putus bersamaan digabung jadi **satu pesan**.
- Opsional: pesan **tersambung lagi** (beserta lama putus), **pengingat** jika masih putus, dan **jam tenang** (pesan tanpa bunyi).
- Router berstatus **Menunggu pemasangan** (belum pernah tersambung) tidak dikirim notifikasi.

### 8c. Domain Cloudflare + HTTPS (opsional)
Menu **Pengaturan → Domain & HTTPS**. Isi domain (misalnya `vpn.domainanda.com`) dan **API Token** Cloudflare: template **Edit zone DNS**, lalu **tambahkan izin Zone → Zone → Read**, dan batasi ke domain Anda. Jangan pakai Global API Key.

Panel memeriksa token → domain → izin DNS → IP VPS → membuat record A (**DNS only**) → memastikan domain sudah mengarah ke VPS → (opsional) menerbitkan sertifikat **Let's Encrypt** → menerapkan. **Jika satu langkah gagal, semua dibatalkan** dan pengaturan tetap seperti semula.

Setelah berhasil:
- Alamat VPS di script MikroTik otomatis memakai domain. MikroTik lama tidak wajib diubah karena domain dan IP mengarah ke router yang sama.
- Jika HTTPS dipilih, panel dibuka lewat `https://domain:8088`, dan alamat http/IP dialihkan otomatis. Sertifikat diperpanjang otomatis oleh certbot.
- Record harus **DNS only** (awan abu-abu). Proxy Cloudflare (awan oranye) tidak bisa meneruskan L2TP dan Winbox; panel mengaturnya otomatis.

**Subdomain layanan:** setelah domain terhubung, bagian **Subdomain layanan** di halaman yang sama membuat record DNS otomatis untuk **GenieACS** (bawaan `acs`, misalnya `http://acs.inetwifi.xyz:3000`) dan **ZTNET** (bawaan `zt`, misalnya `http://zt.inetwifi.xyz:3300`). Link di dashboard dan alamat login ZTNET ikut diperbarui. Namanya bisa diganti kapan saja; record lama buatan panel dihapus otomatis. Pakai subdomain ini untuk GenieACS dan ZTNET, jangan domain panel, karena domain panel ber-HTTPS membuat browser memaksa https di port lain.

### 8d. Router lewat ZeroTier (opsional)
Router **ARM/ARM64 dengan RouterOS v7** (paket `zerotier`) bisa tersambung ke VPS lewat ZeroTier, bukan L2TP. Router MIPS (hAP lite, hEX, RB951) tetap memakai L2TP. Keduanya bisa dipakai bersamaan.

1. Pasang ZTNET (web pengelola ZeroTier, port **3300**, tanpa Docker):
   ```bash
   cd /root/suwazed-panel
   bash pasang-ztnet.sh
   ```
   Script ini memeriksa Node.js dan RAM (menawarkan swap 2 GB bila perlu), memindahkan port ZTNET ke 3300 agar tidak bentrok dengan GenieACS (3000), lalu menjalankan installer resmi ZTNET. Saat ditanya alamat, isi subdomain sendiri, misalnya `zt.inetwifi.xyz`. Saat ditanya kirim laporan error, jawab `No`.
2. Buka `http://zt.domain-anda:3300` dan **segera daftar** (akun pertama menjadi admin). Buat jaringan di **Networks → Create Network**, lalu atur rentang IPv4, misalnya `172.27.0.0/24`. Rentang ini tidak boleh bentrok dengan `192.168.42.0/24`, `10.100.0.0/14`, subnet ONT, atau `172.17.0.0/16`.
3. Panel → **Pengaturan → ZeroTier** → pilih jaringan → **Hubungkan VPS**.
4. **Tambah router** → jalur **ZeroTier** → pasang script di MikroTik → tab **Ringkasan** → **Pilih router yang bergabung**. Panel otomatis menyetujui router, memberi IP ZeroTier, dan memasang route ke IP virtual.

URL ACS di ONT tetap `http://192.168.42.1:7547`, baik lewat L2TP maupun ZeroTier. Status, riwayat uptime, notifikasi Telegram, tes koneksi, dan port forwarding berlaku untuk kedua jalur.

### 9. GenieACS UI
Buka `http://IP_VPS:3000`. Jika muncul *initialization wizard*, buat akun admin dan centang **Users saja** agar config dari repo beryindo tidak tertimpa.

### 10. Tambah router
Panel → **Tambah router** → isi nama, subnet ONT (lihat Winbox: IP → DHCP Server → Networks), IP virtual (opsional, tidak boleh sama dengan router lain) → **Simpan** → tab **Script MikroTik** → **Salin** → tempel di Winbox **New Terminal** → tunggu status **Tersambung** → klik **Tes koneksi** (hasilnya tampil bertahap di popup).

Remote: buka router → tab **Remote** → **Tambah** → pilih layanan. Untuk Winbox, pakai alamat `IP_VPS:20001` di *Connect To*. Untuk layanan web (WebFig, Web ONT), alamatnya bisa langsung diklik dan terbuka di tab baru.

Dashboard menampilkan ringkasan uptime setiap router (24 jam, 7 hari, 30 hari, dan grafik 30 hari). Klik barisnya untuk membuka riwayat lengkap.

Router baru berstatus **Menunggu pemasangan** sampai MikroTik tersambung pertama kali. Setelah itu tab **Riwayat** mencatat setiap putus (kapan dan berapa lama), uptime 24 jam / 7 hari / 30 hari, dan grafik 30 hari. Riwayat disimpan 90 hari.

Semua perubahan di panel (login, tambah/ubah/hapus router, remote, pengaturan, Cloudflare) tercatat di menu **Log aktivitas** selama 90 hari. Password dan token tidak ikut dicatat.

### 11. ONT
- URL ACS: `http://192.168.42.1:7547` (atau `.1` dari jaringan VPN yang dipilih, lihat menu Pengaturan)
- Periodic Inform: aktif, 300 detik
- ACS username/password: kosong

### 12. Uji
ONT muncul di GenieACS → parameter `ConnectionRequestURL` berisi **IP virtual** → **Summon** berhasil.

---

## Update dari GitHub
```bash
cd /root/suwazed-panel
git pull
bash install-vpn-acs.sh          # data router & password admin tetap tersimpan
```
Jika GenieACS di-update, jalankan ulang `bash genieacs-virtualip.sh`.

## Perintah berguna
```bash
bash install-vpn-acs.sh password     # ganti password admin panel
bash install-vpn-acs.sh uninstall    # hapus panel (akun VPN tetap)
bash genieacs-virtualip.sh rollback  # kembali ke GenieACS asli

journalctl -u vpn-acs -n 50 --no-pager
journalctl -u genieacs-cwmp -n 50 --no-pager
journalctl -u xl2tpd -n 50 --no-pager
```

## Membersihkan / menghapus

### Di VPS
```bash
cd /root/suwazed-panel
bash bersihkan.sh
```
Pilihan menu:
1. **Hapus semua port forwarding saja** (VPN & router tetap jalan)
2. **Hapus Panel VPN ACS** + akun VPN router + route IP virtual + aturan firewall panel, dan kembalikan xl2tpd ke bawaan `vpnsetup.sh`
3. **Kembalikan GenieACS asli** (hapus patch IP virtual)
4. **Kembalikan parameter GenieACS** dari backup lama (`/root/backup-parameter-*`), jika pernah dibuat
5. **Hapus semua** (2 + 3, parameter ditanyakan)

Atau langsung: `bash bersihkan.sh portforward|panel|genieacs|parameter|semua`. Setiap pilihan meminta konfirmasi (ketik `YA`) dan membackup data penting ke `/root` dulu. Server VPN (xl2tpd/IPsec), GenieACS, MongoDB, dan data ONT tidak dihapus.

### Di setiap MikroTik
Tempel di Winbox → New Terminal (hanya menghapus pengaturan bertanda "VPN ACS"):
```
/interface l2tp-client remove [find where name="l2tp-acs"]
/ip route remove [find where comment="VPN ACS"]
/ip firewall nat remove [find where comment~"^VPN ACS"]
/ip firewall filter remove [find where comment~"^VPN ACS"]
:put "Pengaturan VPN ACS sudah dihapus."
```

## Backup
```bash
mongodump --db genieacs --out /root/backup-genieacs-$(date +%F)
cp /opt/vpn-acs/data.json /root/backup-vpnacs-$(date +%F).json
```
`data.json` berisi password VPN semua router: **jangan** di-commit ke GitHub.
