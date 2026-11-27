// Lama ONT menyala sejak boot terakhir, format "3d 04:05:06". Hanya baca.
const now = Date.now();
let secs = NaN;
for (const root of ["InternetGatewayDevice", "Device"]) {
  const d = declare(root + ".DeviceInfo.UpTime", { value: now });
  if (d.size && d.value && d.value[0] !== "") { secs = parseInt(d.value[0], 10); break; }
}
let up = "";
if (isFinite(secs) && secs >= 0) {
  const p = (n) => (n < 10 ? "0" : "") + n;
  up = Math.floor(secs / 86400) + "d " + p(Math.floor((secs % 86400) / 3600)) + ":" + p(Math.floor((secs % 3600) / 60)) + ":" + p(secs % 60);
}
return { writable: false, value: [up, "xsd:string"] };
