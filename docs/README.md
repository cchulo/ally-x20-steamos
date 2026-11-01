# Documentation index

User-facing:

| page | what it covers |
|---|---|
| [install.md](install.md) | prerequisites, Desktop Mode install steps, what gets written where |
| [audio.md](audio.md) | speakers: the four problems, UCM overlay, firmware, ACPI override, how to verify |
| [audio-dsp.md](audio-dsp.md) | headphone virtual surround and speaker chain, knobs, verification |
| [inputplumber.md](inputplumber.md) | controller profile, hwdb autostart, fallback daemon |
| [rgb.md](rgb.md) | joystick ring RGB in Steam, effect/speed sysfs |
| [hdr.md](hdr.md) | Desktop and Game Mode HDR, the gamescope profile and wrapper |
| [kernel-modules.md](kernel-modules.md) | what is rebuilt, when, lockdown, forcing a rebuild |
| [update-survival.md](update-survival.md) | what a SteamOS update does to us and how we survive it; update policy |
| [self-update.md](self-update.md) | channels, signed tags, rollback, migrations |
| [uninstall.md](uninstall.md) | guarantees, deny-list, running from recovery media, audit |
| [notifications.md](notifications.md) | what the user notifier shows and the queue format |

Developer-facing:

| page | what it covers |
|---|---|
| [architecture.md](architecture.md) | CLI, fixture-root contract, component model, manifest, state dir |
| [contributing.md](contributing.md) | rules, workflow, dev host setup |
| [vm-testing.md](vm-testing.md) | QEMU/KVM harness, what each VM check proves |
| [etc-survival.md](etc-survival.md) | measurement template for `/etc` carry-over across slots |
| [hardware-data.md](hardware-data.md) | every fact still to be collected on a real X20 (`TODO(hw)`) |
| [xtc-notes.md](xtc-notes.md) | speaker crosstalk cancellation: why the speaker virtual surround was removed, what a better attempt needs |
| [rumble-analysis.md](rumble-analysis.md) | rumble report formats (kernel, InputPlumber, hhd), the kernel magnitude-scaling bug, speaker-hiss hypotheses and the raw-report device test |
| [../acpi/dump-dsdt.md](../acpi/dump-dsdt.md) | dumping and patching the DSDT, testing the override |
| [../build/kernel-sources.md](../build/kernel-sources.md) | where kernel sources and headers come from |
| [../patches/kernel/README.md](../patches/kernel/README.md), [README-hid.md](../patches/kernel/README-hid.md) | the kernel patches |
| [../vm/README.md](../vm/README.md) | VM research notes |
