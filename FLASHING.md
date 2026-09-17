# Flashing vs995 (LG V20, Verizon) — lineage-22.2

Artifacts land in `build_output/src/out/target/product/vs995/` — the ROM zip
(`lineage-22.2-*-UNOFFICIAL-*-vs995.zip`), `recovery.img`, `boot.img` and `boot-magisk.img`.

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
# ON THE PHONE: Factory reset -> Format data, then Apply update -> Apply from ADB
adb sideload lineage-22.2-*-vs995.zip
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

Dirty flash (same branch, keep data): skip *Format data* and just sideload.

## Known limitation: CONFIG_FHANDLE is off here
`device/lge/msm8996-common/msm8996.mk` sets `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := true`,
and `compatibility_matrix.5.xml` requires `CONFIG_FHANDLE=n`. dockerd wants it on, so this device
opts out via `WITH_LINUX_FHANDLE=false` in `device.conf`. Everything else in the container set is
enabled (`PID_NS`, `IPC_NS`, `CFS_BANDWIDTH`, cgroup noprefix patch). Whether dockerd works without
`name_to_handle_at()` is untested.
