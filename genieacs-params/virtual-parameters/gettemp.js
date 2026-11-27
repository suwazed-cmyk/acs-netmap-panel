// Suhu modul optik ONT dalam °C. Hanya baca.
// Sebagian vendor memberi nilai mentah 1/256 °C (mis. 11520 = 45 °C), sebagian sudah °C.
const now = Date.now();
const day = Date.now(86400000);
const paths = [
  "Device.DeviceInfo.TemperatureStatus.TemperatureSensor.*.Value",
  "Device.Optical.Interface.*.X_Temperature",
  "InternetGatewayDevice.WANDevice.*.X_ZTE-COM_WANPONInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_GponInterafceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_HW_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_FH_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_FH_EponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_CMCC_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_CMCC_EponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_CT-COM_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_CT-COM_EponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_CU_WANGPONInterfaceConfig.OpticalTransceiver.Temperature",
  "InternetGatewayDevice.WANDevice.*.X_CU_WANEPONInterfaceConfig.OpticalTransceiver.Temperature",
  "InternetGatewayDevice.WANDevice.*.X_CDATA_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.WANDevice.*.X_RTK_GponInterfaceConfig.TransceiverTemperature",
  "InternetGatewayDevice.X_ALU_OntOpticalParam.Temperature",
];
const found = paths.map((p) => declare(p, { path: day, value: now }));

function toC(raw) {
  const n = parseFloat(String(raw).replace(/[^0-9.eE+\-]/g, ""));
  if (!isFinite(n) || n === 0) return null;
  const v = Math.abs(n) > 150 ? n / 256 : n;
  if (v < -40 || v > 125) return null;
  return Math.round(v * 10) / 10;
}

let out = null;
for (const d of found) {
  for (const it of d) {
    if (!it.value) continue;
    const v = toC(it.value[0]);
    if (v !== null) { out = v; break; }
  }
  if (out !== null) break;
}
return { writable: false, value: out === null ? ["N/A", "xsd:string"] : [out, "xsd:double"] };
