# Updates: why Google OTAs don't work, and what an update-friendly Churro would need

Status: **note for the future, nothing implemented.** Until then `firmware-lockdown` disables
`update_engine` (safety: delta OTAs fail, so Google serves a ~3 GB full OTA, seen during setup).

## Today
| | Churro | GBRUNCH |
|---|---|---|
| Kernel | rebuilt GKI on the ESP (extra drivers) | Google's original kernel + modules |
| system / super bytes | vendor + system_ext repacked inside `super` | original bytes kept on disk |
| Vendor actually used | the repacked one | a *derived vendor view* on its own partition (also modified) |
| AVB / dm-verity | vbmeta flags off | on for system; unlocked/orange overall |
| Owned config | edits inside vendor | `/oem` partition, `androidboot.init_rc=/oem/init.gbrunch.rc` |
| OTA | broken (delta OTA source check fails) | "not implemented or validated" (README) |

GBRUNCH keeps the originals *on disk*, but it boots its own vendor copy, so an OTA would update
partitions it doesn't run. Neither project gets working Google updates today.

## What an OTA needs to work
1. **Original partitions byte-identical** (`super`, `boot`, `vendor_boot`, `vbmeta`): incremental
   OTAs verify the source hashes first. → no repacking; dm-verity on.
2. **Our boot path follows the slot**: update_engine writes slot B (incl. `boot_b`, `vendor_boot_b`)
   and flips the active slot; GRUB must boot the matching slot's kernel/ramdisk (or ours, see 3).
3. **Kernel matches the new build**: Google's `vendor_dlkm`/`system_dlkm` modules are built
   against that build's GKI. A rebuilt Churro kernel would be the old version → modules refuse to
   load. Options: Google's kernel as-is (GBRUNCH) + only KMI-clean extra modules; or re-run
   `prepare` after every OTA (kernel compile — can't happen on the device).
4. **All changes outside Google's partitions**, applied at runtime from an owned partition:
   - init rc via `androidboot.init_rc` (import stock rc, override services) — GBRUNCH approach;
   - files replaced by bind mounts from `/oem` (crossystem stub, Mesa, firmware); needs SELinux
     `mounton` permissions → policy is in vendor, so this is the hard part (GBRUNCH hit it too);
   - kernel cmdline is ours (GRUB) → blacklists/`efi_pstore`/spi-intel flags survive an OTA.
5. **Safety without deleting files**: flash tools can only be neutralised (blacklisted drivers,
   bind-mounted stubs, services stopped). Each one must be re-checked against every new build;
   anything missed comes back silently after an OTA. Board RAPL/TCC `write` lines in vendor rc can't
   be removed without editing vendor (would need a later override that restores sane values).
6. **Google must serve the OTA**: unregistered device, unlocked boot, software KeyMint — it may
   never be offered. Unverified.

## Realistic alternative (simpler, keeps safety)
"Re-churro" a newer recovery image and keep the user's data: rebuild every partition except
`userdata` in place (same layout, userdata already last). Safety edits are re-applied and checked
by the build each time; no on-device update logic. Needs: same userdata format/encryption across
versions, and a build step that writes a new image onto an existing install without touching
userdata.
