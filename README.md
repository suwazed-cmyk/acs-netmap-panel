# Suwazed Panel: GenieACS + VPN L2TP MikroTik

Paket untuk menjalankan **GenieACS di VPS** yang bisa memberi perintah (Summon) ke ONT di banyak lokasi MikroTik, walaupun semua lokasi memakai **subnet lokal yang sama**.

- **VPN L2TP** dari setiap MikroTik ke VPS (tanpa IPsec, atau dengan IPsec jika diinginkan)
- **IP virtual (NETMAP)** per lokasi: ONT `10.0.0.25` di lokasi A terlihat di GenieACS sebagai `10.100.1.25`
- **Patch GenieACS** agar Summon memakai IP virtual
- **Panel web** untuk membuat akun VPN, script MikroTik siap salin, tes koneksi, dan **port forwarding** (remote Winbox/web ONT lewat IP publik VPS)

```
ONT ─ OLT ─ MikroTik lokasi ═══ VPN L2TP ═══ VPS (GenieACS + Panel)
                                               ▲
                     Remote Winbox: IP_VPS:20001
```

## Isi repo

| File | Fungsi |
|---|---|
| `install-vpn-acs.sh` | Installer Panel VPN ACS (sudah berisi seluruh panel) |
| `genieacs-virtualip.sh` | Patch IP virtual untuk GenieACS v1.2.13 |
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
```bash
wget -O /root/genie.sh https://raw.githubusercontent.com/beryindo/genieacs/refs/heads/main/genie.sh
bash /root/genie.sh
```
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
| 500, 4500 | UDP | Hanya jika IPsec dinyalakan |

Port 7547 dan 7557 **tidak perlu** dibuka ke publik.

### 8. Atur panel (sekali di awal)
Menu **Pengaturan**:
1. **Alamat VPS**: IP publik atau domain VPS → Simpan
2. **Pakai IPsec**: biarkan mati (L2TP biasa)
3. **Jaringan VPN (L2TP)**: tentukan **sekarang** (default `192.168.42.0/24`). Mengganti belakangan berarti URL ACS di semua ONT ikut berubah.
4. **Patch IP virtual GenieACS** harus berstatus **Aktif**

### 9. GenieACS UI
Buka `http://IP_VPS:3000`. Jika muncul *initialization wizard*, buat akun admin dan centang **Users saja** agar config dari repo beryindo tidak tertimpa.

### 10. Tambah lokasi
Panel → **＋ Tambah Lokasi** → isi nama, subnet ONT (lihat Winbox: IP → DHCP Server → Networks), IP virtual (opsional, tidak boleh sama dengan lokasi lain) → **Salin Script** → tempel di Winbox **New Terminal** → tunggu status **Tersambung** → **Tes Koneksi**.

Remote MikroTik: **🌐 Remote / Port Forward** → Winbox → Tambah → pakai alamat `IP_VPS:20001` di Winbox *Connect To*.

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
bash install-vpn-acs.sh          # data lokasi & password admin tetap tersimpan
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

## Backup
```bash
mongodump --db genieacs --out /root/backup-genieacs-$(date +%F)
cp /opt/vpn-acs/data.json /root/backup-vpnacs-$(date +%F).json
```
`data.json` berisi password VPN semua lokasi: **jangan** di-commit ke GitHub.
