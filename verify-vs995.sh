#!/usr/bin/env bash
# verify-vs995.sh — check the 24.0 bringup claims for the V20 against the tree and the device.
# Prints PASS/FAIL per claim; exits non-zero if any fails.
#
#   ./verify-vs995.sh              # tree claims, then device claims if a phone is attached
#   ./verify-vs995.sh --tree-only  # tree claims only, and do not pretend the rest passed
#
# WHY IT IS SHAPED THIS WAY
#
# Six subsystems changed to get this device onto 24.0 and none of them has run on hardware. Three
# HIDL HALs became AIDL, LiveDisplay moved to AIDL, one of two WLAN trees stopped claiming
# wpa_supplicant.conf, and the eBPF stack is expected to fail outright because Android 17 puts its
# map and program floor at kernel 4.9 while this phone is on 4.4. Guessing from a boot animation
# which of those worked is not a test.
#
# A checker that cannot fail is worth nothing. The device claims here need a phone, so with none
# attached they are NOT skipped-as-passed: the script says so and exits non-zero, because
# "everything passed" on an empty adb is the failure mode that makes a checker worse than nothing.
# Patch claims match by SLUG, never by number: the series gets renumbered and a stale number
# silently checks a different patch.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
ADB=/media/Storage/Coding/tools/platform-tools/adb
SRC="${BUILD_ROOT:-$PWD/build_output}/src"
P=overlay/patches
TREE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tree-only) TREE_ONLY=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "!! unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail=0
ck(){ if [ "$2" = 1 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
# Resolve a patch by slug. Empty result is a FAIL at the call site, never a silent skip.
pat(){ find "$P" -name "*$1*.patch" 2>/dev/null | head -1; }

echo "== tree claims"
[ -d "$SRC" ] || echo "  !! no synced tree at $SRC -- tree claims that read it will FAIL, not skip"

# T1 the WLAN collision is fixed at the source, not worked around
f=$(pat 'gate-wpa_supplicant.conf-on-BOARD_WLAN_DEVICE'); [ -n "$f" ] || f=$(pat 'wpa_supplicant')
n=$(grep -c 'board_wlan_device' "$f" 2>/dev/null || echo 0)
ck "T1  a patch gates qcwcn's wpa_supplicant.conf on board_wlan_device (${f:-no patch found})" \
   "$([ -n "$f" ] && [ "$n" -ge 1 ] && echo 1 || echo 0)"
n=$(grep -rc 'board_wlan_device' "$SRC/hardware/qcom-caf/wlan/qcwcn/config/Android.bp" 2>/dev/null || echo 0)
ck "T1b that guard is present in the synced tree ($n)" "$([ "$n" -ge 1 ] && echo 1 || echo 0)"

# T2 no PRODUCT_PACKAGES entry that 24.0 deleted. kati reports these only after a 13 minute run.
# Counting absences passes for free when there is nothing to read, so establish that the makefiles
# exist before believing that none of them names a dead module. This claim passed against a
# nonexistent tree until the negative test caught it.
mks=$(ls "$SRC"/device/lge/*/*.mk 2>/dev/null | wc -l)
ck "T2a the device makefiles are present to be searched ($mks)" "$([ "$mks" -ge 3 ] && echo 1 || echo 0)"
dead=0
for m in 'android.system.suspend@1.0' 'disable_configstore' 'vendor.lineage.livedisplay@2.0-service-sdm' \
         'android.hardware.light@2.0-service.elsa' 'android.hardware.ir@1.0-service.lge' \
         'android.hardware.biometrics.fingerprint@2.0-service'; do
  if grep -rqF -- "$m" "$SRC"/device/lge/*/*.mk 2>/dev/null; then
    echo "        still referenced: $m"; dead=$((dead+1))
  fi
done
ck "T2b no device makefile names a module 24.0 deleted ($dead found)" \
   "$([ "$mks" -ge 3 ] && [ "$dead" -eq 0 ] && echo 1 || echo 0)"

# T3 the AIDL replacements are the ones actually requested
got=0
for m in 'android.hardware.light-service.lineage' 'android.hardware.ir-service.lge' \
         'android.hardware.biometrics.fingerprint-service.lineage' 'vendor.lineage.livedisplay-service.sdm'; do
  grep -rqF -- "$m" "$SRC"/device/lge/*/*.mk 2>/dev/null && got=$((got+1))
done
ck "T3  all four AIDL services are in PRODUCT_PACKAGES ($got/4)" "$([ "$got" -eq 4 ] && echo 1 || echo 0)"

# T4 the fingerprint type property, which the service treats as fatal when unset
n=$(grep -rc 'persist.vendor.fingerprint.type=rear' "$SRC"/device/lge/*/*.mk 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
ck "T4  persist.vendor.fingerprint.type=rear is set (UNIMPLEMENTED(FATAL) if not) ($n)" \
   "$([ "${n:-0}" -ge 1 ] && echo 1 || echo 0)"

# T5 the 4.4 kernel takes the GCC path, which needs prebuilts 24.0 deleted
g=0
for d in prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9; do
  [ -x "$SRC/$d/bin/$(basename "$d" | sed 's/-4\.9$//')-as" ] && g=$((g+1))
done
ck "T5  both GCC 4.9 prebuilts present with a working assembler ($g/2)" "$([ "$g" -eq 2 ] && echo 1 || echo 0)"

# T6 analysis needs a heap cap on this host or it OOMs rather than failing
n=$(grep -c '^SOONG_MEM_LIMIT=' device.conf 2>/dev/null || echo 0)
ck "T6  device.conf caps soong_build's heap ($n)" "$([ "$n" -ge 1 ] && echo 1 || echo 0)"
n=$(grep -c 'export SOONG_MEM_LIMIT' forge/bootstrap.sh 2>/dev/null || echo 0)
ck "T6b bootstrap exports it, or the cap never reaches the container ($n)" "$([ "$n" -ge 1 ] && echo 1 || echo 0)"

# T7 the engine patch for a device with no vendor partition
n=$(ls forge/patches/lineage-24.0/build/soong/*fsgen* 2>/dev/null | wc -l)
ck "T7  fsgen vendor-variant engine patch is vendored ($n)" "$([ "$n" -ge 1 ] && echo 1 || echo 0)"

echo
echo "== device claims"
dev=$("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | head -1)
if [ "$TREE_ONLY" = 1 ]; then
  echo "  !! --tree-only: device claims NOT checked. This run proves nothing about the phone."
elif [ -z "$dev" ]; then
  echo "  !! no device on adb. The device claims below are the whole point of this script, so"
  echo "     they count as FAILED rather than passing by absence."
  for c in "D1  lights AIDL service registered" "D2  fingerprint AIDL service registered" \
           "D3  IR AIDL service registered" "D4  LiveDisplay AIDL service registered" \
           "D5  backlight responds to a write" "D6  netd alive despite bpf failures" \
           "D7  bpf map floor behaviour recorded"; do ck "$c" 0; done
else
  sl(){ "$ADB" shell service list 2>/dev/null; }
  L=$(sl)
  ck "D1  lights AIDL service registered"      "$(echo "$L" | grep -qF 'android.hardware.light.ILights/default' && echo 1 || echo 0)"
  ck "D2a fingerprint AIDL service registered" "$(echo "$L" | grep -qF 'android.hardware.biometrics.fingerprint.IFingerprint/default' && echo 1 || echo 0)"
  t=$("$ADB" shell getprop persist.vendor.fingerprint.type 2>/dev/null | tr -d '\r')
  ck "D2b fingerprint type reads back as rear (got '${t:-unset}')" "$([ "$t" = rear ] && echo 1 || echo 0)"
  ck "D3  IR AIDL service registered"          "$(echo "$L" | grep -qF 'android.hardware.ir.IConsumerIr/default' && echo 1 || echo 0)"
  ck "D4  LiveDisplay AIDL service registered" "$(echo "$L" | grep -q 'vendor.lineage.livedisplay' && echo 1 || echo 0)"
  b=$("$ADB" shell 'cat /sys/class/leds/lcd-backlight/brightness' 2>/dev/null | tr -d '\r')
  ck "D5  lcd-backlight brightness node readable (got '${b:-nothing}')" \
     "$([ -n "$b" ] && echo 1 || echo 0)"
  ck "D6  netd is running"                     "$("$ADB" shell pidof netd >/dev/null 2>&1 && echo 1 || echo 0)"
  # Not a pass/fail on the feature: this records which side of the 4.9 floor the kernel landed on, so the
  # decision about Data Saver visibility is made from evidence.
  sk=$("$ADB" shell logcat -d -s NetBpfLoad 2>/dev/null | grep -c 'skipping map' || echo 0)
  cr=$("$ADB" shell 'ls /sys/fs/bpf/ 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
  echo "  INFO  bpf: $sk 'skipping map' lines, ${cr:-?} entries under /sys/fs/bpf"
  ck "D7  bpf outcome recorded (skipped=$sk pinned=${cr:-?})" "$([ -n "${cr:-}" ] && echo 1 || echo 0)"
fi

echo
if [ "$fail" -eq 0 ]; then echo ">> all claims passed"; exit 0; fi
echo ">> $fail claim(s) failed"
exit 1
