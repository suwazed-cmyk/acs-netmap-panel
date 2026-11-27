// Jenis jalur uplink ONT: GPON, EPON, atau Ethernet. Hanya baca.
const now = Date.now();
const day = Date.now(86400000);
const W = "InternetGatewayDevice.WANDevice.*.";
const maker = String((declare("DeviceID.Manufacturer", { value: day }).value || [""])[0]).toUpperCase();
const acc = declare(W + "WANCommonInterfaceConfig.WANAccessType", { path: day, value: now });
const hw = declare("InternetGatewayDevice.DeviceInfo.X_HW_UpPortMode", { path: day, value: now });
// Cukup dicek keberadaannya (tanpa membaca nilai)
const has = (list) => list.map((p) => declare(p, { path: day }).size).some((n) => n > 0);
const epon = has(["X_FH_EponInterfaceConfig", "X_CMCC_EponInterfaceConfig", "X_CT-COM_EponInterfaceConfig", "X_CU_WANEPONInterfaceConfig"].map((x) => W + x + ".*"));
const gpon = has(["X_ZTE-COM_WANPONInterfaceConfig", "X_GponInterafceConfig", "X_HW_GponInterfaceConfig", "X_FH_GponInterfaceConfig", "X_CMCC_GponInterfaceConfig", "X_CT-COM_GponInterfaceConfig", "X_CU_WANGPONInterfaceConfig", "X_CDATA_GponInterfaceConfig", "X_RTK_GponInterfaceConfig"].map((x) => W + x + ".*")
  .concat(["Device.Optical.Interface.*", "InternetGatewayDevice.X_ALU_OntOpticalParam.*"]));

let txt = "";
for (const d of [acc, hw]) for (const it of d) if (it.value && it.value[0]) txt += " " + String(it.value[0]).toUpperCase();

let mode = "Ethernet";
if (txt.includes("EPON") || (epon && !txt.includes("GPON"))) mode = "EPON";
else if (txt.includes("PON") || gpon || maker.includes("RAISECOM")) mode = "GPON";
return { writable: false, value: [mode, "xsd:string"] };
