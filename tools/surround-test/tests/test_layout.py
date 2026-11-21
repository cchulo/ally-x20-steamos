# SPDX-License-Identifier: GPL-2.0-only
import math

from x20surround import layout

# The convolver lines of PipeWire 1.6.8
# src/daemon/filter-chain/sink-virtual-surround-7.1-hesuvi.conf, reduced to
# (convolver name, WAV channel): "convFL_L ... channel = 0" and so on.
UPSTREAM = [
    ("convFL_L", 0), ("convFL_R", 1), ("convSL_L", 2), ("convSL_R", 3),
    ("convRL_L", 4), ("convRL_R", 5), ("convFC_L", 6), ("convFR_R", 7),
    ("convFR_L", 8), ("convSR_R", 9), ("convSR_L", 10), ("convRR_R", 11),
    ("convRR_L", 12), ("convFC_R", 13),
]
# ... and its sink: audio.position = [ FL FR FC LFE RL RR SL SR ].
UPSTREAM_INPUTS = ["FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR"]


def test_hesuvi_order_matches_upstream():
    assert len(layout.HESUVI) == 14
    for name, channel in UPSTREAM:
        speaker, ear = name[4:].split("_")
        assert layout.HESUVI[channel] == (speaker, ear)
        assert layout.HESUVI_INDEX[(speaker, ear)] == channel


def test_inputs_match_upstream():
    assert list(layout.INPUTS) == UPSTREAM_INPUTS
    assert set(layout.SPEAKERS) == set(UPSTREAM_INPUTS) - {"LFE"}


def test_angles_are_mirrored_and_sides_match():
    for c, az in layout.AZIMUTH.items():
        assert layout.AZIMUTH[layout.MIRROR[c]] == -az
        want = None if az == 0 else ("L" if az > 0 else "R")
        assert layout.SIDE[c] == want
    assert layout.AZIMUTH["FL"] == 30 and layout.AZIMUTH["SL"] == 90 and layout.AZIMUTH["RL"] == 150


def test_raw_downmix_is_the_measured_matrix():
    s = math.sqrt(0.5)
    assert layout.RAW_DOWNMIX["FL"] == (1.0, 0.0)
    assert layout.RAW_DOWNMIX["FR"] == (0.0, 1.0)
    assert layout.RAW_DOWNMIX["FC"] == (s, s)
    assert layout.RAW_DOWNMIX["LFE"] == (s / 2, s / 2)
    for c in ("SL", "RL"):
        assert layout.RAW_DOWNMIX[c] == (s, 0.0)
    for c in ("SR", "RR"):
        assert layout.RAW_DOWNMIX[c] == (0.0, s)


def test_pairs_roundtrip():
    chans = [[float(i)] for i in range(14)]
    table = layout.pairs(chans)
    assert table[("FC", "R")] == [13.0]
    assert layout.unpairs(table) == chans


def test_71_mask_is_fl_fr_fc_lfe_bl_br_sl_sr():
    assert layout.MASK_71 == 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x200 | 0x400
