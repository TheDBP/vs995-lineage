#!/usr/bin/env bash
# stage-volte.sh -- build the IMS artifacts this ROM's VoLTE needs out of a stock LG system image.
#
#   ./stage-volte.sh <stock system.image> <aosp-root>
#
# Run for you by the forge's `volte` option (post-patch, after the device patches are applied).
# Supply the image and never think about this again; see IMS.md "Building the IMS stack from stock
# firmware" for where the image comes from.
#
# WHY AN IMAGE AND NOT THE KDZ: nothing here reads LG's container format. Extract the KDZ once with
# third-party kdztools (unkdz, then undz) and keep the `system` partition -- that is the one manual
# step, and it needs a tool we cannot vendor.
#
# Everything this produces is derived from proprietary firmware: it is written into the build tree
# and committed nowhere. That is also why it cannot simply ship -- see README.md.
set -euo pipefail
IMG="${1:?usage: stage-volte.sh <stock system.image> <aosp-root>}"
AOSP="${2:?usage: stage-volte.sh <stock system.image> <aosp-root>}"
[ -f "$IMG" ]  || { echo "!! no such image: $IMG" >&2; exit 1; }
[ -d "$AOSP" ] || { echo "!! no such tree: $AOSP" >&2; exit 1; }
command -v debugfs >/dev/null || { echo "!! debugfs (e2fsprogs) not found; it reads the ext4 image" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
IMS="$AOSP/device/lge/msm8996-common/ims"
[ -x "$IMS/build-ims4.sh" ] || { echo "!! $IMS/build-ims4.sh missing -- device patches not applied yet?" >&2; exit 1; }

# Scratch under the build tree, never /tmp: these are hundreds of megabytes and /tmp is a tmpfs on
# the usual build host. Cleared each run so a half-finished previous attempt cannot be mistaken for
# a good one.
W="${BUILD_ROOT:-$AOSP/..}/tmp/stage-volte"
rm -rf "$W"; mkdir -p "$W/lib" "$W/bin"

pull() {  # pull <path-in-image> <dest>
  debugfs -R "dump $1 $2" "$IMG" >/dev/null 2>&1
  [ -s "$2" ] || { echo "!! not in this image: $1" >&2
                   echo "!! Wrong variant? vs995 is the Verizon V20; h918/us996 ship a different IMS build." >&2
                   exit 1; }
}

echo ">> [1/3] pulling the stock IMS pieces out of $(basename "$IMG")"
pull /priv-app/Ims4/Ims4.apk                  "$W/Ims4.apk"
pull /framework/arm64/boot-ims-common.oat     "$W/boot-ims-common.oat"
pull /framework/arm64/boot-framework.oat      "$W/boot-framework.oat"
pull /bin/ipsecstarter                        "$W/bin/ipsecstarter"
pull /bin/ipsecclient                         "$W/bin/ipsecclient"
# /lib is the 32-bit tree. The 64-bit namesakes in /lib64 link-fail much later and in a way that
# does not point back here. The list lives in build-ims4.sh so the two cannot drift apart.
for l in $(sed -n 's/^LG_LIBS="\(.*\)"/\1/p' "$IMS/build-ims4.sh"); do
  pull "/lib/$l.so" "$W/lib/$l.so"
done

echo ">> [2/3] deodexing the stock framework (for the real com.android.ims parcelables)"
BUILD_ROOT="${BUILD_ROOT:-$AOSP/..}" "$HERE/forge/tools/deodex-jar.sh" \
    "$W/boot-framework.oat" "$IMG" "$W/framework-smali" >/dev/null

echo ">> [3/3] reworking Ims4 for Android 17 (minutes)"
FORGE="$HERE/forge" "$IMS/build-ims4.sh" \
    "$W/Ims4.apk" "$W/boot-ims-common.oat" "$IMG" "$W/framework-smali" "$W/lib" \
    "$IMS/Ims4-reworked.apk" "$W/bin"

# build-ims4.sh stages the IPsec helpers beside the apk itself (its step 7). Verify rather than
# assume: a missing one is a REGISTER that dies at "add policy is failed", hours later.
for f in Ims4-reworked.apk ipsecstarter ipsecclient; do
  [ -s "$IMS/$f" ] || { echo "!! $IMS/$f was not produced" >&2; exit 1; }
done
rm -rf "$W"
echo ">> volte: staged Ims4-reworked.apk, ipsecstarter, ipsecclient"
