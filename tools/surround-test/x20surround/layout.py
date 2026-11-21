# SPDX-License-Identifier: GPL-2.0-only
"""Channel layouts shared by the renderer, the checks and the conf generator."""

RATE = 48000

# Input channels of every candidate sink, in sink order (PulseAudio 7.1 map,
# the order PipeWire's sink-virtual-surround-7.1-hesuvi.conf uses).
INPUTS = ("FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR")
# Channels that carry an HRIR pair (LFE reuses the centre pair).
SPEAKERS = ("FL", "FR", "FC", "RL", "RR", "SL", "SR")
EARS = ("L", "R")

# The 14 channels of a HeSuVi HRIR file: (input channel, ear) per WAV channel.
# Verified against PipeWire 1.6.8
# src/daemon/filter-chain/sink-virtual-surround-7.1-hesuvi.conf, where
# "convFL_L ... channel = 0" up to "convFC_R ... channel = 13" give exactly
# this table. tests/test_layout.py checks it against a copy of those lines.
HESUVI = (
    ("FL", "L"),
    ("FL", "R"),
    ("SL", "L"),
    ("SL", "R"),
    ("RL", "L"),
    ("RL", "R"),
    ("FC", "L"),
    ("FR", "R"),
    ("FR", "L"),
    ("SR", "R"),
    ("SR", "L"),
    ("RR", "R"),
    ("RR", "L"),
    ("FC", "R"),
)
HESUVI_INDEX = {pair: i for i, pair in enumerate(HESUVI)}

# Loudspeaker azimuths in degrees, SOFA convention: 0 is straight ahead,
# positive is to the listener's left (counter-clockwise seen from above).
# Sides at 90 and rears at 150, the angles the removed x20-headphones sink
# used (899ba9b:docs/audio-dsp.md).
AZIMUTH = {
    "FL": 30.0,
    "FR": -30.0,
    "FC": 0.0,
    "SL": 90.0,
    "SR": -90.0,
    "RL": 150.0,
    "RR": -150.0,
}

# Which ear is on the same side as each loudspeaker (None: centre).
SIDE = {"FL": "L", "SL": "L", "RL": "L", "FR": "R", "SR": "R", "RR": "R", "FC": None}
MIRROR = {"FL": "FR", "FR": "FL", "SL": "SR", "SR": "SL", "RL": "RR", "RR": "RL", "FC": "FC"}
OTHER_EAR = {"L": "R", "R": "L"}

# What an 8-channel stream becomes on a stereo hardware sink ("raw"): the
# gain from each input channel to each ear. Measured, not assumed: an
# impulse per channel through PipeWire 1.6.11 with WirePlumber 0.5.19
# (pw-cat into a stereo null sink, tools/surround-test/pw-harness.sh raw).
# TODO(hw): repeat on the device (PipeWire 1.6.8) with `surround-test doctor`.
_S = 0.7071067811865476
RAW_DOWNMIX = {
    "FL": (1.0, 0.0),
    "FR": (0.0, 1.0),
    "FC": (_S, _S),
    "LFE": (_S / 2, _S / 2),
    "RL": (_S, 0.0),
    "RR": (0.0, _S),
    "SL": (_S, 0.0),
    "SR": (0.0, _S),
}

# WAVE_FORMAT_EXTENSIBLE channel mask of the 7.1 test streams:
# FL FR FC LFE BL BR SL SR.
MASK_71 = 0x63F

# Hardware sinks on the X20 (899ba9b:docs/audio-dsp.md).
SINK_SPEAKERS = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"
SINK_HEADPHONES = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink"


def pairs(channels):
    """Map a 14-channel list to {(input, ear): samples}."""
    if len(channels) != len(HESUVI):
        raise ValueError("expected %d channels, got %d" % (len(HESUVI), len(channels)))
    return {pair: channels[i] for i, pair in enumerate(HESUVI)}


def unpairs(table):
    """Inverse of pairs(): {(input, ear): samples} to a 14-channel list."""
    return [table[pair] for pair in HESUVI]
