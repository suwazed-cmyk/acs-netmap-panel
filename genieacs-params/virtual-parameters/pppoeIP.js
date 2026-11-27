// IP PPPoE ONT. Koneksi PPPoE bridge dan 0.0.0.0 dilewati; koneksi yang tersambung diutamakan.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANPPPConnection.*.";
const ok = (ip) => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) && ip !== "0.0.0.0";
const ips = declare(W + "ExternalIPAddress", { path: day, value: now });
const types = declare(W + "ConnectionType", { path: day, value: day });
const stat = declare(W + "ConnectionStatus", { path: day, value: now });
const tInfo = {}, sInfo = {};
for (const it of types) tInfo[it.path.replace(/ConnectionType$/, "")] = String((it.value || [""])[0]);
for (const it of stat) sInfo[it.path.replace(/ConnectionStatus$/, "")] = String((it.value || [""])[0]);

let out = "", alt = "";
for (const it of ips) {
  const base = it.path.replace(/ExternalIPAddress$/, "");
  const ip = String((it.value || [""])[0]).trim();
  if (!ok(ip) || /bridge/i.test(tInfo[base] || "")) continue;
  if (/^connected$/i.test(sInfo[base] || "")) { out = ip; break; }
  if (!alt) alt = ip;
}
if (!out) out = alt;
if (!out) {
  const tr = declare("Device.PPP.Interface.*.IPCP.LocalIPAddress", { path: day, value: now });
  for (const it of tr) { const ip = String((it.value || [""])[0]).trim(); if (ok(ip)) { out = ip; break; } }
}
return { writable: false, value: [out, "xsd:string"] };
