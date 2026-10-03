# Flashing vs995 (LG V20, Verizon) — lineage-24.0

Artifacts land in `build_output/src/out/target/product/vs995/` — the ROM zip
(`lineage-24.0-*-UNOFFICIAL-*-vs995.zip`), `recovery.img`, `boot.img` and `boot-magisk.img`.
`build_output/artifacts/` holds the same set under the full build name and survives the next build.

Data on these devices is disposable — clean-flash without ceremony.

## Always verify the device first
This build is for **vs995** (Verizon); us996/h990/ls997 have different modem and bootloader
configuration. Verify from the running system: `adb shell getprop ro.product.model` = `LG-VS995`.
The bootloader cannot tell you: a DirtySanta-unlocked VS995 runs the US996 engineering aboot, so
fastboot reports `product: msm8996 64GB`, a serial starting `LGUS996`, and `unlocked: no` -- and
flashes anyway.

## Flash
No adb? Fastboot by keys: phone off, hold **Volume Down**, plug in USB while holding. Recovery by
keys: hold **Power + Volume Down**; at the LG logo release Power for a second and press it again;
answer **Yes** twice at the reset prompt (Lineage recovery boots instead of wiping).
```sh
adb reboot bootloader
fastboot flash recovery recovery.img # the built one, not TWRP: matches the ROM's encryption
fastboot reboot                      # `fastboot boot recovery.img` is refused (unsigned image)
adb reboot recovery                  # once Android is up; or the key combo above
# This does NOT reach recovery on its own. The bootloader puts its factory-reset prompt in the
# way and Lineage recovery boots only if you answer Yes twice. Unanswered, the phone returns to
# Android and adb reports state `device`, as though the reboot never happened.
# ON THE PHONE: Factory reset -> Format data, then Apply update -> Apply from ADB
adb sideload lineage-24.0-*-vs995.zip
adb reboot -p                        # power off instead of booting
```
`full` zips carry Magisk in their boot image already. For a `clean` or `libre` zip, root afterwards
with `fastboot flash boot boot-magisk.img` (the ROM install rewrites boot).

## What this build contains
- **interactive governor and HMP retune** (device patch; full table in README.md). The values read
  back as set on a running vs995; the gain is not measured. Thermal trips and core_ctl untouched.
- **build tag** (device patch): `ro.lineage.version` ends `-UNOFFICIAL-<tag>-vs995`; the tag names
  the preset.
- With `PRESET=full`: MindTheGapps and Magisk root. Every preset: a container-capable kernel (`linux`).
- **four HALs on AIDL** (24.0 removed their HIDL interfaces): lights and fingerprint use the generic
  Lineage services, LiveDisplay uses `vendor.lineage.livedisplay-service.sdm`, and IR keeps a device
  implementation ported to AIDL because its blaster is a UART behind `libcir_driver`, not a LIRC node.

Dirty flash (same branch, keep data): skip *Format data* and just sideload.

## CONFIG_FHANDLE, and why it could now be on

`WITH_LINUX_FHANDLE=false` in `device.conf` exists because `compatibility_matrix.5.xml` required
`CONFIG_FHANDLE=n` while `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS` was `true`. On 24.0 both
sides of that changed: the matrix target level is 7, and enforcement is off because the FCM has no
kernel entry below 4.14.336 and this SoC tops out at 4.4. So the constraint that forced the flag off
is gone and dockerd could have `name_to_handle_at()` again. Not flipped yet -- it is a kernel config
change and belongs in its own flash. Everything else in the container set is on (`PID_NS`, `IPC_NS`,
`CFS_BANDWIDTH`, cgroup noprefix patch).

## Getting into recovery, and the boot loop that follows a bad one

**`fastboot reboot recovery` and `adb reboot recovery` are silently dropped on this device.** They
answer OKAY, the phone boots normally, and `ro.boot.bootreason` reads `bootloader`. The only
mechanism that works is writing the request into the BCB and doing a NORMAL reboot:

```sh
adb root
adb shell 'printf "boot-recovery" | dd of=/dev/block/bootdevice/by-name/misc bs=1 seek=0 conv=notrunc'
adb reboot
```

**A recovery image that does not boot, plus a BCB that still says boot-recovery, is a loop the phone
cannot leave.** Every power-on retries recovery, fails, reboots, and spends charge without ever
reaching Android to clear the flag; it will flatten the battery and then be too weak to hold any
mode. Always clear the flag after a failed attempt, from fastboot:

```sh
fastboot erase misc        # 0.13s, ends the loop
```

To break in when it is already looping: the battery is removable, so pull it, connect USB to the
host, hold **Volume Down**, and insert the battery while still holding -- the key is read before the
BCB, so it lands in fastboot without attempting a boot. Have something already polling for the
device (`.scratch/vs995-rescue.sh` does this several times a second); a weak cell may only hold
fastboot for a second. If the cell is flat, charge it out of the phone -- it is a BL-44E1F and a
universal charger does it. A looping phone draws more than it takes in, so charging in place does
not work.

## The recovery image has a size ceiling the partition does not explain

The recovery partition is 42,467,328 bytes, but the bootloader will not boot a recovery image much
over **28 MiB (29,360,128)**. Measured:

| image | bytes | result |
|---|---|---|
| 24.0 kernel + 22.2 ramdisk | 28,942,336 | boots |
| 22.2 recovery (stock) | 28,958,720 | boots |
| 24.0 recovery | 29,671,424 | does not boot, no kernel console |
| 22.2 kernel + 24.0 ramdisk | 29,687,808 | does not boot |

A rejected image leaves no ramoops record at all, which is how you tell it apart from a kernel that
booted and panicked. AOSP has the same class of problem and solves it the same way: see the
`rm -f .../fastbootd` block in `build/make/core/Makefile`, commented "to fit in 32MB".

Trimming that works, in order of safety: `system/bin/fastbootd` (1.4 MB, useless here -- no dynamic
partitions) and `res/images/*_text.png` (~800 KB of localized UI text; already-compressed PNGs, so
they give up nearly their full size). Keep `font.png`, `font_menu.png` and the loop frames.

## Recovery adb: 22.2 strands, 24.0 does not

22.2 recovery ships `ro.adb.secure=1`, so its adb comes up `unauthorized` and accepts no commands at
all -- not even `reboot`. Booting it without someone at the screen means a power cycle. The 24.0
recovery built with the `bringup` option has `ro.adb.secure=0`, `ro.debuggable=1` and
`persist.sys.usb.config=adb`, so it is drivable.

## Unverified on 24.0

Nothing below has run on hardware. `verify-vs995.sh` checks each one and fails loudly rather than
passing when a phone is absent.

- **eBPF will not load.** Android 17 floors its bpf maps and programs at kernel 4.9
  (`DEFINE_BPF_MAP_EXT` hardcodes `KVER_4_9`; `KVER_4_9` is the lowest constant that exists) and this
  kernel is 4.4. Expect no bpf traffic accounting or firewall, so Data Saver and per-app data
  restriction will not enforce. bonito's eight-patch suite under
  `bonito-24.0/overlay/patches/packages/modules/Connectivity` makes the failure non-fatal; all eight
  dry-run clean against this tree.
- **Backlight is linear, not gamma-corrected.** The device's HIDL light HAL applied a cube-root
  curve; the generic AIDL service scales against `max_brightness`. Low settings will read dimmer.
- **A2DP offload may be broken.** The Bluetooth audio HIDL declaration was dropped because FCM 7
  does not list it. If offload is gone, move the HAL to AIDL (bonito patch 0015) rather than
  restoring the manifest entry.
- **VINTF kernel guarantees are unasserted**, per the enforcement change above.
- **Fingerprint depends on one property.** `persist.vendor.fingerprint.type=rear`; the AIDL service
  calls `UNIMPLEMENTED(FATAL)` on a value it does not recognise, and unset reaches that branch.
