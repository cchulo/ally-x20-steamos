# Components

One file per fix. The contract is documented in [`lib/component.sh`](../lib/component.sh)
and [`docs/architecture.md`](../docs/architecture.md). Summary:

| symbol | required | purpose |
|---|---|---|
| `COMPONENT_DESCRIPTION` | yes | one line |
| `<name>_files` | yes | tab-separated `src dest mode [slot]` lines; `src` relative to `overlay/` |
| `<name>_probe` | yes | 0 superseded by stock SteamOS, 1 still needed, 2 unknown |
| `<name>_apply` | no | extra idempotent steps after files are installed |
| `<name>_status` | no | override `active|stock|superseded|n/a` computation |
| `<name>_remove` | no | extra cleanup before manifest-driven removal |

Rules: never write outside `manifest_install_file` / `manifest_install_symlink`;
build every path with `ax20_path`; stay bash-3.2 compatible; add a bats file
under `tests/components/<name>.bats` with fixture roots for "stock lacks X"
and "stock has X".
