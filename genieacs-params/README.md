# Parameter standar ONT untuk GenieACS

Kumpulan virtual parameter, provision, dan tampilan GenieACS UI yang dipasang oleh
**ACS NETMAP Panel** (menu GenieACS → Pengaturan → Parameter standar ONT).

Semua parameter **hanya membaca** data ONT. Tidak ada akun ACS, password admin, WiFi,
firewall, atau akses remote ONT yang diubah.

## Isi

| Virtual parameter | Isi | Disegarkan |
|---|---|---|
| `RXPower` | Redaman optik (dBm) | tiap 5 menit |
| `gettemp` | Suhu modul optik (°C) | tiap 5 menit |
| `activedevices` | Jumlah perangkat WiFi tersambung | tiap 5 menit |
| `pppoeIP` | IP PPPoE | tiap 5 menit |
| `IPTR069` | IP WAN manajemen (TR-069) | tiap 5 menit |
| `getdeviceuptime` | Lama ONT menyala | tiap 5 menit |
| `getpppuptime` | Lama PPPoE tersambung | tiap 5 menit |
| `pppoeUsername`, `pppoeUsername2` | Username PPPoE | tiap 1 jam |
| `pppoeMac` | MAC WAN PPPoE | tiap 1 jam |
| `getSSID` | Nama WiFi utama | tiap 1 jam |
| `getponmode` | GPON / EPON / Ethernet | tiap hari |
| `PonMac` | MAC ONT | tiap hari |
| `getSerialNumber` | SN yang mudah dibaca (FHTT…, ZTEG…, HWTC…) | tiap hari |

Nama parameter sama dengan yang umum dipakai komunitas, sehingga aplikasi lain
(mis. Panel ACS) tetap bisa membacanya.

Jalur yang didukung: TR-181 (`Device.*`) dan TR-098 (`InternetGatewayDevice.*`) dengan
ekstensi vendor ZTE, Huawei, FiberHome, C-Data, Nokia/ALU, Realtek, serta ONT OEM
CMCC / CT-COM / CU.

- `provisions/acsnm-params.js` — menyegarkan parameter di atas sesuai jadwal (preset `acsnm-params`).
- `ui/index.json`, `ui/filters.json` — kolom dan filter daftar perangkat GenieACS UI.
- `ui/overview.json` — grafik ringkasan "Kondisi ONT" (redaman, suhu, jenis jalur).

## Pemasangan

Dari panel: **GenieACS → Pengaturan → Parameter standar ONT → Pasang**. Panel memasang lewat
NBI lokal tanpa menghapus provision lain. Parameter bernama sama yang sudah ada dan tampilan
GenieACS UI disimpan dulu, lalu dikembalikan bila parameter standar dihapus dari panel.

## Sumber dan lisensi

Disusun ulang dan disederhanakan dari kumpulan parameter komunitas:

- [SafriNetwork / GACS-Ubuntu-22.04](https://github.com/safrinnetwork/GACS-Ubuntu-22.04)
- [alijayanet / genieacs](https://github.com/alijayanet/genieacs)
- [beryindo / genieacs](https://github.com/beryindo/genieacs)
- R-Tech

Folder ini dirilis dengan lisensi **GNU GPL v3** (lihat `LICENSE`), mengikuti sumber aslinya.
