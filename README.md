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
  It is LG's stock IMS app rebuilt for Android 17 plus a bridge into the modern telephony stack, so
  **building it needs the stock firmware you supply** — see *Build it* below and
  **[IMS.md](IMS.md)**.
- **Mobile data on a DirtySanta-unlocked handset** — the engineering bootloader leaves a flag the
  modem reads as "factory cable attached" and refuses every data call, on any ROM including the
  official nightly. A kernel patch clears it.
- **Boots enforcing** on a device tree that needed thirteen separate fixes to get there, with no
  permissive domains: the IMS stack runs under real policy rather than the usual bring-up exemption.

### What does not work

- **SMS over IMS.** Texting works over the circuit-switched path, which is what the phone uses
  today; only the IMS path is unfinished (the modem refuses the QMI WMS transport registration).
- **Wi-Fi calling and video calling.** Not offered — VT needs a media path that does not work here,
  and WFC needs an ePDG tunnel that is not ported. Both are hidden rather than left to fail.
- **RCS** is not provided by the IMS stack. Google Messages does RCS over its own backend on plain
  data, so a `full` build is the way to get it.
- **`full` builds carry MindTheGapps only** (Play Store, GMS, services framework). NikGapps has no
  Android 17 release, so Google's replacements for the stock apps are not preinstalled -- install
  them from Play. `device.conf` says to drop `WITH_GAPPS_EXTRAS=false` when that changes.

## Build it

> **VoLTE needs LG's stock firmware, which cannot be shipped here.** It is LG's own 2016 IMS app
> reworked to run on Android 17 — proprietary, so this repo carries the recipe and none of the
> ingredients.
>
> Drop a stock VS995 Nougat system image named `VS995_Stock_ROM_*.image` in the root of this repo
> and the first build rebuilds the IMS stack out of it by itself; later builds skip straight past.
> Leave it out and **the build still works** — it just ships without VoLTE, says so while it runs,
> and names the image `-novolte`. Asking for `volte` explicitly without the firmware stops the
> build rather than handing you an image that cannot place a call.
>
> An image rather than the KDZ: nothing here reads LG's container format. Extract it once with
> [kdztools](https://github.com/ehem/kdztools) — `unkdz` gives you a `.dz`, `undz` gives you
> `parts/system.image` — and **rename that to `VS995_Stock_ROM_*.image`**, because the build matches
> on the name and will not find a file still called `system.image`. Step by step, including what a
> build without VoLTE actually costs you: **[Building the IMS stack from stock
> firmware](IMS.md#building-the-ims-stack-from-stock-firmware)**.

```sh
git clone https://github.com/TheDBP/vs995-lineage.git
cd vs995-lineage
cp <kdz-extract>/parts/system.image VS995_Stock_ROM_VS9951CA.image   # optional; without it, -novolte
PRESET=clean ./forge/bootstrap.sh
```

Needs Docker and enough free disk for a full AOSP checkout plus build output. The stock KDZ and
everything derived from it stay out of this repo; nothing proprietary is committed or released.

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

## Options

Every option usable on this device's branch. They live in `forge/options/`, so they work on any
device rather than being wired into this tree; add one to a preset in `device.conf`, or to a single
build with `EXTRA_OPTIONS=`. This table is generated from the forge by
`forge/tools/gen-option-index.py` — do not edit it by hand.

<!-- options:start device -->

| option | what it does |
|---|---|
| `advanced-restart` | Advanced restart in the power menu. |
| `bringup` | adbd from boot with no authorisation prompt, plus persistent logcat, so a build that never reaches the lock screen can still be traced. **Never hand out an image built with this** — it accepts adb from any host. |
| `connectbot` | ConnectBot: an SSH client with saved hosts, keys and port forwarding. Pulls in `fdroid`. |
| `dark-default` | Default to dark theme. |
| `drm-trace` | Diagnostic: kernel trace of whoever disables a DRM plane or CRTC, for a panel that dies while the framework still thinks it is on. |
| `fdroid` | F-Droid app store + Privileged Extension (silent installs/updates). |
| `firefox` | Firefox (Fennec F-Droid) as the browser, replacing Jelly. Pulls in `fdroid`. Mutually exclusive with `fulguris`. **In no preset**: it overrides Jelly, and stages 320 MB against Fulguris's 9. |
| `fulguris` | Fulguris as the browser, replacing Jelly. Pulls in `fdroid`. A WebView browser, 9 MB where Fennec stages 320 MB. Mutually exclusive with `firefox`. **In no preset**: it overrides Jelly, so a preset carrying it ships the only browser in the image, and its first run asks you to accept terms with nothing else able to open them. |
| `gapps` | Google apps: Play Store and GMS from MindTheGapps, plus Google's versions of the stock apps. |
| `google-feed-off` | Google feed (-1 screen) off by default. |
| `home-defaults` | Home screen defaults: no icon labels, no auto-add. |
| `k9` | K-9 Mail (the Thunderbird for Android codebase) as the mail client. Pulls in `fdroid`. |
| `kdeconnect` | KDE Connect (phone <-> desktop: notifications, clipboard, files, remote input). Pulls in `fdroid`. |
| `linphone` | Linphone: a SIP client, for voice over data where the device has no VoLTE. Pulls in `fdroid`. |
| `linux` | On-device Linux environment (chroot + Docker): container kernel config and cgroup fixes. |
| `livedisplay-off` | LiveDisplay off by default. |
| `minimal-home` | Minimal home screen: hotseat only, no second page. |
| `nav-icons` | Nextbit Robin style nav-bar icons, drawn as scalable tintable vectors. |
| `nextcloud` | Nextcloud bundle: Files, Talk, NextPush, Deck, NC Passwords, Notes, DAVx5, Tasks — the current F-Droid build of each. Pulls in `fdroid`. ~600 MB against `nextcloud-core`'s ~270. Check the partition before adding either. |
| `nextcloud-core` | Nextcloud, the four that make the phone a client: Files, Talk, NextPush, DAVx5 — the current F-Droid build of each. Pulls in `fdroid`. Mutually exclusive with `nextcloud`, which already carries these four. |
| `nfc-off` | NFC off by default. |
| `oem` | The manufacturer's own boot animation, wallpapers and sounds, reclaimed from its stock ROM. Needs that phone's own stock ROM and a pack that understands its layout — see `forge/docs/OEM-ASSETS.md`. |
| `openvpn` | OpenVPN for Android (de.blinkt.openvpn) as a bundled VPN client. Pulls in `fdroid`. |
| `pong-notification` | Pong as the default notification sound (LineageOS default is Argon). |
| `root` | Magisk baked into the boot image, so the zip flashes pre-rooted. Pulls in `termoneplus`. The image flashes pre-rooted, so treat it like one. |
| `setup-mobile-data` | Mobile data usable during setup, instead of a sign-in page with no way online but Wi-Fi. |
| `setupwizard-lineage` | Use Lineage SetupWizard over Google's (WITH_GAPPS). |
| `setupwizard-nag-skip` | Skip recovery/metrics/backup setup pages. |
| `syncthing-fork` | Syncthing-Fork: continuous file sync between your own devices, no server or account. Pulls in `fdroid`. |
| `teal-skin` | Teal accent — fixed #009D94 Monet preset seed. |
| `teal-wallpaper` | Teal-shag default wallpaper (baked into framework-res). |
| `termoneplus` | TermOne Plus terminal emulator (F-Droid build). Pulls in `fdroid`. |
| `themed-icons` | Themed (monochrome) app icons on by default. |
| `volte` | The manufacturer's own IMS stack, rebuilt from its stock firmware, so the phone can place calls over LTE. Turns itself on when the phone's stock firmware is present and off when it is not, marking the build tag `-novolte` — see `forge/options/volte/README.md`. |

<!-- options:end -->
## Device patches

81 patches across 17 upstream projects, applied at build time from `overlay/patches/`. Nothing here
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

The large one — sixteen patches bringing LG's 2016 `Ims4` up on Android 17, plus an `ImsBridge`
that presents it to the modern telephony stack, the IPsec helpers its SIP registration needs, a QMI
service rule without which calls have no audio, the sepolicy that lets all of it run enforcing, and
one genuine AOSP bug fix (the compat `ImsService` path crashes the phone process).
**[IMS.md](IMS.md)** is the full account.

### Biometrics and lights

Two overlay values this device tree was carrying that described hardware it does not have, or denied
hardware it does.

`config_biometric_sensors` was still declared, which is a HIDL-era thing: a non-empty array makes
`AuthService` route biometrics through `HidlToAidlSensorAdapter` and call
`IBiometricsFingerprint.getService()`. This device is on the generic Lineage AIDL fingerprint HAL, so
there is no such service, every operation returned `BIOMETRIC_ERROR_HW_UNAVAILABLE`, and Settings
offered no fingerprint option at all. Removing the array is the fix, confirmed on hardware.

`config_deviceLightCapabilities` was overridden to `0` against a `lineage-sdk` default of `8`, which
makes `LightsCapabilities.supports()` false for every bit and gates off each LED control. Set to
`11`. **This one is config-only and not yet confirmed against the hardware**; if the panel has no
RGB LED it should drop back to `8`.

### Display and feel

420 dpi, 1.15× font scale, the 32dp status-bar override dropped so the notch strip is respected, an
auto-brightness curve, and an interactive-governor retune (table below).

## Flash it

Prebuilt images, when there are any, are on the
[Releases](https://github.com/TheDBP/vs995-lineage/releases) page. Two are published, in this order:

| preset | what it is |
|---|---|
| `stock` | LineageOS as upstream ships it plus the device patches that make this hardware work — the VoLTE stack, the kernel fixes, nothing else. No theming, no added apps. The one to flash if you want this phone working and nothing more, and the one to reproduce a bug against. |
| `libre` | the same plus F-Droid, K-9 Mail, KDE Connect and ConnectBot. No Google apps, not rooted. |

Neither carries Google apps or anything reclaimed from a manufacturer; `release.sh` refuses to
publish a build that does. Each release is two files: the ROM zip and a `<name>-recovery.img`
(Lineage recovery from the same build). A published image always carries VoLTE — a `-novolte` build
is something you get by building without the stock firmware, not something that is released.

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
