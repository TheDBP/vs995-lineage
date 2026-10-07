# vs995-lineage

LineageOS for the **LG V20, Verizon** (`vs995`, msm8996 / Snapdragon 820, 2016). `main` carries no
build config; each Android version is its own branch, named after the upstream LineageOS branch.

| branch | Android | status |
|---|---|---|
| [`lineage-24.0`](../../tree/lineage-24.0) | 17 | boots enforcing, **with working VoLTE** — outgoing and incoming calls, two-way audio |

Upstream LineageOS stops at 22.2 for this device, so this is not customisation on top of a
maintained build: it is a 2022-era device tree carried onto a 2026 platform, plus LG's own 2016 IMS
stack bridged into the modern telephony framework. Built with
[rom-forge](https://github.com/TheDBP/rom-forge), vendored as `forge/` on the branch.

**VoLTE matters more here than the version number.** Carriers have been retiring the 2G/3G
circuit-switched voice this phone shipped with, so without it the device is not a phone. Nobody else
has VoLTE working on this handset on LineageOS. Building it needs a stock LG firmware image you
supply — none of LG's IMS stack may be redistributed, so the repo carries the recipe and none of the
ingredients. A build without that firmware still works; it just ships without VoLTE and says so.

Android 16+ was supposed to be out of reach on a 4.4 kernel, for want of eBPF features it does not
have. It is reachable, with the bpf loaders patched to carry on with what the kernel can give them
instead of hanging.

Installing, building, what is changed and what is not: the README on the branch.

## License

Apache-2.0 — see `LICENSE`.
