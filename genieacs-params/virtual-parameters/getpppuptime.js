// Lama koneksi PPPoE tersambung, format "3d 04:05:06". Hanya baca.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.WANConnectionDevice.*.WANPPPConnection.*.";
const ups = declare(W + "Uptime", { path: day, value: now });
const stat = declare(W + "ConnectionStatus", { path: day, value: now });
const sInfo = {};
for (const it of stat) sInfo[it.path.replace(/ConnectionStatus$/, "")] = String((it.value || [""])[0]);
let secs = NaN;
for (const it of ups) {
  const n = parseInt((it.value || [""])[0], 10);
  if (!isFinite(n) || n <= 0) continue;
  if (/^connected$/i.test(sInfo[it.path.replace(/Uptime$/, "")] || "")) { secs = n; break; }
  if (!isFinite(secs)) secs = n;
}
let up = "";
if (isFinite(secs)) {
  const p = (n) => (n < 10 ? "0" : "") + n;
  up = Math.floor(secs / 86400) + "d " + p(Math.floor((secs % 86400) / 3600)) + ":" + p(Math.floor((secs % 3600) / 60)) + ":" + p(secs % 60);
}
return { writable: false, value: [up, "xsd:string"] };
