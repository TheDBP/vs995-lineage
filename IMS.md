# IMS / VoLTE on the V20 -- what the stock firmware does and what a bridge needs

No LineageOS build for the V20 has VoLTE. This records what the stock
Nougat firmware (VS99519A/VS9951CA, 7.0 NRD90M) actually does so the work
need not be redone. Method per item in brackets; nothing here is inferred
from documentation.

## Architecture: AP-side IMS

The modem does not run an IMS stack. The SIP/IMS stack is a Qualcomm
AP-side one driven by LG's `Ims4` app.

- Modem image strings: no SIP/INVITE/IMSA/IMSS strings; LG hooks only
  (`cmcall.c [LGIMS] DRB_SETUP_IND/PDN_REJECT_IND`, `cmsds.c [hVoLTE]
  STATUS_LTE_GET_CURRENT_IMS_STATUS to LGIMS`, `lgims_callstatus`,
  `LGE_UNSOL_VOLTE_STR` events 0x69000-0x69010,
  `lgrilhook_oem_rapi_telephony.c oem_rapi_get/set_ims_setting`,
  `cmcall_esm_msgr_rpt_to_lgims`). [strings on the stock modem image]
- Live QMI service table (LineageOS 24.0, stock modem): the modem (node 0)
  publishes 42 services -- WDS DMS NAS QOS WMS AUTH AT VOICE CAT2 UIM PBM
  TEST LOC SAR MFS TIME TS TMD WDA CSVT COEX PDC RFRPE DSD SSCTL DPM UIMRMT
  ATH SLIMBUS SERVREG_NOTIF(0x42) 0x36 0x44 0x302 0x320 0x1001 and LG vendor
  services 0x2bd-0x2c3 -- and **none of IMSS 0x12, IMSP 0x1f, IMSVT 0x20,
  IMSA 0x21, IMS_RTP 0x28**. A modem-side IMS stack (Robin, Pixel) always
  publishes these. [`/sys/kernel/debug/msm_ipc_router/dump_servers`]
- Stock `vendor/lib/libqmiservices.so` still carries client descriptors
  for 0x12/0x20/0x21/0x28 (generic Qualcomm lib), and `lib-imss.so` carries
  IMSS 0x12 -- the AP stack is the IMSS server, not a client of the modem.
  [service-object structs: `06|05 00 00 00, 01 00 00 00, <service id>,
  <max msg len>` in .data.rel.ro]
- Stock AP assets (all 32-bit, 2016): `priv-app/Ims4` (com.lge.ims
  v4.0.20150602, targetSdk 24, `sharedUserId=android.uid.phone`,
  persistent, uses-library com.qualcomm.qcrilhook,
  com.android.lge.lgsvcitems, GBAService), `ImsVT`, `vendor/lib/lib-imss.so`
  (SIP), lib-imsdpl, lib-imsqimf, lib-imsSDP, lib-imsxml, lib-imsvt,
  lib-imsrcs*, lib-imscamera, `libril-qcril-hook-oem.so`, `imswmsproxy`,
  `lib/libvss_ims_qcci.so`. [stock system.image listing]

## LG's modem hook: QMI service 0x2bf (`lge_ims`, IDL v2)

`libvss_ims_qcci.so` exports `lge_ims_qmi_idl_service_object_v02` (service 0x2bf,
max msg 0x411). Wire format from the IDL tables
(`rom-forge/tools/qmi-services.py idl libvss_ims_qcci.so 2bf`):

| msg | REQ | RESP | IND |
|-----|-----|------|-----|
| 0x060c | TLV1 `u8[300]` | TLV2 `qmi_response_type` | TLV1 `u8[300]` |
| 0x060d | TLV1 `u32` | TLV2 result, TLV3 `u32`, TLV 0x10 opt `u8[1024]` | TLV1 `u32`, TLV 0x10 opt `u8[1024]` |

The live modem publishes **0x2bf instance 0x0102** on node 0, so the modem
side exists in the firmware a Lineage build runs on. It is a plain QMI client
and does not need LG's RIL (unlike `oem_rapi_*_ims_setting` via
`libril-qcril-hook-oem.so`; our tree runs the tissot qcril).

**Who uses it.** Only `/system/lib/libimsmmpf.so` (LG IMS Media Platform
Framework, unstripped C++). `libimsvtjni.so` links the qcci lib but imports
nothing. **0x060d is unused by any AP code in the stock image.** `libims.so`
(11.9 MB, LG's own SIP/IMS stack, NEEDED libimsmmpf/libimswms/libssl, no RIL
libs) gets the modem's IMS PDN address through it
(`MediaResourceMngr::UpdateModemIPv6() - QMI is not prepared yet. Postpone
getting IP CP`).

**0x060c payload = a fragmented "CP message" pipe.** `MMPF_CP_IF_send_msg(session,
data, len, type)` builds 300-byte blocks and sends each with
`qcci_qmi_lge_ims_send_cmd(0x60c, buf, 0x12c, &resp, 8, 1000 ms)`:

    u32 msg_type          _eMMPFCPMsgType below
    u32 is_last_fragment
    u32 chunk_len         <= 0xdc (220)
    u32 offset            of this chunk in the whole message
    u32 header_size       0x20
    u32 session_id        < 65
    u32 seq               global counter
    u32 reserved          0
    u8  payload[220]

AP -> modem `_eMMPFCPMsgType`: 0 createMediaSession, 1 destroyMediaSession,
2 setProperty(`_tMMPFProperty`), 3 request(`_tMMPFRequest`),
4 getState(`_eMMPFModeType`), 5 sendClearAll, 6 GetIpAddrOfCP,
7 createSocketBridge(`_tMMPFNetworkInfo`, `_tMMPFPortInfo`),
8 destroySocketBridge, 9 sendDataToBridge, 10 SetMMPFDebugLog.

Modem -> AP IND 0x060c, same header, `MMPF_OnIndFromCP` (rejects
header_size != 0x20, offset > 0xbb8, session > 64, duplicate headers;
reassembles fragments by offset): 0 RESPONSE (payload[0] request id,
payload[4] response; per-session listener), 1 NOTIFY, 2 IP_ADDR (string at
payload+4, <= 46 chars -> `m_strIpAddrOfCP`), 3 CREATE_SOCKET_BRIDGE
(`_tSocketBridgeParam`, 0x144 bytes), 4 DESTROY_SOCKET_BRIDGE, 5 SOCKET_DATA
(<= 3000 bytes -> `IMMPFSocketBridgeDataListener`), 6 PCAP/media trace
(<= 1500 -> `MMPFPcapWriter::OnData`), 7 RTP_SESSION_INFO
(`OnRtpSessionInfoInd`), 8 UKNIGHT_INFO (`OnUKnightInfoInd`).

Reading: the modem hosts an MMPF-compatible media session engine
(`_eMMPFModeType` AP vs CP) and bridges sockets so AP-side media can use the
IMS PDN; libimsmmpf also carries its own RTP/SRTP stack and video codecs.
Not yet decoded: the layouts of `_tMMPFRequest`, `_tMMPFProperty`,
`_tSocketBridgeParam`, `_tMMPFNetworkInfo`, `_tMMPFPortInfo`,
`RtpSessionInfoInd`, `_tMMPFResponseEvent_UKnight`. Registration state
takes a different path (next section).

## How registration state reaches the modem

Not through 0x2bf and not through qcrilhook (Ims4's `ImsQcRilHook` only does
TuneAway). `Ims4` -> Binder `com.lge.ims.phone`
(`com.android.internal.telephony.IIMSPhone`, impl `IMSPhone` inside the
stock `telephony-common.jar`) -> LG `RIL` OEM requests -> LG qcril
(`/vendor/lib64/libril-qc-qmi-1.so`) -> LG vendor QMI services. Traced from
`com.lge.ims.volte.agents.RegiProcessAgent` (baksmali of the stock Ims4 and
`boot-telephony-common.oat`) and `llvm-objdump` of the qcril lib.

Route A, every operator (`setImsRegistrationStateForModem(regState)`):

    IIMSPhone.setSysInfo(1, 0xd, regState, "")
    -> IMSPhone.setBalItem(0xd, regState)
    -> item 0x60039 LGE_MODEM_INFO_IMS_REG_STATUS (com.lge.internal.telephony.ModemItem$W_BASE)
    -> Phone.setModemIntegerItem -> RIL.setModemInfo
    -> RIL_REQUEST_SET_MODEM_INFO 374 (0x176), parcel {int item, String data}
    -> qcril_qmi_lge_vss_set_modem_info
    -> qcci_qmi_lge_vss_send_cmd(0x0609, req, 0x410, resp, 8, 500 ms)
    -> QMI service 0x320 (lge_vss common, IDL libvss_common_idl.so) msg 0x0609
       req: TLV 0x01 u32 item; TLV 0x02 u32 instance (qmi_ril_get_process_instance_id);
            TLV 0x10 u8[1024] string, var-len
       resp: result only (8 bytes)

GET_MODEM_INFO (375) is msg 0x060a on the same service. Other W_BASE items:
0x60020 DETACH, 0x60021 ATTACH, 0x60022 OPRT_MODE, 0x6002d SKT_VTCALL_STATE,
0x60032 BOOT_COMPLETED, 0x6003e IMS_RF_QUALITY.

Route B, VZW only (`setRegiStateForVZW(appType=10, .., registered)`):

    IIMSPhone.setSysInfo(0x12, 1, -1, "")
    -> CommandsInterface.setImsRegistration(1)
    -> RIL_REQUEST_LG_IMS_REGISTRATION_STATE 280 (0x118), parcel {1, state}
    -> qcril_lgrilhook_set_lg_ims_reg_state
    -> qcril_qmi_raw_cmd_local(2, 0x1063, req, resp) -> qcril_qmi_raw_cmd(1, 2, 0x1063, ..)
    -> qcci_qmi_lge_nv_send_cmd
    -> QMI service 0x2bd (lge_nv, IDL libvss_nv_idl.so) msg 0x0603 (NV write)
       req 1032 bytes {u32 item=0x1063; u32 len; u8[1024] data}, state as u8 in a
       10-byte buffer; resp 16 bytes. raw_cmd: arg1==1 -> msg 0x0602 (read,
       req u32 item, resp {result, u32, u32, u8[1024]}); arg1==2 -> 0x0603
       (only for arg0 in {1,3}).

Route C, hVoLTE (`setRegServiceToModem` -> `setSysInfo(0x64, sysMode,
service, "")` -> `RIL.setImsRegistrationForHVoLTE`):

    RIL_REQUEST_UPDATE_IMS_STATUS_REQ 292 (0x124)
    -> lge_qcril_qmi_nas_hvolte_update_ims_status_request (client lge_hvolte_client,
       bound to the stock NAS service object)
    -> qmi_client_send_msg_sync(NAS 0x03, msg 0x0072, req 520 bytes, 30 s)
       req: TLV 0x01 enum8 ims_status; TLV 0x02 struct[64] var-len {u32 radio_if; u8 status}
       (standard Qualcomm NAS `update_ims_status`, present in libqmiservices' NAS IDL --
       not LG-specific)

VZW extras from the same agent: `setSysInfo(0x10, 0xc8, -1, str)` ->
sendEnvelope (SIM toolkit); `setImsStatusToModem(1, provisioned&&enabled, 0,
slot)` -> RIL 453 (0x1c5) VSS_SET_IMS_STATUS, parcel {4, type, state,
reason, slot} -> `qcril_qmi_lge_vss_set_ims_status` -> lge_vss 0x320 msg
0x0703 req {u32 type; u32 state; u32 reason; u32 slot} (500 ms).

Modem side (strings from the stock `modem.b*` segments, `.scratch/ims4/
modem-strings.txt`): 0x0703 lands in `qmi_vss_common_service.c:
qmi_vss_set_ims_status_req` -> `cmss.c: lgp_set_ims_status(type, state)`
(type LGP_IMS_STATE_TYPE_ADV_CALLING = "advanced calling" on/off). The
registration info feeds Call Manager domain selection, `cmsds.c` ("[hVoLTE]
cmsds_clear_lgims_reg_info", "IMS deregistered for voice while operating in
CSFB mode, switch to SRLTE mode", "lgims_callstatus", "send
STATUS_LTE_GET_CURRENT_IMS_STATUS to LGIMS") -- i.e. SRLTE vs 1xCSFB mode
switching and scan gating during VoLTE calls. CM knows a "3rd Part[y] IMS
Enabled" mode ("LG IMS Doesn't send IMS REG Information when comback to
In-SVC"); which EFS/NV item selects it is not identified. Relevant modem EFS
items: `/nv/item_files/ims/IMS_enable`, `/nv/item_files/modem/vap/hvoltelte`,
`/nv/item_files/modem/hvolte/*`, `/nv/item_files/modem/mmode/
{ims_reg_status_wait_timer,ssac_hvolte}`. Only ~51k strings survive in
the segments (rest compressed), so absence of a string proves nothing.

`IMSPhone.setSysInfo(type, ..)` dispatch: 0x1 setBalItem, 0x5 detachLte,
0xb setDan, 0xd setEmergency, 0x10 sendEnvelope, 0x12 setImsRegistration,
0x1b setSimTuneAway, 0x1d exitVolteE911EmergencyMode, 0x1f sendIMSCallState,
0x64 setImsRegistrationForHVoLTE, 0x66 setVoiceDomainPref, 0x67 setVoLteCall;
also 0xa 0xc 0xe 0x11 0x13 0x14 0x16 0x17 0x18 0x1a 0x20 0x21 0x23. Type 0x51
(sent by `setImsServiceRegState`) is not handled -- dead call.

Other LG IMS-related RIL requests (ids from the stock `RIL.smali`): 233
GET_EHRPD_INFO_FOR_IMS, 256 VSS_SET_UE_MODE, 277/278/279 VOLTE_E911
scan/network-type/exit, 283 SEND_E911_CALL_STATE, 292 UPDATE_IMS_STATUS_REQ,
295 HVOLTE_SET_VOLTE_CALL_STATUS, 340 VSS_LGEIMS_LTE_DETACH, 341
LTE_INFO_FOR_IMS, 346 SET_SRVCC_CALL_CONFIG, 347 IMS_CALL_STATE_NOTI_REQ, 350
SET_IMS_STATUS_FOR_DAN, 454 VSS_VOLTE_CALL_FLUSH, 462
IWLAN_SEND_IMS_PDN_STATUS.

Ims4 also reports state AP-side only: `TelephonyManager.setImsRegistrationState`,
`ITelephonyRegistry.notifyVoLteServiceStateChanged`, and
`com.android.lge.lgsvcitems.LgSvcCmd` (property-style get/set, not a modem
path).

Implication for a bridge: every modem hook is a plain QMI write to a service
that is live on the modem (0x320 msgs 0x0609/0x0703; 0x2bd NV 0x1063; stock
NAS 0x0072) -- reachable from a QMI client without LG's RIL or qcril, same
as 0x2bf. NAS 0x0072 is the one a non-LG IMS stack would normally send. What the modem does with them (domain selection / SRVCC gating is
the guess) is untested.

## Binder surface of `Ims4` vs the Robin bridge

`com.lge.ims.server.ims.ImsSystemServiceImpl extends
com.android.ims.internal.IImsService$Stub` -- the AOSP N legacy IMS API
the Robin bridge (`ether-20.0/VOLTE-BRINGUP.md` 2-3,
`ims-bridge/aidl/org/codeaurora/ims/legacy/internal/`) already talks to.
Transaction tables compared stub-by-stub (TRANSACTION_* from
baksmali of the stock `boot-framework.oat`):

- Identical to the Robin AIDL (0 differences): IImsCallSession 28,
  IImsCallSessionListener 30, IImsConfig 9, IImsEcbm 2, IImsEcbmListener,
  IImsExternalCallStateListener, IImsMultiEndpoint,
  IImsRegistrationListener 11, IImsUt 18, IImsUtListener 7,
  IImsVideoCallProvider 11, IImsVideoCallCallback 7.
- `IImsService`: LG 15 transactions, Robin 16. The LG framework is 7.0;
  7.1 inserted `addRegistrationListener` at transaction 6 and shifted the
  rest. A bridge for the V20 needs a 7.0 `IImsService.aidl` with that
  method removed (`ether-20.0/gen-legacy-aidl.py` on the deodexed stock
  framework emits it).
- LG-only `*Ex` interfaces, unused by AOSP ImsPhone, ignorable:
  IImsServiceEx (deregister, getEmergencyCallConfig,
  isEmergencyCallAvailableOverWfc), IImsCallSessionEx (push/transfer/ECT/
  merge), IImsCallSessionListenerEx, IImsRegistrationListenerEx,
  IImsUtEx (21), IImsVideoCallProviderEx, IImsVideoCallCallbackEx,
  IImsStreamMediaSession.

## Gaps for a V20 bridge

1. API -- closed. Robin bridge reusable with the one-method AIDL variant.
2. ABI -- open, the real work. `Ims4` + 32-bit 2016 Qualcomm AP SIP libs
   against an Android 17 framework; expect the same class of shims the
   Robin needed (nanopb 0.2.8, Surface sizeof) and unknown new ones.
   `com.qualcomm.qcrilhook`, `com.android.lge.lgsvcitems`, GBAService
   must exist or be stubbed.
3. Modem hook -- mapped, untested. QMI 0x2bf (media/socket bridge), 0x320
   msg 0x0609 item 0x60039 and 0x2bd NV 0x1063 (registration state) are all
   reachable without LG's RIL; the `oem_rapi` path is not. Whether SIP
   registration works with only these served, and what the modem does with
   the registration writes beyond domain selection, is untested. Open: the
   EFS item behind CM's "3rd party IMS" mode; qcril handler for RIL 292's
   siblings (295, 340, 341, 346, 347).

Working files (not in the repo): `.scratch/ims4/` (dexes, smali, QMI
dumps, stock libs, `qmi/imsmmpf.dis` full disassembly + `qmi/plt.txt`
PLT-to-symbol map, `qmi/{set_modem_info,set_lg_ims_reg_state,raw_cmd}.dis`,
`smali-telcommon/`), `.scratch/kdz/vs995/parts/system.image`.
