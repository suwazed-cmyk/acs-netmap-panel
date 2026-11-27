// Redaman optik (RX power) dalam dBm. Hanya baca.
// Mendukung jalur standar TR-181 dan jalur vendor TR-098 (ZTE, Huawei, FiberHome, C-Data,
// CMCC/CT-COM/CU (ONT OEM China: Xpon, Hioso, GM220S, F477, dll.), Nokia/ALU, Realtek).
const now = Date.now();
const day = Date.now(86400000);
const paths = [
  "Device.Optical.Interface.*.OpticalSignalLevel",
  "InternetGatewayDevice.WANDevice.*.X_ZTE-COM_WANPONInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_GponInterafceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_HW_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_FH_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_FH_EponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CMCC_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CMCC_EponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CT-COM_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CT-COM_EponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CU_WANGPONInterfaceConfig.OpticalTransceiver.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CU_WANEPONInterfaceConfig.OpticalTransceiver.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_CDATA_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.WANDevice.*.X_RTK_GponInterfaceConfig.RXPower",
  "InternetGatewayDevice.X_ALU_OntOpticalParam.RXPower",
];
const found = paths.map((p) => declare(p, { path: day, value: now }));

// Ubah nilai mentah menjadi dBm. Vendor memakai satuan berbeda:
// - sudah dBm (mis. -18.5)              -> dipakai apa adanya
// - 0.1 mikroWatt (ZTE/CMCC/CT-COM/CU)  -> 30 + 10*log10(nilai * 1e-7)
// - 0.001 dBm (TR-181, mis. -18500)     -> dibagi 1000
// - 0.01 dBm (sebagian OEM, mis. -1850) -> dibagi 100
function toDbm(raw, tr181) {
  const n = parseFloat(String(raw).replace(/[^0-9.eE+\-]/g, ""));
  if (!isFinite(n) || n === 0) return null;
  let v;
  if (tr181) v = n / 1000;
  else if (n > 0) v = 30 + 10 * Math.log10(n * 1e-7);
  else if (n < -1000) v = n / 1000;
  else if (n < -100) v = n / 100;
  else if (n < -60) v = n / 10;
  else v = n;
  if (!isFinite(v) || v < -60 || v > 10) return null;
  return Math.round(v * 100) / 100;
}

let out = null;
for (let i = 0; i < found.length && out === null; i++) {
  for (const it of found[i]) {
    if (!it.value || it.value[0] === "" || it.value[0] === null) continue;
    const v = toDbm(it.value[0], i === 0);
    if (v !== null) { out = v; break; }
  }
}
return { writable: false, value: out === null ? ["N/A", "xsd:string"] : [out, "xsd:double"] };
