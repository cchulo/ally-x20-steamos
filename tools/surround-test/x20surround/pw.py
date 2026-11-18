# SPDX-License-Identifier: GPL-2.0-only
"""Thin wrappers around the PipeWire command-line tools the switcher uses:
pw-dump, wpctl, pw-metadata, pw-cat, pw-record and pipewire itself.

Everything goes through Pw so tests can substitute a fake. Only stdout is
parsed; the tools print warnings on stderr.
"""

import json
import os
import re
import shutil
import subprocess
import time

CONFIGURED_KEY = "default.configured.audio.sink"
DEFAULT_KEY = "default.audio.sink"
TOOLS = ("pipewire", "pw-dump", "wpctl", "pw-metadata", "pw-cat", "pw-record")


class PwError(RuntimeError):
    pass


class Pw:
    def __init__(self, env=None):
        self.env = env

    # -- plumbing ---------------------------------------------------------
    def _run(self, argv, check=True):
        try:
            r = subprocess.run(argv, env=self.env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, universal_newlines=True)
        except OSError as e:
            raise PwError("%s: %s" % (argv[0], e))
        if check and r.returncode != 0:
            raise PwError("%s failed with status %d" % (" ".join(argv), r.returncode))
        return r.stdout

    def spawn(self, argv, log=None):
        try:
            return subprocess.Popen(argv, env=self.env, stdin=subprocess.DEVNULL,
                                    stdout=log or subprocess.DEVNULL,
                                    stderr=subprocess.STDOUT if log else subprocess.DEVNULL)
        except OSError as e:
            raise PwError("%s: %s" % (argv[0], e))

    def version(self, tool):
        """Version of a tool, "present" when it has no --version (wpctl),
        None when it is not installed."""
        if not shutil.which(tool, path=(self.env or os.environ).get("PATH")):
            return None
        try:
            out = self._run([tool, "--version"], check=False)
        except PwError:
            return None
        m = re.search(r"(\d+\.\d+\.\d+)", out)
        return m.group(1) if m else "present"

    # -- graph ------------------------------------------------------------
    def dump(self):
        out = self._run(["pw-dump"])
        try:
            return json.loads(out)
        except ValueError:
            raise PwError("pw-dump did not print JSON")

    def nodes(self):
        """{node.name: {"id", "class", "channels", "props"}} for every node."""
        return nodes_from(self.dump())

    def node(self, name):
        return self.nodes().get(name)

    def wait_node(self, name, timeout=10.0, proc=None):
        end = time.time() + timeout
        while time.time() < end:
            if proc is not None and proc.poll() is not None:
                return None
            found = self.node(name)
            if found:
                return found
            time.sleep(0.2)
        return None

    # -- volumes ----------------------------------------------------------
    def volume(self, node_id):
        """(volume as wpctl shows it, muted)."""
        return parse_volume(self._run(["wpctl", "get-volume", str(node_id)]))

    def set_volume(self, node_id, value):
        self._run(["wpctl", "set-volume", str(node_id), "%.4f" % value])

    def set_mute(self, node_id, muted):
        self._run(["wpctl", "set-mute", str(node_id), "1" if muted else "0"])

    # -- default sink -----------------------------------------------------
    def _metadata(self, key):
        return parse_metadata(self._run(["pw-metadata", "-n", "default", "0", key]), key)

    def configured_default(self):
        """node.name of the sink the user picked, None when on automatic."""
        return self._metadata(CONFIGURED_KEY)

    def default_sink(self):
        return self._metadata(DEFAULT_KEY)

    def set_configured_default(self, name):
        if name is None:
            self._run(["pw-metadata", "-n", "default", "-d", "0", CONFIGURED_KEY])
        else:
            self._run(["pw-metadata", "-n", "default", "0", CONFIGURED_KEY,
                       json.dumps({"name": name}), "Spa:String:JSON"])

    # -- streams ----------------------------------------------------------
    def play(self, path, target=None, name="x20test-stream"):
        """Start pw-cat, on `target` or (None) on the default sink.

        No node.dont-fallback here: WirePlumber 0.5.19 rejects a stream that
        carries it when its target is the current default sink ("defined
        target not found", measured headless). Without it a missing target
        means a silent fallback to the default sink, so callers check that
        the target node exists before every call (Session.play_blocking)."""
        argv = ["pw-cat", "-p"]
        if target:
            argv += ["--target", target]
        return self.spawn(argv + ["-P", '{ node.name = "%s" }' % name, path])

    def record_monitor(self, sink, path):
        return self.spawn(["pw-record", "--target", sink, "-P", "{ stream.capture.sink = true }",
                           "--channels", "2", "--format", "f32", "--rate", "48000", path])

    def start_filter(self, conf_path, log=None):
        return self.spawn(["pipewire", "-c", conf_path], log=log)


def nodes_from(objs):
    out = {}
    for o in objs:
        if not str(o.get("type", "")).endswith("Node"):
            continue
        info = o.get("info") or {}
        props = info.get("props") or {}
        name = props.get("node.name")
        if not name:
            continue
        fmt = (info.get("params") or {}).get("Format") or []
        channels = fmt[0].get("channels") if fmt and isinstance(fmt[0], dict) else None
        out[name] = {"id": o.get("id"), "class": props.get("media.class"), "channels": channels,
                     "props": props}
    return out


def parse_volume(text):
    m = re.search(r"Volume:\s*([0-9.]+)", text)
    if not m:
        raise PwError("unexpected wpctl get-volume output: %r" % text.strip())
    return float(m.group(1)), "[MUTED]" in text


def parse_metadata(text, key):
    """The node name in `update: id:0 key:'<key>' value:'{"name":"x"}'`."""
    m = re.search(r"key:'%s' value:'(.*?)' type:" % re.escape(key), text)
    if not m:
        return None
    try:
        return json.loads(m.group(1)).get("name")
    except (ValueError, AttributeError):
        return None
