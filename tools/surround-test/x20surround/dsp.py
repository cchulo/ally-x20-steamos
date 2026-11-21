# SPDX-License-Identifier: GPL-2.0-only
"""Small signal-processing helpers in plain Python.

Impulse responses here are a few thousand samples long, so plain loops are
fast enough; convolve() uses numpy when it happens to be installed.
"""

import math

try:  # optional speed-up, never required
    import numpy as _np
except ImportError:  # pragma: no cover - depends on the host
    _np = None


def db(power):
    """10*log10 of a power, with a floor instead of -inf."""
    return 10.0 * math.log10(power) if power > 1e-30 else -300.0


def amp_db(amplitude):
    return db(amplitude * amplitude)


def from_db(value):
    return 10.0 ** (value / 20.0)


def energy(h):
    return math.fsum(v * v for v in h)


def peak(h):
    return max((abs(v) for v in h), default=0.0)


def trim_tail(h, floor_db=-120.0):
    """Drop trailing samples below floor_db relative to the peak."""
    limit = peak(h) * from_db(floor_db)
    n = len(h)
    while n > 0 and abs(h[n - 1]) <= limit:
        n -= 1
    return h[:n]


def arrival(h, fraction=0.05):
    """Index where the cumulative energy reaches `fraction` of the total
    (None for a silent response). Unlike a threshold on the peak, this is
    not fooled by the pre-ringing of equalised sets (SADIE II)."""
    total = energy(h)
    if total <= 0.0:
        return None
    limit = fraction * total
    acc = 0.0
    for i, v in enumerate(h):
        acc += v * v
        if acc >= limit:
            return i
    return len(h) - 1


def power_at(h, freq, rate):
    """|H(f)|^2 of an impulse response at one frequency (Goertzel)."""
    w = 2.0 * math.pi * freq / rate
    coeff = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for v in h:
        s1, s2 = v + coeff * s1 - s2, s1
    return max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0.0)


def third_octaves(lo, hi):
    """Third-octave centre frequencies within [lo, hi]."""
    out = []
    k = -30
    while True:
        f = 1000.0 * 2.0 ** (k / 3.0)
        if f > hi * 1.0001:
            return out
        if f >= lo * 0.9999:
            out.append(f)
        k += 1


def band_powers(h, centres, rate, points=3):
    """Mean |H|^2 in each third-octave band, sampled at `points` log-spaced
    frequencies per band."""
    h = trim_tail(h)
    out = []
    for fc in centres:
        acc = 0.0
        for j in range(points):
            f = fc * 2.0 ** ((j - (points - 1) / 2.0) / (3.0 * points))
            acc += power_at(h, min(f, rate * 0.499), rate)
        out.append(acc / points)
    return out


def biquad_power(b, a, freq, rate):
    """|H(f)|^2 of a biquad given as (b0, b1, b2), (1, a1, a2)."""
    w = 2.0 * math.pi * freq / rate
    z1 = complex(math.cos(w), -math.sin(w))
    z2 = z1 * z1
    num = b[0] + b[1] * z1 + b[2] * z2
    den = a[0] + a[1] * z1 + a[2] * z2
    return abs(num / den) ** 2


def biquad_filter(x, b, a):
    """Direct form I filtering of a list."""
    out = []
    x1 = x2 = y1 = y2 = 0.0
    b0, b1, b2 = b
    _, a1, a2 = a
    for v in x:
        y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, y
        out.append(y)
    return out


def butter2(kind, freq, rate):
    """Second-order Butterworth low-pass or high-pass (RBJ cookbook, Q =
    1/sqrt(2)). Returns (b, a) with a[0] = 1."""
    w = 2.0 * math.pi * freq / rate
    cw, sw = math.cos(w), math.sin(w)
    alpha = sw / (2.0 * math.sqrt(0.5))
    a0 = 1.0 + alpha
    if kind == "lowpass":
        b = ((1.0 - cw) / 2.0, 1.0 - cw, (1.0 - cw) / 2.0)
    elif kind == "highpass":
        b = ((1.0 + cw) / 2.0, -(1.0 + cw), (1.0 + cw) / 2.0)
    else:
        raise ValueError(kind)
    return tuple(v / a0 for v in b), (1.0, -2.0 * cw / a0, (1.0 - alpha) / a0)


def fractional_delay(delay, taps=31):
    """Windowed-sinc FIR that delays by `delay` samples (may be fractional).
    The kernel is symmetric around the delay, so `delay` must be at least
    (taps - 1) / 2: callers add a bulk delay to every path instead of
    truncating the kernel."""
    half = (taps - 1) // 2
    start = int(math.floor(delay)) - half
    if start < 0:
        raise ValueError("delay %.2f is shorter than half the kernel (%d)" % (delay, half))
    out = [0.0] * (start + taps)
    for i in range(taps):
        n = start + i
        t = n - delay
        s = 1.0 if abs(t) < 1e-12 else math.sin(math.pi * t) / (math.pi * t)
        # Hann window centred on the delay.
        w = 0.5 + 0.5 * math.cos(math.pi * t / (half + 1.0)) if abs(t) < half + 1.0 else 0.0
        out[n] = s * w
    total = sum(out)
    return [v / total for v in out]


def convolve(a, b):
    if not a or not b:
        return []
    if _np is not None:
        return [float(v) for v in _np.convolve(_np.asarray(a, float), _np.asarray(b, float))]
    if len(a) < len(b):
        a, b = b, a
    out = [0.0] * (len(a) + len(b) - 1)
    for j, bv in enumerate(b):
        if bv == 0.0:
            continue
        for i, av in enumerate(a):
            out[i + j] += av * bv
    return out


def add(a, b, scale=1.0):
    """a + scale * b for lists of different lengths."""
    n = max(len(a), len(b))
    out = list(a) + [0.0] * (n - len(a))
    for i, v in enumerate(b):
        out[i] += scale * v
    return out


def delayed(h, samples):
    return [0.0] * samples + list(h)


def impulse(gain, at, length):
    out = [0.0] * max(length, at + 1)
    out[at] = gain
    return out
