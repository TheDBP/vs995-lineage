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

## Reading a failed boot: fastboot means init died, a loop means the kernel died

Two outcomes, and they are not interchangeable:

- **Back in fastboot by itself within ~60 s.** Android `init` chose it: `InitFatalReboot` (target
  `androidboot.init_fatal_reboot_target`, default bootloader) or a service with
  `reboot_on_failure reboot,bootloader,...` -- in Android 17 only `apexd-bootstrap` has that.
  The kernel booted, the linker worked, init started. The fastboot session erases ramoops.
- **Looping on the LG logo, never reaching USB.** The kernel panicked (an init that *exits* is
  "Attempted to kill init" -- also a panic), or init asked for a plain reboot. The ramoops record
  survives the warm reboot, but not a fastboot session or a key-combo reset.

There is **no size ceiling**: a 30 MB boot image boots. An image that "fails silently" is failing
for the reasons below.

### Getting the console out of a loop

`reboot recovery` and a `boot-recovery` BCB in `misc` are both honoured by this bootloader. The
loop never gets to either on its own, so wrap the real first-stage init: a boot image whose ramdisk
is the recovery ramdisk (it has `toybox` and a shell) plus the 24.0 `init` as `/init.boot` and a
`/wrap.sh` run via `rdinit=/wrap.sh`. The script mounts `pstore`, copies the previous iteration's
`console-ramoops-0` into `misc` at 16 MiB (32 MiB partition; the bootloader and recovery only use
the first few KiB, and recovery zeroes the BCB on start), arms the BCB once it has saved something,
removes `/system/bin/recovery` so init takes the normal path, and `exec`s `/init.boot`. The loop runs
twice and lands in recovery; read misc with
`dd if=/dev/block/sda5 bs=4096 skip=4096 count=512 | tr -d '\000'`.
A *hang* (no reboot) leaves nothing in ramoops after the forced power-off, so the wrapper also forks
a watchdog before exec'ing init: under `toybox unshare -m`, a tmpfs chroot holding `toybox`, the
`misc`/`kmsg` nodes and `/proc`; at the timeout (150 s default) it writes `dmesg` to misc at 16 MiB,
arms the BCB and `echo b > /proc/sysrq-trigger`. `forge/tools/boot-console-wrap.sh` builds the
image from the build's boot.img + recovery.img (`HOST_BIN=build_output/src/out/host/linux-x86/bin`;
permissive by default, which shows everything behind the first denial; `--timeout 1800` keeps the
system up for logcat) and `pull` reads the slots back from recovery. `--enforcing` is two boots:
after the policy loads the watchdog is in the `kernel` domain and can only sleep (mksh builtin --
a toybox `sleep` fails and the old tick counter fired sysrq at 19.7 s into a healthy boot) and
write sysrq, so it just resets at the timeout; console-ramoops survives that reset on this device,
and the next boot of the image saves it and goes to recovery. No DIAGLOG slot enforcing. It must be invisible to init: `FreeRamdisk` deletes the rootfs
after `switch_root`, and `SwitchRoot` MS_MOVEs every mount it can see and `PLOG(FATAL)`s when one
cannot land on the read-only system (`mkdir /system/diag` fails -> fastboot). Hand off with a
`/diag-ready` marker so the mounts are already private before init starts.
Traps, each of which cost a flash: PID 1 starts with fds 0-2 closed, no `/proc` and (recovery
ramdisk) an empty `/dev`. bionic `_exit(1)`s every process except PID 1 whose stdio is closed when
neither `/dev/null` nor `/sys/fs/selinux/null` opens, so not even `toybox mknod /dev/null` runs:
`: > /dev/null; exec 0</dev/null 1>/dev/null 2>/dev/null` first, then mknod the real nodes and
`exec 0</dev/null 1>/dev/kmsg 2>&1`. Broken, the kernel panics `Attempted to kill init!
exitcode=0x00000100` 16 ms after "Freeing unused kernel memory" (ramoops survives that one). bionic
cannot find a binary by bare name without `/proc/self/exe`, so mount `/proc` and call
`/system/bin/toybox` by absolute path. Dry-run the script from recovery with the fds closed INSIDE
the chroot shell -- `toybox unshare -p -f chroot <rd> /system/bin/sh -c 'exec <&- >&- 2>&-; exec
/dry.sh'` -- closing them outside tests nothing because `env`/`unshare`/`chroot` re-open them. A
dry run that reaches the misc write leaves a slot that reads like a real boot; zero the slots first. `fakeroot` state dies with its session: `mknod` and `cpio`
must run in the same `fakeroot sh -c`, or the nodes become empty regular files and `dd` to
`/dev/misc` "succeeds" into the ramfs. Check the archive with `cpio -tv`.

### The twelve things that stopped 24.0 booting on this kernel

With 1-5 fixed the system boots on this kernel (2026-10-03, `androidboot.selinux=permissive` on the
wrap image): sdk 37, vold up, adbd `device` at ~110 s, display stuck on the LG logo (6). With 1-7
and the three platform patches below the system boots ENFORCING (2026-10-04, build 12): adb
`device`, surfaceflinger and the SDM composer up, boot animation drawing, then (8).

1. **SELinux policy does not load.** Android 16+ policy carries netlink-message xperms rules
   (`AVTAB_XPERMS_NLMSG`, specified=3); the 4.4 avtab parser's "Android M compatibility" heuristic
   takes any unknown xperms type as a pre-xperms policy, switches format, and desyncs
   (`SELinux: avtab: invalid type or class`). init reboots to the bootloader; recovery and system
   both die here. Kernel patch "selinux: accept netlink xperms rules". Test a policy against a
   running kernel with ONE write -- `cat` chunks and the first chunk alone reads as
   "ebitmap: truncated map":
   `adb shell 'dd if=/tmp/sepolicy of=/sys/fs/selinux/load bs=$(stat -c %s /tmp/sepolicy) count=1'`
2. **No first-stage fstab.** Android 17 removed device-tree fstab support from libfstab
   (`system/fs/fs_mgr` b474d16b), so `firmware/android/fstab/system` in the DT is ignored; first
   stage finds no fstab, exits, kernel panics, continuous loop. Fix: `fstab.qcom` copied into the
   boot ramdisk with `/system` marked `first_stage_mount` and addressed as
   `/dev/block/by-name/system` -- `/dev/block/bootdevice` is a second-stage symlink.
3. **cgroup setup fails.** Android 17 mounts cpuset with `cpuset_v2_mode` (Linux 4.15+); this
   kernel returns ENOENT for the unknown token, `SetupCgroups` aborts, no service can get a process
   group, `apexd-bootstrap` fails and its `reboot_on_failure` lands in fastboot. Kernel patch
   "cgroup: accept the cpuset_v2_mode mount option".
4. **vold cannot link.** `msm8996.mk` copied the VNDK v32 `libhardware_legacy.so` over the system
   one; it NEEDs `android.system.suspend@1.0.so`, gone in 17. Every system binary linking it fails
   (vold, audioserver, dumpstate, libandroid_runtime, libandroid_servers); vold's
   `reboot_on_failure` gives a `reboot,vold-failed` loop. A bionic link failure is `_exit(1)` with
   the message on stderr only -- the console shows just "exited with status 1", even for a daemon
   that logs to kmsg. Find it from recovery: mount system ro, bind `/dev`, mount `proc`/`sysfs`,
   tmpfs on `<root>/linkerconfig`, then
   `chroot <root> /system/bin/bootstrap/linker64 /system/bin/vold --help` prints the
   `CANNOT LINK EXECUTABLE ... library X not found` line (`/system/bin/linker64` is a symlink into
   the runtime APEX, dead in a chroot; a missing `libandroidicu.so` is the i18n APEX, not a bug).
   Device patch "stop overriding libhardware_legacy with the VNDK v32 prebuilt".
5. **netbpfload refuses the kernel.** `Android S & T require kernel 4.9.` -> exit 3 ->
   `reboot,bpfloader-failed` loop. The 4.4 kernel's bpf UAPI is the same Android backport
   msm-4.9 carries (identical helper/program/map/attach lists), so the device sets
   `ro.bpf.kver_override=4.9.0` -- read only by netbpfload, netd and the platform bpfloader --
   and takes bonito's Connectivity and system/bpf series for a 4.9 kernel unchanged.

6. **No display: libui dropped gralloc 2/3.** On sdk >= 36 `GraphicBufferMapper` loads only
   mapper 4/5 (`require_gralloc4_or_newer`); this vendor has allocator@2.0/mapper@2.1 over
   `gralloc.msm8996.so`. composer@2.1-service aborts `gralloc-mapper is missing`, surfaceflinger
   dies on the dead composer, its `onrestart` kills zygote, and audioserver/media/netd/wificond
   follow every ~5 s -- `logcat -b crash` names them in that order. Lineage keeps gralloc 2/3
   behind `soong_config libui.legacy_gralloc`; device patch 0019 sets it.
7. **`/dev/ion` is labeled `device`.** Android 17 `system/sepolicy` dropped the `/dev/ion` entry
   and the coredomain ion rules; the composer and keymaster are denied. Device patch 0020
   includes Lineage's `device/lineage/sepolicy/libion/sepolicy.mk`.
8. **The odm sepolicy files are unreadable.** Vendor is inside the system image here
   (`/vendor -> /system/vendor`), so the image builder labels them by `/system/vendor/odm/...`,
   which no odm rule in `system/sepolicy/private/file_contexts` matches (only the odm_dlkm rules
   carry `system/vendor/...`); the subtree is `vendor_file`, system_server dies in
   PackageManagerService with `Unable to load SELinux MMAC policy`, zygote restarts every ~5 s
   behind a boot animation that never ends. `overlay/patches/system/sepolicy/0001` adds the
   alternative to every odm rule (build 13: labels right, system_server past PackageManager).
9. **The IR HAL has no SELinux domain.** Device patch 0003 renamed the binary to
   `android.hardware.ir-service.lge` but left `sepolicy/vendor/file_contexts` on the old
   `ir@1.0-service.lge` name, so the binary is `vendor_file`; init never starts a service it
   cannot find a domain for, the VINTF fragment still declares `IConsumerIr/default`, and
   `ConsumerIrService` blocks system_server's main thread in `waitForDeclaredService` until the
   Watchdog kills it (`*** GOODBYE!`, every ~105 s, boot animation forever). Fixed inside 0003.
   Check every `service` line's binary against the image before flashing:
   `forge/tools/check-service-domains.sh <system.img>`.
10. **Camera and fingerprint blobs name framework libraries the vendor namespace cannot load.**
   `camera.msm8996.so`, `libmmcamera2_stats_modules.so`, `libarcsoft_beauty_shot.so` and
   `libmpbase.so` carry `DT_NEEDED libandroid.so`; `fpc_early_loader` and both `libfpfactory.so`
   carry `libandroid_runtime.so`; `libfilm_emulation.so` carries `libjnigraphics.so`. Vendor is
   inside system here but the `[vendor]` linker namespace still applies (`/vendor/bin` is
   realpath'd to `/system/vendor/bin`), and it reaches system only for the LLNDK, which none of
   these are: the camera provider@2.4 fails init and restarts every 5 s, `mm-qcamera-daemon` and
   `fpc_early_loader` die with `CANNOT LINK EXECUTABLE ... not found`. No vendor linker.config is
   possible without a vendor image. None of the eight blobs imports a symbol from the library it
   names, so `overlay/blob-fixups` drops the entries with patchelf at overlay time
   (`forge/tools/blob-fixups.sh`; same edit Lineage's xiaomi msm8996 extract-files makes). Find
   these from the out tree, not the phone:
   `forge/tools/check-vendor-needed.sh --import-check . out/target/product/vs995`. Goes in build 15.
11. **No `/metadata`, so no aconfig flags, so system_server dies.** Android 17 reads aconfig flags
   from `/metadata/aconfig/{maps,boot,flags}`, which aconfigd populates in `post-fs`. This device
   has no metadata partition, and the system-as-root image had no `/metadata` directory at all:
   every aconfigd service stayed `stopped`, `AconfigPackage.load` returned
   `ERROR_PACKAGE_NOT_FOUND` for every package, and `AdvancedProtectionConfigLoader` turns an
   unreadable flag into `IllegalArgumentException: Invalid feature flag` -- fatal in
   system_server, every ~20 s, boot animation forever (build 14). Fix (patch 0021, the Lineage
   sony/nile-common pattern): `BOARD_USES_METADATA_PARTITION := true` creates the mount point,
   `init.target.rc` `on fs` mounts `tmpfs` there (`size=10m`) after `mount_all`, and vendor
   sepolicy grants the fourteen public `*_metadata_file` types `tmpfs:filesystem associate`
   (`tmpfs` is `fs_type`, so without it init's labelled `mkdir`s are denied). The three
   private-only types (tradeinmode, prefetch, libprocessgroup) cannot be named in vendor policy;
   those `mkdir`s fail and nothing needs them. Nothing under `/metadata` survives a reboot: flag
   overrides, bootstat, watchdog state. The unused `encrypt` partition (sda10, labelled
   `metadata_block_device` already) is the persistent alternative if that ever matters. Static
   check before flashing: the root of `system.img` must contain `metadata`. Goes in build 15.

12. **lmkd cannot start, so every oom-adj update stalls 3 s, so the network stack ANRs and
   system_server dies.** Android 17's lmkd knows two pressure sources only: PSI, or the in-kernel
   `lowmemorykiller` module; the vmpressure/memcg-v1 path 22.2 fell back to is gone, and 24.0's
   `cgroups.json` puts the memory controller in cgroup2. This kernel has no PSI
   (no `/proc/pressure`) and the stock defconfig left `CONFIG_ANDROID_LOW_MEMORY_KILLER` unset, so
   lmkd logs `Old kill strategy can only be used with v1 cgroup hierarchy` / `Failed to initialize
   PSI monitors` and exits; init restarts it forever and `/dev/socket/lmkd` never appears.
   `ProcessList.writeLmkd()` then waits 3 s per call under the AMS lock ("Failed to connect to lmkd,
   retry after 1000 ms"), ANRs pile up (systemui, phone, nfc, TelecomService 24 s), the network
   stack is killed for its ANR and system_server dies with `IllegalStateException: Lost network
   stack` every ~80 s (build 15). Fix (kernel patch 0005): `CONFIG_ANDROID_LOW_MEMORY_KILLER=y`
   in `lge_msm8996_defconfig`; lmkd sees `/sys/module/lowmemorykiller/parameters/minfree` and uses
   the in-kernel interface. Static check: `CONFIG_ANDROID_LOW_MEMORY_KILLER=y` in the built
   kernel `.config` (`/proc/config.gz` on the device). Known residue: after `dev.bootcomplete` AMS
   sends `LMK_START_MONITORING`, which in in-kernel mode makes lmkd exit once ("Failure to
   initialize monitoring"); init restarts it and it stays up. Goes in build 16.

Three platform patches taken from bonito once adb was alive, all confirmed in build 12:
`hardware/interfaces` libhealthloop (`filterPowerSupplyEvents.o` needs a 5.3 loop verifier;
without it bpfloader exits 121), `system/memory/libmeminfo` (`gpuMem.bpf` needs the
`gpu_mem_total` tracepoint this kernel lacks; `BpfMapRO` must not abort system_server) and
`frameworks/base` SystemServiceRegistry (one wtf per missing service).

Still seen enforcing after (8), none of them boot-blocking: livedisplay-sdm SIGABRT "DisplayModes
backend not ready"; `timeInState.bpf` fails with ESRCH; `bpf.progs_loaded` stays unset though
netd runs; qseecomd exit 255; `xtwifi-inet-agent` needs a
`libcurl.so` no image carries (same on 22.2; GNSS runs through the qti HAL regardless).

Sandbox a candidate `init` on the running recovery before flashing: copy it to a tmpfs, bind-mount
an empty file over `/system/bin/init` so second stage cannot exec, mount selinuxfs under the chroot,
and run `toybox unshare -f -p -m chroot <root> /mnt/init selinux_setup`. In a child PID namespace
its `reboot()` only kills the sandbox. It runs the whole `selinux_setup` stage (policy load,
enforcing, restorecon) and sets the live kernel enforcing -- `setenforce 0` afterwards.

## Recovery adb: use Enable ADB in the menu

Unattended reflash from a running system: `adb reboot sideload-auto-reboot` -- this recovery
honours that BCB argument (it ignores `--wipe_data` given the same way), `adb devices` shows
`sideload` ~50 s later, `adb sideload <zip>` installs and reboots with no menu interaction.

22.2 recovery ships `ro.adb.secure=1`, so adb is `unauthorized` until someone selects
**Advanced -> Enable ADB** on the screen; after that it is a root shell. Booting it without someone
at the phone means a power cycle. The 24.0 recovery built with the `bringup` option has
`ro.adb.secure=0`, `ro.debuggable=1` and `persist.sys.usb.config=adb`, so it is drivable unattended.

Do not `fastboot erase userdata` or `erase cache` on this device: the fstab has no `formattable`
flag, init cannot mount `/data`, and every boot goes to recovery -- which looks exactly like a ROM
that does not boot. Wipe from the recovery menu.

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
