# Parameter GenieACS versi bersih

Basis: parameter dari [beryindo/genieacs](https://github.com/beryindo/genieacs) (preset, provision, virtual parameter, dan tampilan UI), dengan beberapa bagian dari [safrinnetwork/GACS-Ubuntu-22.04](https://github.com/safrinnetwork/GACS-Ubuntu-22.04).

Pasang dengan `bash pasang-parameter.sh` dari folder utama repo. Yang diganti hanya koleksi `presets`, `provisions`, `virtualParameters`, dan `config`. **Data perangkat ONT tidak disentuh.**

## Perubahan dibanding beryindo

| Bagian | Asli (beryindo) | Versi ini |
|---|---|---|
| Preset + provision `useradmin` | Aktif; mencoba mengganti user admin web ONT ke `userjkb`/`userjkb`, dan error karena variabel `superuser` tidak didefinisikan | **Dihapus** (fault lama ikut dibersihkan) |
| Provision `inform`: kredensial ACS & Connection Request | `acs` / `acsadmin12345` (tertulis di repo publik) | Diisi saat pemasangan (default acak) |
| Provision `inform`: URL ACS | Tidak diubah (baris dinonaktifkan) | Tetap tidak diubah |
| Provision `default`: akses WAN ONT | Selalu membuka HTTP + SSH + Telnet (Huawei), HTTP (ZTE), remote web (FiberHome) | Saklar 3 mode: `buka-web` (HTTP saja, SSH/Telnet ditutup), `tutup`, `biarkan` |
| Virtual parameter `RXPowerInt` | Tidak ada | **Baru.** Redaman dibulatkan sebagai angka, untuk filter/grafik |
| Grafik redaman | Memakai `RXPower` (teks): filter dibandingkan secara alfabetis, kategori "Lumayan"/"Kritis" tidak pernah terisi | Memakai `RXPowerInt`: Baik −8 s/d −24, Waspada −25 s/d −27, Buruk < −27, Terlalu kuat > −8 (dBm) |
| Grafik suhu | Ada celah 60–65 °C yang tidak masuk kategori mana pun | Celah ditutup |
| Tampilan daftar perangkat | Kolom "Tag" & "Action" tanpa judul | Judul kolom, kolom Temp dengan titik warna (dari safrinnetwork) |
| Grafik merk perangkat | Tanpa Xpon | Irisan "Xpon" (`ZICG`) (dari safrinnetwork) |

Selebihnya (19 virtual parameter, provision `bootstrap`, sisa provision `default`, dan tampilan UI lain) sama dengan beryindo.

## Mode akses WAN
- **buka-web**: web ONT bisa dibuka dari sisi WAN. Dibutuhkan fitur **Web ONT** di Panel VPN ACS (port forwarding ke IP TR-069 ONT). SSH & Telnet dari WAN ditutup.
- **tutup**: HTTP, SSH, dan Telnet dari WAN ditutup. Fitur Web ONT di panel tidak akan bisa dipakai.
- **biarkan**: tidak mengubah apa pun. ONT yang sebelumnya sudah dibuka oleh parameter beryindo tetap terbuka.

Untuk mengganti mode atau kredensial, jalankan ulang `bash pasang-parameter.sh`.
