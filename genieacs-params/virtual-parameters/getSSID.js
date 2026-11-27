// Nama WiFi (SSID) utama ONT, 2.4 GHz lebih dulu. Hanya baca.
const day = Date.now(86400000);
const hour = Date.now(3600000);
const paths = [
  "InternetGatewayDevice.LANDevice.1.WLANConfiguration.1.SSID",
  "InternetGatewayDevice.LANDevice.1.WLANConfiguration.*.SSID",
  "Device.WiFi.SSID.1.SSID",
  "Device.WiFi.SSID.*.SSID",
];
const found = paths.map((p) => declare(p, { path: day, value: hour }));
let out = "";
for (const d of found) {
  for (const it of d) { const v = String((it.value || [""])[0] || "").trim(); if (v) { out = v; break; } }
  if (out) break;
}
return { writable: false, value: [out, "xsd:string"] };
