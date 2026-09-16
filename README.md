# vs995-lineage

LineageOS for the **LG V20, Verizon** (`vs995`, msm8996 / Snapdragon 820, 2016). `main` carries no
build config; each Android version is its own branch, named after the upstream LineageOS branch.

| branch | Android | status |
|---|---|---|
| [`lineage-22.2`](../../tree/lineage-22.2) | 15 | builds, flashes and runs |
| [`lineage-23.2`](../../tree/lineage-23.2) | 16 | starting point — not synced or built; the msm8996 CAF HALs have no 23.2 branch |

Upstream LineageOS still maintains this device, so the branches are customisation on top: a short
device patch series plus the shared options, built with
[rom-forge](https://github.com/TheDBP/rom-forge), vendored as `forge/` on each branch.

Installing, building, what is changed and what is not: the README on the branch.

## License

Apache-2.0 — see `LICENSE`.
