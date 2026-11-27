// IP WAN manajemen (jalur TR-069) ONT. Koneksi bridge dan 0.0.0.0 dilewati.
// Bila tidak ditemukan, dipakai alamat dari ConnectionRequestURL.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANIPConnection.*.";
const ok = (ip) => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) && ip !== "0.0.0.0" && !ip.startsWith("127.");
const ips = declare(W + "ExternalIPAddress", { path: day, value: now });
const types = declare(W + "ConnectionType", { path: day, value: day });
const names = declare(W + "Name", { path: day, value: day });
const tInfo = {}, nInfo = {};
for (const it of types) tInfo[it.path.replace(/ConnectionType$/, "")] = String((it.value || [""])[0]);
for (const it of names) nInfo[it.path.replace(/Name$/, "")] = String((it.value || [""])[0]).toUpperCase();

let out = "", alt = "";
for (const it of ips) {
  const base = it.path.replace(/ExternalIPAddress$/, "");
  const ip = String((it.value || [""])[0]).trim();
  if (!ok(ip) || /bridge/i.test(tInfo[base] || "")) continue;
  if (/TR069|TR-069|MANAGE|ACS|OAM/.test(nInfo[base] || "")) { out = ip; break; }
  if (!alt) alt = ip;
}
if (!out) out = alt;
if (!out) {
  for (const root of ["InternetGatewayDevice", "Device"]) {
    const cr = declare(root + ".ManagementServer.ConnectionRequestURL", { value: now });
    const m = String((cr.value || [""])[0] || "").match(/^[a-z]+:\/\/(?:[^@/]*@)?([0-9.]+)/i);
    if (m && ok(m[1])) { out = m[1]; break; }
  }
}
return { writable: false, value: [out, "xsd:string"] };
