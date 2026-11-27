// Jumlah perangkat WiFi yang sedang tersambung (semua SSID). Hanya baca.
// FiberHome melaporkan jumlah yang benar di WLAN_AssociatedDeviceNumberOfEntries,
// vendor lain di AssociatedDeviceNumberOfEntries atau TotalAssociations.
const now = Date.now();
const day = Date.now(86400000);
const L = "InternetGatewayDevice.LANDevice.*.WLANConfiguration.*.";
const keys = ["WLAN_AssociatedDeviceNumberOfEntries", "AssociatedDeviceNumberOfEntries", "TotalAssociations"];
const sets = keys.map((k) => declare(L + k, { path: day, value: now }));
const perWlan = {};
sets.forEach((d, i) => {
  for (const it of d) {
    const base = it.path.slice(0, it.path.length - keys[i].length);
    const n = parseInt((it.value || [""])[0], 10);
    if (perWlan[base] === undefined && isFinite(n) && n >= 0) perWlan[base] = n;
  }
});
let total = 0, seen = false;
for (const b in perWlan) { total += perWlan[b]; seen = true; }
if (!seen) {
  const tr = declare("Device.WiFi.AccessPoint.*.AssociatedDeviceNumberOfEntries", { path: day, value: now });
  for (const it of tr) { const n = parseInt((it.value || [""])[0], 10); if (isFinite(n) && n >= 0) { total += n; seen = true; } }
}
return { writable: false, value: seen ? [total, "xsd:unsignedInt"] : ["", "xsd:string"] };
