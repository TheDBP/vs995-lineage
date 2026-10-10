# IMS / VoLTE on the V20 -- what the stock firmware does and what a bridge needs

No LineageOS build for the V20 has VoLTE. This records what the stock
Nougat firmware (VS99519A/VS9951CA, 7.0 NRD90M) actually does so the work
need not be redone. Method per item in brackets; nothing here is inferred
from documentation.

## Building the IMS stack from stock firmware

*If you are building this ROM, start here.*

**VoLTE on this device is LG's own 2016 IMS app, reworked to run on Android 17. It is proprietary,
so this repo carries the recipe and none of the ingredients.** You supply the stock firmware; the
build turns it into the shipped artifacts. Nothing derived from it is ever committed here.

`ims/ims.mk` is included unconditionally, so a tree without these artifacts does not quietly produce
a ROM lacking VoLTE -- it fails to build. Three files must exist before you start:

| staged file | produced by |
|---|---|
| `device/lge/msm8996-common/ims/Ims4-reworked.apk` | `ims/build-ims4.sh` |
| `device/lge/msm8996-common/ims/ipsecstarter` | `ims/build-ims4.sh` step 7 (copied from stock) |
| `device/lge/msm8996-common/ims/ipsecclient` | likewise |

### 1. Get the stock firmware

A VS995 KDZ, Nougat 7.0 (`VS99519A` or `VS9951CA`) -- the same images this document was reverse
engineered from. LG does not publish these; the usual community mirrors carry them. Verify you have
the **Verizon vs995** variant: `h918`/`us996` ship a different IMS build and the smali offsets this
port patches will not match.

Two steps with [kdztools](https://github.com/ehem/kdztools), which is third-party and not vendored
here: `unkdz` turns the `.kdz` into a `.dz` (e.g. `VS9951CA_01.dz`), and `undz` unpacks that into a
`parts/` directory of raw partition images. You want `parts/system.image` -- ignore the `.params`
file beside it, and ignore `modem.image` unless you are doing modem work.

**Then rename it.** `undz` calls it `system.image`; the build looks for `VS995_Stock_ROM_*.image`
(the `VOLTE_STOCK_GLOB` in `device.conf`), so a file still called `system.image` is simply not
found. Something like:

```sh
cp <kdz-extract>/parts/system.image  VS995_Stock_ROM_VS9951CA.image
```

The name after the prefix is yours; put the firmware version in it so a stale image is obvious.

### 2. Pull what the rework needs out of it

Everything comes from that one image; nothing comes off a running phone. `debugfs` reads an ext4
image without mounting it, so no root and no loop device:

```sh
I=<path>/system.image
O=<staging-dir>; mkdir -p $O/lib $O/bin

debugfs -R 'dump /priv-app/Ims4/Ims4.apk        '$O'/Ims4.apk'           $I
debugfs -R 'dump /framework/arm64/boot-ims-common.oat '$O'/boot-ims-common.oat' $I
debugfs -R 'dump /framework/arm64/boot-framework.oat  '$O'/boot-framework.oat'  $I
debugfs -R 'dump /bin/ipsecstarter '$O'/bin/ipsecstarter' $I
debugfs -R 'dump /bin/ipsecclient  '$O'/bin/ipsecclient'  $I

# The 32-bit LG SIP + QMI libs. The authoritative list is LG_LIBS at the top of
# ims/build-ims4.sh -- read it from there rather than copying it, so the two cannot drift.
for l in $(sed -n 's/^LG_LIBS="\(.*\)"/\1/p' device/lge/msm8996-common/ims/build-ims4.sh); do
  debugfs -R "dump /lib/$l.so $O/lib/$l.so" $I
done
```

`/lib` is the 32-bit tree: these libs must be the 32-bit ones. The stock image ships both ABIs and
the 64-bit namesakes in `/lib64` will link-fail later, in a way that does not obviously point back
here.

### 3. Deodex the framework, then build the app

The rework needs a **clean** framework deodex -- it copies the real `com.android.ims` parcelables
out of it, and quickened smali will not reassemble:

```sh
./forge/tools/deodex-jar.sh $O/boot-framework.oat $I $O/framework-smali
```

Then the app itself. Six positional arguments, in this order:

```sh
cd build_output/src/device/lge/msm8996-common
FORGE=<repo>/forge ./ims/build-ims4.sh \
    $O/Ims4.apk $O/boot-ims-common.oat $I $O/framework-smali $O/lib \
    ims/Ims4-reworked.apk $O/bin
```

It writes `ims/Ims4-reworked.apk` and copies `ipsecstarter`/`ipsecclient` beside it. The output is
deliberately **unsigned** -- `ims/Android.bp` imports it with `certificate: "platform"`, because
`Ims4` is `sharedUserId android.uid.phone` and must carry the platform key. Do not sign it yourself.

### 4. Build normally

```sh
PRESET=clean ./forge/bootstrap.sh
```

The staged files sit in the synced tree, which `repo sync --force-sync` prunes, so after a sync that
resets `device/lge/msm8996-common` you repeat step 3 (not steps 1-2 -- keep the staging dir).

**Known gap:** unlike the Robin, where `device.mk` stages the IMS blobs itself on first build from a
stock zip dropped in the repo root, this is a hand-run step with no guard. A fresh clone fails at
Soong with a missing-file error that does not say "you need the stock firmware". Adopting the
Robin's pattern here is the obvious fix and is not done yet.

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
switching and scan gating during VoLTE calls.

The "3rd Part[y] IMS Enabled" mode ("LG IMS Doesn't send IMS REG Information
when comback to In-SVC") is **not selected by any EFS item on this modem** --
it is dead code here. Chased into the q6zip-compressed code segment (seg 17 @
0xc4a22000 decompresses to VA 0xd0000000; `nlitsme/qualcomm-q6zip` q6unzip.py,
lookback 7, no per-page meta prefix): the branch sits in a `cmsds.c`
domain-selection function at VA 0xd0065c74 (main) / 0xd0065c84 (HYBR2) /
0xd00659e8 (HYBR3) and fires only when the Call Manager control block (`cmsds`
global at VA 0xd0d1f53e) byte `+0x7d` == 2, additionally gated by the event's
srv_domain (`msg+0x25` == 2, i.e. PS) and `cmsds+0x98` == 1. That `+0x7d`
selector byte is **read-only across the entire image** -- no store reaches it
in the q6-compressed code, none in the uncompressed segments, and no data
pointer to it exists in any segment; it lies in demand-zero BSS (offset 0x4f5bb
into the dlpager region, past the 0x42000 the delta segment @0xc51e9000
initializes), so it defaults to 0. Nothing arms it. The CM note describing an
EFS selector refers to a different/newer modem; LG left the hook dangling on
vs995.

Relevant modem EFS items that *are* wired (all hVoLTE/SRLTE tuning, none the
3rd-party selector): `/nv/item_files/ims/IMS_enable`,
`/nv/item_files/modem/vap/hvoltelte`, `/nv/item_files/modem/hvolte/*`,
`/nv/item_files/modem/mmode/{ims_reg_status_wait_timer,ssac_hvolte}`. Only
~51k strings survive uncompressed in the segments (rest in q6zip); decompress
seg 17 to read the rest (see `docs/debugging-volte.md`).

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
2. ABI -- open, but smaller than feared for voice. Measured on 24.0 build 20
   (`abi-gap.sh`, see "Inert load" below): the SIP core `libims.so` needs only
   2 shim symbols + 1 stock lib + 1 over-link stub; all the hard ABI work
   (Surface-ctor sizeof, camera/GraphicBufferMapper/AudioSystem signature
   drift) is in the media lib `libimsmmpf.so` and is video-call code. Still
   expect the Robin-class runtime shims (nanopb 0.2.8) and unknowns at
   onCreate. `com.qualcomm.qcrilhook`, `com.android.lge.lgsvcitems`,
   GBAService must exist or be stubbed.
3. Modem hook -- mapped, untested. QMI 0x2bf (media/socket bridge), 0x320
   msg 0x0609 item 0x60039 and 0x2bd NV 0x1063 (registration state) are all
   reachable without LG's RIL; the `oem_rapi` path is not. Whether SIP
   registration works with only these served, and what the modem does with
   the registration writes beyond domain selection, is untested. CM's "3rd
   party IMS" mode is dead code here (cmsds+0x7d, never set -- see above), so
   a bridge cannot lean on it to stop the modem waiting for LG IMS reg; the
   modem must be fed reg state the normal way. Open: qcril handler for RIL
   292's siblings (295, 340, 341, 346, 347).

## Inert load on 24.0 (ABI gap), build 20

`Ims4` (`com.lge.ims`, versionName 4.0.20150602, platformBuildVersion 7.0):
`sharedUserId="android.uid.phone"`, `persistent=true`, own process
`com.lge.ims`, **targetSdk 24**, native libs **not** in the APK (they live in
`/system/lib`). The SIP stack libs are **32-bit ARM only** -- and 24.0 is
`zygote64_32` with a full `/system/lib` 32-bit userspace (`ro.product.cpu.
abilist` has `armeabi-v7a`), so the 2016 stack can run bit-for-bit. The whole
stock LG 32-bit `/system/lib` is in `.scratch/ims4/stock/lib/` (every
DT_NEEDED, incl. `libsurfaceflinger`, `libext2_uuid`, `libOmx*`).

Symbol gap vs the live 24.0 libs (`abi-gap.sh <lib> --keep`, siblings
pre-seeded into `plat/`):

- `libims.so` (SIP core): 308 imports, **7 unresolved**. 5 are `uuid_*`
  (`uuid_generate{,_random,_time}`, `uuid_is_null`, `uuid_unparse`) from the
  absent `libext2_uuid.so` -- pure libc, the stock 32-bit copy drops in. 2 are
  libutils drops since N: `android::String8::getPathLeaf() const`,
  `strndup16to8` -- a few-line shim. `libsurfaceflinger.so` is DT_NEEDED but
  contributes **0 symbols** (over-link) -> empty stub satisfies it. The
  framework-coupled libs (libbinder/libgui/libandroid_runtime/libutils)
  resolve cleanly otherwise -- a narrow, ABI-stable slice.
- `libimsmmpf.so` (media): 240 imports, **7 unresolved**, and this is where the
  real work is. `qmi_idl_message_decode` (absent `libqmi_encdec.so`, vendor,
  safe to supply). The other 6 are the predicted ABI landmines, all video:
  `android::Surface::Surface(sp<IGraphicBufferProducer>&, bool)` (the grown-
  type ctor -- Surface was 3560->8168 B on the Robin; patch the baked sizeof
  before shimming), `Camera::connectLegacy`/`setPreviewTarget`/
  `CameraBase::getCameraInfo` (libcamera_client rewrite), `GraphicBufferMapper
  ::unlock(native_handle const*)` and `AudioSystem::setParameters(int, String8
  const&)` (signature drift). `libsurfaceflinger`/`libicuuc` absent but
  over-link/APEX.

Consequence: voice needs `libims` + `libimsmmpf` to *load* (libims DT_NEEDs
mmpf), not to do video. Shim the 6 mmpf symbols enough to link; only
`AudioSystem::setParameters` plausibly touches the voice audio path and must be
correct. Video correctness is deferrable.

First real wall is **not symbols but the linker namespace**: libims pulls
libgui/libbinder/libandroid_runtime/libsurfaceflinger, none of which are in
`/system/etc/public.libraries.txt`, so an app classloader namespace cannot
dlopen it. LG's stock `ld.config.txt` grants the `com.lge.ims` process access;
AOSP 24.0's does not. Options: a namespace/`ld.config.txt` entry for the libs,
or run the stack in a process that already has the system namespace (the Robin
bridge sidestepped this by living in the RIL/telephony context).

### Load test -- both libs LOAD on 24.0 build 20 (2026-10-04)

Confirmed empirically with a hand-built 32-bit ARM PIE dlopen harness
(`.scratch/ims4/dlopen-harness/`, compiled with the tree's clang against the
device's pulled libc/libdl) run from `adb shell` (shell UID = default
namespace, which can reach /system/lib + the staged dir, so it sidesteps the
app-namespace wall and isolates the ABI question). **`dlopen("libims.so")` and
`dlopen("libimsmmpf.so")` both succeed**, and since dlopen runs the init-array,
the static constructors execute without faulting too. The recipe:

- **Real shim** `libimscompat.so` (authored, correct reimpl): `String8::
  getPathLeaf()` (calls live libutils String8 ctor) + `strndup16to8` (self-
  contained UTF16->UTF8). ~40 lines, freestanding (`-nostdlibinc`), linked
  against the device's libutils+libc. Loaded via `LD_PRELOAD` (on 32-bit bionic
  `RTLD_GLOBAL`=0x2, `RTLD_NOW`=0; the global-group route was unreliable,
  LD_PRELOAD put it in the global group deterministically).
- **Load-only stubs** (authored, NOT functional): `libimsvideostub.so` =
  the 6 mmpf symbols as `__asm__`-named stubs returning 0 (Camera x3, Surface
  ctor, GraphicBufferMapper::unlock, AudioSystem::setParameters);
  `libOmxCore.so` = OMX_Init/Deinit/GetHandle/FreeHandle (the only OMX API
  libimsmmpf calls directly); empty-`.so` stubs for libsurfaceflinger,
  libOmxVenc, libOmxVdec, libstagefrighthw, libc2dcolorconvert (video/codec HW,
  co-loading stock copies fails on libbinder vtable thunks e.g.
  `MemoryHeapBase` -- all video, irrelevant to voice).
- **Real stock libs supplied** (no framework ABI ties, drop in): libext2_uuid,
  and the vendor QMI stack libimswms transitively needs -- libqmi, libqmi_cci,
  libqmi_common_so, libqmi_encdec, libqmi_client_qmux, libqmiservices, libidl,
  libsmemlog, libmdmdetect, libdsutils, libvss_ims_qcci.
- **APEX libs** libnativehelper (com.android.art) + libicuuc (com.android.i18n)
  staged from the device because the shell default namespace lacks the apex
  links the real app namespace has; not needed in a proper app build.
- Everything else (libbinder/libgui/libandroid_runtime/libmedia/libcamera_
  client/libutils/...) resolves to **live 24.0** /system/lib -- not shadowed.

So the dlopen/constructor layer is **cleared** for voice. What remains, in
order: (1) make `AudioSystem::setParameters` real (only voice-audio symbol
stubbed); the Surface ctor stays a never-called stub. (2) package this as an app
namespace (ld.config.txt / sepolicy) so `com.lge.ims` loads it, or host it in
the telephony process. (3) onCreate/runtime -- untested; the service's
`ImsSystemServiceImpl` (IImsService 7.0) must come up and the Robin-style
bridge wire it to AOSP ImsPhone. (4) feed modem reg state (QMI routes above).

Artefacts: `.scratch/ims4/dlopen-harness/` (harness `h`, `shim.cpp`/
`libimscompat.so`, `videostub.c`, `omxcore.c`, `dev-lib/` pulled device libs),
`.scratch/ims4/stage/` (the full working lib set), `abigap-ims/`, `abigap-mmpf/`.

Working files (not in the repo): `.scratch/ims4/` (dexes, smali, QMI
dumps, stock libs, `qmi/imsmmpf.dis` full disassembly + `qmi/plt.txt`
PLT-to-symbol map, `qmi/{set_modem_info,set_lg_ims_reg_state,raw_cmd}.dis`,
`smali-telcommon/`, `modem.elf` reassembled firmware, `q6.bin` decompressed
q6zip image @VA 0xd0000000 + `q6.dis`, `modem-uncomp.dis`, `modem-map.py`/
`msgconst.py`/`strref.py` xref helpers), `.scratch/kdz/vs995/parts/
system.image`.

## Build plan: the full voice-IMS stack (adapted from the Robin bridge)

The Robin (`ether-20.0`, QTI IMS on A13) proves the architecture; this is the
LG/A17 adaptation. Data flow (works on the Robin, HD VoLTE both ways):

```
A17 telephony (ImsPhone, ImsResolver)
  -> android.telephony.ims.*                              (modern ImsService API)
  -> ImsServiceControllerCompat + MmTelFeatureCompatAdapter  (AOSP's own pre-P compat layer)
  -> android.telephony.ims.compat.*
  -> ImsBridge (our android_app)                          <- the bridge
  -> com.android.ims.internal.IImsService (legacy 7.0 Binder, renamed)
  -> Ims4 (LG app, registers ServiceManager "ims")
  -> libims/libimsmmpf (LG SIP stack) -> LG qcril QMI -> modem
```

Verified on this A17 tree (build 20):
- **Compat layer present** (the #1 risk, cleared): `frameworks/base/telephony/
  java/android/telephony/ims/compat/{ImsService,feature/MMTelFeature,...}.java`
  (base classes the bridge extends) + `frameworks/opt/telephony/.../ims/
  {ImsServiceControllerCompat,MmTelFeatureCompatAdapter}.java` (framework side).
  Bridge binds via `ImsService.SERVICE_INTERFACE` = action
  `android.telephony.ims.compat.ImsService`.
- **Ims4 publishes the same way as Robin's QTI app**: `ImsSystemServiceImpl.
  smali:269-273` does `ServiceManager.addService("ims", binder)` where the
  binder extends `com.android.ims.internal.IImsService$Stub`. Bridge uses
  `ServiceManager.waitForService("ims")` + `IImsService.Stub.asInterface`.

Where LG is harder than the Robin's QTI (QTI's ims.apk was self-contained; LG
split code into framework jars):
- Ims4 references `com.android.ims.internal.*` (ImsService/parcelables, removed
  since P) **and** `com.lge.ims.common.*` (ImsLog, MessageExecutor, ...) which
  live in LG's **boot framework jar `boot-ims-common`** (have `.oat` +
  carved `.0.dex` in `.scratch/ims4/`), not in the APK. So the port needs an
  LG-framework-jar port, not just an app rename.
- LG's SIP stack is `libims`/`libimsmmpf` loaded by the app (no QTI
  imsqmidaemon/imsdatadaemon/ims_rtp_daemon). The native load is already
  solved (see "Inert load"): one `libimscompat.so` + real stock QMI/uuid blobs.

### Build components (each a patch/module; flash together)

1. **Native libs + load shims.** Install LG `libims/libimsmmpf/libimswms` + the
   real stock deps (libext2_uuid, libqmi*, libvss_ims_qcci, libidl, libsmemlog,
   libmdmdetect, libdsutils) via proprietary-files.txt -> vendor tree ->
   PRODUCT_PACKAGES. Build one `libimscompat.so` (String8::getPathLeaf +
   strndup16to8 real; the 6 mmpf video syms + OMX_Init/Deinit/Get/FreeHandle as
   load-only stubs). Wire via `overlay/blob-fixups`: libims/libimsmmpf
   `add-needed libimscompat.so` + `remove-needed` the dead video DT_NEEDED
   (libsurfaceflinger, libOmx*, libstagefrighthw, libc2dcolorconvert). Make
   `AudioSystem::setParameters` real before audio (only on-path stub). Robin
   used `TARGET_LD_SHIM_LIBS` for the inject; blob-fixups add-needed is the
   forge's equivalent -- verify it beats the namespace, see item 2.
2. **Namespace** (the open problem the Robin dodged via /vendor app). libims
   pulls libgui/libbinder/libandroid_runtime -- not in any app classloader
   namespace's exposed set, and the extended-public-libraries file requires
   `lib*.<company>.so` names so it can't expose them. Candidates, in order of
   cleanliness to try: (a) run the stack where the default/system namespace
   applies; (b) add the needed system libs to the base
   `/system/etc/public.libraries.txt` (no name constraint there) -- global but
   works; (c) lower Ims4 targetSdk 24->23 to hit the bionic greylist for old
   apps (verify the greylist still covers libgui/libbinder on A17). Settle
   empirically post-flash.
3. **Port `boot-ims-common`** (LG framework jar): oat-to-smali the carved dex,
   rename `com.android.ims.*` -> a legacy package (e.g. `com.lge.ims.legacy`),
   ship as a system jar on the boot/system classpath (or fold into the app).
4. **Rebuild Ims4**: deodex, rename `com.android.ims.*` refs to match item 3,
   keep `com.lge.ims.*` and the broadcast action strings, re-sign with the
   platform key (sharedUserId `android.uid.phone` must match the framework
   signer -- the ROM signing keys dir). Install as priv-app.
5. **ImsBridge app** (`android_app`, platform cert, privileged,
   sharedUserId android.uid.phone): manifest `<service>` with intent-filter
   `android.telephony.ims.compat.ImsService` + `MMTEL_FEATURE` meta +
   BIND_IMS_SERVICE; extends `android.telephony.ims.compat.ImsService`,
   `onCreateMMTelImsFeature` -> `LegacyMMTelFeature` that `waitForService("ims")`
   then `setFeatureState(READY)` and `open(slot, SERVICE_CLASS_MMTEL, ...)`.
   AIDL under `com.android.ims.internal.legacy` regenerated by
   `ether-20.0/gen-legacy-aidl.py` **against LG's deodexed Ims4 smali** (LG's
   transaction order, not the Robin's). LG `IImsService` is the 7.0 shape (15
   txns, no `addRegistrationListener`) -- see "Binder surface" above.
6. **Point telephony at the bridge**: overlay `config_ims_mmtel_package` =
   bridge package; add `android.hardware.telephony.ims.prebuilt.xml` (without
   the feature PhoneGlobals never builds an ImsResolver).
7. **sepolicy** (A17 strict): domains for the IMS app process (`com.lge.ims`,
   phone uid) + the libs' socket/QMI access; expect to author, not delta.
8. **Behavioral**: `config_device_volte_available` under the **SIM's** MCC/MNC
   qualifier (not the serving network's); the IMS APN for the carrier; the
   Robin's `ro.telephony.block_binder_thread_on_incoming_calls=false`
   equivalent; CarrierConfig IMS flags.

Robin reference patches (ether-20.0 VOLTE-BRINGUP.md): device 0018-0029,
hardware/ril 0001, vendor/apn 0001. Robin shim sources: `libshims/
vtsurface_shim.cpp`, `nanopb-0.2.8/`. Re-run `abi-gap.sh` per blob on A17 (the
nanopb delta and Surface sizeof will differ or not apply -- LG's stack differs
from QTI's).

## Flash A status (2026-10-05): com.lge.ims SIP-REGISTERS on T-Mobile (200 OK, IPsec up)

Verified on device (pushed artifacts, then banked as patches 0029-0031):
`com.lge.ims` stable (no native/Java crash through a 90 s soak), native engine
up (SystemInterface/PlatformInterface traffic, DCNAgent rat=LTE, PhoneStateAgent
IN_SERVICE), `service check ims` -> found (`com.lge.imslegacy.internal.IImsService`).

Fixes it took, in order hit:
- **Parcel ABI**: libims stack-allocates `android::Parcel` at the 2016 size (52 B);
  A17's ctor smashes the frame (`__stack_chk_fail` in `GetImsFeatures`). Fixed by
  symbol interposition in `libimscompat` (first DT_NEEDED): `{MAGIC, real*}`
  wrapper + heap real Parcel, every imported Parcel method forwards;
  `BBinder::transact/onTransact` unwrap. BBinder itself is still 16 B on 32-bit
  and the IBinder/BBinder vtable order is unchanged 7.0->17 -- no shim needed.
- **`dlsym(RTLD_NEXT)` returns NULL in an app namespace** (all libs RTLD_LOCAL);
  resolve real libbinder symbols from `dlopen("libbinder.so")`. A null-guarded
  resolver turns this into a pc=0 SIGSEGV one frame below the real caller
  (debuggerd frame N>0 pc = return addr - 4, so "+42" names the *call*).
- **Collision rename**: bundled libs whose name exists in /system/lib (libssl,
  libcrypto, ...) are shadowed by the system copy; rename to `*_lgeims.so` and
  rewrite DT_NEEDED (`build-ims4.sh`).
- **`com.lge.server.ims` feature**: `SystemServiceManager` only runs
  `ImsSystemServiceImpl.start()` (the `addService("ims")`) when
  `hasSystemFeature("com.lge.server.ims")`; stock declares it in
  `/system/etc/permissions/com.lge.server.ims.xml`. Shipped as
  `ims/lge-ims-features.xml`. Other gates it then passes: `ImsGlobal.
  isVolteEnabled` ("ims-frw-config", satisfied by `persist.dbg.volte_avail_ovr=1`
  during bringup), operator list VZW/ATT/TMO-US/... or `getEnablerType()=="global"`.
- Verify stubs (`gen-verify-stubs.py`) for LG framework classes incl.
  `com.android.lge.lgsvcitems.LgSvcCmd`.

- **`lgeims_mmpf`** (LG media engine: RTP, AMR/EVS, vocoder; `AudioAdaptor` needs
  it, so VOICE needs it) is now hosted in-process: `MmpfHost.start()` (extra-smali,
  hooked into `JNIIms.<clinit>` after `loadLibrary`) -> JNI in libimscompat ->
  `android::MMPFService::instantiate()` found in libimsmmpf.so via
  `dl_iterate_phdr` + GNU-hash walk (a public system lib cannot `dlopen` an
  apk-bundled lib: dlopen resolves in the CALLER's namespace). Stock publishes it
  from the persistent `com.lge.imsvt` process (libimsvtjni). `service list` shows
  `lgeims_mmpf: [com.lge.mmpf.MMPFService]`, libims's 5 s poll stops, MMPF engine
  init runs (`MMPF_VER_2.0.0_160519`).
- **libimswms NULL-format crash** (hit as soon as mmpf unblocked the SMS-over-IP app
  init): every `ALOGE` in libimswms is `__android_log_print(6, tag, NULL, "fmt", ...)`
  -- real format as the first vararg -- so any WMS error path segfaults in vsnprintf
  (stock liblog has no NULL check either; stock simply never hit the paths).
  Fixed in build-ims4.sh: `rename-import.py` rewrites libimswms's import to
  `__lgims_log_nullfmt` (same length) + `add-needed libimscompat.so`; the shim
  pulls the format from the varargs when fmt is NULL.

- **APN block = verify-stub enum trap** (first thing after the engine came up:
  `DCApn` never requested the IMS PDN). `LGPhoneConstants$LteStateInfo` /
  `LGDataPhoneConstants$LteStateInfo` were plain verify stubs; `Enum.valueOf()`
  on them throws, the catch path reports "LTE emergency only" and the APN gate
  stays shut. Faithful enums (extra-smali, all stock constants) fix it. Rule:
  anything whose *values* are read (enums, constants) needs a faithful copy,
  verify stubs only satisfy the linker.
- **`TelephonyManager.getPcscfAddress[ForSubscriber]` gone** (NoSuchMethodError on
  the ConnectivityThread the moment the IMS PDN came up -- hidden behind the APN
  gate until then). `method-redirects.txt` rule `|static` -> `com.lge.ims.compat.
  TelephonyCompat` (`ims/compat-java`, compiled against the `system` stub jar, merged
  into the dex) reads `LinkProperties.getPcscfServers()` off the NET_CAPABILITY_IMS
  network. Verified: 3 P-CSCF v6 addresses -> `AoSPCSCF AddPCSCF`, `AoSConnector
  STATE_IDLE -> STATE_READY`, `Connection_Activated`.
- **ISIM state: `com.lge.ims.phone` (IIMSPhone) is absent** -> `SIMStateAgent.
  getIsimStateFromPhone()` "NOT_PRESENT" -> "ISIM is disabled on INIT", IMPI
  `anonymous@anonymous.invalid`, AoS blocks with `SUBSCRIBERINCOMPLETED` (the last
  of AOSINCOMPLETED/OUTOFSERVICE/SERVICECONNECTING/SUBSCRIBERINCOMPLETED). Stock
  item 0x19 is `LGImsIsimHandler.getIsimState()` (UiccController APPTYPE_ISIM ->
  LOADED/NOT_READY/NOT_PRESENT, plus sticky `com.lge.ims.ISIM_STATE_CHANGED`
  broadcast, extras `isimState`/`subscription`/`phone`). Redirected to
  `TelephonyCompat.getIsimStateFromPhone`: LOADED <=> IMPI readable; NOT_READY
  re-checks on the main looper and sends that same broadcast in-process. Plus
  `|static` rules for LG's `getIsim*ForSubscriber` and the pre-O
  `getIsimChallengeResponse` -> `getIccAuthentication(APPTYPE_ISIM, AUTHTYPE_EAP_AKA)`
  (same call Ims4's own MTK branch makes). The SIM does carry an ISIM app
  (`UiccCardApplication ... APPTYPE_ISIM,APPSTATE_READY`).
- **Operator profile**: `pref_operator` resolves VZW from the stub `Build$CA_TARGET`
  while the test SIM is Mint (T-Mobile MVNO); the VZW profile REGISTERed against
  `msg.pc.t-mobile.com` and got `421 Extension Required, Require: sec-agree`
  (VZW profile sends no Security-Client). Hand-set for bringup:
  `persist.lg.ims.pref_operator=TMO`, `persist.lg.ims.pref_country=US`,
  `net.ims.debug=1`. TMO-profile LGIMS logs are masked unless
  `persist.service.privacy.enable=1`. Both still to be build-produced (CA_TARGET
  from the SIM / `ro.build.target_operator`).
- **Restart only by reboot**: `kill`/`force-stop` of com.lge.ims races VoLTEService
  against DCGov (NPE) and gives false negatives. `deploy-lte.sh` swaps the apk
  across two reboots (see `rom-forge/tools/push-system-app.sh`).
- `TelephonyManager.setCellInfoListRate(int)` is gone -> `|drop` rule.
- **IIMSPhone (`com.lge.ims.phone`) stand-in**: `IIMSPhone$Stub.asInterface` is
  redirected to `com.lge.ims.compat.ImsPhoneCompat` (in-process object, never a
  null phone). Item table and sources are in its javadoc; the one that matters for
  registration is **item 8 = VoPS**: `BootupGov.notifyVOPSState` ->
  `SystemInterface.notifyEvent(0x800 IMS_VOICE_OVER_PS_STATE)`, and libims
  `AoSServiceAvailableCellular::CheckNetworkType` sets BOTH `NONETWORK` (0x80000)
  and `VOPS` (0x40000) when RAT==LTE and VoPS==false -- "NONETWORK" there does
  not mean no network. Answered from `NetworkRegistrationInfo(PS, WWAN).
  getDataSpecificInfo().getVopsSupportInfo()`.
- **VoPS timing + second enum trap**: BootupGov polls item 8 only twice (1 s
  apart) right after the IMS PDN; the framework says NOT_SUPPORTED then and flips
  to SUPPORTED ~25-30 s after boot. Stock gets the late update from LG RIL's
  `lge.intent.action.LTE_NETWORK_SUPPORTED_INFO` broadcast (int extras
  `VoPS_Support`/`EPDN_Support`), which `DCNetWatcher.handleVoLTEEPSNetworkSupport`
  compares as `LGDataPhoneConstants$VolteAndEPDNSupport.fromInt(v) == VOLTE_SUPPORT`
  -- our verify stub's `fromInt` returned a fresh object, so it could never match.
  Fixes: faithful enum (NONE 0, VOLTE_NOT_SUPPORT 1, VOLTE_SUPPORT 2,
  EPDN_NOT_SUPPORT 3, EPDN_SUPPORT 4) + `ImsPhoneCompat.startVopsMonitor()`
  (started from `setListener`) sends that broadcast sticky (DCNetWatcher registers
  its filter after the bind) and on every `TelephonyCallback.ServiceStateListener`
  change. Keep a strong reference to the TelephonyCallback: the registry stub
  holds it weakly and a bare `new` listener is GC'd and goes silent.
- **qcrild VoPS/LTE_CA flicker**: `libril-qc-hal-qmi` reports
  `lteVopsInfo.isVopsSupported=true` only in DATA_REGISTRATION_STATE responses
  with rat=14 (LTE); every rat=19 (LTE_CA) response says false, and the RAT flips
  14<->19 around data activity (right as REGISTER goes out), so framework
  VopsSupportInfo reads 2/3/2/3 and Ims4 aborted each REGISTER ~0.4 s after
  `SendREGISTER`. VoPS is per tracking area and cannot change without a TAU, so
  `ImsPhoneCompat.vops()` latches true while PS stays registered on LTE (reset on
  leaving LTE / deregistration). A libril-side fix would be the proper place.

Open, next:
- **REGISTER / IPsec -- DONE (hand-pushed helpers; build-produced since patch
  0033)**. The TMO profile REGISTERs with `Security-Client: ipsec-3gpp;alg=
  hmac-md5-96/hmac-sha-1-96;prot=esp;mod=trans;ealg=null`, the P-CSCF answers
  401 (`AKAv1-MD5`, `Security-Server ... port-c=65528;port-s=65529`), AoSIPSecHelper
  builds 4 SAs + 6 SPs. libims does NOT program xfrm: `ipsec_inf.cpp` sends
  text `SPADD/SAADD ... src dst secproto esp spi ... auth hmac-sha1 <key>` to
  the proxy. Chain, all **ABSTRACT** AF_UNIX dgram sockets (`@/tmp/ims/socket/
  ipsec_user` libims, `@.../ipsec_controller` `ipsecstarter`, `@.../ipsec_proxy`
  `ipsecclient`; no /tmp dir exists or is needed -- ECONNREFUSED instead of
  ENOENT with no path was the tell): libims binds ipsec_user -> UP to the starter
  -> `ctl.start ipsecclient` -> client binds the proxy, acks to ipsec_user, then
  installs SAs via netlink xfrm. **ipsecclient exits immediately if ipsec_user is
  not bound**, so it is start-on-demand only (stock rc: `disabled`); never run it
  by hand before Ims4 is up. Without the helpers: `IsActiveIPSecClient failed`,
  `Pipe_Write send failed (111)`, `IPSEC ERROR --- nConf`, `add policy is
  failed`, registration torn down + IMS PDN dropped, retried forever. With them:
  authenticated REGISTER -> `200 OK` (`expires=3600`, P-Associated-URI x4,
  Service-Route :65529), `STATE_REGISTERED`, `REASON_REGISTRATION_SUCCESS/
  [REG_SUCCESS][VOLTE]`, `VoLTE_Indicator reg=1`, reg-event NOTIFY `active`.
  Shipped as: `ims/Android.bp` `cc_prebuilt_binary` ipsecstarter/ipsecclient
  (stock 32-bit, libc/libcutils/libc++ only, staged by build-ims4.sh step 7, not
  committed), `ims/lge-ims-ipsec.rc` (stock service lines: starter uid system
  net_admin/net_raw, client root disabled), `sepolicy/private/lge_ims_ipsec.te`
  + `file_contexts` + `property_contexts` (`ctl.start$ipsecclient` ->
  `ctl_ipsec_prop`, `system_internal_prop` because a coredomain may only set
  system_property_type). `ipsecd` is the VoWiFi strongSwan daemon, unrelated.
  Framework still shows no IMS registration (expected: Flash B).
  Note `cc_prebuilt_binary` shared_libs must list `liblog` too: check_elf_file
  resolves `__android_log_print` only against the listed libs (stock DT_NEEDED
  reached it via libcutils).
  **Verified build-produced 2026-10-05 20:19** (full ROM build, enforcing, stale
  hand-pushed helpers deleted first): `ipsecstarter` runs as an init service
  (uid system, `u:r:ipsecstarter:s0`), `ipsecclient` is `ctl.start`ed on demand
  and installs the ESP SAs (`SAADD ... secproto esp`, "command succeeded"),
  LGIMS logs `IPSecClient is active`, and REGISTER gets `SIP/2.0 200 OK` ->
  `MSG_REG_EVENT_REGISTERED` about one minute after boot.
- **MT VoLTE call reaches the phone over SIP** (2026-10-05 17:03, 31 min after
  REGISTER): network INVITE -> Ims4 `100 Trying`, `180 Ringing` (reliable, PRACK
  received), `UCSession SendIncomingSession` to its 4 listeners; nothing reaches
  Telecom (no InCallUI), so the network CANCELs after ~18 s (`Reason: SIP;cause=
  480;text="CC_NOT_REACHABLE"`) -> `487`. Confirms the stack is live end to end;
  surfacing the call is Flash B. Media-side error to track once calls are
  bridged: `AudioAdaptor::GetIPAddrOfCP() Error[21]` / `MediaResourceMngr::
  UpdateModemIPv6() failed for APNName[ims]` at INVITE time -- the RTP path
  wants the modem-side IMS PDN address.
- **IIMSPhone modem side**: `setSysInfo` / `setImsStatusToModem(IIII)` are logged
  and dropped. `setImsStatusToModem` is how the modem learns IMS registered (CSFB
  vs VoLTE routing) -- Flash B (ImsBridge) scope.
- **SMS over IMS needs `imswmsproxy`** (not shipped yet). libimswms (`SoIClient::
  ConnectSC` -> `AndroidWMS::Init`) talks AF_UNIX/SOCK_DGRAM over ABSTRACT sockets:
  binds `@/tmp/ims/wms/wms_user_static` (or `wms_user`), sends to
  `@/tmp/ims/wms/wms_proxy` -> ECONNREFUSED today, so SoI init fails (non-fatal
  after the fix above; SMS stays on CS). The listener is stock
  `/system/bin/imswmsproxy` (14 KB, 64-bit; init.elsa_product.rc: `class main,
  user system, group radio system net_admin net_raw`; sepolicy domain
  `imswmsproxy`, `imswmsproxy_exec`). It registers as the QMI WMS *transport
  layer* (`qmi_wms_transport_init/reg_mo_sms_cb/rpt_ind/nw_reg_status_update/
  cap_update` from `libqmi_wms_client_helper.so`, stock /system/vendor/lib64,
  22 KB; that lib needs libqmiservices, libqmi_cci, libcutils, `wms_get_service_
  object_internal_v01`) so the modem hands MO SMS to the IMS stack and takes MT
  SMS back. Closure is small and all-C: ship both as vendor prebuilts
  (`vendor/bin` + `vendor/lib64`, our vendor already has the Oreo libqmi*), an
  init rc service, and a sepolicy domain (abstract unix dgram socket to radio
  app + qmux). Stock dump: `.scratch/kdz/vs995/parts/system.image`
  (`debugfs -R 'dump /bin/imswmsproxy ...'`, `/vendor/lib64/libqmi_wms_client_
  helper.so`); stock rc in boot.image ramdisk (`undz.py -s 27`).
- QMI `svc_id 703` (0x2bf, LG `lge_ims`) TXN send errors / `qmi_client_
  register_error_cb` -- modem side of the hook (see above section); check
  `/dev/smd*`/qmuxd access under radio once sepolicy is tightened.
- sepolicy: radio is permissive on the bringup build; denials seen so far:
  `net.ims.operator` set (system_prop), find `lgeims_mmpf`/`com.lge.ims.phone`
  (default_android_service -> needs service_contexts entries), raw socket
  create/ioctl 0xc304 (QMI).

## Flash B (ImsBridge): framework <-> Ims4, design and what to verify

> Design as written before hardware. For what actually happened see "Flash B on hardware" below;
> two things here needed correcting on the device -- the bitmap probe has to run when registration
> CONNECTS rather than at `startSession`, and `isConnected(NORMAL, VOICE)` cannot be trusted as the
> voice indicator. The `dumpsys telephony.registry` check in "Verify on hardware" is also not the
> one to use: read `isVolteEnabled=` in the `ImsPhoneCallTracker` log instead, which is
> `isVoiceOverCellularImsEnabled()` itself.

Goal: the A17 telephony stack sees Ims4's registration and routes MO/MT voice
calls through it. Shipped as device patch 0036 (`ims/bridge/`, `ims/ims.mk`,
`build-ims4.sh` steps 2.7 + 3.5, Telephony overlay `config_ims_mmtel_package`).

- **Entry point**: A17 `ImsResolver` still binds compat services (`android.
  telephony.ims.compat.ImsService` -> `ImsServiceControllerCompat`). ImsBridge
  (`org.lineageos.ims.bridge`, platform cert, privileged, `sharedUserId
  android.uid.phone` so seapp_contexts puts it in `radio`) implements
  `MMTelFeature` (compat) over `ServiceManager.waitForService("ims")` ->
  `com.lge.imslegacy.internal.IImsService` (LG 7.0: 15 txns, single-slot
  `setRegistrationListener`, no `addRegistrationListener`). Adapted from the
  Robin bridge (`ether-20.0/ims-bridge`), package renamed; `aidl/com/lge/
  imslegacy/**` is generated by `build-ims4.sh` step 2.7 from the deodexed stock
  framework and committed (the ROM build compiles it).
- **Registration listener is single-slot** on 7.0: the bridge hands Ims4 ONE
  `RegistrationListenerAdapter` at `open()` and fans out to every listener the
  framework adds later; it caches reg state / radio tech / feature bitmaps /
  URIs and replays them to late joiners.
- **Feature bitmap never arrives on a late open**: `ImsCallApp` replays only
  connected/disconnected to a new listener; `registrationFeatureCapabilityChanged
  (1, int[6], int[6])` fires only from `UCStateTracker` on a UC reg-state
  CHANGE. After `open()` returns the bridge probes `isConnected(serviceId, 1,
  2)` (voice) and `(…, 1, 4)` (video) and synthesizes the 6-slot bitmap
  (slot i = i if enabled else -1) when none was cached.
- **Parcelables**: the shipped Ims4 compiled against empty stubs
  (`ImsCallProfile` 1 field vs 51 in LG's framework). The real `com/android/ims/
  *` classes live in `boot-framework.oat` **classes2.dex** -- baksmali `x` alone
  deodexes only the first dex entry (rom-forge `deodex-jar.sh` now walks every
  entry; a tree with `invoke-virtual-quick` is NOT a usable source). Step 3.5
  copies the clean smali over the stubs. LG's `ImsCallProfile` wire format adds
  `mRestrictCause` after `mMediaProfile`; the bridge's Java copy reads it.
- **The compat path needs a framework patch on A17** (`overlay/patches/frameworks/opt/telephony/
  0001`): `ImsServiceControllerCompat.createMMTelCompat()` builds the MmTel/registration/config
  compat adapters and calls `setDefaultExecutor()` on none of them, while every `*ImplBase`
  dispatches its binder calls through `CompletableFuture.runAsync(.., mExecutor)`. A null executor
  throws in `screenExecutor()` instead of running on the caller's thread, so the first framework call
  (`ImsProvisioningController` -> `ImsConfig#addConfigCallback`) is fatal and `com.android.phone`
  restart-loops as soon as the bridge binds. Verified on hardware 2026-10-05 by pushing the bridge
  onto the A3 build. The modern path is unaffected (`ImsService#getConfig/getRegistration/
  createMmTelFeature` each set it) -- the compat path has been deprecated since P and nothing in
  tree exercises it. Give the adapters a DIRECT executor, not the controller's single-threaded
  `mExecutor`: `MmTelFeature`'s stub routes every inbound call through
  `executeMethodAsync(..).join()`, and `changeEnabledCapabilities` /
  `queryCapabilityConfiguration` block on a 2 s `CountDownLatch` per capability, so one shared
  thread would queue call setup (`createCallSession`, `getPendingCallSession` for an incoming
  call) behind several of those -- long enough for the network to cancel the INVITE, which looks
  exactly like the pre-bridge failure.
- **MO dialling does not consult the modem's VoPS flag**: `GsmCdmaPhone.useImsForCall()` ->
  `ImsPhone.isVoiceOverCellularImsEnabled()` -> `ImsPhoneCallTracker
  .isImsCapabilityInCacheAvailable(CAPABILITY_TYPE_VOICE, REGISTRATION_TECH_LTE)`, i.e. the
  capability cache fed by the registration callbacks -- the bitmap the bridge synthesizes.
  `vops=false` from the RIL does not block an IMS call here; a missing bitmap does.
- **A17 build facts**: telecom is a mainline module -- `platform_apis: true` is
  enough for `android.telecom.*`; AIDL `include_dirs` needs `frameworks/base/
  telecomm/framework/aidl-export` for `VideoProfile`; `android/view/Surface.aidl`
  no longer exists in core/java, the bridge keeps its own parcelable decl.
- `ro.telephony.block_binder_thread_on_incoming_calls=false` (ImsPhoneCallTracker
  honours it) -- the Robin needed it; keep until proven unnecessary.
- **Verify on hardware**: `dumpsys telephony.registry` shows IMS registered
  (LTE); logcat tag `ImsBridge` open()/listener replay/bitmap probe; MT call
  rings the InCallUI (network INVITE no longer CANCELs with 480); MO call places
  over IMS (`ImsPhoneCallTracker` dial, no CSFB). Then: `setImsStatusToModem`
  still dropped -- if the modem keeps CSFB routing, that is the next hook.

## Media/RTP: what `GetIPAddrOfCP() Error[21]` actually is (static analysis, 2026-10-05)

Full trace in `.scratch/ims4/research-media/FINDINGS.md`. Short version, all verified by
disassembly:

- `AudioAdaptor::GetIPAddrOfCP` is not a property or ioctl. It binders into LG's MMPF media service
  (`getService("lgeims_mmpf")`, descriptor `com.lge.mmpf.MMPFService`) -> `MMPF_CP_IF::GetIpAddrOfCP`
  -> `qcci_qmi_lge_ims_send_cmd(msg_id 0x060C)` on **QMI service 0x2BF** (`lge_ims`, idl v2).
  0x060C is an opaque `u8[300]` tunnel: the request goes out, the answer comes back as an
  **indication**, handled by `MMPF_OnIndFromCP`, which copies an ASCII address from `ind+0x24`.
- **`Error[21]` is a 1000 ms timeout waiting for that indication** -- a hardcoded `0x15`, the only
  failure value. The QMI send result is discarded, so a failed send and a silent modem look
  identical. It also means the `lgeims_mmpf` binder service WAS published and the server ran (a dead
  proxy returns 2).
- **It does not blank the SDP.** `AudioProfileConfigurer` falls back to the stack's normal
  local-address accessor when `GetModemIPv6()` is empty, and that address is what
  `AudioNego::MakeSDPFromProfile` puts in `c=`/`o=`. So a call should still negotiate a real address;
  whether RTP must instead go through the modem socket bridge
  (`MMPF_CP_IF::createSocketBridge/sendDataToBridge` exist) is the open question.
- `UpdateModemIPv6` has eight gates, each logged. One is `IsUseSingleIP()` =
  `persist.lg.data.iwlan.ipsec.ap` (its only caller anywhere); it is set nowhere in the tree, so
  `setprop persist.lg.data.iwlan.ipsec.ap 1` suppresses the query entirely -- useful to confirm the
  gate, useless as a fix.
### Measured during a real INVITE (2026-10-05 22:01, A3 build, MMPF/QMI_FW captured for the first time)

The three-way split above resolves to a **fourth** case: the client is alive and the modem is not
silent -- the request never leaves the AP.

```
[LGE_VSS_QCCI][AP] IMS sendind MSG = 0x60c
QCCI qmi_cci_flush_tx_q: Error sending TXN: svc_id: 703 txn_id: 4 msg_id: 1548
xport_send: Sendto failed for port 14336
[mmpf_cpif_send_msg] send_msg_sync error: -16        (QMI transport error)
[MMPF_CP_IF_send_msg] fail to send message to cp[-16]
```
`svc_id 703` = 0x2BF, `msg_id 1548` = 0x60C. Four retries, ~1.1 s apart, so a failed modem-address
query adds **~3.3 s to call setup**. Same root as the "QMI svc_id 703 TXN send errors" already noted
above; the sendto on the IPC-router port fails, so 0x060C never reaches the modem.

Also measured, and it is an AP-side config gap of the familiar kind:
`UpdateModemIPv6() - Entered. nPDNType[1], nIsIPv6[-1]` then `PDP profile : -1, Socket Pos : 0`.
LG's stack expects LG's RIL to tell it the IMS PDN profile number; with a non-LG RIL it asks the
modem about profile -1.

**WRONG CALL, corrected 2026-10-06 -- this WAS what blocked audio.** The reasoning below was that
the IMS PDN is up AP-side (APN `ims` CONNECTED over LTE on its own `rmnet_data*` with a global IPv6
address and the P-CSCF list), so `AudioProfileConfigurer` has a real local address to fall back to
for `c=`/`o=` and the modem query looked like a cosmetic failure. The SDP part of that is true and
the fallback does work. What it missed is that **the same QMI service also creates the modem's media
session** (`MMPF_CP_IF::createMediaSession`), and on this SoC the modem is what carries the voice.
So the failure was never about the address at all: with no modem session there was no RTP, the
framework's 5 s RTP-inactivity threshold killed every answered call after ~20 s, and Ims4 then went
`STATE_NOTREADY`. Fixed by the sec_config rule below. Lesson kept deliberately: a failing call into
the modem is not cosmetic just because the data it fetches has a fallback -- check what else rides
on the same transport.

`setprop persist.lg.data.iwlan.ipsec.ap 1` (skips the query, single caller, read per call) is
therefore NOT wanted: the query must succeed, not be skipped.

`lgeims_mmpf` **is** published (`avc: denied { add } ... name=lgeims_mmpf` from the IMS app,
permissive) -- so it needs a `service_contexts` entry before `permissive radio` can be removed, or
media dies. A separate denial stops the *shell* domain finding it, which is why `service list` looks
empty; that is the check lying, not the service missing.

- **Next test costs nothing:** capture `logcat -b all -s MMPF QMI_FW LGIMS` during call setup. Those
  two tags are not in the LGIMS filter and have never been captured here. They split the cause:
  `[LGE_VSS_QCCI][AP] ERROR!!! ims handle is NULL` means the QMI client never came up in the
  `lgeims_mmpf` process (AP-side, suspect the IPC-router/qmuxd socket under sepolicy); `IMS sendind
  MSG = 0x60c` with no `MMPF_OnIndFromCP` means the modem never answered.
  Also read the existing `UpdateModemIPv6() - PDP profile : %d` line: profile `-1` is an AP-side
  config gap.

## SOLVED: QMI service 703 had no IPC-router rule (2026-10-06)

Root cause of "calls connect, no audio, then drop themselves". The kernel said it plainly, and
`dmesg` is the only place it is unambiguous:

```
IPC_RTR: msm_ipc_router_send_to: permission failure for Framework
IPC_RTR: msm_ipc_router_sendmsg: Send_to failure -1
```

The MSM IPC router gates every QMI service by GID from `sec_config`, and a service with **no rule**
is reachable only by root. `configs/permissions/sec_config` (ours, installed by `msm8996.mk` and fed
to `irsc_util` by `rootdir/etc/init.qcom.rc`) granted services 1-511, 704 and 4097 -- and omitted
**703**, the `lge_ims` service LG's own IMS stack needs. com.lge.ims runs as radio, so every
`0x060C` was denied.

Fixed in patch `msm8996-common: sec_config: allow QMI service 703 (lge_ims)`:
`703:4294967295:1000:1001:3004`. After it:
`AudioAdaptor::GetIPAddrOfCP() - Getting success`, `UpdateModemIPv6() - Updated IP for APNName[ims]`,
`nIsIPv6` 1 instead of -1, the audio media session reaches **LIVE**, and an answered call stays up
until someone hangs up (`onCallTerminated reasonCode=501 CODE_USER_TERMINATED`) instead of dying at
~20 s. RTP is arriving: Ims4's own monitor (`bRTPMonitoring TRUE`, 5 s threshold) never fires.

**Ordering trap that cost a cycle:** the router binds a rule to a service when the service
REGISTERS. Running `irsc_util -f <file>` by hand after boot changed nothing, which made a correct
fix look wrong. The rule has to be in the file init feeds before the modem comes up. Check any
device with `forge/tools/qmi-sec-check.sh`.

`PDP profile : -1` is a separate, still-open AP-side gap (LG expects LG's RIL to supply the IMS PDN
profile number) and does not stop the query succeeding.

## Flash B on hardware: what works, and the one thing left (2026-10-06)

Verified on the Flash B build plus the pushed bridge revisions:

- **An incoming VoLTE call rings, answers, stays up and tears down cleanly.** `processIncomingCall`
  -> `RINGING` -> `OFFHOOK`/`ACTIVE` -> `onCallTerminated` -> `IDLE`, with caller ID populated
  (proof the real 51-field `ImsCallProfile` marshals; a stubbed one arrives with no number).
  Longest call 77 s, ended by the user.
- **Bridge bugs found on hardware and fixed** (all now in `forge/templates/ims-bridge`):
  probe the capability bitmap when registration CONNECTS, not at `startSession` -- Ims4 registers
  ~24 s after the framework opens the session, so the open()-time probe always ran too early and the
  framework kept `Voice: false` forever; take `isConnected(NORMAL, 0)` (isRegistered) as the voice
  ground truth, because `isConnected(NORMAL, VOICE)` additionally demands LG UC-layer flags fed by
  provisioning Ims4 refuses to let us write (`setProvisionedValue ... refused, rc=1`), so it answers
  false while voice demonstrably works; report `RIL_RADIO_TECHNOLOGY_LTE` when Ims4 reports no tech
  (it only ever calls `registrationConnected()`), or the dial gate fails; acknowledge
  `setFeatureValue` ourselves, or each capability change blocks the framework's 2 s latch and
  toggling one SIM-settings switch ANRs Settings; and do not advertise video (`isConnected(...,4)`
  answers true regardless, and VT needs the media path).
- **Gate open:** `isVolteEnabled=true` (that log line is `isVoiceOverCellularImsEnabled()` itself),
  `MmTel Capabilities - [Voice: true Video: false]`.
- **Audio works** (2026-10-06 06:43, wifi off so cellular-only): the bridge sends
  `vsid=297816064;call_state=2` and 182 ms later the HAL runs `update_call_states ... in_call:1,
  mode:2`, opening the voice path. Nothing in AOSP sends those keys; see `ModemVoiceSession`.
- **Outgoing AND incoming calls work with two-way audio** (2026-10-06 07:52, back to back on one
  boot). Two further bugs had to be fixed first, both consequences of the rename-and-merge:
  - **MO calls died in `createCallSession`** with `BadParcelableException: ClassNotFoundException:
    com.lge.imslegacy.ImsStreamMediaProfile`. The renamed parcelables' generated `readFromParcel`
    still passes `null` to `readParcelable` -- the BOOT class loader, correct while they were
    `com.android.ims` framework classes, useless once they live in the app's dex. It only bites
    framework -> Ims4, which is why MT always worked and MO failed in half a second. Fixed by
    redirecting `readParcelable` to a compat static using the app loader (safe: the app loader
    delegates to the boot one). 9 classes, 12 sites -- LG's own IM/IM3 parcelables had it too.
    **Check this first in any rename-and-merge port**; it is invisible until something marshals
    downward.
  - **One call per boot**: LG's EAB presence agent queried CallLog for `duration_video`, an LG-only
    column. AOSP's provider throws, `EABAgent` catches nothing on its own thread, and
    `com.lge.ims` is `persistent`, so the IMS process died after every call and restarted unable to
    re-register. Stubbed via `ims/smali-stubs.txt` (build-ims4.sh step 4.4).
- **FIXED and VERIFIED ON HARDWARE (2026-10-06): an unanswered incoming call used to ring forever.** Caught in
  the act on the GApps build -- a real call arrived 12:06:55, the caller gave up, and the handset
  was still `RINGING` and driving the vibrator ten minutes later, with Telecom refusing to dial
  ("Cannot place a call as there is an unanswered incoming call"). This is the same rough edge
  previously filed as an unreaped `DISCONNECTED` object; the real mechanism is:

  Ims4 reports a remote hangup on a call that was never answered as `callSessionStartFailed`, not
  `callSessionTerminated` -- its own model is that the session never started. The bridge forwards
  it faithfully, and AOSP's `ImsPhoneCallTracker.onCallStartFailed` only unwinds `mPendingMO` (plus
  a `findConnection` branch gated on `DomainSelectionResolver.isDomainSelectionSupported()`, which
  is off here). On an MT call `mPendingMO` is null, so the handler does nothing at all and the
  ringing connection is never disconnected. Telecom's own `CallAnomalyWatchdog` notices after 2
  minutes and reports "caught and disconnected a stuck/zombie call", but the call survives that too.

  The log signature is one line: `ImsPhoneCallTracker: onCallStartFailed reasonCode=510`
  (`CODE_USER_TERMINATED_BY_REMOTE`) on a call that is ringing rather than dialling. A correct
  teardown reads `onCallTerminated`. LG's own layer logs the truth just above it
  (`UCCallManager ... onCallTerminated :: An active call is terminated`), so the information is
  there -- only the callback it is delivered on is wrong.

  **Fix** (folded into the ImsBridge patch, and into `forge/templates/ims-bridge`):
  `CallSessionWrapper` carries an `incoming` flag, set only on the `getPendingCallSession` path --
  the only way an MT session arrives -- and `CallSessionListenerAdapter.callSessionStartFailed`
  delivers MT as `callSessionTerminated`. MO is untouched: it needs `startFailed`, which is what
  drives the CSFB retry path. **Not yet exercised on hardware**: it only fires on a call nobody
  answers, so confirm with one deliberately unanswered incoming call, then check
  `dumpsys telecom | grep mCalls` is empty and that the next outgoing call dials.

  **Confirmed 2026-10-06 15:52 on the flashed build.** A real call, left unanswered, reaped in 5 ms:

  ```
  15:52:42.192  ImsPhoneCallTracker: processIncomingCall: incoming call intent
  15:52:55.963  LGIMS_J [GII-UC] onCallTerminated :: An active call is terminated
  15:52:55.968  ImsBridge: startFailed on an incoming session -> terminated, code 510
  15:52:55.982  ImsPhoneCallTracker: onCallTerminated reasonCode=510
  15:52:56.068  LGIMS_J [GII-UC] onCallDestroyed :: activeCalls=0
  ```

  The line that used to read `onCallStartFailed reasonCode=510` now reads `onCallTerminated`, and
  `mCalls` is empty afterwards with no CallAnomalyWatchdog zombie report.
- **SMS over IMS: ROOT CAUSE FOUND AND FIXED at the QMI layer** (2026-10-06). The blocker was a
  (tested on hardware 2026-10-06, both earlier leads disproven). Staging the stock `imswmsproxy` +
  the 64-bit `libqmi_wms_client_helper.so` and running it gets further than before: the proxy binds
  `@/tmp/ims/wms/wms_proxy`, Ims4's SMS client reaches `Update SoI Service Mode :: STATE_READY`, and
  the whole AP-side chain is live. It still fails, one step earlier than previously recorded:

  ```
  ImsWmsClient :: InitWmsService(rmnet0)
  ImsWmsClient :: srvc_init_client - client=-1, qmi_err_code=0     <- the real failure
  ImsWmsClient :: InitTransport - client=-1, smsFormat=1
  ImsWmsClient :: transport_init failed; status=-1                 <- only the consequence
  ```

  `transport_init` is not where it breaks -- it is called with an already-invalid client. The QMI
  **client allocation** fails, and `qmi_err_code=0` says QMI never reported an error, which is what
  you get when the library cannot reach its transport at all rather than being refused by it.

  **Why: it asks QCCI for the QMUX transport, and nothing serves QMUX here.** The kernel confirms
  it -- `QMI_FW: QMUXD: WARNING qmi_qmux_if_pwr_up_init failed! rc=-6` -- and
  `libqmi_client_qmux.so` carries a `qmi_client [%d] QMUXD disabled` path for exactly this. No
  `qmuxd` is shipped or running; `/dev/socket/qmux_radio` is a **directory** owned by `qcrild`
  (holding `qcril_radio_config0/1`), and the data stack is `qcrild` + `netmgrd` + `ipacm` talking
  QMI over the IPC router.

  `rmnet0` is NOT the problem, despite looking like one: it is a QMI **connection id**, not a
  netdev. `libqmi.so`'s own table lists `rmnet0`..`rmnet7`, and the device having `rmnet_data0..7`
  interfaces is irrelevant. Checked, because it is the obvious wrong turn here.

  The encouraging part: `libqmi_wms_client_helper.so` is already a **QCCI** client. It imports
  `qmi_client_init_instance` and `qmi_client_send_raw_msg_sync` -- the modern API qcrild uses -- plus
  `qmi_cci_qmux_xport_unregister`, i.e. it explicitly drives the QMUX transport under QCCI rather
  than being written against legacy QMUX throughout. It exports 24 symbols, of which the WMS surface
  is five: `qmi_wms_srvc_init_client`, `qmi_wms_transport_init`, `qmi_wms_transport_cap_update`,
  `qmi_wms_transport_nw_reg_status_update`, `qmi_wms_srvc_extract_return_code` (the rest are generic
  `qmi_util_*` txn/TLV helpers).

  **Both earlier leads are wrong, and so was a later one.** It is not the daemon running as root
  instead of `group radio`: as root it gets all the way to the QMI client call, and there are no
  IPC-router denials, exactly as the original note said. It is not our RIL "owning" the WMS
  transport either -- nothing is refusing it, there is nothing there to refuse. (The sec_config rule
  `5:4294967295:1001` granting WMS to radio only is real but irrelevant here; it would matter if the
  transport existed.)

  **What a fix would take.** The promising route is to rebuild `libqmi_wms_client_helper.so` against
  QCCI's IPC-router transport instead of its QMUX one, keeping the same five WMS entry points so the
  stock `imswmsproxy` binary links against it unchanged. The device already ships `libqmi_cci.so`,
  and qcrild proves the transport works. Scope is one small library, not a transport layer -- but
  the WMS request/response TLVs it builds have to be reproduced, and that is the unknown.

  The alternative -- shipping a stock `qmuxd` alongside `qcrild` -- collides with `qcrild` over
  `/dev/socket/qmux_radio`, and LG's own `/system/bin` has no `qmuxd` (only `netmgrd`), so it would
  have to come out of the stock **vendor** partition, which is not extracted yet.

  Until then SMS stays on the circuit-switched path, which works and which the user has verified
  both ways.

  **It is a QMI IDL VERSION GATE, and the fix is one stock blob.** `wms_get_service_object_internal_v01`
  is a generated getter that returns NULL unless the caller's (major, minor, tool) matches the
  library exactly. LG's 2016 helper asks for **(1, 24, 6)**; this ROM's `libqmiservices.so` accepts
  only **(1, 35, 6)** -- eleven minor revisions newer. NULL object means no QMI transaction ever
  happens, which is precisely why every symptom pointed nowhere: `qmi_err_code=0`, no IPC-router
  denial, no SELinux denial, no QMI library output at all.

  Verified by a standalone QCCI probe (no LG daemon involved) that dlopens the device's own libs and
  calls the getter, then `qmi_client_init_instance`:

  ```
  ROM libqmiservices:    (1,24,6) -> NULL          -> FAIL
  scan:                  (1,35,6) -> 0x70229eac30  (the only version accepted)
  STOCK libqmiservices:  (1,24,6) -> 0x751782fb68  -> qmi_client_init_instance rc=0 client=0x1  PASS
  ```

  Put the stock 64-bit `/vendor/lib64/libqmiservices.so` (127968 bytes, from the KDZ) ahead of the
  ROM's on `imswmsproxy`'s library path and the whole chain comes up:

  ```
  InitWmsService - client=1, qmi_err_code=0              (was client=-1)
  UpdateServiceStatus - status=READY, tid=0              (was tid=-1 + "WMS service is not connected")
  SoIClient.cpp:416 Update SoI Service Mode :: STATE_READY
  ```

  This is not a hack: the modem is stock 2016 firmware, so the stock IDL is the *correct* encoder
  for it. The newer IDL came in with the newer userspace.

  **But the framework still cannot use it, and the bridge cannot be made to help.** With the
  transport up, `MmTel ... SMS: false` and `ImsSmsDispatcher: cap=false` remain, and that is
  structural rather than a missing probe:

  - The legacy 6-slot feature bitmap has no SMS slot (0-5 are voice/video/UT over LTE/WiFi), and
    AOSP's `MmTelFeatureCompatAdapter.convertCapabilities()` sets only VOICE, VIDEO and UT.
    `CAPABILITY_TYPE_SMS` appears **nowhere** in that adapter. No re-probe can surface it.
  - The adapter implements **none** of the SMS surface -- no `sendSms`, `acknowledgeSms`,
    `onSmsReady`, `setSmsListener`, `getSmsFormat`. The modern `MmTelFeature` has 13 references to
    `ImsSmsImplBase`; the compat path has zero. So `ImsSmsDispatcher` has nothing to send to.
  - The 7.0 `IImsService` LG exposes has no SMS method either (0 matches in `iface-list.txt`).
    LG's SMS over IMS lives entirely inside Ims4: SoI client -> libimswms -> wms_proxy -> QMI WMS.
    It never crosses the IMS binder, so there is nothing for an adapter to call even if one existed.

  So the QMI fix makes LG's own SMS path healthy, and the AOSP framework still has no route to it.
  Closing that needs a **modern** (non-compat) ImsService: implement `MmTelFeature` directly with
  `getSmsImplementation()`, reimplementing what `MmTelFeatureCompatAdapter` does for calls (which is
  readable, ~500 lines) plus the SMS surface, and a way for Ims4 to hand MT SMS up -- which on stock
  is LG framework code we do not have. That is a different project from this bridge, not a last
  step, and it is why SMS is parked rather than nearly done.

  The reusable half of this is in the forge, so the next device does not repeat it:
  `tools/android-cc.sh` (build a one-file C probe against the tree and push it),
  `tools/native-probes/qmi-idl-probe.c` (which IDL version the ROM accepts, and whether a client
  then initialises), `tools/native-probes/unix-dgram-poke.c` (drive an OEM daemon's message
  dispatcher without its app), `tools/native-probes/run-as-gid.c` (test a GID gate without an
  init.rc), GOTCHAS 40 for the version gate itself, and the "SMS over IMS" section of
  `docs/debugging-volte.md` for the method and the compat-path dead end.

  To ship it: `imswmsproxy` as a `cc_prebuilt_binary` with an rc (`class main, user system, group
  radio system net_admin net_raw`), the 64-bit helper and the **stock** `libqmiservices.so` as vendor
  prebuilts placed so only this daemon sees them, and a sepolicy domain shaped like
  `lge_ims_ipsec.te`.

  **The GID theory is refuted, conclusively** (2026-10-06). `sec_config` grants WMS (service 5) to
  GID 1001 only, and the daemon had only ever been tested as root -- an obvious suspect. It is not
  the cause. Run with stock's exact credentials (`Gid: 1001`, groups `1001,1000,3004,3005`, via a
  freestanding setgid wrapper) the failure is byte-identical to the root run:
  `srvc_init_client - client=-1, qmi_err_code=0`. Do not spend time here again.

  **How to test this in ten seconds instead of rebooting.** `InitWmsService` has exactly one caller:
  message id **1** on the abstract socket `@/tmp/ims/wms/wms_proxy`. The daemon is a select/recvfrom
  loop; each datagram is 524 bytes, the first u32 is the id, bounds-checked 1-12 and dispatched
  through a jump table at 0x272c (1 InitWmsService, 5 UpdateServiceStatus -- the one Ims4 sends most
  and the reason earlier runs looked inconsistent). So a 30-line AF_UNIX/SOCK_DGRAM sender that
  writes 524 bytes with the first u32 = 1 drives the whole QMI path on demand, with no reboot and no
  dependence on Ims4's timing. Note `Modem is initialized; handle=%d` is logged from TWO sites --
  daemon startup and inside InitWmsService -- so seeing it does not mean the QMI path ran.

  **Where it actually fails:** inside `qmi_client_init_instance` (QCCI), which returns non-zero with
  `qmi_err_code=0` -- no QMI transaction took place. Nothing is refusing it; it cannot reach the
  service. The next probe is a ~40-line standalone QCCI client linked against the device's own
  `libqmi_cci.so` + `libqmiservices.so` that calls `wms_get_service_object_internal_v01` then
  `qmi_client_init_instance` and prints the rc. That answers the one remaining question -- can ANY
  process on this ROM get a WMS client over QCCI -- without LG's daemon in the picture at all.

  Ordering note for whoever retries: Ims4 asks once. It sends `IMSConnected` to the proxy ~59 s
  after `sys.boot_completed` and never retries, so a hand-started proxy has to be up *and*
  modem-connected before that. Started earlier than ~boot+25 s the modem is not ready and the QMI
  init fails anyway.

- **DONE: runs enforcing** (2026-10-06, patch `sepolicy: stop making radio permissive`). No
  permissive domains at all, and zero `permissive=0` denials in the radio domain on a boot that
  registers. `lgeims_mmpf`, `com.lge.ims.phone` and `com.lge.ims.rcs.media` have service types and
  a `service_contexts`; `net.ims.*`/`persist.lg.ims.*` get a `system_internal_prop` type because a
  coredomain may only set a `system_property_type`.

  **The trap that cost a flash**, worth reading before touching this: the audit from a permissive
  boot showed ioctl `0xc304` on the QMI socket, so the first rule named only that. Adding ANY
  `allowxperm` switches that domain/class to whitelist mode, so every other ioctl became denied --
  including `0xc302`, which the same QMI path uses. Calls still connected, registration still
  worked, and audio was silent, because the denied ioctl broke `GetIPAddrOfCP` and with it the
  modem's voice session. Now `0xc300-0xc30f`, the whole IPC-router family. A permissive audit
  cannot show this class of bug, because whitelist mode does not exist until the rule does: budget
  an enforcing boot. See rom-forge GOTCHAS 38.
- **Still open:** `setImsStatusToModem` is logged and dropped (if the modem keeps CSFB routing, that
  is the next hook); SMS over IMS needs the modem to accept the QMI WMS transport (above).
  The unanswered-call hang is fixed above but not yet exercised on hardware.

## Two user-visible warts on the GApps build (2026-10-06)

- **Hiding WFC/VT takes a property, not just the CarrierConfig key.** A17 Settings decides whether
  to draw the `Calling` rows from `ImsMmTelManager.isSupported()`, which lands in
  `ImsManager.isVtEnabledByPlatform()` / `isWfcEnabledByPlatform()`. Each returns true OUTRIGHT when
  `persist.dbg.vt_avail_ovr` / `persist.dbg.wfc_avail_ovr` is 1, before it reads
  `config_device_*_available` or the carrier key -- so `carrier_vt_available_bool=false` and
  `carrier_wfc_ims_available_bool=false` read back correctly in `dumpsys carrier_config` while both
  rows stayed on screen. These are `persist.` properties: with nothing in the tree their value is
  whatever an earlier boot wrote to `/data/property`, which is how a bring-up `setprop` survived
  every later flash. `vendor_prop.mk` now pins all three (volte=1, vt=0, wfc=0). Note the order:
  `/data/property` is loaded after `build.prop`, so the tree value does NOT win on a handset that
  already has a stale one -- `setprop persist.dbg.vt_avail_ovr 0` to correct it in place.

  Confirm from logcat rather than from the carrier config:
  `ImsMmTelRepository: [1] isSupported(capability=2,transportType=1)` is VT/WWAN,
  `(capability=1,transportType=2)` is voice/WLAN i.e. WFC. `false` on both = rows gone.

- **"Phone Services isn't compatible with the latest version of Android."** A17's
  `DeprecatedAbiDialog`, shown whenever a `com.android.phone` activity starts (call settings,
  `RadioInfo`); dialling never triggers it. `com.lge.ims` declares `android.uid.phone`, PackageManager
  resolves ONE ABI per shared UID, and the IMS stack is 32-bit only (LG's SIP libs, and
  `libimscompat` is `compile_multilib: "32"`), so `com.android.phone` is dragged to
  `primaryCpuAbi=armeabi-v7a`. Cosmetic, and the price of the shared UID the port depends on --
  the alternative is giving `com.lge.ims` its own UID, which breaks its access to the radio.

## RCS: PARKED (2026-10-06) -- try GApps/Messages first, port LG's RCS only if that fails

**Decision (2026-10-06): not doing it.** Too much work for too little -- a second bridge larger than
the first, against ~500 classes of undocumented proprietary interfaces, with no AOSP adapter layer
to plug into, living inside a `persistent` process where any crash kills voice. Use GApps/Messages
for RCS instead. The mapping notes below are kept only so that a future attempt, if anyone ever
wants one, does not restart from zero -- they are not a plan of record.

Google Messages does RCS over **Jibe Cloud** on plain data, not through the carrier IMS stack, and
T-Mobile (so Mint) migrated to Jibe -- so on this SIM Chat features should work with GApps and the
mobile data we already have, with no IMS involvement. The two ways an app *could* use a device IMS
stack for RCS are both closed to us: UCE capability exchange needs an `RcsFeature` bridge that does
not exist, and single registration needs `SipTransportImplBase` (Android 12), which a 2016 stack
predates by six years. Test order: get SMS working (Jibe verifies the number by SMS), build
`PRESET=full`, sign in, check Chat features. That experiment decides it.

**Three corrections to the earlier plan, each verified 2026-10-06 -- the old plan was wrong:**
- `ImsServiceControllerCompat.createRcsFeature()` returns `null` unconditionally ("Return non-null
  if there is a custom RCS implementation that needs a compatability layer"). The compat path has an
  RCS placeholder that upstream never implemented.
- **There is no `RcsFeatureCompatAdapter` in AOSP.** MMTel, registration and config each have one;
  RCS does not. The MMTel bridge worked because a finished adapter layer existed to plug into. For
  RCS there is nothing to plug into, so the whole adapter would be ours.
- **Ims4 does not implement AOSP's UCE API at all** -- zero references to `IUceService` or
  `UceServiceBase`. The `com.android.ims.internal.uce.*` classes exist in LG's framework but Ims4
  never touches them, so "un-stub UCE and wire config_ims_rcs_package" (the earlier plan) cannot
  work. LG's RCS is ~500 classes behind proprietary interfaces: `IEABService`/`IEABServiceListener`,
  `ICapability3`/`ICapabilityListener3`, `IContentShare`, `IImageSession`, `IVideoSession`,
  `IEnrichedCallService`, `IInCallSession`/`IOutCallSession`.

If it is ever attempted: skip the compat path and write a **modern** `RcsFeature` ImsService in a
separate app (`config_ims_rcs_package` may differ from the mmtel package) -- we would be writing the
adapter either way, so write it against the supported API. Then regenerate LG's RCS AIDL with
gen-legacy-aidl.py (verify with aidl-tx-diff.py), un-stub the RCS parcelables via build-ims4.sh step
3.5, and expect the same capability lie as voice (Ims4's UC flags are provisioning-gated and
`setProvisionedValue` is refused, so derive capability from registration).

**Stability constraint that makes this risky:** `com.lge.ims` is `persistent`, so an RCS crash takes
VOICE down with it. Proven 2026-10-06: LG's EAB presence agent crashed the whole IMS process after
every call (see the `duration_video` stub in `ims/smali-stubs.txt`), costing one working call per
boot. Any RCS work belongs behind a build option, default off.

Flash A/B target voice VoLTE only. The surface mapping below predates the corrections above -- read
it with them in mind.

What RCS adds on top of the voice stack:
- **Ims4 already carries the RCS code** (no extra app): `com.lge.ims.rcs`,
  `com.lge.ims.service.rcs`, `com.lge.ims.service.eab` (EAB = presence/enhanced
  address book), `com.lge.ims.volte.provider.eab`. These are in the APK, so once
  Ims4 runs they are present -- RCS is a configuration/wiring problem, not a
  second port.
- **UCE legacy classes** (User Capability Exchange = the presence/options SIP
  layer): `com.android.ims.internal.uce.*` -- 58 classes in smali-fw
  (presence: PresCapInfo/PresRlmiInfo/PresTupleInfo/IPresenceService/
  IPresenceListener; options: OptionsCapInfo/IOptionsService; common: CapInfo/
  StatusCode/UceLong; uceservice: ImsUceManager/IUceService/IUceListener/
  UceServiceBase). All quickened -- for voice they are **stubbed** (category D).
  For RCS they must be made real: regenerate the `IUceService`/`IOptionsService`/
  `IPresenceService` + listeners via gen-legacy-aidl (same path as the voice
  interfaces), and provide the UCE parcelables (CapInfo, PresCapInfo, ...) real
  rather than stubbed.
- **The LG parcelables stubbed for voice become load-bearing for RCS**:
  LGImsDialog/LGImsDialogState (conference/dialog state), LGImsDevice/
  LGImsDeviceInfo (device management), LGImsIcbInfo. Un-stub them (deodex from
  the right source or reconstruct).
- **Shared lib**: `com.verizon.ims.jar` (/system/framework, VZW RCS) -- a
  uses-library Ims4 may need on Verizon; port like boot-ims-common if so.
- **Bridge**: AOSP's modern RCS path is `config_ims_rcs_package` +
  `android.telephony.ims.RcsFeature` / the compat `RcsFeature`
  (`frameworks/base/.../compat/feature/RcsFeature.java` exists on A17). The
  Robin bridge did **not** wire RCS (MMTEL only -- it set only
  `config_ims_mmtel_package`). For RCS, add an `onCreateRcsFeature` to the
  bridge returning a LegacyRcsFeature that talks to Ims4's UCE binder, and set
  `config_ims_rcs_package`.
- **Config**: RCS provisioning (autoconfig/ACS), the `com.lge.ims.rcs.*`
  broadcast actions (CONFIG_STATE, STARTER, enrichedcall.*, rcsim.*) must not be
  renamed (wire contracts, like the voice IMS_SERVICE_UP actions), carrier
  CarrierConfig RCS keys, and an RCS APN if the carrier separates it.
- **Modem**: the SIP stack is the same libims; RCS rides the same IMS PDN, so no
  new modem hook beyond what voice needs.

Order when resuming: voice end-to-end first, then un-stub UCE + LG dialog/device
parcelables, regenerate the UCE AIDL, add the RcsFeature to the bridge, wire
config_ims_rcs_package, then provisioning.

## Direct boot: there is no IMS until the user unlocks (2026-10-09)

`Ims4` is `android:persistent="true"` and is **not** `android:directBootAware="true"`. Persistent
only tells ActivityManager to keep the process alive and restart it; it does not start it early.
Nothing launches until credential-encrypted storage unlocks, which means until someone types the
PIN.

On a handset with no screen lock this is invisible, because such a device unlocks itself during
boot. That is how every build before this one was tested. Once a PIN exists:

- every reboot has a window, as long as the lock screen sits there, with no IMS stack at all, and
- `Ims4` then starts cold and registers once against a modem and a telephony stack that have
  already been up for minutes.

LG's stack registers on startup and does not meaningfully retry, so "registers then drops" and
"worked before I set a PIN" are the same bug wearing different clothes. Check it with:

    dumpsys package com.lge.ims | grep -i directBoot
    dumpsys activity processes | grep com.lge.ims

Making it direct-boot-aware is not obviously safe: it keeps SIP credentials and registration state
in CE storage, so an early start would read an empty profile. The cheaper fix is to make
registration retry on `ACTION_USER_UNLOCKED` rather than fire once at process start. See GOTCHAS 44.

## VoLTE regression and the A/B (2026-10-09, OPEN)

Current state: IMS registers once when `Ims4` starts, then drops. Outgoing calls fail with
`DisconnectCause: LOCAL`, outgoing SMS fails, and `ImsSmsDispatcher` reports `up=false reg=false
cap=false`. No VoLTE entry appears in SIM settings. This worked on earlier builds.

Two confounds were identified before drawing any conclusion:

1. **Upstream moved.** In a single day `frameworks/base` gained 6 commits, `Settings` 3 and
   `vendor/lineage` 4. Builds here were never reproducible, so "it worked last week" was not
   evidence about our patch series. `bootstrap.sh` now snapshots the manifest after every sync and
   `PIN_MANIFEST=` replays it; see GOTCHAS 47.
2. **A PIN now exists**, which opened the direct-boot window described above. That changed IMS
   startup ordering independently of any build.

A/B baseline is tagged `ab-6a86e24`, the tree before 32fbfa3, 0bc75c4, 07650b8 and 598fca4. Its
build did **not** pin upstream, so a pass proves those four commits caused it and a failure proves
nothing. The upstream SHAs it used are in `build_output/manifests/manifest-ab-6a86e24.xml`
(local only, `build_output/` is gitignored).

Ruled out by experiment: SELinux. `setenforce 0` produced zero denials and an identical failure, so
patch 0039 is not implicated. Boot-time permissive (`androidboot.selinux=permissive`) is still
untested and is the only remaining policy question.

## Other open items on the GApps build (2026-10-09)

- **Play Store sign-in loops** in `PreAddAccountChimeraActivity`, hanging on "Checking info".
- **The satellite section flashes** on the SIM settings page specifically, then disappears.
- **The clock widget never receives RemoteViews.** It is the AOSP DeskClock provider, the package is
  not stopped, and launching the app does not help. See GOTCHAS 41.
