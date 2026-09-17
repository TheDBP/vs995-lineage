# vs995 (LG V20) and Android 16 — where things actually stand

Researched 2026-09-09. See `forge/docs/lineage-branches.md` for the branch picture for all three devices.

## There is no upstream 23.x tree for this device

```
android_device_lge_vs995            newest branch: lineage-22.2
android_device_lge_msm8996-common   newest branch: lineage-22.2
```

LineageOS stopped at Android 15 for the V20 family. So unlike bonito there is no 23.x tree to
evaluate -- and also no stale one to be misled by. An A16 port means carrying our 22.2 tree forward
ourselves, the same shape as the ether 18.1 -> 20.0 work.

## The upside: our base is current and healthy

| tree | last upstream commit |
|---|---|
| `android_device_lge_vs995` | 2026-06-06 |
| `android_device_lge_msm8996-common` | 2026-07-19 |

Both were maintained through mid-2026 -- **more recently than bonito's 22.2**, which stopped in
2025-11. Starting from a tree upstream was still actively fixing is a materially better position
than starting from an abandoned one.

## Assessment

Of the three devices, this is the **strongest lineage-23.2 candidate**:

- current, actively-maintained 22.2 base
- `msm8996` has far better legacy-CAF support than ether's `msm8992` -- more devices carried it
  forward, so more of the shim work already exists upstream
- no stale-branch trap to fall into
- the measured device-tree cost of 22.2 -> 23.2 is small (see the branch doc); the real work is
  vendor-blob and HAL compatibility

Target `lineage-23.2` (`android-16.0.0_r4`), never 23.0 or 23.1 -- both froze on 2025-12-27.

Dependencies: `android_device_lge_v20-common`, and via msm8996-common: `android_hardware_lge`,
`android_kernel_lge_msm8996`, `android_hardware_sony_timekeep`.

Reference trees were read from local clones; nothing from them is committed here.

---

## CORRECTION (2026-09-09, same day): the CAF HALs are the problem

The assessment above -- "strongest lineage-23.2 candidate" -- was made from device-tree health
alone, before checking whether this SoC's CAF HAL trees were carried forward. They were not.

| `hardware/qcom-caf/msm8996` | newest LineageOS branch |
|---|---|
| audio  | **lineage-22.2** |
| display | lineage-23.0 |
| media  | lineage-23.0 |

There is **no msm8996 CAF tree on 23.2 for any of the three**. A 23.2 V20 would mean carrying all
three forward ourselves -- audio across two Android versions of CAF drift, display and media across
one. Audio HALs are the worst of those to port.

That is a materially larger job than the device-tree carry-forward this doc originally described,
and it is the kind of work that consumed the ether 18.1 -> 20.0 port.

The good news still stands: msm8996 IS in QCOM_BOARD_PLATFORMS on 23.2, and 23.2 replaced the
BOARD_SEPOLICY_M4DEFS SoC list with a check on BOARD_VENDOR_SEPOLICY_DIRS, so neither of the two
silent-gating traps that cost days on ether applies here.

**Revised view: bonito is the better first Android 16 target**, despite its worse device-tree
situation -- it depends on hardware/google/* rather than per-SoC CAF trees. See
`ANDROID-16.md` on the `lineage-22.2` branch of [TheDBP/bonito-lineage](https://github.com/TheDBP/bonito-lineage).

---

## The kernel gate (2026-09-17): Android 16+ needs eBPF that 4.4 does not have

Bigger than the CAF HALs. LineageOS's [Changelog 30](https://lineageos.org/Changelog-30/): Android
16 "requires Linux 5.4 and above, and ... the necessary features have only been properly backported
as far back as 4.14. Unfortunately, LineageOS 22.2 still supports many devices running 4.4 and 4.9.
As of now, no complete backports of the required features exist for these kernels." Their own
MSM8996 common kernel (4.4) is listed for Android 13–15 only.

vs995 is `kernel/lge/msm8996` at 4.4.302. Qualcomm shipped msm8996 on 3.18 and 4.4 and nothing
later; the only newer kernel for the SoC is mainline (no vendor HALs, no modem, no camera).

So 23.2 and 24.0 have the same first cost: the 4.14-era eBPF backport set adapted onto 4.4 — a
generation further back than bonito's 4.9, so harder. Nothing in this repo starts it. On 22.2 the
loader only warns below 4.19 (`NetBpfLoad.cpp`: "Android V requires kernel 4.19."); what 16's
loader does below 4.14 has not been read here. LineageOS's statement is that the features are
required, not advisory.

**Decision 2026-09-17:** the `lineage-23.2` branch of this repo was removed. bonito goes first
(`lineage-24.0`, Android 17); the V20 follows only if that works, and only once an eBPF backport
onto 4.4 exists. Nothing 16-specific is worth carrying when the gate is the same for 17.
