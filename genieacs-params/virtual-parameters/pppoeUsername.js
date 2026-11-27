// Username PPPoE ONT. Koneksi PPPoE bridge dilewati; koneksi yang tersambung diutamakan.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANPPPConnection.*.";
const users = declare(W + "Username", { path: day, value: now });
const types = declare(W + "ConnectionType", { path: day, value: day });
const stat = declare(W + "ConnectionStatus", { path: day, value: now });
const tInfo = {}, sInfo = {};
for (const it of types) tInfo[it.path.replace(/ConnectionType$/, "")] = String((it.value || [""])[0]);
for (const it of stat) sInfo[it.path.replace(/ConnectionStatus$/, "")] = String((it.value || [""])[0]);

let out = "", alt = "";
for (const it of users) {
  const base = it.path.replace(/Username$/, "");
  const u = String((it.value || [""])[0]).trim();
  if (!u || /bridge/i.test(tInfo[base] || "")) continue;
  if (/^connected$/i.test(sInfo[base] || "")) { out = u; break; }
  if (!alt) alt = u;
}
if (!out) out = alt;
if (!out) {
  const tr = declare("Device.PPP.Interface.*.Username", { path: day, value: now });
  for (const it of tr) { const u = String((it.value || [""])[0]).trim(); if (u) { out = u; break; } }
}
return { writable: false, value: [out, "xsd:string"] };
