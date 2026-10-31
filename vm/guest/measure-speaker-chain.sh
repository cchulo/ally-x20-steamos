#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/measure-speaker-chain.sh — measure peak level and digital clipping
# of the X20 speaker chains (docs/audio-dsp.md, "Headroom"). Runs on the
# device (or in the VM) as the desktop user, inside the PipeWire session,
# NOT as root.
#
# Usage:
#   measure-speaker-chain.sh [run] [--point hw|speakers|surround|NODE]
#                            [--sink NODE] [--seconds N] [--out DIR]
#                            [--method pw|parec]
#       Generate the worst-case 7.1 test file, play it (through the router,
#       or into --sink), record the measurement point while it plays, print
#       peak dBFS and the share of clipped samples.
#   measure-speaker-chain.sh generate <out.wav> [seconds-per-segment]
#   measure-speaker-chain.sh analyze <recording.wav>
#
# Measurement points (--point, default hw):
#   hw        the hardware sink's monitor: what reaches the DAC/amps. Taken
#             in float before the conversion to the device format, so
#             samples above full scale are still visible (>= 1.0 = clipped
#             at the conversion).
#   speakers  the x20-speakers.output stream (output of the plain chain)
#   surround  the x20-speakers-surround.output stream (output of the speaker
#             surround chain, before x20-speakers)
#   NODE      any node.name (a sink is recorded through its monitor)
#
# Test file, 8 channels FL FR FC LFE RL RR SL SR, 48 kHz, three segments:
#   1. coherent: the same 100 Hz-10 kHz log sweep on all 7 full-range
#      channels at -1 dBFS, a 60 Hz sine on LFE at -1 dBFS (worst case)
#   2. uncorrelated: independent noise on every channel, peaks at -1 dBFS,
#      LFE 60 Hz at -1 dBFS (a loud game scene)
#   3. LFE only: 60 Hz at -1 dBFS
#
# The file names start with "x20-measure-": pw-cat uses the file name as
# media.name, which is how the link report finds the two streams.
#
# Recording, PipeWire 1.6: pw-record --target <node.name> (a node NAME or
# object.serial; a plain object id is not a valid target and silently falls
# back to the default source, which records silence), plus
# -P '{ stream.capture.sink = true }' for a sink so WirePlumber links its
# monitor ports. --method parec records the pulse monitor source
# <sink>.monitor instead (sinks only). The script prints what the recorder
# was actually linked to, so a wrong link is visible.
set -eu

MS_RATE=48000

ms_die() {
    printf 'measure-speaker-chain: error: %s\n' "$*" >&2
    exit 2
}

# ms_generate <out.wav> [seconds per segment]
ms_generate() {
    python3 -I - "$1" "${2:-4}" <<'PY'
import math, random, struct, sys, wave
path, seg = sys.argv[1], float(sys.argv[2])
RATE = 48000
n = int(RATE * seg)
peak = 10 ** (-1 / 20)
rng = random.Random(20)
frames = bytearray()
pack = struct.Struct('<8h').pack
def s16(v):
    return max(-32768, min(32767, int(round(v * 32767))))
# 1. coherent sweep on the 7 full-range channels, 60 Hz LFE
f0, f1 = 100.0, 10000.0
k = math.log(f1 / f0)
for i in range(n):
    t = i / RATE
    x = peak * math.sin(2 * math.pi * f0 * seg / k * (math.exp(t / seg * k) - 1))
    lfe = peak * math.sin(2 * math.pi * 60 * t)
    v = s16(x)
    frames += pack(v, v, v, s16(lfe), v, v, v, v)
# 2. uncorrelated noise (uniform, peak -1 dBFS), 60 Hz LFE
for i in range(n):
    t = i / RATE
    lfe = s16(peak * math.sin(2 * math.pi * 60 * t))
    c = [s16(peak * (2 * rng.random() - 1)) for _ in range(7)]
    frames += pack(c[0], c[1], c[2], lfe, c[3], c[4], c[5], c[6])
# 3. LFE only
for i in range(n):
    t = i / RATE
    frames += pack(0, 0, 0, s16(peak * math.sin(2 * math.pi * 60 * t)), 0, 0, 0, 0)
w = wave.open(path, 'wb')
w.setnchannels(8)
w.setsampwidth(2)
w.setframerate(RATE)
w.writeframes(bytes(frames))
w.close()
PY
}

# ms_analyze <file.wav> : peak dBFS, clipped share, per channel and overall.
# Reads PCM 16/24/32 and IEEE float WAV (also WAVE_FORMAT_EXTENSIBLE), which
# the stdlib wave module cannot (no float support).
ms_analyze() {
    python3 -I - "$1" <<'PY'
import array, math, struct, sys
data = open(sys.argv[1], 'rb').read()
if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
    sys.exit('not a WAV file: ' + sys.argv[1])
pos, fmt, raw = 12, None, None
while pos + 8 <= len(data):
    cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
    body = data[pos + 8:pos + 8 + size]
    if cid == b'fmt ':
        fmt = body
    elif cid == b'data':
        # a recorder killed before it fixed the header leaves 0 or 0xFFFFFFFF
        if size == 0 or size == 0xFFFFFFFF or pos + 8 + size > len(data):
            body = data[pos + 8:]
        raw = body
    pos += 8 + size + (size & 1)
if fmt is None or raw is None:
    sys.exit('WAV without fmt or data chunk')
tag, ch, rate = struct.unpack('<HHI', fmt[:8])
bits = struct.unpack('<H', fmt[14:16])[0]
if tag == 0xFFFE and len(fmt) >= 26:
    tag = struct.unpack('<H', fmt[24:26])[0]
if tag == 3 and bits == 32:
    s = array.array('f')
    s.frombytes(raw[:len(raw) // 4 * 4])
    full = 1.0
elif tag == 1 and bits in (16, 32):
    s = array.array('h' if bits == 16 else 'i')
    s.frombytes(raw[:len(raw) // (bits // 8) * (bits // 8)])
    full = float(2 ** (bits - 1))
elif tag == 1 and bits == 24:
    s = [int.from_bytes(raw[i:i + 3], 'little', signed=True) for i in range(0, len(raw) - 2, 3)]
    full = float(2 ** 23)
else:
    sys.exit('unsupported WAV format tag %d, %d bits' % (tag, bits))
if sys.byteorder != 'little' and not isinstance(s, list):
    s.byteswap()
# float: clipped = |x| >= 1.0 (clipped at the conversion to the device);
# integer: clipped = sample at the rails
limit = 1.0 if tag == 3 else (full - 1) / full
frames = len(s) // ch
def db(x):
    return -math.inf if x <= 0 else 20 * math.log10(x)
print('file: %s, %d ch, %d Hz, %s, %.2f s' % (sys.argv[1], ch, rate,
      'float32' if tag == 3 else '%d-bit PCM' % bits, frames / float(rate or 1)))
tot_peak, tot_clip = 0.0, 0
for c in range(ch):
    v = [abs(x) / full for x in s[c::ch]]
    peak = max(v) if v else 0.0
    clip = sum(1 for x in v if x >= limit)
    rms = math.sqrt(sum(x * x for x in v) / len(v)) if v else 0.0
    tot_peak, tot_clip = max(tot_peak, peak), tot_clip + clip
    print('channel %d: peak %+.2f dBFS, rms %+.2f dBFS, clipped %d of %d (%.3f%%)' % (
        c + 1, db(peak), db(rms), clip, len(v), 100.0 * clip / max(1, len(v))))
print('overall: peak %+.2f dBFS, clipped %.3f%% of samples' % (db(tot_peak), 100.0 * tot_clip / max(1, len(s))))
if tot_peak == 0:
    print('WARNING: the recording is digital silence: the recorder was not linked to the measurement point')
    sys.exit(3)
PY
}

# ms_node_class <node.name> : media.class of a node (from pw-dump).
ms_node_class() {
    pw-dump 2>/dev/null | jq -r --arg n "$1" \
        'first(.[] | select(.type == "PipeWire:Interface:Node") | select(.info.props["node.name"]? == $n) | .info.props["media.class"]) // ""'
}

# ms_default_sink : node.name of the default sink, else the first ALSA sink.
ms_default_sink() {
    local n
    n=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | sed -n 's/^[ *]*node.name = "\(.*\)"$/\1/p' | head -n1)
    case "$n" in
        '' | x20-*)
            n=$(pw-dump 2>/dev/null | jq -r 'first(.[] | select(.info.props["media.class"]? == "Audio/Sink") | select(.info.props["node.name"] | startswith("alsa_output")) | .info.props["node.name"]) // ""')
            ;;
    esac
    printf '%s\n' "$n"
}

# ms_links <media.name pattern> : what our recorder and player are linked to.
ms_links() {
    pw-dump 2>/dev/null | jq -r --arg p "$1" '
        (map(select(.type == "PipeWire:Interface:Node")) | map({key: (.id | tostring), value: .info.props}) | from_entries) as $n
        | .[] | select(.type == "PipeWire:Interface:Link")
        | ($n[(.info["output-node-id"] | tostring)] // {}) as $o
        | ($n[(.info["input-node-id"] | tostring)] // {}) as $i
        | select((($o["media.name"] // "") | test($p)) or (($i["media.name"] // "") | test($p)))
        | "  \($o["node.name"] // $o["media.name"]) -> \($i["node.name"] // $i["media.name"])"' | sort -u
}

ms_run() {
    local point=hw sink="" seconds=4 out="" method=pw target class dur t pidp pidr rc=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --point)
                point=${2:?--point needs a value}
                shift
                ;;
            --sink)
                sink=${2:?--sink needs a node name}
                shift
                ;;
            --seconds)
                seconds=${2:?--seconds needs a number}
                shift
                ;;
            --out)
                out=${2:?--out needs a directory}
                shift
                ;;
            --method)
                method=${2:?--method needs pw or parec}
                shift
                ;;
            *) ms_die "unknown option: $1" ;;
        esac
        shift
    done
    case "$seconds" in '' | *[!0-9]*) ms_die "--seconds must be a whole number" ;; esac
    [ "$(id -u)" != 0 ] || ms_die "run as the desktop user (deck), not root: the recorder must join that user's PipeWire session"
    for t in pw-play pw-record pw-dump jq python3 wpctl; do
        command -v "$t" >/dev/null 2>&1 || ms_die "needs $t"
    done
    case "$point" in
        hw) target=$(ms_default_sink) ;;
        speakers) target=x20-speakers.output ;;
        surround) target=x20-speakers-surround.output ;;
        *) target=$point ;;
    esac
    [ -n "$target" ] || ms_die "no hardware sink found; pass --point <node.name>"
    class=$(ms_node_class "$target")
    [ -n "$class" ] || ms_die "node '$target' does not exist (is audio-dsp on? is that chain loaded?)"
    [ -n "$out" ] || out=$(mktemp -d "${TMPDIR:-/tmp}/x20-measure.XXXXXX")
    mkdir -p "$out"
    printf 'generating the worst-case 7.1 test file (%s s per segment)...\n' "$seconds"
    ms_generate "$out/x20-measure-7.1.wav" "$seconds"
    dur=$((seconds * 3 + 2))

    printf 'recording %s (%s) with %s\n' "$target" "$class" "$method"
    case "$method" in
        pw)
            case "$class" in
                Audio/Sink*)
                    pw-record --target "$target" -P '{ stream.capture.sink = true }' \
                        --rate "$MS_RATE" --channels 2 --format f32 \
                        "$out/x20-measure-rec.wav" &
                    ;;
                *)
                    pw-record --target "$target" \
                        --rate "$MS_RATE" --channels 2 --format f32 "$out/x20-measure-rec.wav" &
                    ;;
            esac
            ;;
        parec)
            command -v parec >/dev/null 2>&1 || ms_die "needs parec (libpulse)"
            case "$class" in Audio/Sink*) ;; *) ms_die "--method parec records sink monitors only" ;; esac
            parec --device="$target.monitor" --rate="$MS_RATE" --channels=2 --format=float32le \
                --file-format=wav --client-name=x20-measure-rec "$out/x20-measure-rec.wav" &
            ;;
        *) ms_die "--method must be pw or parec" ;;
    esac
    pidr=$!
    sleep 1
    if [ -n "$sink" ]; then
        pw-play --target "$sink" --channels 8 --channel-map FL,FR,FC,LFE,RL,RR,SL,SR \
            "$out/x20-measure-7.1.wav" &
    else
        pw-play --channels 8 --channel-map FL,FR,FC,LFE,RL,RR,SL,SR --media-role Game \
            "$out/x20-measure-7.1.wav" &
    fi
    pidp=$!
    sleep 1
    printf 'links while playing:\n'
    ms_links 'x20-measure-'
    wait "$pidp" || true
    sleep 1
    # TERM, not INT: background jobs of a non-interactive shell ignore SIGINT.
    # pw-record and parec finish the WAV header on TERM.
    kill -TERM "$pidr" 2>/dev/null || true
    wait "$pidr" 2>/dev/null || true
    printf 'test file and recording kept in %s (about %s s)\n' "$out" "$dur"
    ms_analyze "$out/x20-measure-rec.wav" || rc=$?
    return "$rc"
}

ms_main() {
    case "${1:-run}" in
        generate)
            [ $# -ge 2 ] || ms_die "usage: $0 generate <out.wav> [seconds-per-segment]"
            ms_generate "$2" "${3:-4}"
            ;;
        analyze)
            [ $# -ge 2 ] || ms_die "usage: $0 analyze <recording.wav>"
            ms_analyze "$2"
            ;;
        run)
            [ $# -eq 0 ] || shift
            ms_run "$@"
            ;;
        -h | --help | help) sed -n '3,45p' "$0" ;;
        --*) ms_run "$@" ;;
        *) ms_die "unknown command: $1 (run, generate, analyze)" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ms_main "$@"
fi
