#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""headless.py - run overlay/bin/x20-surround.py against a private PipeWire
and WirePlumber with a null sink in place of the speakers. No sound, no
hardware. Not part of `make test` (needs Linux with pipewire, wireplumber
and pw-cli); run it by hand, as a normal user:

    dbus-run-session -- python3 tests/surround/headless.py

It checks what the unit tests cannot: that PipeWire loads the generated
config, that WirePlumber makes the surround sink the default because its
priority is one above the hardware sink's, that "stereo" removes it again,
and that a profile change replaces the filter. The headphone jack is not
covered: a null sink has no routes, so the speakers count as in use.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, os.pardir, os.pardir, "overlay", "bin", "x20-surround.py")
SPEAKERS = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"
OURS = "ally_x20_surround_speakers"


def main():
    tmp = tempfile.mkdtemp(prefix="x20-surround-headless.")
    env = dict(os.environ, XDG_RUNTIME_DIR=tmp, HOME=tmp, XDG_CONFIG_HOME=os.path.join(tmp, "cfg"),
               PIPEWIRE_RUNTIME_DIR=tmp)
    procs = []
    failures = []

    def spawn(argv):
        log = open(os.path.join(tmp, "%s.%d.log" % (os.path.basename(argv[0]), len(procs))), "w")
        p = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT)
        procs.append(p)
        return p

    def dump():
        out = subprocess.run(["pw-dump"], env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False).stdout
        try:
            return json.loads(out)
        except ValueError:
            return []

    def sinks():
        found = {}
        for o in dump():
            props = (o.get("info") or {}).get("props") or {}
            if props.get("media.class") == "Audio/Sink":
                found[props.get("node.name")] = props
        return found

    def default_sink():
        for o in dump():
            for m in o.get("metadata") or ():
                if m.get("key") == "default.audio.sink":
                    return (m.get("value") or {}).get("name")
        return None

    def wait(test, what, timeout=20.0):
        end = time.time() + timeout
        while time.time() < end:
            if test():
                print("ok   %s" % what)
                return True
            time.sleep(0.25)
        print("FAIL %s" % what)
        failures.append(what)
        return False

    def helper(*argv):
        return subprocess.run([sys.executable, HELPER] + list(argv), env=env, check=False,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode()

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

        print(helper("set", "sadie-d2-dry", "--device", "speakers").strip().splitlines()[0])
        spawn([sys.executable, HELPER, "run"])
        wait(lambda: OURS in sinks(), "the surround sink appears")
        props = sinks().get(OURS) or {}
        wait(lambda: str(props.get("audio.channels")) == "8" and
             int(props.get("priority.session") or 0) == 713,
             "it has 8 channels and priority 713 (got %s, %s)"
             % (props.get("audio.channels"), props.get("priority.session")), timeout=1)
        wait(lambda: default_sink() == OURS, "WirePlumber makes it the default")
        status = helper("status")
        wait(lambda: "running: Speakers (7.1 surround)" in status and "[in use]" in status,
             "status reports it", timeout=1)

        first = [p for p in subprocess.run(["pgrep", "-f", "pipewire -c"], stdout=subprocess.PIPE,
                                           check=False).stdout.split()]
        helper("set", "hutubs-pp1-dry", "--device", "speakers")
        conf = os.path.join(tmp, "ally-x20-steamos-surround", "speakers.conf")
        wait(lambda: os.path.exists(conf) and "hutubs-pp1-dry.wav" in open(conf).read(),
             "a profile change rewrites the config")
        wait(lambda: OURS in sinks() and
             subprocess.run(["pgrep", "-f", "pipewire -c"], stdout=subprocess.PIPE,
                            check=False).stdout.split() != first,
             "and replaces the filter process")
        wait(lambda: default_sink() == OURS, "the new filter is the default again")

        helper("set", "stereo", "--device", "speakers")
        wait(lambda: OURS not in sinks(), "stereo removes the surround sink")
        wait(lambda: default_sink() == SPEAKERS, "the speaker sink is the default again")

        helper("set", "user", "--device", "speakers")
        time.sleep(5)
        wait(lambda: OURS not in sinks(), "user without a file falls back (speakers: stereo)",
             timeout=1)
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
