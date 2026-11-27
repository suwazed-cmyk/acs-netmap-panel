// MAC address ONT (sisi LAN / perangkat). Hanya baca.
const now = Date.now();
const day = Date.now(86400000);
const paths = [
  "InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.MACAddress",
  "InternetGatewayDevice.LANDevice.1.LANEthernetInterfaceConfig.1.MACAddress",
  "InternetGatewayDevice.DeviceInfo.X_CU_SerialNumber",
  "InternetGatewayDevice.DeviceInfo.MACAddress",
  "Device.Ethernet.Interface.1.MACAddress",
  "Device.Ethernet.Link.1.MACAddress",
  "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANPPPConnection.*.MACAddress",
  "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANIPConnection.*.MACAddress",
];
const found = paths.map((p) => declare(p, { path: day, value: now }));
function mac(v) {
  const h = String(v || "").replace(/[^0-9A-Fa-f]/g, "");
  if (h.length !== 12 || /^0+$/.test(h)) return "";
  return h.toUpperCase().match(/../g).join(":");
}
let out = "";
for (const d of found) {
  for (const it of d) { out = mac(it.value && it.value[0]); if (out) break; }
  if (out) break;
}
return { writable: false, value: [out, "xsd:string"] };
