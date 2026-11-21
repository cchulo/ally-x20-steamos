# SPDX-License-Identifier: GPL-2.0-only
"""Signal processing for component surround (docs/surround.md): crosstalk
cancellation for the built-in speakers (xtc), the level estimate (level) and
the offline checks (checks) of a 14-channel HeSuVi impulse response set.

Standard library only: overlay/bin/x20-surround.py runs it on the device,
which has no numpy. The modules are those of the test rig of pull request
#70 (tools/surround-test/x20surround), without its manifest handling.
"""
