#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""headless.py - run overlay/bin/x20-surround.py against a private PipeWire
and WirePlumber with a null sink in place of the speakers. No sound, no
hardware. Not part of `make test` (needs Linux with pipewire, wireplumber,
pw-cli, pw-metadata and pw-cat); run it by hand, as a normal user:

    dbus-run-session -- python3 tests/surround/headless.py

It checks what the unit tests cannot: that PipeWire loads the generated
config (also with a generated crosstalk-cancellation variant), that
WirePlumber makes the surround sink the default because its priority is
above the hardware sink's, that "stereo" removes it again, and that a change
of profile or of the crosstalk setting hands over from one filter to the
next without the hardware sink becoming the default in between.

How the hand-over is watched. `pw-metadata -m` reports every change of
default.audio.sink, so a change to the hardware sink cannot slip between two
samples. In addition an 8-channel stream of silence plays the whole time
(pw-cat), and during each change pw-dump is polled as fast as it answers:
the stream must never be linked to the hardware sink. That second check is
sampled, so a link shorter than one pw-dump (some tens of milliseconds)
could be missed, and silence cannot show a dropout: whether a switch is
audible is for the device (docs/surround.md, TODO(hw)).

The headphone jack is not covered: a null sink has no routes, so the
speakers count as in use.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, os.pardir, os.pardir, "overlay", "bin", "x20-surround.py")
SPEAKERS = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"
OURS = "ally_x20_surround_speakers_"
STREAM = "x20-headless-71"


def main():
    tmp = tempfile.mkdtemp(prefix="x20-surround-headless.")
    env = dict(os.environ, XDG_RUNTIME_DIR=tmp, HOME=tmp, XDG_CONFIG_HOME=os.path.join(tmp, "cfg"),
               XDG_CACHE_HOME=os.path.join(tmp, "cache"), PIPEWIRE_RUNTIME_DIR=tmp)
    procs = []
    failures = []
    defaults = []  # (time, name) of every default.audio.sink change

    def spawn(argv, **kw):
        log = open(os.path.join(tmp, "%s.%d.log" % (os.path.basename(argv[0]), len(procs))), "w")
        kw.setdefault("stdout", log)
        p = subprocess.Popen(argv, env=env, stderr=subprocess.STDOUT, **kw)
        procs.append(p)
        return p

    def dump():
        out = subprocess.run(["pw-dump"], env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False).stdout
        try:
            return json.loads(out)
        except ValueError:
            return []

    def sinks(objects=None):
        found = {}
        for o in dump() if objects is None else objects:
            props = (o.get("info") or {}).get("props") or {}
            if props.get("media.class") == "Audio/Sink":
                found[props.get("node.name")] = props
        return found

    def ours(objects=None):
        return sorted(n for n in sinks(objects) if n and n.startswith(OURS))

    def default_sink(objects=None):
        for o in dump() if objects is None else objects:
            for m in o.get("metadata") or ():
                if m.get("key") == "default.audio.sink":
                    return (m.get("value") or {}).get("name")
        return None

    def stream_sinks(objects):
        """node.name of every node the 8-channel test stream is linked to."""
        names, stream = {}, None
        for o in objects:
            props = (o.get("info") or {}).get("props") or {}
            if str(o.get("type", "")).endswith(":Node"):
                names[o.get("id")] = props.get("node.name")
                if props.get("node.name") == STREAM:
                    stream = o.get("id")
        linked = set()
        for o in objects:
            info = o.get("info") or {}
            if str(o.get("type", "")).endswith(":Link") and info.get("output-node-id") == stream:
                linked.add(names.get(info.get("input-node-id")))
        return linked

    def filters():
        return subprocess.run(["pgrep", "-f", "pipewire -c"], stdout=subprocess.PIPE,
                              check=False).stdout.split()

    def check(ok, what):
        print("%s %s" % ("ok  " if ok else "FAIL", what))
        if not ok:
            failures.append(what)
        return ok

    def wait(test, what, timeout=20.0):
        end = time.time() + timeout
        while time.time() < end:
            if test():
                return check(True, what)
            time.sleep(0.25)
        return check(False, what)

    def node_id(name):
        for o in dump():
            if ((o.get("info") or {}).get("props") or {}).get("node.name") == name:
                return o.get("id")
        return None

    def volume(name):
        """The volume wpctl shows for a node, or None."""
        ident = node_id(name)
        if ident is None:
            return None
        out = subprocess.run(["wpctl", "get-volume", str(ident)], env=env, check=False,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode()
        m = re.search(r"Volume:\s*([0-9.]+)", out)
        return round(float(m.group(1)), 2) if m else None

    def set_volume(name, value):
        subprocess.run(["wpctl", "set-volume", str(node_id(name)), "%.2f" % value], env=env,
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def helper(*argv):
        return subprocess.run([sys.executable, HELPER] + list(argv), env=env, check=False,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode()

    def conf_of(name):
        path = os.path.join(tmp, "ally-x20-steamos-surround", "speakers-%s.conf" % name[-1])
        return open(path).read() if os.path.exists(path) else ""

    def watch_defaults(pipe):
        for line in pipe:
            found = re.search(r"key:'default\.audio\.sink' value:'(.*)' type:", line)
            if found:
                try:
                    defaults.append((time.time(), json.loads(found.group(1)).get("name")))
                except ValueError:
                    defaults.append((time.time(), found.group(1)))

    def hand_over(what, wanted_in_conf, *argv):
        """Change a setting while a filter runs and watch the hand-over."""
        before = ours()
        check(len(before) == 1, "%s: one surround sink before the change (%s)" % (what, before))
        old = before[0] if before else ""
        start = time.time()
        print(helper(*argv).strip().splitlines()[0])
        samples = to_hardware = hardware_default = 0
        both = False
        done = None
        while time.time() < start + 40:
            objects = dump()
            samples += 1
            now = ours(objects)
            both = both or len(now) == 2
            hardware_default += default_sink(objects) == SPEAKERS
            to_hardware += SPEAKERS in stream_sinks(objects)
            if now and old not in now and done is None:
                done = time.time()
            if done is not None and time.time() > done + 1.5:
                break
        took = (done or time.time()) - start
        now = ours()
        new = now[0] if now else ""
        check(len(now) == 1 and new != old and wanted_in_conf in conf_of(new),
              "%s: %s took over from %s after %.1f s" % (what, new or "nothing", old, took))
        check(both, "%s: both sinks existed at the same time (new first, then the old one goes)"
              % what)
        seen = [name for at, name in defaults if at >= start]
        check(SPEAKERS not in seen and hardware_default == 0,
              "%s: the hardware sink never became the default (changes reported: %s; %d samples)"
              % (what, " -> ".join(n.replace(OURS, "..._") for n in seen) or "none", samples))
        check(to_hardware == 0,
              "%s: the 8-channel stream was never linked to the hardware sink (%d samples)"
              % (what, samples))
        wait(lambda: default_sink() == new, "%s: %s is the default" % (what, new), timeout=5)
        wait(lambda: stream_sinks(dump()) == {new}, "%s: the stream plays into it" % what,
             timeout=5)
        check(len(filters()) == 1, "%s: exactly one filter process remains" % what)
        return new

    try:
        spawn(["pipewire"])
        wait(lambda: os.path.exists(os.path.join(tmp, "pipewire-0")), "pipewire is up")
        spawn(["wireplumber"])
        subprocess.run(["pw-cli", "create-node", "adapter",
                        "{ factory.name=support.null-audio-sink node.name=%s node.description=Speaker "
                        "media.class=Audio/Sink object.linger=true audio.position=[FL FR] "
                        "priority.session=712 priority.driver=712 }" % SPEAKERS],
                       env=env, check=False, stdout=subprocess.DEVNULL)
        wait(lambda: default_sink() == SPEAKERS, "the fake speaker sink is the default")
        monitor = spawn(["stdbuf", "-oL", "pw-metadata", "-m"], stdout=subprocess.PIPE, text=True)
        threading.Thread(target=watch_defaults, args=(monitor.stdout,), daemon=True).start()
        wait(lambda: any(name == SPEAKERS for _, name in defaults),
             "pw-metadata -m reports the default sink")

        # the defaults: sadie-d2-dry on both outputs, crosstalk cancellation
        # 60 us / 50 % on the speakers, generated on first use
        status = helper("status")
        check("speakers   sadie-d2-dry" in status and "not generated yet" in status,
              "defaults: sadie-d2-dry, the speaker variant not generated yet")
        # the user's volume sits on the hardware sink before the filter exists
        set_volume(SPEAKERS, 0.50)
        wait(lambda: volume(SPEAKERS) == 0.50, "the speaker sink is at 0.50 before the filter")
        spawn([sys.executable, HELPER, "run"])
        wait(lambda: ours() == [OURS + "a"], "the surround sink appears as ..._a")
        wait(lambda: volume(OURS + "a") == 0.50 and volume(SPEAKERS) == 1.00,
             "the surround sink took the volume (0.50) and the speaker sink is held at 1.00")
        check((sinks().get(OURS + "a") or {}).get("node.description")
              == "Speakers (Surround - SADIE D2 Dry)",
              "the sink is called 'Speakers (Surround - SADIE D2 Dry)'")
        props = sinks().get(OURS + "a") or {}
        check(str(props.get("audio.channels")) == "8" and
              int(props.get("priority.session") or 0) == 713,
              "it has 8 channels and priority 713 (got %s, %s)"
              % (props.get("audio.channels"), props.get("priority.session")))
        cache = os.path.join(tmp, "cache", "ally-x20-steamos", "surround")
        check(re.search(r'filename = "%s/[0-9a-f]{16}-d060-s50\.wav"' % re.escape(cache),
                        conf_of(OURS + "a")) is not None,
              "PipeWire loaded the generated crosstalk variant from the cache")
        wait(lambda: default_sink() == OURS + "a", "WirePlumber makes it the default")
        status = helper("status")
        check("running: Speakers (Surround - SADIE D2 Dry)" in status and "[in use]" in status
              and "sadie-d2-dry + xtc 60 us / 50 %" in status, "status reports it")

        spawn(["pw-cat", "--playback", "--raw", "--format", "s16", "--rate", "48000",
               "--channels", "8", "--channel-map", "FL,FR,FC,LFE,RL,RR,SL,SR",
               "-P", "node.name=%s" % STREAM, "/dev/zero"])
        wait(lambda: stream_sinks(dump()) == {OURS + "a"},
             "an 8-channel stream plays into the surround sink")

        set_volume(OURS + "a", 0.40)            # the volume keys move the default sink
        time.sleep(3)                           # one look of the service, to remember it
        now = hand_over("profile a->b", "profile: hutubs-pp1-dry\n", "set", "speakers",
                        "hutubs-pp1-dry")
        wait(lambda: volume(now) == 0.40 and volume(SPEAKERS) == 1.00,
             "the volume (0.40) went along to the new sink; the speaker sink is still at 1.00",
             timeout=5)
        check((sinks().get(now) or {}).get("node.description")
              == "Speakers (Surround - HUTUBS PP1 Dry)", "and it shows the new profile's name")
        check((sinks().get(now) or {}).get("priority.session") == 714,
              "the second slot has priority 714")
        now = hand_over("profile b->a", "profile: mit-kemar-dry\n", "set", "speakers",
                        "mit-kemar-dry")
        check((sinks().get(now) or {}).get("priority.session") == 713,
              "back in the first slot with priority 713 (no creep)")
        hand_over("xtc 100/30", "d100-s30.wav", "xtc", "100", "30")
        # mit-kemar-dry with 60 us / 70 % fails the routing check: the
        # profile's own file plays instead, and status says why
        now = hand_over("xtc 60/70 (unusable)", "hrir/mit-kemar-dry.wav", "xtc", "60", "70")
        status = helper("status")
        check("is not usable with mit-kemar-dry" in status and "routing check" in status,
              "status explains the fall-back to the profile without xtc")
        hand_over("xtc 80/50", "d080-s50.wav", "xtc", "80", "50")

        helper("set", "speakers", "stereo")
        wait(lambda: not ours(), "stereo removes the surround sink")
        wait(lambda: default_sink() == SPEAKERS, "the speaker sink is the default again")
        wait(lambda: not filters(), "no filter process is left")
        wait(lambda: volume(SPEAKERS) == 0.40,
             "the speaker sink got the volume back (0.40), not left at 1.00", timeout=5)

        helper("set", "speakers", "user")
        wait(lambda: len(ours()) == 1 and "sadie-d2-dry.wav" not in conf_of(ours()[0])
             and "d080-s50.wav" in conf_of(ours()[0]),
             "user without a file falls back to sadie-d2-dry (with the crosstalk setting)")
    finally:
        for p in reversed(procs):
            if p.poll() is None:
                p.terminate()
        for p in procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        if failures:
            for name in sorted(os.listdir(tmp)):
                if name.endswith(".log"):
                    print("--- %s" % name)
                    print(open(os.path.join(tmp, name)).read()[-1500:])
        shutil.rmtree(tmp, ignore_errors=True)
    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
