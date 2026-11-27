// Menyegarkan virtual parameter standar secara berkala saat ONT melapor.
// Hanya membaca; tidak ada nilai di ONT yang diubah.
// Interval bisa diatur lewat argumen preset: args[0] = menit untuk data cepat (default 5).
const fastMin = Math.max(1, parseInt(args[0], 10) || 5);
const fast = Date.now(fastMin * 60000);
const hourly = Date.now(3600000);
const daily = Date.now(86400000);
const plan = [
  ["RXPower", fast], ["gettemp", fast], ["activedevices", fast],
  ["pppoeIP", fast], ["IPTR069", fast], ["getdeviceuptime", fast], ["getpppuptime", fast],
  ["pppoeUsername", hourly], ["pppoeUsername2", hourly], ["pppoeMac", hourly], ["getSSID", hourly],
  ["getponmode", daily], ["PonMac", daily], ["getSerialNumber", daily],
];
for (const [name, t] of plan) declare("VirtualParameters." + name, { path: daily, value: t });
