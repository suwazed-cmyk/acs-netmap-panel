// Serial number ONT yang mudah dibaca. SN GPON sering dikirim dalam heksadesimal
// (mis. 46485454xxxxxxxx); 4 byte pertama diubah ke huruf vendor (FHTT, ZTEG, HWTC, ...).
const day = Date.now(86400000);
const raw = String((declare("DeviceID.SerialNumber", { value: day }).value || [""])[0] || "").trim();
let sn = raw;
if (/^[0-9A-Fa-f]{16}$/.test(raw)) {
  let vendor = "";
  for (let i = 0; i < 8; i += 2) vendor += String.fromCharCode(parseInt(raw.substr(i, 2), 16));
  if (/^[A-Z0-9]{4}$/.test(vendor)) sn = vendor + raw.substr(8).toUpperCase();
}
return { writable: false, value: [sn, "xsd:string"] };
