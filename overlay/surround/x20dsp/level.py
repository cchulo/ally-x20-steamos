# SPDX-License-Identifier: GPL-2.0-only
"""Loudness estimate used to level-match candidates to the raw sink.

Model: uncorrelated pink noise at equal level in the seven full-range
channels (no LFE), K-weighted (ITU-R BS.1770), power averaged over both
ears. This is an electrical estimate from the filters alone; the on-device
`calibrate` step measures the real difference and corrects the remainder.
"""

from . import dsp
from .layout import EARS, RAW_DOWNMIX, RATE, SPEAKERS, pairs

# BS.1770 K-weighting at 48 kHz: high-shelf, then high-pass.
_K_SHELF = ((1.53512485958697, -2.69169618940638, 1.19839281085285),
            (1.0, -1.69065929318241, 0.73248077421585))
_K_HP = ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621))

BANDS = dsp.third_octaves(50.0, 16000.0)


def k_weight(freq, rate=RATE):
    return dsp.biquad_power(_K_SHELF[0], _K_SHELF[1], freq, rate) * dsp.biquad_power(
        _K_HP[0], _K_HP[1], freq, rate
    )


_K = [k_weight(f) for f in BANDS]


def weighted_power(h, rate=RATE):
    """K-weighted power of a response driven by pink noise (equal power per
    third-octave band)."""
    return sum(k * p for k, p in zip(_K, dsp.band_powers(h, BANDS, rate)))


def channel_powers(channels, rate=RATE):
    """{(input, ear): K-weighted power} for a 14-channel HRIR set."""
    return {pair: weighted_power(h, rate) for pair, h in pairs(channels).items()}


def loudness_db(powers, inputs=SPEAKERS):
    """Loudness in dB of the reference programme given per-pair powers."""
    total = sum(powers[(c, ear)] for c in inputs for ear in EARS)
    return dsp.db(total / len(EARS))


def raw_powers():
    flat = sum(_K)
    return {
        (c, ear): flat * RAW_DOWNMIX[c][i] ** 2 for c in SPEAKERS for i, ear in enumerate(EARS)
    }


def raw_loudness_db():
    return loudness_db(raw_powers())


def trim_db(channels, rate=RATE):
    """Gain in dB that brings a candidate to the raw sink's loudness."""
    return raw_loudness_db() - loudness_db(channel_powers(channels, rate))
