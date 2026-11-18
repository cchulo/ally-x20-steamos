#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""hrir_tool.py - work on 14-channel HRIR candidates. Standard library only.

usage:
  hrir_tool.py dry IN.wav OUT.wav
      derive the dry-fronts form (FL/FR/FC dry, sides and rears unchanged)
  hrir_tool.py check WAV...
      run the offline checks and print them; exit 1 when a check FAILs
  hrir_tool.py add --manifest FILE --id ID [--set NAME] [--form FORM]
                   [--licence TEXT] [--source TEXT] WAV
      run the checks and record the candidate in the manifest
  hrir_tool.py report --manifest FILE
      print the table of every candidate in the manifest
  hrir_tool.py speakers --manifest FILE --id ID [--delays US,US...]
                        [--strengths S,S...] [--order N]
      speaker candidates from one headphone candidate (the winner): the set
      itself plus a sweep of side/rear crosstalk cancellation (delay in
      microseconds, strength 0..1), written next to it and recorded in the
      manifest for the device "speakers"
  hrir_tool.py conf --manifest FILE --id ID --target NODE --node NAME
                    --description TEXT [--extra-db DB] [-o FILE]
      write the PipeWire config of one candidate
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from x20surround import checks, conf, dsp, forms, manifest, wav, xtc  # noqa: E402
from x20surround.layout import RATE  # noqa: E402


def cmd_dry(args):
    channels = manifest.read_hrir(args.input)
    wav.write(args.output, RATE, forms.dry_fronts(channels))
    return 0


def cmd_check(args):
    rc = 0
    for path in args.wav:
        channels = manifest.read_hrir(path)
        trim, results = checks.run_all(channels)
        print("%s: level trim %+.2f dB" % (path, trim))
        for r in results:
            print("  %-9s %-4s %s" % (r.name, r.status, r.detail))
        if checks.worst_status(results) == checks.FAIL:
            rc = 1
    return rc


def cmd_add(args):
    data = manifest.load(args.manifest) if os.path.exists(args.manifest) else manifest.empty()
    entry = manifest.describe(args.wav, args.id, set=args.set, form=args.form,
                              licence=args.licence, source=args.source)
    base = os.path.dirname(os.path.abspath(args.manifest))
    manifest.add(data, entry, base)
    manifest.save(args.manifest, data)
    print("%s: %s, level trim %+.2f dB" % (args.id, entry["status"], entry["trim_db"]))
    return 1 if entry["status"] == checks.FAIL else 0


def cmd_report(args):
    sys.stdout.write(manifest.report(manifest.load(args.manifest)))
    return 0


def _numbers(text, kind):
    try:
        return [kind(v) for v in text.split(",") if v != ""]
    except ValueError:
        raise ValueError("not a list of numbers: %r" % text)


def cmd_speakers(args):
    data = manifest.load(args.manifest)
    base_dir = os.path.dirname(os.path.abspath(args.manifest))
    made = xtc.add_speaker_candidates(data, base_dir, args.id, _numbers(args.delays, float),
                                      _numbers(args.strengths, float), args.order)
    manifest.save(args.manifest, data)
    for entry in made:
        print("%-34s %s, level trim %+.2f dB" % (entry["id"], entry["status"], entry["trim_db"]))
    return 1 if any(e["status"] == checks.FAIL for e in made) else 0


def cmd_conf(args):
    data = manifest.load(args.manifest)
    entry = manifest.find(data, args.id)
    path = manifest.resolve(entry, os.path.dirname(os.path.abspath(args.manifest)))
    gain = dsp.from_db(entry["trim_db"] + args.extra_db)
    text = conf.render(args.id, args.node, args.description, path, args.target, gain=gain)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    p = sub.add_parser("dry")
    p.add_argument("input")
    p.add_argument("output")
    p.set_defaults(fn=cmd_dry)
    p = sub.add_parser("check")
    p.add_argument("wav", nargs="+")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("add")
    p.add_argument("--manifest", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--set")
    p.add_argument("--form")
    p.add_argument("--licence")
    p.add_argument("--source")
    p.add_argument("wav")
    p.set_defaults(fn=cmd_add)
    p = sub.add_parser("report")
    p.add_argument("--manifest", required=True)
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("speakers")
    p.add_argument("--manifest", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--delays", default=",".join(str(d) for d in xtc.DELAYS_US))
    p.add_argument("--strengths", default=",".join(str(v) for v in xtc.STRENGTHS))
    p.add_argument("--order", type=int, default=xtc.ORDER)
    p.set_defaults(fn=cmd_speakers)
    p = sub.add_parser("conf")
    p.add_argument("--manifest", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--node", required=True)
    p.add_argument("--description", required=True)
    p.add_argument("--extra-db", type=float, default=0.0)
    p.add_argument("-o", "--output")
    p.set_defaults(fn=cmd_conf)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except (manifest.CandidateError, OSError, ValueError) as e:
        print("hrir_tool: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
