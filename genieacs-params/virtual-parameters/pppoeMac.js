// MAC address WAN PPPoE ONT. Hanya baca.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANPPPConnection.*.";
const macs = declare(W + "MACAddress", { path: day, value: now });
const types = declare(W + "ConnectionType", { path: day, value: day });
const tInfo = {};
for (const it of types) tInfo[it.path.replace(/ConnectionType$/, "")] = String((it.value || [""])[0]);
function mac(v) {
  const h = String(v || "").replace(/[^0-9A-Fa-f]/g, "");
  if (h.length !== 12 || /^0+$/.test(h)) return "";
  return h.toUpperCase().match(/../g).join(":");
}
let out = "", alt = "";
for (const it of macs) {
  const m = mac(it.value && it.value[0]);
  if (!m) continue;
  if (!/bridge/i.test(tInfo[it.path.replace(/MACAddress$/, "")] || "")) { out = m; break; }
  if (!alt) alt = m;
}
return { writable: false, value: [out || alt, "xsd:string"] };
