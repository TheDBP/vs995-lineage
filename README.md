# LG V20 (Verizon) — LineageOS 24.0 (Android 17)

A custom LineageOS 24.0 ROM for the **LG V20, Verizon** (`vs995`, Snapdragon 820 / msm8996, 2016),
**with working VoLTE**.

Android 17 on 2016 hardware is a stretch. LineageOS still carries the device trees, but nobody
builds this device on 24.0, so a good deal of this repo is making a 22.2-era device tree work on a
2026 platform: HALs that lost their HIDL interfaces, bpf loaders that assume a newer kernel, and a
first-stage mount that moved. The rest is the thing that actually makes the phone usable as a phone
— the 2016 LG IMS stack carrying calls on a 2026 framework.

**Status: builds, flashes, runs, and makes VoLTE calls.** Running on one V20. Hardware support is
otherwise LineageOS's for this device; what this build changes is listed below, and nothing else is
claimed.

### What works that would not otherwise

- **VoLTE — outgoing and incoming calls with two-way audio.** Carrier networks have shut down the
  2G/3G circuit-switched voice this phone shipped with, so without this the device is not a phone.
  See **[IMS.md](IMS.md)**.
- **Mobile data on a DirtySanta-unlocked handset** — the engineering bootloader leaves a flag the
  modem reads as "factory cable attached" and refuses every data call, on any ROM including the
  official nightly. A kernel patch clears it.
- **Boots enforcing** on a device tree that needed thirteen separate fixes to get there.

### What does not work

- **SMS over IMS.** Texting works over the circuit-switched path, which is what the phone uses
  today; only the IMS path is unfinished (the modem refuses the QMI WMS transport registration).
- **Wi-Fi calling and video calling.** Not offered — VT needs a media path that does not work here,
  and WFC needs an ePDG tunnel that is not ported. Both are hidden rather than left to fail.
- **RCS** is not provided by the IMS stack. Google Messages does RCS over its own backend on plain
  data, so a `full` build is the way to get it.

## Build it

```sh
git clone https://github.com/TheDBP/vs995-lineage.git
cd vs995-lineage
PRESET=clean ./forge/bootstrap.sh
```

Needs Docker and enough free disk for a full AOSP checkout plus build output.

**Output:** `build_output/src/out/target/product/vs995/lineage-24.0-*.zip`

## What you can build

One command produces one image. `PRESET` names a saved set of options:

```sh
PRESET=clean ./forge/bootstrap.sh      # or libre, or full
```

To pick options directly instead of using a preset:

```sh
OPTIONS="gapps fdroid" ./forge/bootstrap.sh
```

Options come from the forge (`forge/options/`) and behave the same on every device; what lives in
this repo's `overlay/patches/` is only what is true of this phone.

## Presets

A preset is a saved selection of options — it has no behaviour of its own. The authoritative list
is `device.conf`.

| preset | tag | adds over `clean` |
|---|---|---|
| `clean` | `turbo-clean` | nothing — this is the baseline |
| `libre` | `turbo-libre` | `fdroid`, `k9`, `kdeconnect`, `connectbot` |
| `full` | `turbo` | `gapps` plus everything in `libre` |

Every preset also gets the common options in `device.conf`: dark theme, themed icons, teal accent,
minimal home, LiveDisplay off, advanced restart, setup-wizard nag skip, and a container-capable
kernel.

`EXTRA_OPTIONS=bringup` adds adb from boot without an authorisation prompt and persistent logcat —
useful when a build does not reach the lock screen, and not something to ship to someone else.

## Device patches

71 patches across 15 upstream projects, applied at build time from `overlay/patches/`. Nothing here
is a fork: each is a single commit against the upstream tree, replayed on every build, so upstream
stays upstream and what we changed stays legible. One patch per thing it enables.

### Making a 22.2-era device tree boot on 24.0

`device/lge/msm8996-common`, `device/lge/v20-common`, `device/lge/vs995` — HIDL manifest entries for
interfaces 24.0 deleted, the IR and LiveDisplay HALs moved to AIDL, the lights and fingerprint HALs
switched to the generic Lineage AIDL services, FCM target level raised, first-stage mount of
`/system` from a ramdisk, a tmpfs on `/metadata`, and the in-kernel low memory killer enabled
because this kernel has no PSI for lmkd.

### Kernel (`kernel/lge/msm8996`)

4.4-era kernel against a 2026 userspace: `MADV_WIPEONFORK`, netlink xperms for Android 16+ policy,
the `cpuset_v2_mode` mount option, a clang fix, and the DirtySanta factory-cable flag that blocks
mobile data.

### bpf and connectivity (`packages/modules/Connectivity`, `system/bpf`)

The 24.0 bpf loaders assume a 4.14+ kernel and either hang or reboot on 4.9. These let them load
what they can and carry on instead.

### VoLTE (`device/lge/msm8996-common`, `frameworks/opt/telephony`)

The large one — fifteen patches bringing LG's 2016 `Ims4` up on Android 17, plus an `ImsBridge` that
presents it to the modern telephony stack, the IPsec helpers its SIP registration needs, a QMI
service rule without which calls have no audio, and one genuine AOSP bug fix (the compat
`ImsService` path crashes the phone process). **[IMS.md](IMS.md)** is the full account.

### Display and feel

420 dpi, 1.15× font scale, the 32dp status-bar override dropped so the notch strip is respected, an
auto-brightness curve, and an interactive-governor retune (table below).

## Flash it

Prebuilt images are on the [Releases](https://github.com/TheDBP/vs995-lineage/releases) page —
always the `libre` preset: LineageOS plus F-Droid, K-9 Mail, KDE Connect and ConnectBot, no Google
apps, not rooted. Each release is two files: the ROM zip and a `<name>-recovery.img` (Lineage
recovery from the same build).

See **[FLASHING.md](FLASHING.md)**. This is a V20 — the bootloader unlock path differs by carrier
model, and `vs995` is the Verizon variant. Do not follow `h918` or `us996` guides.

## What is different from stock LineageOS

- VoLTE (see above) — the reason this repo exists
- Themed (monochrome) icons on by default, dark theme by default, teal accent
- Minimal home screen; Google feed (−1 screen) off
- NFC off by default; LiveDisplay off; advanced restart in the power menu
- Setup wizard skips the recovery/metrics/backup nags
- 420 dpi and a 1.15× font scale, so the notch strip is not sat on by the status bar
- `libre` and `full`: F-Droid, K-9 Mail, KDE Connect, ConnectBot; `full` adds GApps
- Responsiveness tuning on the CPU governor (see below)

### About the tuning

The kernel is LineageOS's msm8996 4.4 (`CONFIG_SCHED_HMP=y`, `interactive`; no WALT, no schedutil),
so tuning is limited to what the `interactive` governor exposes:

| Knob | Stock | Here |
|---|---|---|
| little (cpu0) `go_hispeed_load` | 90 | 85 |
| little `hispeed_freq` | 960000 | 1113600 |
| little `target_loads` | 80 | `80 1113600:85 1401600:90` |
| big (cpu2) `go_hispeed_load` | 90 | 85 |
| big `hispeed_freq` | 1248000 | 1478400 |
| `input_boost_freq` | `0:1324800 2:1324800` | `0:1324800 2:1708800` |
| `input_boost_ms` | 40 | 60 |
| `sched_upmigrate` / `sched_downmigrate` | 95 / 90 | 85 / 75 |

Thermal trip points and core_ctl are deliberately untouched: on aged 2016 silicon the low trips do
real safety work. The cpufreq values above read back as set on a running vs995; the gain is not
measured.

## More

| File | What is in it |
|---|---|
| [IMS.md](IMS.md) | How VoLTE was made to work, and what is still open |
| [FLASHING.md](FLASHING.md) | Step-by-step flashing |
| [ANDROID-16.md](ANDROID-16.md) | Historical: whether this device could go past 22.2, researched before 24.0 was attempted |
| `device.conf` | Every knob this build has |

## License

Apache-2.0 — see `LICENSE`. The patches under `overlay/patches/` modify Apache-2.0 (AOSP/LineageOS)
code and carry that license.

## Support

This is unpaid work on phones their makers abandoned. If a build saved one from the drawer, [a donation](https://www.paypal.com/donate/?hosted_button_id=7U8PDZLK7742Q) keeps the next one coming.
