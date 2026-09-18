# LG V20 (Verizon) — LineageOS 22.2 (Android 15)

A custom LineageOS 22.2 ROM for the **LG V20, Verizon GSM-unlocked** (`vs995`, Snapdragon 820 /
msm8996, 2016).

Android 15 on 2016 hardware is a community stretch, but LineageOS still carries the device tree and
it is actively maintained, so this repo is customisation on top rather than a rescue.

**Status: builds, flashes and runs.** Running on one V20 (`full` preset). Hardware support and
limitations are official LineageOS 22.2's for this device; what this build changes is listed
below, and nothing else is claimed.

## Build it

```sh
git clone https://github.com/TheDBP/vs995-lineage.git
cd vs995-lineage
PRESET=clean ./forge/bootstrap.sh
```

Needs Docker and enough free disk for a full AOSP checkout plus build output.

**Output:** `build_output/src/out/target/product/vs995/lineage-22.2-*.zip`

## What you can build

One command produces one image. `PRESET` names a saved set of options:

```sh
PRESET=clean ./forge/bootstrap.sh      # or libre, or full
```

To pick options directly instead of using a preset:

```sh
OPTIONS="gapps root" ./forge/bootstrap.sh
```

Options come from the forge (`forge/options/`) and behave the same on every device; what lives in
this repo's `overlay/patches/` is only what is true of this phone.

## Presets

One build command produces one image. A preset is a saved selection of options — it has no
behaviour of its own.

| preset | tag | adds over `clean` |
|---|---|---|
| `clean` | `turbo-clean` | nothing — this is the baseline |
| `libre` | `turbo-libre` | `fdroid`, `firefox`, `k9`, `termoneplus`, `kdeconnect` |
| `full` | `turbo` | `fdroid`, `firefox`, `gapps`, `k9`, `termoneplus`, `kdeconnect`, `root` |

Every preset also carries the shared set, which is what makes this build look and behave the way
it does regardless of which preset you pick:

`advanced-restart` `dark-default` `google-feed-off` `home-defaults` `linux` `livedisplay-off` `minimal-home` `nav-icons` `nfc-off` `setupwizard-nag-skip` `teal-skin` `teal-wallpaper` `themed-icons`

`EXTRA_OPTIONS` adds an option to whichever preset you build, and every option added that way
appends its name to the tag:

```sh
EXTRA_OPTIONS=nextcloud PRESET=libre ./forge/bootstrap.sh   # tag turbo-libre-nextcloud
```

`oem` is in no preset and has nothing to stage here: there is no reclaimed LG pack
(`OEM_ASSET_PACK=none`), so `EXTRA_OPTIONS=oem` fails at the asset check. To use it, point
`OEM_ASSET_PACK` and `STOCK_ROM_GLOB` at a pack you have, in `device.conf.local` (gitignored).

## Options

Every option this device uses, and what each one does. They live in `forge/options/`, so they
work on any device rather than being wired into this tree.

| option | what it does |
|---|---|
| `advanced-restart` | Advanced restart in the power menu |
| `dark-default` | Default to dark theme |
| `fdroid` | F-Droid app store + Privileged Extension (silent installs/updates) |
| `firefox` | Firefox (Fennec F-Droid) as the browser, replacing Jelly |
| `fulguris` | Fulguris as the browser, replacing Jelly — a WebView browser, 9 MB where Fennec stages 320 MB. Mutually exclusive with `firefox` |
| `gapps` | Google apps: Play Store and GMS from MindTheGapps, plus Google's versions of the stock apps |
| `google-feed-off` | Google feed (-1 screen) off by default |
| `home-defaults` | Home screen defaults: no icon labels, no auto-add of new apps |
| `kdeconnect` | KDE Connect: phone <-> desktop notifications, clipboard, files, remote input |
| `linux` | On-device Linux environment (chroot + Docker): container kernel config and cgroup fixes |
| `livedisplay-off` | LiveDisplay off by default |
| `minimal-home` | Minimal home screen: hotseat only, no second page |
| `k9` | K-9 Mail (the Thunderbird for Android codebase) as the mail client |
| `nav-icons` | Nextbit Robin style nav-bar icons, drawn as scalable tintable vectors (on every preset) |
| `nextcloud` | Nextcloud bundle: Files, Talk, NextPush, Deck, NC Passwords, Notes, DAVx5, Tasks — the current F-Droid build of each, fetched at build time. `EXTRA_OPTIONS=nextcloud` on any preset, see *Presets* |
| `nfc-off` | NFC off by default |
| `oem` | The manufacturer's own boot animation, wallpapers and sounds, reclaimed from its stock ROM — no LG pack exists, see *Presets* |
| `root` | Magisk baked into the boot image, so the zip flashes pre-rooted |
| `setupwizard-nag-skip` | Skip recovery/metrics/backup setup pages |
| `teal-skin` | Teal accent — fixed #009D94 Monet preset seed |
| `teal-wallpaper` | Teal-shag default wallpaper (baked into framework-res) |
| `termoneplus` | TermOne Plus terminal emulator |
| `themed-icons` | Themed (monochrome) app icons on by default |

## Device patches

2 patches across 2 upstream projects, applied at build time from
`overlay/patches/`. Nothing here is a fork: each is a single commit against the upstream tree,
replayed on every build, so upstream stays upstream and what we changed stays legible.

One patch per thing it enables.

### `device/lge/msm8996-common`

- **interactive governor and HMP retune** — the table under *About the tuning* below; one pass
  over `init.power.sh` rather than two.

### `device/lge/vs995`

- **tag the build so a custom image is identifiable** — build tag in the zip filename and
  `ro.lineage.version` (`…-UNOFFICIAL-<tag>-vs995`), overridable via `TURBO_BUILD_ID` (how the forge
  gives each preset its tag). Set before the `common_full_phone` inherit, or `version.mk` never sees
  it.

## Flash it

Prebuilt images are on the [Releases](https://github.com/TheDBP/vs995-lineage/releases) page —
always the `libre` preset: LineageOS plus F-Droid, Firefox, K-9 Mail, TermOne Plus and KDE Connect,
no Google apps, not rooted. Each release is two files: the ROM zip and a `<name>-recovery.img`
(Lineage recovery from the same build).

See **[FLASHING.md](FLASHING.md)**. This is a V20 — the bootloader unlock path differs by carrier
model, and `vs995` is the Verizon variant. Do not follow `h918` or `us996` guides.

## What is different from stock LineageOS

- Themed (monochrome) icons on by default, dark theme by default, teal accent
- Minimal home screen; Google feed (−1 screen) off
- NFC off by default; LiveDisplay off; advanced restart in the power menu
- Setup wizard skips the recovery/metrics/backup nags
- `libre` and `full`: Firefox, F-Droid, K-9 Mail, TermOne Plus, KDE Connect; `full` adds GApps and Magisk
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
| [ANDROID-16.md](ANDROID-16.md) | Whether this device can go to Android 16 — short answer: harder than it looks |
| [FLASHING.md](FLASHING.md) | Step-by-step flashing |
| `device.conf` | Every knob this build has |

## License

Apache-2.0 — see `LICENSE`. The patches under `overlay/patches/` modify Apache-2.0 (AOSP/LineageOS)
code and carry that license.

## Support

This is unpaid work on phones their makers abandoned. If a build saved one from the drawer, [a donation](https://www.paypal.com/donate/?hosted_button_id=7U8PDZLK7742Q) keeps the next one coming.
