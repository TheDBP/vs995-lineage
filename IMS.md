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
`RtpSessionInfoInd`, `_tMMPFResponseEvent_UKnight`, and how `Ims4`/`libims.so`
tells the modem the SIP registration state -- not via qcrilhook (Ims4's
`ImsQcRilHook` only does TuneAway enable/disable); SRVCC goes through
`SrvccStateTracker`/`ISystemAPISRVCC`; `com.android.lge.lgsvcitems.LgSvcCmd`
is the remaining candidate (LG RIL OEM request).

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
3. Modem hook -- half open. QMI 0x2bf is reachable without LG's RIL and is
   only the media/socket-bridge pipe (above); the `oem_rapi` path is not
   reachable. Whether registration works with only 0x2bf served is
   untested, and the path that reports SIP registration to the modem is
   not yet identified.

Working files (not in the repo): `.scratch/ims4/` (dexes, smali, QMI
dumps, stock libs, `qmi/imsmmpf.dis` full disassembly + `qmi/plt.txt`
PLT-to-symbol map), `.scratch/kdz/vs995/parts/system.image`.
