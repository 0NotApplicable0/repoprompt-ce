#!/usr/bin/env bash
# FM-05 live proof probe (DEBUG app only). Exit: 0 pass; 1 invariant/cleanup; 2 precondition/ambiguity/
# create-delete timeout; 130/143 signals after cleanup.

FM05_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' FM05_PROBE_PY <<'PY' || true
import argparse
import codecs
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
import xml.parsers.expat

SCRIPT_DIR = sys.argv[1]
DEFAULT_RECORD_ROOT = "/Volumes/U34 Bolt/Projects/Repos/_PERSONAL_/docs/repoprompt-ce/2026-10-14-fm-05-live-proof"
DEBUG_BUNDLE_ID = "com.repoprompt.ce.debug"
EXEC_CLIENT = "repoprompt cli (exec)"
FLEET_KEY = "agent_mode.fleet_park_agent_windows"
APPROVAL_OPERATIONS = ("create_workspace", "delete_workspace", "add_folder", "remove_folder")
ACTIVE_RAW = {"running", "waitingForUser", "waitingForQuestion", "waitingForApproval"}
WAITING_RAW = {"waitingForUser", "waitingForQuestion", "waitingForApproval"}
# MCPCLIExitCode raw values the exec CLI uses for connect/approval/server-termination failures.
CLI_ENVIRONMENT_EXIT = {73: "connection failed", 74: "approval denied", 76: "terminated by server"}
DENIED_TEXT = ("Workspace creation was denied by the user.", "Workspace deletion was denied by the user.")
LOCAL_FLAG_KEYS = {"is_current_window", "is_bound", "is_bound_for_client", "binding"}
PROMPT = (
    "FM-05 disposable live proof. Do not read/edit files, run commands, call providers directly or start helpers. "
    "Ask exactly one question through the available user-question tool: “May this disposable proof session finish?” "
    "Then remain waiting for the answer. Do not answer your own question or continue work."
)


class Precondition(Exception):
    """Missing precondition or ambiguous evidence: exit 2."""


class Invariant(Exception):
    """Contract, invariant or cleanup failure: exit 1."""


class CallTimeout(Exception):
    pass


class ToolError(Exception):
    pass


class EnvironmentFailure(ToolError):
    """CLI connection/approval refusal or an exact server denial: exit-2 class, ownership recovery still runs."""


class SignalExit(BaseException):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def mono():
    # The helper stamps samples with CLOCK_UPTIME_RAW; time.monotonic() is a different epoch on some interpreters.
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)

class DocStream:
    def __init__(self):
        self.buf = ""
        self.docs = []
        self.decoder = json.JSONDecoder()

    def feed(self, chunk, stamp):
        self.buf += chunk
        while True:
            text = self.buf.lstrip()
            if not text:
                self.buf = ""
                return
            try:
                obj, end = self.decoder.raw_decode(text)
            except ValueError:
                self.buf = text
                return
            self.docs.append((stamp, obj))
            self.buf = text[end:]

    def finish(self):
        if self.buf.strip():
            raise ToolError("malformed output: " + self.buf.strip()[:80])
        return self.docs


def doc_error(doc):
    return isinstance(doc, dict) and (doc.get("isError") is True or "error" in doc or "error_code" in doc)


class Result:
    def __init__(self, status, docs, stdout, stderr, t0, t1, timed_out, argv, parse_error=None):
        self.status, self.docs, self.stdout, self.stderr = status, docs, stdout, stderr
        self.t0, self.t1, self.timed_out, self.argv = t0, t1, timed_out, argv
        self.parse_error = parse_error

class Real:
    def __init__(self, cfg):
        assert not cfg.self_test
        if not hasattr(time, "CLOCK_UPTIME_RAW"):
            raise Precondition("this interpreter lacks CLOCK_UPTIME_RAW, the sampler clock")
        self.cfg = cfg
        self.home = os.path.expanduser("~")
        self.children = set()
        self.helper_bin = None

    def now(self):
        return mono()

    def sleep(self, seconds):
        time.sleep(seconds)

    def bundle_path(self):
        override = os.environ.get("REPOPROMPT_DEBUG_APP_BUNDLE")
        if override:
            return override
        return os.path.join(self.home, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app")

    def list_pids(self, executable):
        try:
            out = subprocess.run(
                [sys.executable, "-I", os.path.join(SCRIPT_DIR, "debug_app_process.py"), "list", "--executable", executable],
                capture_output=True, text=True, timeout=30)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise Precondition("debug app discovery unavailable: %s" % exc)
        if out.returncode != 0:
            raise Precondition("debug app discovery failed: " + out.stderr.strip())
        try:
            return [int(x) for x in out.stdout.split()]
        except ValueError:
            raise Precondition("debug app discovery printed a non-numeric PID")

    def proc_identity(self, pid):
        env = dict(os.environ, LC_ALL="C", LANG="C")
        try:
            out = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
                                 capture_output=True, text=True, timeout=10, env=env)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise Precondition("process identity unavailable: %s" % exc)
        return out.stdout.strip() if out.returncode == 0 else None

    def which_cli(self):
        path = shutil.which("rpce-cli-debug")
        return os.path.realpath(path) if path else None

    def cli_version(self, cli):
        try:
            out = subprocess.run([cli, "-w", "1", "--version"], capture_output=True, text=True, timeout=10)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise Precondition("rpce-cli-debug --version unavailable: %s" % exc)
        if out.returncode != 0:
            raise Precondition("rpce-cli-debug --version failed")
        return out.stdout.strip()[:200]

    def default_head(self):
        try:
            out = subprocess.run(["git", "-C", SCRIPT_DIR, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return ""
        return out.stdout.strip() if out.returncode == 0 else ""

    def approval_policy(self, domain):
        try:
            out = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Precondition("persisted defaults unavailable: %s" % exc)
        if out.returncode != 0:
            return None
        try:
            value = plistlib.loads(out.stdout).get("workspace.approvalSettings")
        except (ValueError, plistlib.InvalidFileException, xml.parsers.expat.ExpatError) as exc:
            raise Precondition("persisted defaults are unreadable: %s" % exc)
        return bytes(value) if isinstance(value, (bytes, bytearray)) else None

    def cli(self, cmds, timeout, label):
        argv = [self.cfg.cli_path, "-w", "1", "--backend", "app", "--raw-json", "--tool-timeout", "30", "--fail-fast"]
        for command in cmds:
            argv += ["-e", command]
        stream, err_chunks = DocStream(), []
        t0 = mono()
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as exc:
            raise Precondition("CLI could not start: %s" % exc)
        self.children.add(proc)
        utf8_error = []

        def pump_out():
            # Strict incremental decoding: a multibyte character may straddle two reads.
            decoder = codecs.getincrementaldecoder("utf-8")("strict")
            while True:
                chunk = os.read(proc.stdout.fileno(), 65536)
                text = ""
                if not utf8_error:
                    try:
                        text = decoder.decode(chunk, final=not chunk)
                    except UnicodeDecodeError as exc:
                        utf8_error.append("invalid UTF-8 in stdout: %s" % exc.reason)
                if text:
                    stream.feed(text, mono())
                if not chunk:
                    return

        def pump_err():
            err_chunks.append(proc.stderr.read().decode("utf-8", "replace"))

        threads = [threading.Thread(target=pump_out, daemon=True), threading.Thread(target=pump_err, daemon=True)]
        for thread in threads:
            thread.start()
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()
            proc.wait()
        for thread in threads:
            thread.join(5)
        self.children.discard(proc)
        t1 = mono()
        parse_error = utf8_error[0] if utf8_error else None
        try:
            docs = stream.finish()
        except ToolError as exc:
            docs, parse_error = stream.docs, parse_error or str(exc)
        return Result(proc.returncode, docs, "", "".join(err_chunks), t0, t1, timed_out, argv, parse_error)

    def start_sampler(self, pid):
        return LiveSampler(self, pid)

    def oneshot(self, pid):
        try:
            out = subprocess.run([self.helper_bin, str(pid)], capture_output=True, text=True, timeout=15)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise Precondition("window sampler unavailable: %s" % exc)
        if out.returncode != 0:
            raise Precondition("window sampler failed: " + out.stderr.strip())
        try:
            sample = json.loads(out.stdout)
        except ValueError:
            raise Precondition("window sampler printed unreadable JSON")
        if not (isinstance(sample, dict) and isinstance(sample.get("count"), int)
                and isinstance(sample.get("numbers"), list) and isinstance(sample.get("t"), (int, float))):
            raise Precondition("window sampler printed an unexpected sample shape")
        return sample

    def compile_helper(self, run_dir):
        tmp = os.path.join(run_dir, "tmp")
        cache = os.path.join(run_dir, "module-cache")
        os.makedirs(tmp, exist_ok=True)
        os.makedirs(cache, exist_ok=True)
        binary = os.path.join(run_dir, "fleet_onscreen_windows")
        try:
            out = subprocess.run(
                ["xcrun", "swiftc", "-O", "-module-cache-path", cache, "-o", binary,
                 os.path.join(SCRIPT_DIR, "fleet_onscreen_windows.swift")],
                capture_output=True, text=True, timeout=300, env=dict(os.environ, TMPDIR=tmp + "/"))
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise Precondition("helper compile unavailable: %s" % exc)
        if out.returncode != 0:
            raise Precondition("helper compile failed: " + out.stderr.strip()[-400:])
        self.helper_bin = binary

    def kill_children(self):
        for proc in list(self.children):
            try:
                proc.kill()
            except OSError:
                pass


class LiveSampler:
    def __init__(self, env, pid):
        self.env = env
        self.samples = []
        self.ready = threading.Event()
        try:
            self.proc = subprocess.Popen(
                [env.helper_bin, "--watch", "--interval-ms", "20", "--duration-seconds", "600", str(pid)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except OSError as exc:
            raise Precondition("window sampler could not start: %s" % exc)
        env.children.add(self.proc)
        self.thread = threading.Thread(target=self.pump, daemon=True)
        self.thread.start()

    def pump(self):
        for line in self.proc.stdout:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("event") == "ready":
                self.ready.set()
            elif "t" in obj:
                self.samples.append(obj)

    def wait_ready(self, seconds):
        return self.ready.wait(seconds)

    def stop(self):
        try:
            self.proc.terminate()
            self.proc.wait(5)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()
        self.env.children.discard(self.proc)
        self.thread.join(2)
        return list(self.samples)

def canonical_under(root, path):
    root_real = os.path.realpath(root)
    parts = os.path.abspath(path)
    if parts == root_real:
        return root_real
    cursor = root_real
    rel = os.path.relpath(parts, root_real)
    if rel.startswith(".."):
        raise Precondition("output root escapes the record root: " + path)
    for piece in rel.split(os.sep):
        cursor = os.path.join(cursor, piece)
        if os.path.islink(cursor):
            raise Precondition("output root contains a symlink: " + cursor)
    return os.path.join(root_real, rel)


def projected(item, drop=()):
    if isinstance(item, dict):
        return {k: projected(v, drop) for k, v in sorted(item.items())
                if k not in drop and k != "last_modified"
                and not k.endswith(("_at", "_time", "_timestamp", "_count"))}
    if isinstance(item, list):
        return [projected(v, drop) for v in item]
    return item


def collect_values(item, key, out):
    if isinstance(item, dict):
        for k, v in item.items():
            if k == key and isinstance(v, str):
                out.add(v)
            collect_values(v, key, out)
    elif isinstance(item, list):
        for v in item:
            collect_values(v, key, out)
    return out


def sample_coverage(samples, t_send, t_resp, tail=1.25, max_gap=0.1):
    """Return (ok, reason, stats). Gaps are measured across the whole send..resp+tail span."""
    end = t_resp + tail
    if not samples:
        return False, "no samples", {}
    times = sorted(s["t"] for s in samples)
    if times[0] > t_send:
        return False, "first sample after request send", {}
    if times[-1] < end:
        return False, "last sample before response+1.25s", {}
    lo = max(t for t in times if t <= t_send)
    hi = min(t for t in times if t >= end)
    span = [t for t in times if lo <= t <= hi]
    gaps = [b - a for a, b in zip(span, span[1:])]
    worst = max(gaps) if gaps else 0.0
    counts = [s["count"] for s in samples if lo <= s["t"] <= hi]
    stats = {"max_gap_ms": round(worst * 1000, 1), "samples": len(span),
             "min_count": min(counts) if counts else None, "max_count": max(counts) if counts else None}
    if worst > max_gap:
        return False, "sampler gap %.0f ms exceeds 100 ms" % (worst * 1000), stats
    return True, "ok", stats


class Probe:
    def __init__(self, env, cfg):
        self.env, self.cfg = env, cfg
        self.run_dir = cfg.run_dir
        self.errors = []
        self.residuals = []
        self.flags = {"timeout": False, "invariant": False, "precondition": False, "signal": 0}
        self.J = {"nonce": cfg.nonce, "intents": [], "workspaces": [], "fleet": {"state": "never"}, "events": []}
        self.calls = 0
        self.mutations = 0
        self.identity = None
        self.baseline = None
        self.report_lines = []
        self.cleaned = False

    def journal(self, kind, **data):
        self.J["events"].append(dict(kind=kind, t=self.env.now(), **data))
        os.makedirs(self.run_dir, exist_ok=True)
        final = os.path.join(self.run_dir, "journal.json")
        try:
            with open(final + ".tmp", "w") as handle:
                json.dump(self.J, handle, indent=1, sort_keys=True, default=str)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(final + ".tmp", final)
        except BaseException:
            if os.path.exists(final + ".tmp"):
                os.unlink(final + ".tmp")
            raise

    def note(self, line):
        self.report_lines.append(line)
        print(line, flush=True)

    def append_report(self, title, lines):
        path = os.path.join(self.cfg.record_root, "v9-report.md")
        with open(path, "a") as handle:
            handle.write("\n## %s %s (%s)\n" % (self.cfg.nonce, title, self.cfg.phase))
            for line in lines:
                handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def fail(self, kind, message):
        self.flags[kind] = True
        self.errors.append("%s: %s" % (kind, message))
        print("ERROR[%s] %s" % (kind, message), file=sys.stderr, flush=True)

    def run_cli(self, cmds, label, timeout=30.0, mutation=False):
        if mutation:
            self.revalidate()
            self.mutations += 1
        self.calls += 1
        result = self.env.cli(cmds, timeout, label)
        self.record_call(label, cmds, result)
        if result.timed_out:
            raise CallTimeout(label)
        if result.status in CLI_ENVIRONMENT_EXIT:
            raise EnvironmentFailure("%s exited %s (%s): %s" % (
                label, result.status, CLI_ENVIRONMENT_EXIT[result.status], result.stderr.strip()[:200]))
        if result.status != 0:
            if any(text in (result.stderr or "") for text in DENIED_TEXT):
                raise EnvironmentFailure("%s denied: %s" % (label, result.stderr.strip()[:200]))
            raise ToolError("%s exited %s: %s" % (label, result.status, result.stderr.strip()[:200]))
        if result.parse_error:
            raise ToolError("%s %s" % (label, result.parse_error))
        if re.search(r"(?im)^\s*(error|warning):", result.stderr or ""):
            raise ToolError("%s stderr: %s" % (label, result.stderr.strip()[:200]))
        for _, doc in result.docs:
            if doc_error(doc):
                if any(text in json.dumps(doc) for text in DENIED_TEXT):
                    raise EnvironmentFailure("%s denied: %s" % (label, json.dumps(doc)[:200]))
                raise ToolError("%s tool error: %s" % (label, json.dumps(doc)[:200]))
        return result

    def record_call(self, label, cmds, result):
        calls = os.path.join(self.run_dir, "calls")
        os.makedirs(calls, exist_ok=True)
        entry = {"label": label, "cmds": cmds, "status": result.status, "timed_out": result.timed_out,
                 "t0": result.t0, "t1": result.t1, "stderr": result.stderr, "parse_error": result.parse_error,
                 "docs": [{"read_chunk_time": t, "doc": d} for t, d in result.docs]}
        with open(os.path.join(calls, "%03d-%s.json" % (self.calls, re.sub(r"\W+", "-", label))), "w") as handle:
            json.dump(entry, handle, indent=1, default=str)

    def call(self, tool, args, label, window=None, mutation=False, timeout=30.0):
        cmds = []
        if window is not None:
            cmds.append("use %d" % int(window))
        cmds.append("call %s %s" % (tool, json.dumps(args, separators=(",", ":"))))
        result = self.run_cli(cmds, label, timeout, mutation)
        docs = [d for _, d in result.docs]
        if window is not None:
            binding = docs[0].get("binding") if docs and isinstance(docs[0], dict) else None
            if not isinstance(binding, dict) or binding.get("window_id") != int(window):
                raise ToolError("%s: use %s did not bind that window" % (label, window))
            docs = docs[1:]
        if len(docs) != 1 or not isinstance(docs[0], dict):
            raise ToolError("%s: expected exactly one result document" % label)
        return docs[0]

    def list_windows(self, label="windows"):
        result = self.run_cli(["windows"], label)
        docs = [d for _, d in result.docs]
        if len(docs) != 1 or not isinstance(docs[0].get("windows"), list):
            raise ToolError("windows: unexpected payload")
        return docs[0]["windows"]

    def list_workspaces(self, label="workspaces"):
        doc = self.call("manage_workspaces", {"action": "list"}, label)
        if not isinstance(doc.get("workspaces"), list):
            raise ToolError("workspace list: unexpected payload")
        return doc["workspaces"]

    def list_sessions_many(self, window_ids, label, timeout=30.0):
        """One CLI process, `use N` + list per window; returns {window: (receipt, sessions)}."""
        cmds = []
        for window in window_ids:
            cmds += ["use %d" % window,
                     "call agent_manage " + json.dumps({"op": "list_sessions", "limit": 1001}, separators=(",", ":"))]
        result = self.run_cli(cmds, label, timeout=timeout)
        docs = result.docs
        if len(docs) != 2 * len(window_ids):
            raise ToolError("%s: expected %d documents, got %d" % (label, 2 * len(window_ids), len(docs)))
        out = {}
        for index, window in enumerate(window_ids):
            _, bind = docs[2 * index]
            stamp, listing = docs[2 * index + 1]
            binding = bind.get("binding") if isinstance(bind, dict) else None
            if not isinstance(binding, dict) or binding.get("window_id") != window:
                raise ToolError("%s: window %s did not bind" % (label, window))
            if not isinstance(listing, dict) or not isinstance(listing.get("sessions"), list):
                raise ToolError("%s: unreadable session list for window %s" % (label, window))
            out[window] = (stamp, listing["sessions"], result.t0, result.t1)
        return out

    def validate_bundle(self):
        bundle = os.path.realpath(self.env.bundle_path())
        if os.path.basename(os.path.dirname(bundle)) != "DebugApps" or not bundle.endswith(".app"):
            raise Precondition("bundle is not inside a DebugApps directory: " + bundle)
        try:
            with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
                info = plistlib.load(handle)
        except (OSError, ValueError, plistlib.InvalidFileException, xml.parsers.expat.ExpatError) as exc:
            raise Precondition("debug bundle Info.plist unreadable: %s" % exc)
        if not isinstance(info, dict):
            raise Precondition("debug bundle Info.plist is not a dictionary")
        if info.get("CFBundleIdentifier") != DEBUG_BUNDLE_ID:
            raise Precondition("bundle identifier is %r, not %s" % (info.get("CFBundleIdentifier"), DEBUG_BUNDLE_ID))
        name = info.get("CFBundleExecutable", "")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name or ""):
            raise Precondition("unsafe CFBundleExecutable: %r" % name)
        executable = os.path.join(bundle, "Contents/MacOS", name)
        if not (os.path.isfile(executable) and os.access(executable, os.X_OK)):
            raise Precondition("debug executable missing or not executable: " + executable)
        return bundle, os.path.realpath(executable)

    def read_provenance(self, bundle):
        path = os.path.join(bundle, "Contents/Resources/RepoPromptDebugProvenance.json")
        try:
            with open(path, "rb") as handle:
                raw = handle.read()
            data = json.loads(raw)
        except (OSError, ValueError) as exc:
            raise Precondition("debug provenance unavailable: %s" % exc)
        if not isinstance(data, dict):
            raise Precondition("debug provenance is not a JSON object")
        return data, hashlib.sha256(raw).hexdigest()

    def revalidate(self):
        if self.identity is None:
            return
        pids = self.env.list_pids(self.identity["executable"])
        if pids != [self.identity["pid"]]:
            raise Precondition("debug app PID identity changed: %s" % pids)
        if self.env.proc_identity(self.identity["pid"]) != self.identity["start"]:
            raise Precondition("debug app process start identity changed")
        _, digest = self.read_provenance(self.identity["bundle"])
        if digest != self.identity["provenance_sha256"]:
            raise Precondition("debug provenance changed")

    def approval_ok(self, data):
        try:
            settings = json.loads(data)
        except (TypeError, ValueError):
            raise Precondition("workspace.approvalSettings is not decodable JSON")
        # Synthesized Codable of WorkspaceApprovalSettings/WorkspaceApprovalClientPolicy: every non-optional key is
        # required and an unknown operation raw value fails the whole decode, so such data can grant nothing.
        def operations(value, where):
            if not (isinstance(value, list) and all(isinstance(v, str) and v in APPROVAL_OPERATIONS for v in value)):
                raise Precondition("workspace.approvalSettings %s is not a list of known operations" % where)
            return value

        def number(value):
            return isinstance(value, (int, float)) and not isinstance(value, bool)

        if not isinstance(settings, dict) or not isinstance(settings.get("autoApproveAll"), bool):
            raise Precondition("workspace.approvalSettings is not an object with a boolean autoApproveAll")
        global_ops = operations(settings.get("autoApproveOperations"), "autoApproveOperations")
        policies = settings.get("clientPolicies")
        if not isinstance(policies, dict):
            raise Precondition("workspace.approvalSettings clientPolicies is not an object")
        allowed = {}
        for key, policy in policies.items():
            if (not isinstance(policy, dict) or not isinstance(policy.get("clientID"), str)
                    or not number(policy.get("createdAt"))
                    or not (policy.get("lastUsedAt") is None or number(policy.get("lastUsedAt")))):
                raise Precondition("workspace.approvalSettings client policy %r is not decodable" % key)
            allowed[key] = operations(policy.get("allowedOperations"), "policy allowedOperations")
        out = {}
        for operation in ("create_workspace", "delete_workspace"):
            ok = settings["autoApproveAll"] or operation in global_ops
            for key, ops in allowed.items():
                if key.strip().lower() == EXEC_CLIENT and operation in ops:
                    ok = True
            out[operation] = ok
        return out

    def preflight(self):
        bundle, executable = self.validate_bundle()
        pids = self.env.list_pids(executable)
        if not pids:
            raise Precondition("missing-debug-app: no running process for " + executable)
        if len(pids) != 1:
            raise Precondition("ambiguous debug app processes: %s" % pids)
        pid = pids[0]
        start = self.env.proc_identity(pid)
        if not start:
            raise Precondition("could not read process identity for pid %d" % pid)
        provenance, digest = self.read_provenance(bundle)
        expected = self.cfg.expect_commit or self.env.default_head()
        if not re.fullmatch(r"[0-9a-f]{40}", expected or ""):
            raise Precondition("expected commit is not 40 hex")
        if provenance.get("commit") != expected or provenance.get("dirty") is not False:
            raise Precondition("debug provenance does not match a clean %s" % expected)
        cli = self.env.which_cli()
        helper = os.path.realpath(os.path.join(bundle, "Contents/MacOS/repoprompt-mcp"))
        if not cli or cli != helper:
            raise Precondition("rpce-cli-debug does not resolve to the validated bundle helper")
        self.cfg.cli_path = cli
        self.identity = {"pid": pid, "start": start, "executable": executable, "bundle": bundle,
                         "provenance_sha256": digest, "commit": expected, "branch": provenance.get("branch"),
                         "buildTime": provenance.get("buildTimeISO")}
        policy = self.approval_ok(self.env.approval_policy(DEBUG_BUNDLE_ID))
        if not all(policy.values()):
            raise Precondition("persisted approval policy does not auto-approve create+delete: %s" % policy)
        self.identity["approval"] = policy
        self.identity["cli_version"] = self.env.cli_version(cli)
        self.start_args = self.load_start_args()
        self.journal("preflight", identity=self.identity)

    def load_start_args(self):
        try:
            with open(self.cfg.start_args_file) as handle:
                items = json.load(handle)
        except (OSError, ValueError) as exc:
            raise Precondition("start arguments file unusable: %s" % exc)
        if not isinstance(items, list) or len(items) != 3:
            raise Precondition("start arguments must be a three-element array")
        for item in items:
            ok = (isinstance(item, dict) and set(item) == {"decision_id", "start_arguments"}
                  and isinstance(item["decision_id"], str) and item["decision_id"]
                  and isinstance(item["start_arguments"], dict)
                  and set(item["start_arguments"]) <= {"model_id", "model_parameters"})
            if not ok:
                raise Precondition("invalid start argument entry: %s" % json.dumps(item)[:120])
        return items

    def snapshot(self, label):
        windows = self.list_windows(label + "-windows")
        if len(windows) > 32:
            raise Precondition("baseline has more than 32 windows")
        ids = sorted(w.get("window_id") for w in windows)
        sessions = self.list_sessions_many(ids, label + "-sessions") if ids else {}
        for window, (_, rows, _, _) in sessions.items():
            if len(rows) > 1000:
                raise Precondition("window %s session list saturated" % window)
        one = self.env.oneshot(self.identity["pid"])
        return {"windows": windows, "ids": ids, "workspaces": self.list_workspaces(label + "-ws"),
                "sessions": {w: rows for w, (_, rows, _, _) in sessions.items()}, "cg": one}

    def take_baseline(self):
        base = self.snapshot("baseline")
        if 1 not in base["ids"]:
            raise Precondition("startup window 1 is not present")
        if base["cg"]["count"] < 1:
            raise Precondition("no on-screen layer-0 window for the debug app")
        if abs(base["cg"]["t"] - self.env.now()) > 5.0:
            raise Precondition("clock domain mismatch between helper samples and probe timestamps")
        self.baseline = base
        self.journal("baseline", ids=base["ids"], cg=base["cg"]["numbers"])

    def set_fleet(self):
        doc = self.call("app_settings", {"op": "get", "key": FLEET_KEY}, "fleet-get")
        value = (doc.get("values") or {}).get(FLEET_KEY)
        if not isinstance(value, bool):
            raise Precondition("fleet setting unreadable")
        self.J["fleet"] = {"original": value, "state": "never"}
        if value is True:
            return
        self.J["fleet"]["state"] = "attempted"
        self.journal("fleet-set-intent")
        self.call("app_settings", {"op": "set", "key": FLEET_KEY, "value": True}, "fleet-set", mutation=True)
        self.J["fleet"]["state"] = "set"
        check = self.call("app_settings", {"op": "get", "key": FLEET_KEY}, "fleet-readback")
        if (check.get("values") or {}).get(FLEET_KEY) is not True:
            raise Invariant("fleet setting did not read back true")

    def reconcile_workspace(self, name):
        try:
            matches = [w for w in self.list_workspaces("reconcile-ws") if w.get("name") == name]
        except (ToolError, CallTimeout):
            return None
        if len(matches) != 1:
            if matches:
                self.residuals.append("ambiguous workspaces named %s preserved" % name)
            return None
        return matches[0]

    def window_of(self, workspace_id):
        try:
            windows = self.list_windows("reconcile-windows")
        except (ToolError, CallTimeout):
            return None
        for window in windows:
            if workspace_id in collect_values(window, "workspace_id", set()):
                return window.get("window_id")
        return None

    def create_one(self, index):
        name = "fm05-%s-%d" % (self.cfg.run8, index)
        entry = {"name": name, "workspace_id": None, "window_id": None, "session_name": name + "-agent",
                 "session_id": None, "deleted": False}
        self.J["workspaces"].append(entry)
        self.journal("create-intent", name=name)
        before = self.env.oneshot(self.identity["pid"])
        sampler = self.env.start_sampler(self.identity["pid"])
        t_send = t_resp = None
        try:
            if not sampler.wait_ready(5.0):
                raise Precondition("sampler never reported readiness")
            t_send = self.env.now()
            try:
                doc = self.call("manage_workspaces",
                                {"action": "create", "name": name, "open_in_new_window": True, "switch_to_created": True},
                                "create-%d" % index, mutation=True)
            except CallTimeout:
                self.flags["timeout"] = True
                found = self.reconcile_workspace(name)
                if found:
                    entry["workspace_id"] = found.get("id")
                    entry["window_id"] = self.window_of(found.get("id"))
                    self.journal("create-reconciled", entry=entry)
                raise Precondition("create timed out (possible pending approval)")
            except ToolError as exc:
                found = self.reconcile_workspace(name)
                if found:
                    entry["workspace_id"] = found.get("id")
                    entry["window_id"] = self.window_of(found.get("id"))
                    self.journal("create-reconciled", entry=entry)
                if isinstance(exc, EnvironmentFailure):
                    raise Precondition("create refused: %s" % exc)
                raise Invariant("create failed: %s" % exc)
            t_resp = self.env.now()
            workspaces = doc.get("workspaces")
            window_id = doc.get("window_id")
            if (not isinstance(workspaces, list) or len(workspaces) != 1 or not workspaces[0].get("id")
                    or not isinstance(window_id, int)):
                raise Invariant("create returned an unusable payload")
            entry["workspace_id"], entry["window_id"] = workspaces[0]["id"], window_id
            self.journal("create-confirmed", entry=entry)
            self.env.sleep(max(0.0, t_resp + 1.25 - self.env.now()) + 0.05)
        finally:
            trace = self.save_trace("open-%d" % index, index, before, t_send, t_resp, sampler.stop())
        if not trace["ok"]:
            raise Precondition("sampler evidence inconclusive: " + trace["reason"])
        return entry

    def save_trace(self, label, index, before, t_send, t_resp, samples):
        """Raw series always lands on disk, including failed/inconclusive calls."""
        path = os.path.join(self.run_dir, "trace-%s.jsonl" % label)
        known = set(before["numbers"])
        seen = set(n for s in samples for n in s.get("all_numbers", []))
        first = min(samples, key=lambda s: s["t"]) if samples else None
        started_with = set(first.get("all_numbers", [])) if first else set()
        with open(path, "w") as handle:
            handle.write(json.dumps({"kind": "call", "label": label, "t_send": t_send, "t_resp": t_resp,
                                     "baseline_count": before["count"], "baseline_numbers": before["numbers"]}) + "\n")
            for sample in samples:
                handle.write(json.dumps(dict(sample, kind="sample")) + "\n")
        if t_send is not None and t_resp is not None:
            ok, reason, stats = sample_coverage(samples, t_send, t_resp)
        else:
            ok, reason, stats = False, "call did not complete", {}
        trace = {"label": label, "index": index, "path": path, "t_send": t_send, "t_resp": t_resp, "ok": ok,
                 "reason": reason, "stats": stats, "samples": len(samples), "baseline_count": before["count"],
                 "max_count": max([s["count"] for s in samples] or [0]),
                 "extra_visibility": any(set(s["numbers"]) - known for s in samples),
                 "aux_numbers_seen": sorted(seen),
                 "aux_numbers_new_since_first_sample": sorted(seen - started_with)}
        self.J.setdefault("traces", []).append(trace)
        self.journal("trace", trace=trace)
        return trace

    def start_one(self, index, entry):
        decision = self.start_args[index]
        args = {"op": "start", "message": PROMPT, "session_name": entry["session_name"], "detach": True, "timeout": 0}
        args.update(decision["start_arguments"])
        self.journal("start-intent", name=entry["session_name"], decision=decision["decision_id"])
        try:
            doc = self.call("agent_run", args, "start-%d" % index, window=entry["window_id"], mutation=True)
        except (CallTimeout, ToolError):
            self.reconcile_session(entry)
            raise
        session_id = doc.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            self.reconcile_session(entry)
            raise Invariant("start returned no session id")
        entry["session_id"] = session_id
        self.journal("start-confirmed", entry=entry)

    def reconcile_session(self, entry):
        if entry.get("window_id") is None:
            return
        try:
            rows = self.list_sessions_many([entry["window_id"]], "reconcile-sessions")[entry["window_id"]][1]
        except (ToolError, CallTimeout):
            return
        matches = [r for r in rows if entry["session_name"] in [v for v in r.values() if isinstance(v, str)]]
        if len(matches) == 1 and matches[0].get("session_id"):
            entry["session_id"] = matches[0]["session_id"]
            self.journal("start-reconciled", entry=entry)

    def setup(self):
        self.set_fleet()
        for index in range(3):
            entry = self.create_one(index)
            try:
                self.start_one(index, entry)
            except Precondition:
                raise
            except (CallTimeout, ToolError, Invariant) as exc:
                if index == 0:
                    raise Precondition("first agent could not start: %s" % exc)
                if isinstance(exc, EnvironmentFailure):
                    raise Precondition("agent %d refused: %s" % (index, exc))
                raise Invariant("agent %d did not start: %s" % (index, exc))

    # -- DW-5
    def readiness(self):
        windows = [e["window_id"] for e in self.J["workspaces"]]
        sessions = [e["session_id"] for e in self.J["workspaces"]]
        started = self.env.now()
        overlong = 0
        for round_no in range(30):
            remaining = min(5.0, 120.0 - (self.env.now() - started))
            if remaining <= 0:
                break
            r0 = self.env.now()
            try:
                result = self.list_sessions_many(windows, "poll-%d" % round_no, timeout=remaining)
            except EnvironmentFailure:
                raise
            except (ToolError, CallTimeout):
                overlong += 1
                self.env.sleep(1.0)
                continue
            r1 = self.env.now()
            if r1 - r0 > 5.0:
                overlong += 1
                self.env.sleep(1.0)
                continue
            states, good = [], True
            for window, session_id in zip(windows, sessions):
                row = next((s for s in result[window][1] if s.get("session_id") == session_id), None)
                raw = (row or {}).get("raw_state")
                live = bool(row and row.get("is_live"))
                states.append({"window": window, "raw_state": raw, "state": (row or {}).get("state"), "live": live,
                               "receipt": result[window][0]})
                active = raw in ACTIVE_RAW if raw else (row or {}).get("state") in {"running", "waiting_for_input"}
                good = good and live and active
            self.J.setdefault("rounds", []).append({"round": round_no, "start": r0, "end": r1, "states": states})
            self.journal("poll-round", round=round_no, duration=round(r1 - r0, 3), good=good)
            if good:
                return {"round": round_no, "duration": r1 - r0, "states": states}
            self.env.sleep(1.0)
        if overlong:
            raise Precondition("readiness exhausted with overlong/unreadable rounds")
        raise Invariant("sessions never became active within a timely round")

    def check_dw5(self):
        win = self.list_windows("dw5-windows")
        got = sorted(w.get("window_id") for w in win)
        owned = sorted(e["window_id"] for e in self.J["workspaces"])
        if len(set(owned)) != 3:
            raise Invariant("returned window IDs are not three distinct IDs: %s" % owned)
        if got != sorted(self.baseline["ids"] + owned):
            raise Invariant("window set %s is not baseline + exactly the three returned IDs %s" % (got, owned))
        for entry in self.J["workspaces"]:
            mine = next(w for w in win if w.get("window_id") == entry["window_id"])
            if entry["workspace_id"] not in collect_values(mine, "workspace_id", set()):
                raise Invariant("window %s is not mapped to workspace %s" % (entry["window_id"], entry["workspace_id"]))
        ready = self.readiness()
        now = self.env.oneshot(self.identity["pid"])
        if now["count"] != self.baseline["cg"]["count"] or now["numbers"] != self.baseline["cg"]["numbers"]:
            raise Invariant("on-screen CG count/numbers changed: %s -> %s" % (self.baseline["cg"]["numbers"], now["numbers"]))
        return {"round": ready, "cg_after": now, "windows": got}

    # -- v9
    def v9_delete_first(self):
        entry = self.J["workspaces"][0]
        before = self.env.oneshot(self.identity["pid"])
        sampler = self.env.start_sampler(self.identity["pid"])
        t_send = t_resp = None
        try:
            if not sampler.wait_ready(5.0):
                raise Precondition("sampler never reported readiness")
            self.cancel_entry(entry)
            t_send = self.env.now()
            doc = self.delete_entry(entry)
            t_resp = self.env.now()
            self.env.sleep(1.3)
        finally:
            trace = self.save_trace("delete-first", 0, before, t_send, t_resp, sampler.stop())
        stats = trace["stats"]
        if not trace["ok"]:
            raise Precondition("delete trace inconclusive: " + trace["reason"])
        if doc.get("closed_window_id") != entry["window_id"]:
            raise Invariant("closed_window_id %r != %r" % (doc.get("closed_window_id"), entry["window_id"]))
        ids = [w.get("window_id") for w in self.list_windows("v9-windows")]
        if entry["window_id"] in ids:
            raise Invariant("deleted window still registered")
        after = self.env.oneshot(self.identity["pid"])
        if after["count"] != self.baseline["cg"]["count"]:
            raise Invariant("on-screen count did not return to baseline after delete")
        return {"closed_window_id": doc.get("closed_window_id"), "stats": stats, "before": before, "after": after}

    def pause(self, name, marker_label, owned=None):
        manifest = os.path.join(self.run_dir, name + "-driver-ready.json")
        done = os.path.join(self.run_dir, name + "-driver.done")
        if os.path.exists(done):
            raise Precondition("stale done file present: " + done)
        with open(manifest, "w") as handle:
            json.dump({"run": self.cfg.nonce, "pid": self.identity["pid"],
                       "owned": self.J["workspaces"] if owned is None else owned,
                       "protected_window_ids": self.baseline["ids"], "baseline_cg": self.baseline["cg"],
                       "helper": "%s <pid>" % (self.env_helper_path()), "done_file": done,
                       "pause_seconds": self.cfg.pause_seconds}, handle, indent=1, sort_keys=True)
        print("DRIVER-READY manifest=%s done=%s" % (manifest, done), flush=True)
        deadline = self.env.now() + self.cfg.pause_seconds
        while self.env.now() < deadline:
            if os.path.exists(done):
                return True
            self.env.sleep(0.5)
        self.note(marker_label)
        return False

    def env_helper_path(self):
        return getattr(self.env, "helper_bin", None) or "fleet_onscreen_windows"

    def cancel_entry(self, entry):
        if not entry.get("session_id") or entry.get("deleted") or entry.get("window_id") is None:
            return
        try:
            self.call("agent_run", {"op": "cancel", "session_id": entry["session_id"]}, "cancel",
                      window=entry["window_id"], mutation=True)
        except ToolError:
            if not self.terminal_session(entry):
                raise

    def terminal_session(self, entry):
        """A cancel can lose a race with a run that just finished; one bounded read proves that."""
        try:
            rows = self.list_sessions_many([entry["window_id"]], "cancel-verify", timeout=10.0)[entry["window_id"]][1]
        except (ToolError, CallTimeout):
            return False
        row = next((r for r in rows if r.get("session_id") == entry["session_id"]), None)
        return bool(row) and row.get("is_live") is False and row.get("state") not in ("running", "waiting_for_input") \
            and row.get("raw_state") not in ACTIVE_RAW

    def delete_entry(self, entry):
        windows = self.list_windows("pre-delete-windows")
        mine = next((w for w in windows if w.get("window_id") == entry["window_id"]), None)
        if mine is None or entry["workspace_id"] not in collect_values(mine, "workspace_id", set()):
            raise Invariant("window %s no longer maps to own workspace" % entry["window_id"])
        try:
            doc = self.call("manage_workspaces", {"action": "delete", "workspace": entry["workspace_id"],
                                                  "window_id": entry["window_id"], "close_window": True},
                            "delete", window=entry["window_id"], mutation=True)
        except CallTimeout:
            self.flags["timeout"] = True
            entry["delete_uncertain"] = True
            raise
        entry["deleted"] = True
        return doc

    def reconcile_delete(self, entry):
        """After a delete timeout: one read decides; never replay a possibly committed delete."""
        try:
            present = entry["window_id"] in [w.get("window_id") for w in self.list_windows("reconcile-delete")]
        except (ToolError, CallTimeout):
            return
        if not present:
            entry["deleted"] = True
            self.journal("delete-reconciled", entry=entry)

    def cleanup(self):
        if self.cleaned:
            return
        self.cleaned = True
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        try:
            self.env.kill_children()
        except Exception:
            pass
        for entry in self.J["workspaces"]:
            if entry.get("delete_uncertain") and not entry.get("deleted"):
                self.reconcile_delete(entry)
        steps = []
        for entry in self.J["workspaces"]:
            if entry.get("deleted"):
                continue
            if entry.get("workspace_id") is None:
                found = self.safe(self.reconcile_workspace, entry["name"])
                if found:
                    entry["workspace_id"] = found.get("id")
            if entry.get("workspace_id") is not None and entry.get("window_id") is None:
                entry["window_id"] = self.safe(self.window_of, entry["workspace_id"])
            if entry.get("session_id") is None:
                self.safe(self.reconcile_session, entry)
        for entry in self.J["workspaces"]:
            if entry.get("deleted"):
                continue
            steps.append(("cancel", entry))
        for kind, entry in steps:
            if entry.get("session_id"):
                self.step("cancel %s" % entry["session_id"], self.cancel_entry, entry)
        for entry in self.J["workspaces"]:
            if entry.get("deleted") or entry.get("workspace_id") is None or entry.get("window_id") is None:
                continue
            self.step("delete %s" % entry["workspace_id"], self.delete_entry, entry)
        for entry in self.J["workspaces"]:
            if (not entry.get("deleted") and entry.get("workspace_id") is not None
                    and entry.get("window_id") is None):
                self.fail("invariant", "own workspace %s (%s) has no identifiable window (unregistered or pending); "
                          "not closed" % (entry["workspace_id"], entry["name"]))
                self.residuals.append("workspace %s: window unknown or pending, close it manually"
                                      % entry["workspace_id"])
        fleet = self.J["fleet"]
        if fleet.get("state") in ("attempted", "set") and fleet.get("original") is False:
            def restore():
                self.call("app_settings", {"op": "set", "key": FLEET_KEY, "value": False}, "fleet-restore", mutation=True)
                doc = self.call("app_settings", {"op": "get", "key": FLEET_KEY}, "fleet-restore-readback")
                if (doc.get("values") or {}).get(FLEET_KEY) is not False:
                    raise Invariant("fleet setting not restored")
            self.step("restore fleet boolean", restore)
        self.verify_cleanup()

    def safe(self, fn, *args):
        try:
            return fn(*args)
        except Exception:
            return None

    def step(self, label, fn, *args):
        try:
            fn(*args)
        except (CallTimeout, ToolError, Invariant, Precondition) as exc:
            self.fail("invariant", "cleanup step '%s' failed: %s" % (label, exc))
            self.residuals.append(label)

    def verify_cleanup(self):
        if self.baseline is None or self.identity is None:
            return
        deadline = self.env.now() + 30
        problems = ["not checked"]
        while self.env.now() < deadline:
            try:
                now = self.snapshot("post")
            except (ToolError, CallTimeout, Precondition) as exc:
                problems = ["post-cleanup read failed: %s" % exc]
                self.env.sleep(1.0)
                continue
            problems = self.compare_protected(now)
            if not problems:
                return
            self.env.sleep(1.0)
        for problem in problems:
            self.fail("invariant", "cleanup verification: " + problem)
            self.residuals.append(problem)

    def compare_protected(self, now):
        problems = []
        owned_ids = {e["window_id"] for e in self.J["workspaces"] if e.get("window_id") is not None}
        owned_ws = {e["workspace_id"] for e in self.J["workspaces"] if e.get("workspace_id")}
        present = set(now["ids"])
        if present & owned_ids:
            problems.append("own windows still present: %s" % sorted(present & owned_ids))
        if {w.get("id") for w in now["workspaces"]} & owned_ws:
            problems.append("own workspaces still present")
        if now["cg"]["count"] != self.baseline["cg"]["count"] or now["cg"]["numbers"] != self.baseline["cg"]["numbers"]:
            problems.append("on-screen CG set differs from baseline")
        for window in self.baseline["windows"]:
            wid = window.get("window_id")
            match = next((w for w in now["windows"] if w.get("window_id") == wid), None)
            if match is None:
                problems.append("protected window %s missing" % wid)
            elif projected(match, LOCAL_FLAG_KEYS) != projected(window, LOCAL_FLAG_KEYS):
                problems.append("protected window %s changed" % wid)
        for wid, rows in self.baseline["sessions"].items():
            current = {r.get("session_id"): r for r in now["sessions"].get(wid, [])}
            for row in rows:
                other = current.get(row.get("session_id"))
                if other is None:
                    problems.append("protected session %s missing" % row.get("session_id"))
                elif projected(other) != projected(row):
                    problems.append("protected session %s state or identity changed" % row.get("session_id"))
        return problems


def exit_code(probe):
    f = probe.flags
    if f["signal"]:
        return f["signal"]
    if f["timeout"]:
        return 2
    if f["invariant"]:
        return 1
    if f["precondition"]:
        return 2
    return 0


def trace_line(trace):
    if trace["extra_visibility"]:
        verdict = ("SAMPLED EXTRA VISIBILITY (max on-screen count %d vs baseline %d; EM judges, no mechanism change here)"
                   % (trace["max_count"], trace["baseline_count"]))
    else:
        verdict = "no sampled escape at measured cadence (not proof of no sub-sample flash)"
    return ("- %s trace: %s; ok=%s %s; stats %s; raw series %s; logical window IDs are not CG numbers; no exact attach "
            "timestamp; no onDisappear instrumentation"
            % (trace["label"], verdict, trace["ok"], trace["reason"], json.dumps(trace["stats"]), trace["path"]))


def run(env, cfg):
    probe = Probe(env, cfg)
    os.makedirs(cfg.run_dir, exist_ok=True)

    def handler(number, _frame):
        raise SignalExit(128 + number)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)
    lines = []
    try:
        try:
            probe.preflight()
            if hasattr(env, "compile_helper"):
                env.compile_helper(cfg.run_dir)
            probe.take_baseline()
            probe.setup()
            ready = probe.check_dw5()
            lines += ["- identity: pid %s commit %s provenance %s" % (probe.identity["pid"], probe.identity["commit"],
                                                                     probe.identity["provenance_sha256"][:12]),
                      "- owned: " + json.dumps([{k: e[k] for k in ("workspace_id", "window_id", "session_id")}
                                                for e in probe.J["workspaces"]]),
                      "- CG numbers (distinct from logical IDs) baseline %s after %s" % (
                          probe.baseline["cg"]["numbers"], ready["cg_after"]["numbers"]),
                      "- poll round %d duration %.2fs (round start/end bounds; per-result stamps are stdout read-chunk "
                      "times and may collapse under pipe buffering, not app snapshot times)" % (
                          ready["round"]["round"], ready["round"]["duration"])]
            lines += [trace_line(t) for t in probe.J.get("traces", [])]
            if cfg.phase == "v9":
                measured = probe.v9_delete_first()
                lines.append("- delete-first closed_window_id=%s" % measured["closed_window_id"])
                lines += [trace_line(t) for t in probe.J.get("traces", []) if t["label"] == "delete-first"]
                probe.append_report("measurements", lines)
                driven = probe.pause("v9", "DW-11 not driven")
                if not driven:
                    probe.append_report("driver", ["DW-11 not driven"])
            elif cfg.phase == "ui":
                by_window = {s["window"]: s for s in ready["round"]["states"]}
                owned_states = []
                for entry in probe.J["workspaces"]:
                    observed = by_window[entry["window_id"]]
                    owned_states.append(dict(entry, raw_state=observed["raw_state"], state=observed["state"],
                                             waiting=observed["raw_state"] in WAITING_RAW))
                lines.append("- DW-7 readiness snapshot: " + json.dumps(owned_states, sort_keys=True))
                all_waiting = all(e["waiting"] for e in owned_states)
                lines.append("- DW-7 all waiting=" + str(all_waiting).lower()
                             + " (readiness-poll snapshot, not a live roster guarantee or DW-7 acceptance)")
                if not all_waiting:
                    lines.append("- DW-7 waiting precondition not yet evidenced; EM must re-sample during pause.")
                probe.append_report("DW-5 checks", lines)
                driven = probe.pause("ui", "DW-7 not driven", owned=owned_states)
                if not driven:
                    probe.append_report("driver", ["DW-7 not driven"])
            else:
                probe.append_report("DW-5 checks", lines)
        except Precondition as exc:
            probe.fail("precondition", str(exc))
        except Invariant as exc:
            probe.fail("invariant", str(exc))
        except EnvironmentFailure as exc:
            probe.fail("precondition", str(exc))
        except (CallTimeout, ToolError) as exc:
            probe.fail("invariant", str(exc))
    except SignalExit as sig:
        probe.flags["signal"] = sig.code
    finally:
        try:
            probe.cleanup()
        except SignalExit as sig:
            probe.flags["signal"] = sig.code
        except Exception as exc:
            probe.fail("invariant", "cleanup crashed: %s" % exc)
    if probe.identity is not None and cfg.phase:
        try:
            probe.append_report("cleanup", ["- residuals: %s" % json.dumps(probe.residuals),
                                            "- errors: %s" % json.dumps(probe.errors)]
                                + [trace_line(t) for t in probe.J.get("traces", [])])
        except OSError:
            pass
    for residual in probe.residuals:
        print("RESIDUAL (EM recovery needed, not executed): " + residual, file=sys.stderr)
    code = exit_code(probe)
    print("probe exit %d errors=%s" % (code, probe.errors), flush=True)
    return code, probe

class FakeSampler:
    def __init__(self, app, faults):
        self.app, self.faults, self.t0 = app, faults, app.t

    def wait_ready(self, seconds):
        return not self.faults.get("sampler_not_ready")

    def stop(self):
        out, t = [], self.t0 + (0.5 if self.faults.get("sampler_late") else 0.0)
        while t <= self.app.t:
            gap = self.faults.get("sampler_gap")
            if not (gap and gap[0] <= t - self.t0 <= gap[1]):
                shown = self.app.onscreen_at(t)
                out.append({"t": t + self.faults.get("helper_clock_offset", 0.0), "count": len(shown),
                            "numbers": sorted(shown),
                            "all_numbers": sorted(self.app.all_at(t))})
            t += 0.02
        return out


class FakeApp:
    """Closed in-memory model of the app surface the probe touches; no process, CLI, CG or real HOME."""

    def __init__(self, faults, nonce):
        self.f, self.nonce, self.t = faults, nonce, 1000.0
        self.windows = {1: ["ws-prot"]}
        self.ws = {"ws-prot": "Protected"}
        self.cg = {1: 5001}
        self.visible = {5001}
        self.events = [(0.0, {5001}, {5001})]
        self.sessions = [{"session_id": "S-prot", "window_id": 1, "workspace_id": "ws-prot", "state": "idle",
                          "raw_state": "idle", "is_live": False, "agent": "pair", "name": "Protected session",
                          "lm": 0, "items": 3}]
        self.fleet = faults.get("fleet_initial", False)
        self.next_window, self.next_cg, self.bound = 2, 6001, None
        self.log = []
        self.counts = {}
        self.pending = {}
        self.active_state = faults.get("agent_state", "waitingForQuestion")

    def onscreen_at(self, t):
        shown = self.events[0][1]
        for when, on, _ in self.events:
            if when <= t:
                shown = on
        return shown

    def all_at(self, t):
        every = self.events[0][2]
        for when, _, al in self.events:
            if when <= t:
                every = al
        return every

    def tick(self, seconds):
        self.t += seconds

    def push(self, onscreen, everything):
        self.events.append((self.t, set(onscreen), set(everything)))


class Fake:
    def __init__(self, cfg, app, home, faults, pids=None):
        self.cfg, self.app, self.home, self.f = cfg, app, home, faults
        self.pids = [4242] if pids is None else pids
        self.calls = []
        self.timeouts = []
        self.helper_bin = None

    def now(self):
        return self.app.t

    def sleep(self, seconds):
        self.app.tick(seconds)
        if self.f.get("signal_in_pause") and os.path.exists(os.path.join(self.cfg.run_dir, "ui-driver-ready.json")):
            raise SignalExit(143)

    def bundle_path(self):
        return os.path.join(self.home, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app")

    def list_pids(self, executable):
        return list(self.pids)

    def proc_identity(self, pid):
        return "Wed Oct 14 10:00:00 2026 " + self.bundle_path()

    def which_cli(self):
        if self.f.get("wrong_cli"):
            return "/fake/other/installed/repoprompt-mcp"
        return os.path.realpath(os.path.join(self.bundle_path(), "Contents/MacOS/repoprompt-mcp"))

    def cli_version(self, cli):
        return "fake-cli 0"

    def default_head(self):
        return "a" * 40

    def approval_policy(self, domain):
        if "approval_payload" in self.f:
            return self.f["approval_payload"]
        if self.f.get("no_approval"):
            return json.dumps({"autoApproveAll": False, "autoApproveOperations": [], "clientPolicies": {}}).encode()
        if self.f.get("garbled_approval"):
            return b"not json"
        policy = {"createdAt": 1, "clientID": "RepoPrompt CLI (Exec)", "allowedOperations": ["create_workspace", "delete_workspace"]}
        return json.dumps({"autoApproveAll": False, "autoApproveOperations": [],
                           "clientPolicies": {" RepoPrompt CLI (Exec) ": policy}}).encode()

    def oneshot(self, pid):
        shown = self.app.onscreen_at(self.app.t)
        if self.f.get("stub_ids_only"):
            shown = {5001}
        return {"pid": pid, "t": self.app.t + self.f.get("helper_clock_offset", 0.0), "count": len(shown),
                "numbers": sorted(shown)}

    def start_sampler(self, pid):
        return FakeSampler(self.app, self.f)

    def kill_children(self):
        pass
    def cli(self, cmds, timeout, label):
        app, t0, docs = self.app, self.app.t, []
        self.calls.append((label, list(cmds)))
        self.timeouts.append((label, t0, timeout))
        forced = self.f.get("cli_status")
        if forced and label.startswith(forced[0]):
            return Result(forced[1], [], "", forced[2], t0, app.t, False, cmds)
        for command in cmds:
            app.tick(0.02)
            if command == "windows":
                docs.append(self.windows_doc())
                continue
            if command.startswith("use "):
                n = int(command.split()[1])
                if n not in self.visible_windows():
                    return Result(1, docs, "", "no such window", t0, app.t, False, cmds)
                app.bound = n
                docs.append((app.t, {"binding": {"window_id": n}}))
                continue
            tool, _, payload = command[len("call "):].partition(" ")
            args = json.loads(payload)
            result = self.dispatch(tool, args, label)
            if result == "TIMEOUT":
                app.tick(timeout)
                return Result(None, docs, "", "", t0, app.t, True, cmds)
            if result == "MALFORMED":
                return Result(0, docs, "", "", t0, app.t, False, cmds, "malformed output: injected")
            if isinstance(result, tuple) and result[0] == "STATUS":
                return Result(result[1], docs, "", result[2], t0, app.t, False, cmds)
            if isinstance(result, tuple) and result[0] == "ERROR":
                docs.append((app.t, {"error": result[1]}))
                return Result(1, docs, "", result[1], t0, app.t, False, cmds)
            docs.append((app.t, json.loads(json.dumps(result))))
            if app.t - t0 > timeout:
                return Result(None, docs, "", "", t0, app.t, True, cmds)
        return Result(0, docs, "", "", t0, app.t, False, cmds)

    def visible_windows(self):
        return list(self.app.windows)

    def windows_doc(self):
        # MCPBindContextWindowSummary / MCPBindContextTabSummary key sets (MCPHostRoutingValueContracts.swift)
        for wid in list(self.app.pending):
            ws, number, left = self.app.pending[wid]
            if left <= 1:
                del self.app.pending[wid]
                self.app.windows[wid] = [ws]
                self.app.cg[wid] = number
                self.app.push(self.app.visible, set(self.app.cg.values()))
            else:
                self.app.pending[wid][2] = left - 1
        rows = []
        for w, wss in sorted(self.app.windows.items()):
            tabs = [{"context_id": "c-%d-%d" % (w, i), "name": "Tab", "workspace_id": ws,
                     "workspace_name": self.app.ws.get(ws, ""), "is_active": True, "is_bound": w == self.app.bound,
                     "repo_paths": []} for i, ws in enumerate(wss)]
            rows.append({"window_id": w, "is_current_window": w == self.app.bound,
                         "workspace": {"id": wss[0], "name": self.app.ws.get(wss[0], "")} if wss else None,
                         "active_context_id": tabs[0]["context_id"] if tabs else None, "tabs": tabs})
        return (self.app.t, {"windows": rows})

    def session_row(self, row):
        # sessionSummaryObject key set (AgentManageMCPToolService.swift); raw_state only when it differs
        out = {"session_id": row["session_id"], "name": row.get("name") or row.get("session_name", ""),
               "last_modified": "2026-10-14T10:00:%02dZ" % row.get("lm", 0), "item_count": row.get("items", 0),
               "state": row["state"], "is_live": row["is_live"]}
        if row.get("raw_state") != row["state"]:
            out["raw_state"] = row["raw_state"]
        return out

    def hit(self, key):
        self.app.counts[key] = self.app.counts.get(key, 0) + 1
        return self.app.counts[key]

    def dispatch(self, tool, args, label):
        app, f = self.app, self.f
        if f.get("signal_at") and label.startswith(f["signal_at"][0]) and self.hit("sig") == f["signal_at"][1]:
            raise SignalExit(f["signal_at"][2])
        if tool == "app_settings":
            if args["op"] == "get":
                return {"values": {FLEET_KEY: app.fleet}}
            self.hit("setting_write")
            app.fleet = args["value"]
            return {"values": {FLEET_KEY: app.fleet}}
        if tool == "manage_workspaces" and args["action"] == "list":
            return {"workspaces": [{"id": i, "name": n, "root_count": 0, "repo_paths": [], "is_hidden": False,
                                    "showing_window_ids": [w for w, wss in app.windows.items() if i in wss]}
                                   for i, n in app.ws.items()]}
        if tool == "manage_workspaces" and args["action"] == "create":
            n = self.hit("create")
            if f.get("protected_activity") and n == 1:
                app.sessions[0]["lm"] += 7
                app.sessions[0]["items"] += 2
            if f.get("protected_state_change") and n == 1:
                app.sessions[0]["state"] = "running"
                app.sessions[0]["raw_state"] = "running"
            if f.get("malformed_create"):
                return "MALFORMED"
            if f.get("create_denied"):
                return ("ERROR", "Invalid request: Workspace creation was denied by the user.")
            if f.get("create_fail_at") == n:
                return ("ERROR", "binding error after commit")
            if f.get("foreign_at") == n:
                app.windows[77] = ["ws-foreign"]
                app.ws["ws-foreign"] = "Foreign"
                app.cg[77] = 7777
            wid, ws = app.next_window, "ws-%d" % app.next_window
            app.next_window += 1
            app.ws[ws] = args["name"]
            app.windows[wid] = [ws]
            number = app.next_cg
            app.next_cg += 1
            app.cg[wid] = number
            if f.get("late_window_reads"):
                app.pending[wid] = [ws, number, f["late_window_reads"]]
                app.windows.pop(wid)
                app.cg.pop(wid)
            everything = set(app.cg.values())
            escape = f.get("escape_on_open")
            app.push(app.visible | ({number} if escape else set()), everything)
            app.tick(0.3)
            if escape:
                app.push(app.visible, everything)
            if f.get("create_status_after_commit"):
                return ("STATUS", f["create_status_after_commit"], "RepoPrompt MCP: connection failed")
            if f.get("create_timeout_at") == n:
                return "TIMEOUT"
            returned = wid
            if f.get("wrong_ids") and n == 2:
                returned = 999
            return {"workspaces": [{"id": ws, "name": args["name"]}], "window_id": returned}
        if tool == "manage_workspaces" and args["action"] == "delete":
            n = self.hit("delete")
            self.app.log.append(("delete", args["workspace"]))
            if f.get("delete_fail_at") == n:
                return ("ERROR", "delete failed")
            if f.get("delete_denied_at") == n:
                return ("ERROR", "Invalid request: Workspace deletion was denied by the user.")
            lost = f.get("delete_timeout_at") == n
            if args["workspace"] not in app.ws or app.ws[args["workspace"]] == "Protected":
                return ("ERROR", "unknown workspace")
            wid = args["window_id"]
            if not f.get("delete_leaves_window"):
                app.windows.pop(wid, None)
                app.ws.pop(args["workspace"], None)
                app.cg.pop(wid, None)
                app.push(app.visible, set(app.cg.values()))
            closed = 999 if (f.get("v9_wrong_closed") and wid == 2) else wid
            if lost:
                return "TIMEOUT"
            return {"closed_window_id": closed}
        if tool == "agent_run" and args["op"] == "start":
            n = self.hit("start")
            if f.get("first_start_fails") and n == 1:
                return ("ERROR", "agent unavailable")
            row = {"session_id": "S-%d" % n, "window_id": app.bound, "session_name": args["session_name"],
                   "workspace_id": app.windows[app.bound][0], "state": "waiting_for_input",
                   "raw_state": app.active_state, "is_live": True}
            row.update(f.get("agent_rows", [{}, {}, {}])[n - 1])
            app.sessions.append(row)
            if f.get("start_timeout_at") == n:
                return "TIMEOUT"
            return {"session_id": "S-%d" % n}
        if tool == "agent_run" and args["op"] == "cancel":
            n = self.hit("cancel")
            self.app.log.append(("cancel", args["session_id"]))
            if f.get("cancel_fail"):
                return ("ERROR", "cancel failed")
            if f.get("already_terminal"):
                for row in app.sessions:
                    if row["session_id"] == args["session_id"]:
                        row.update(state="completed", raw_state="completed", is_live=False)
                return ("ERROR", "The run is not currently active")
            for row in app.sessions:
                if row["session_id"] == args["session_id"]:
                    row.update(state="cancelled", raw_state="cancelled", is_live=False)
            return {"ok": True}
        if tool == "agent_manage":
            if f.get("truncated_list"):
                return {"sessions": [{"session_id": "x%d" % i} for i in range(1001)]}
            if f.get("slow_poll"):
                app.tick(6.0)
            return {"sessions": [self.session_row(s) for s in app.sessions if s["window_id"] == app.bound]}
        return ("ERROR", "unsupported fake tool " + tool)

def build_fixture_home(fixtures, name, commit="a" * 40, dirty=False, bundle_id=DEBUG_BUNDLE_ID):
    home = os.path.join(fixtures, name)
    if os.path.isdir(home):
        shutil.rmtree(home)
    bundle = os.path.join(home, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app")
    os.makedirs(os.path.join(bundle, "Contents/MacOS"))
    os.makedirs(os.path.join(bundle, "Contents/Resources"))
    with open(os.path.join(bundle, "Contents/Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "RepoPrompt"}, handle)
    for exe in ("RepoPrompt", "repoprompt-mcp"):
        path = os.path.join(bundle, "Contents/MacOS", exe)
        with open(path, "w") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(path, 0o755)
    with open(os.path.join(bundle, "Contents/Resources/RepoPromptDebugProvenance.json"), "w") as handle:
        json.dump({"commit": commit, "dirty": dirty, "branch": "story/fixture", "buildTimeISO": "2026-10-14T10:00:00-05:00"}, handle)
    return home


class Cfg:
    def __init__(self, **kw):
        self.self_test = True
        self.phase = ""
        self.expect_commit = "a" * 40
        self.pause_seconds = 5.0
        self.cli_path = ""
        self.__dict__.update(kw)


def write_start_args(dirpath, entries=None):
    path = os.path.join(dirpath, "start-args.json")
    entries = entries if entries is not None else [{"decision_id": "d%d" % i, "start_arguments": {}} for i in range(3)]
    with open(path, "w") as handle:
        json.dump(entries, handle)
    return path


FIXTURES = ""


def run_case(name, faults=None, phase="", pids=None, home_kw=None, start_entries=None, done_marker=False,
             pause_seconds=5.0, real_pause=False):
    faults = faults or {}
    case_dir = os.path.join(FIXTURES, "case-" + name)
    if os.path.isdir(case_dir):
        shutil.rmtree(case_dir)
    os.makedirs(case_dir)
    home = build_fixture_home(case_dir, "home", **(home_kw or {}))
    record_root = os.path.join(case_dir, "record")
    os.makedirs(record_root)
    nonce = "case-" + name
    cfg = Cfg(phase=phase, record_root=record_root, run_dir=os.path.join(record_root, "runs", nonce), nonce=nonce,
              run8="c0ffee00", start_args_file=write_start_args(case_dir, start_entries), pause_seconds=pause_seconds)
    app = FakeApp(faults, nonce)
    env = Fake(cfg, app, home, faults, pids)
    if done_marker:
        orig = env.sleep

        def sleeper(seconds, orig=orig):
            orig(seconds)
            marker = os.path.join(cfg.run_dir, ("v9" if phase == "v9" else "ui") + "-driver.done")
            ready_path = os.path.join(cfg.run_dir, ("v9" if phase == "v9" else "ui") + "-driver-ready.json")
            if os.path.isdir(cfg.run_dir) and os.path.exists(ready_path):
                if env.driver_manifest is None:
                    with open(ready_path) as handle:
                        env.driver_manifest = json.load(handle)
                    report_path = os.path.join(record_root, "v9-report.md")
                    if os.path.exists(report_path):
                        with open(report_path) as handle:
                            env.driver_report = handle.read()
                open(marker, "w").close()
        env.driver_manifest = None
        env.driver_report = None
        env.sleep = sleeper
    if real_pause:
        virtual = env.sleep

        def slow(seconds, virtual=virtual):
            virtual(seconds)
            if os.path.exists(os.path.join(cfg.run_dir, "ui-driver-ready.json")):
                time.sleep(0.2)
        env.sleep = slow
    try:
        code, probe = run(env, cfg)
    except Exception as exc:
        code, probe = "EXC:%s" % type(exc).__name__, None
    report = ""
    path = os.path.join(record_root, "v9-report.md")
    if os.path.exists(path):
        report = open(path).read()
    return code, probe, env, app, report


def self_test_fixtures(record_root):
    global FIXTURES
    fixtures = FIXTURES = os.path.join(record_root, "u1", "fixtures")
    os.makedirs(fixtures, exist_ok=True)
    results = []

    def check(name, invariant, condition, detail=""):
        status = "PASS" if condition else "FAIL"
        results.append(bool(condition))
        print("%s %s :: protects: %s %s" % (status, name, invariant, detail), flush=True)

    def snapshot_ok(probe, env, expected):
        if probe is None:
            return False
        manifest, report = env.driver_manifest, env.driver_report
        if not isinstance(manifest, dict) or not report:
            return False
        owned = manifest.get("owned")
        if not isinstance(owned, list) or len(owned) != 3:
            return False
        identity_keys = ("workspace_id", "window_id", "session_id")
        if [{k: e.get(k) for k in identity_keys} for e in owned] != [
                {k: e.get(k) for k in identity_keys} for e in probe.J["workspaces"]]:
            return False
        if not all({"raw_state", "state", "waiting"} <= set(e) for e in owned):
            return False
        if [(e["raw_state"], e["state"], e["waiting"]) for e in owned] != expected:
            return False
        if not all(isinstance(e["waiting"], bool) for e in owned):
            return False
        if set(manifest) != {"run", "helper", "pid", "done_file", "owned", "protected_window_ids",
                             "baseline_cg", "pause_seconds"}:
            return False
        if (manifest.get("pid") != probe.identity["pid"] or manifest.get("baseline_cg") != probe.baseline["cg"]
                or manifest.get("protected_window_ids") != probe.baseline["ids"]
                or manifest.get("pause_seconds") != probe.cfg.pause_seconds):
            return False
        all_waiting = all(e["waiting"] for e in owned)
        if "- DW-7 readiness snapshot: " + json.dumps(owned, sort_keys=True) not in report:
            return False
        if ("- DW-7 all waiting=" + str(all_waiting).lower()) not in report:
            return False
        if "DW-7 waiting precondition not yet evidenced" in report and all_waiting:
            return False
        if "DW-7 waiting precondition not yet evidenced" not in report and not all_waiting:
            return False
        polls = [label for label, _ in env.calls if label.startswith("poll-")]
        return len(polls) == 1

    def own_gone(app):
        return set(app.windows) == {1} and set(app.ws) == {"ws-prot"}

    def zero_mutation(env, app):
        return not any(l == "create" or l.startswith("create") or l.startswith("start") or l.startswith("fleet-set")
                       or l == "delete" or l == "cancel" for l, _ in env.calls) and app.counts.get("create", 0) == 0

    code, probe, env, app, _ = run_case("valid_flow")
    check("valid_flow", "three windows, CG unchanged, cleanup returns to baseline", code == 0 and own_gone(app)
          and app.fleet is False and app.counts.get("create") == 3 and app.counts.get("start") == 3
          and probe.J["workspaces"][0]["window_id"] == 2, "exit=%s" % code)
    stub = FakeApp({}, "stub")
    stub_env = Fake(Cfg(), stub, "", {})
    cfg = Cfg(phase="", record_root=os.path.join(fixtures, "case-stub"), run_dir=os.path.join(fixtures, "case-stub", "run"),
              nonce="stub", run8="c0ffee00", start_args_file="")
    os.makedirs(cfg.run_dir, exist_ok=True)
    probe = Probe(stub_env, cfg)
    probe.identity = {"pid": 1}
    probe.baseline = {"ids": [1], "cg": {"count": 1, "numbers": [5001]}, "windows": [], "workspaces": [], "sessions": {}}
    probe.J["workspaces"] = [{"window_id": w, "workspace_id": "ws-%d" % w, "session_id": "S"} for w in (11, 12, 13)]
    try:
        probe.check_dw5()
        stubbed = False
    except Invariant:
        stubbed = True
    check("ids_only_stub_windows", "three plausible IDs absent from windows/state fail independent checks", stubbed)
    code, probe, env, app, _ = run_case("wrong_cli", {"wrong_cli": True})
    check("wrong_cli", "CLI must resolve to the validated bundle helper before any mutation", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("wrong_bundle", home_kw={"bundle_id": "com.repoprompt.ce"})
    check("wrong_bundle", "non-DEBUG bundle identity fails before mutation", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("dirty_provenance", home_kw={"dirty": True})
    check("dirty_provenance", "dirty provenance fails before mutation", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("commit_mismatch", home_kw={"commit": "b" * 40})
    check("commit_mismatch", "provenance commit must equal expected commit", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("missing_approval", {"no_approval": True})
    check("missing_approval", "missing persisted approval policy fails before mutation", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("garbled_approval", {"garbled_approval": True})
    check("garbled_approval", "undecodable approval policy fails closed", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("bad_start_args", start_entries=[{"decision_id": "x", "start_arguments": {"prompt": "no"}}] * 3)
    check("bad_start_args", "only model_id/model_parameters are accepted in start arguments", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("ambiguous_pids", pids=[1, 2])
    check("ambiguous_pids", "exactly one debug app PID is required", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("first_agent_unavailable", {"first_start_fails": True})
    check("first_agent_unavailable", "unavailable first agent exits 2 after cleanup", code == 2 and own_gone(app) and app.fleet is False, "exit=%s" % code)
    code, probe, env, app, _ = run_case("create_timeout_partial", {"create_timeout_at": 2})
    check("create_timeout_partial", "committed-but-timed-out create is reconciled by nonce, never replayed, cleaned, exit 2",
          code == 2 and app.counts.get("create") == 2 and own_gone(app), "exit=%s creates=%s" % (code, app.counts.get("create")))
    code, probe, env, app, _ = run_case("create_error_partial", {"create_fail_at": 1})
    check("create_error_partial", "binding error after commit is partial success, not a replay", code == 1 and app.counts.get("create") == 1, "exit=%s" % code)
    code, probe, env, app, _ = run_case("start_timeout_partial", {"start_timeout_at": 2})
    check("start_timeout_partial", "uncertain start is reconciled and cancelled, never restarted",
          code in (1, 2) and app.counts.get("start") == 2 and own_gone(app) and app.counts.get("cancel", 0) >= 1, "exit=%s" % code)
    code, probe, env, app, _ = run_case("signal_setup", {"signal_at": ("create-1", 1, 130)})
    check("signal_setup", "INT during setup keeps 130 after cleanup", code == 130 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("signal_term", {"signal_at": ("start-1", 1, 143)})
    check("signal_term", "TERM keeps 143 after cleanup", code == 143 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("cancel_failure", {"cancel_fail": True})
    check("cancel_failure", "cancel failure still attempts every delete and restores the setting",
          code == 1 and app.counts.get("delete") == 3 and app.fleet is False, "exit=%s" % code)
    code, probe, env, app, _ = run_case("delete_failure", {"delete_fail_at": 1})
    check("delete_failure", "one failed delete does not stop remaining deletes or restoration",
          code == 1 and app.counts.get("delete") == 3 and app.fleet is False and probe.residuals, "exit=%s" % code)
    code, probe, env, app, _ = run_case("foreign_resource", {"foreign_at": 2})
    check("foreign_resource", "an unrelated new window/workspace is reported, never adopted or deleted",
          code in (1, 2) and 77 in app.windows and "ws-foreign" in app.ws
          and ("delete", "ws-foreign") not in app.log and app.counts.get("delete") == 3, "exit=%s" % code)
    code, probe, env, app, _ = run_case("window_left", {"delete_leaves_window": True})
    check("window_left", "residual own windows after cleanup are never green", code == 1, "exit=%s" % code)
    code, probe, env, app, _ = run_case("wrong_ids", {"wrong_ids": True})
    check("wrong_ids", "returned window ID absent from windows fails the exact-ID check", code == 1, "exit=%s" % code)
    code, probe, env, app, _ = run_case("truncated_list", {"truncated_list": True})
    check("truncated_list", "saturated session list is inconclusive, no mutation", code == 2 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("malformed_create", {"malformed_create": True})
    check("malformed_create", "malformed JSON never passes and cleanup still runs", code != 0 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("sampler_gap", {"sampler_gap": (0.1, 0.4)})
    check("sampler_gap", "a >100 ms sampler gap is inconclusive (2)", code == 2 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("sampler_late", {"sampler_late": True})
    check("sampler_late", "late first sample (no coverage of send) is inconclusive (2)", code == 2, "exit=%s" % code)
    code, probe, env, app, _ = run_case("slow_poll", {"slow_poll": True})
    check("slow_poll", "an overlong poll round cannot qualify (2)", code == 2 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("protected_state_change", {"protected_state_change": True})
    check("protected_state_change", "a protected session's run state/is_live must be unchanged after cleanup",
          code == 1 and own_gone(app) and any("S-prot" in r for r in probe.residuals), "exit=%s" % code)
    code, probe, env, app, _ = run_case("poll_budget", {"slow_poll": True})
    polls = [(l, t, to) for l, t, to in env.timeouts if l.startswith("poll-")]
    first = polls[0][1] if polls else 0
    check("poll_budget", "each readiness round process is bounded by min(5s, remaining 120s)",
          code == 2 and polls and all(to <= 5.0 and (t - first) + to <= 120.0 for _, t, to in polls),
          "exit=%s timeouts=%s" % (code, sorted({to for _, _, to in polls})))
    code, probe, env, app, _ = run_case("agents_never_active", {"agent_state": "idle"})
    check("agents_never_active", "timely rounds with inactive sessions exit 1", code == 1 and own_gone(app), "exit=%s" % code)
    code, probe, env, app, report = run_case("escape_reported", {"escape_on_open": True})
    check("escape_reported", "sampled extra visibility is preserved as a trace, not hidden",
          code == 0 and any(t["stats"]["max_count"] == 2 for t in probe.J["traces"]), "exit=%s" % code)
    code, probe, env, app, report = run_case("ui_no_marker", phase="ui")
    check("ui_no_marker", "missing UI driver marker writes DW-7 not driven and still exits 0",
          code == 0 and "DW-7 not driven" in report and own_gone(app), "exit=%s" % code)
    code, probe, env, app, report = run_case("ui_marker", phase="ui", done_marker=True)
    check("ui_marker", "done file ends the pause without the not-driven line",
          code == 0 and "DW-7 not driven" not in report
          and snapshot_ok(probe, env, [("waitingForQuestion", "waiting_for_input", True)] * 3), "exit=%s" % code)
    mixed = {"agent_rows": [
        {"raw_state": "waitingForApproval", "state": "waiting_for_input"},
        {"raw_state": "waitingForApproval", "state": "waiting_for_input"},
        {"raw_state": "running", "state": "running"}]}
    code, probe, env, app, report = run_case("ui_mixed_active", mixed, phase="ui", done_marker=True)
    states = probe.J.get("rounds", [{}])[0].get("states", []) if probe else []
    check("ui_mixed_active", "UI accepts three live active seats without demanding questions",
          code == 0 and len(states) == 3
          and [s["raw_state"] for s in states] == ["waitingForApproval", "waitingForApproval", None]
          and all(s["live"] for s in states) and states[2]["state"] == "running"
          and snapshot_ok(probe, env, [("waitingForApproval", "waiting_for_input", True),
                                       ("waitingForApproval", "waiting_for_input", True),
                                       (None, "running", False)])
          and own_gone(app) and app.fleet is False and not probe.residuals, "exit=%s" % code)
    variants = {"agent_rows": [{"raw_state": "waitingForUser", "state": "waiting_for_input"},
                               {"raw_state": "running", "state": "running"},
                               {"raw_state": "waiting_for_input", "state": "waiting_for_input"}]}
    code, probe, env, app, report = run_case("ui_active_variants", variants, phase="ui", done_marker=True)
    check("ui_active_variants", "every remaining active alternative passes UI readiness",
          code == 0 and snapshot_ok(probe, env, [("waitingForUser", "waiting_for_input", True),
                                                 (None, "running", False),
                                                 (None, "waiting_for_input", False)])
          and own_gone(app) and app.fleet is False and not probe.residuals, "exit=%s" % code)

    def refused(name, row):
        code, probe, env, app, report = run_case(name, {"agent_rows": [row, {}, {}]}, phase="ui", done_marker=True)
        return (code == 1 and "sessions never became active" in report
                and not os.path.exists(os.path.join(probe.cfg.run_dir, "ui-driver-ready.json"))
                and own_gone(app) and app.fleet is False), code
    ok, code = refused("ui_inactive_raw", {"raw_state": "idle", "state": "running"})
    check("ui_inactive_raw", "a present inactive raw state stays authoritative over coarse running", ok, "exit=%s" % code)
    ok, code = refused("ui_not_live", {"is_live": False})
    check("ui_not_live", "a not-live session never qualifies", ok, "exit=%s" % code)

    def dw5_guard(tag, owned=(2, 3, 4), mapped=None, cg=None):
        guard_dir = os.path.join(fixtures, "case-" + tag)
        os.makedirs(guard_dir, exist_ok=True)
        guard_env = Fake(Cfg(), FakeApp({}, tag), "", {})
        guard_cfg = Cfg(phase="", record_root=guard_dir, run_dir=os.path.join(guard_dir, "run"), nonce=tag,
                        run8="c0ffee00", start_args_file="")
        os.makedirs(guard_cfg.run_dir, exist_ok=True)
        guard = Probe(guard_env, guard_cfg)
        guard.identity = {"pid": 1}
        guard.baseline = {"ids": [1], "cg": {"count": 1, "numbers": [5001]}, "windows": [], "workspaces": [], "sessions": {}}
        guard.J["workspaces"] = [{"window_id": w, "workspace_id": "ws-%d" % n, "session_id": "S"}
                                 for w, n in zip(owned, (2, 3, 4))]
        shown = {w: "ws-%d" % w for w in (1, 2, 3, 4)}
        shown.update(mapped or {})
        reached = []
        guard.list_windows = lambda label="windows": [{"window_id": w, "tabs": [{"workspace_id": ws}]} for w, ws in shown.items()]
        guard.readiness = lambda *a: reached.append(1) or {"round": 0}
        guard_env.oneshot = lambda pid: (cg if reached and cg else {"count": 1, "numbers": [5001]})
        try:
            guard.check_dw5()
            return None, reached
        except Invariant as exc:
            return str(exc), reached
    msg, reached = dw5_guard("dw5_duplicate_ids", owned=(2, 2, 4))
    check("dw5_duplicate_ids", "owned window ids must be three distinct ids",
          msg is not None and "not three distinct IDs" in msg and not reached)
    msg, reached = dw5_guard("dw5_workspace_mapping", mapped={3: "ws-other"})
    check("dw5_workspace_mapping", "each window maps to its own workspace",
          msg is not None and "not mapped to workspace" in msg and not reached)
    msg, reached = dw5_guard("dw5_cg_count", cg={"count": 2, "numbers": [5001]})
    check("dw5_cg_count", "on-screen CG count is compared after readiness",
          msg is not None and "on-screen CG count/numbers changed" in msg and reached)
    msg, reached = dw5_guard("dw5_cg_numbers", cg={"count": 1, "numbers": [6001]})
    check("dw5_cg_numbers", "on-screen CG numbers are compared after readiness",
          msg is not None and "on-screen CG count/numbers changed" in msg and reached)
    code, probe, env, app, report = run_case("v9_no_marker", phase="v9")
    check("v9_no_marker", "missing DW-11 marker writes exact line, DW-10 + cleanup still exit 0",
          code == 0 and "DW-11 not driven" in report and own_gone(app) and app.counts.get("delete") == 3, "exit=%s" % code)
    code, probe, env, app, report = run_case("v9_wrong_closed", {"v9_wrong_closed": True}, phase="v9")
    check("v9_wrong_closed", "closed_window_id must equal the deleted logical window", code == 1, "exit=%s" % code)
    code, probe, env, app, report = run_case("signal_during_pause", {"signal_in_pause": True}, phase="ui")
    check("signal_during_pause", "TERM during the driver pause cleans up and keeps 143",
          code == 143 and own_gone(app) and app.fleet is False and app.sessions[0]["session_id"] == "S-prot", "exit=%s" % code)
    run_impl_r1_cases(check, own_gone, zero_mutation, record_root, fixtures)
    run_impl_r2_cases(check)
    run_impl_r3_cases(check, own_gone, zero_mutation)
    escape = os.path.join(fixtures, "case-root_escape")
    if os.path.isdir(escape):
        shutil.rmtree(escape)
    assigned, other = os.path.join(escape, "assigned"), os.path.join(escape, "other")
    os.makedirs(assigned)
    saved = globals()["DEFAULT_RECORD_ROOT"]
    globals()["DEFAULT_RECORD_ROOT"] = assigned
    try:
        code = main(["--self-test-no-app", "--record-root", other])
        outside_ok = code == 2 and not os.path.exists(other)
        code2 = main(["--self-test-no-app", "--record-root", os.path.join(assigned, "..", "other")])
        outside_ok = outside_ok and code2 == 2 and not os.path.exists(other)
    finally:
        globals()["DEFAULT_RECORD_ROOT"] = saved
    check("record_root_escape", "--record-root outside the assigned root is rejected before any file is created",
          outside_ok and os.listdir(assigned) == [], "exit=%s" % code)
    print("fixtures: %d/%d passed (fixture results are not live AppKit/provider proof)" % (sum(results), len(results)))
    return 0 if all(results) else 1


def extract_probe_source():
    with open(os.path.join(SCRIPT_DIR, "fleet_manager_live_probe.sh")) as handle:
        text = handle.read()
    return text.split("<<'PY' || true\n", 1)[1].split("\nPY\n", 1)[0]


def run_wrapper_signal(record_root, tag, sig):
    out = os.path.join(FIXTURES, "case-wrapper-" + tag)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    script = os.path.join(SCRIPT_DIR, "fleet_manager_live_probe.sh")
    # run() leaves INT/TERM ignored after cleanup and children inherit that; the wrapper under test must start default
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    proc = subprocess.Popen(["bash", script, "--self-test-wrapper-child", out, "--record-root", record_root],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    ready = False
    deadline = time.time() + 90
    for line in proc.stdout:
        if line.startswith("DRIVER-READY"):
            ready = True
            break
        if time.time() > deadline:
            break
    if ready:
        os.kill(proc.pid, sig)  # the direct wrapper PID only; own dummy run, never a group or the app
    try:
        status = proc.wait(60)
    except subprocess.TimeoutExpired:
        proc.kill()
        status = "hung"
    proc.stdout.read()
    result, waited = None, 0
    while waited < 40 and result is None:
        path = os.path.join(out, "result.json")
        if os.path.exists(path):
            with open(path) as handle:
                result = json.load(handle)
        else:
            time.sleep(0.5)
            waited += 0.5
    return ready, status, result


def real_cli_call(label, body, window=None):
    d = os.path.join(FIXTURES, "case-real-cli-" + label)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    cli = os.path.join(d, "fake-cli")
    with open(cli, "w") as handle:
        handle.write("#!/bin/sh\n" + body)
    os.chmod(cli, 0o755)
    cfg = Cfg(self_test=False, cli_path=cli, run_dir=os.path.join(d, "run"), record_root=d, nonce=label, run8=label)
    probe = Probe(Real(cfg), cfg)
    try:
        return "accepted", probe.call("app_settings", {"op": "get", "key": "x"}, label, window=window), cfg
    except ToolError as exc:
        return "rejected", str(exc), cfg


def run_impl_r3_cases(check, own_gone, zero_mutation):
    for status in (73, 74, 76):
        name = "baseline_status%d" % status
        code, probe, env, app, _ = run_case(
            name, {"cli_status": ("baseline-windows", status, "RepoPrompt MCP: connection failed")})
        check(name, "CLI exit %d at baseline is a precondition failure (2) with zero mutations" % status,
              code == 2 and zero_mutation(env, app) and probe.errors[0].startswith("precondition"), "exit=%s" % code)
    code, probe, env, app, _ = run_case("baseline_status1", {"cli_status": ("baseline-windows", 1, "boom")})
    check("baseline_status1_stays_invariant", "an arbitrary CLI failure is not blanket-mapped to a precondition",
          code == 1 and zero_mutation(env, app), "exit=%s" % code)
    code, probe, env, app, _ = run_case("create_status74_after_commit", {"create_status_after_commit": 74})
    check("create_status74_after_commit", "a CLI refusal after a committed create is exit 2 and still reconciles, deletes, restores",
          code == 2 and own_gone(app) and app.fleet is False and app.counts.get("create") == 1
          and app.counts.get("delete") == 1, "exit=%s" % code)
    code, probe, env, app, _ = run_case("create_denied", {"create_denied": True})
    check("create_denied", "an exact server create-denied error is a precondition failure (2), nothing replayed",
          code == 2 and own_gone(app) and app.counts.get("create") == 1 and not app.counts.get("delete")
          and probe.errors[0].startswith("precondition"), "exit=%s" % code)
    code, probe, env, app, _ = run_case("delete_denied_v9", {"delete_denied_at": 1}, phase="v9")
    check("delete_denied_v9", "an exact server delete-denied error in the v9 measurement is a precondition failure (2) with cleanup",
          code == 2 and own_gone(app) and app.fleet is False and probe.errors[0].startswith("precondition"), "exit=%s" % code)
    code, probe, env, app, _ = run_case("cleanup_delete_denied", {"delete_denied_at": 1})
    check("cleanup_delete_denied", "a denied cleanup delete is a residual cleanup failure (1) and the other deletes still run",
          code == 1 and app.counts.get("delete") == 3 and 2 in app.windows
          and any("ws-2" in r for r in probe.residuals), "exit=%s" % code)
    code, probe, env, app, _ = run_case("poll_status73", {"cli_status": ("poll-", 73, "RepoPrompt MCP: connection failed")})
    polls = [label for label, _ in env.calls if label.startswith("poll-")]
    check("poll_status73", "an environment failure during readiness stops polling at once (2) and cleans up",
          code == 2 and own_gone(app) and len(polls) == 1, "exit=%s polls=%d" % (code, len(polls)))

    split_body = """printf '{"name":"caf\\303'
sleep 0.3
printf '\\251"}\\n'
"""
    outcome, detail, _ = real_cli_call("utf8_split", split_body)
    check("utf8_split_multibyte", "a multibyte character split across reads is decoded intact",
          outcome == "accepted" and detail == {"name": "café"}, "%s %r" % (outcome, detail))
    outcome, detail, _ = real_cli_call("utf8_invalid", """printf '{"name":"caf\\377"}\\n'
""")
    check("utf8_invalid", "invalid UTF-8 on stdout fails closed with an explicit parse error",
          outcome == "rejected" and "UTF-8" in detail, "%s %s" % (outcome, detail))
    outcome, detail, _ = real_cli_call("utf8_dangling", """printf '{"a":1}\\n'
printf 'x\\303'
""")
    check("utf8_dangling", "a dangling UTF-8 lead byte at end of stdout fails closed with an explicit parse error",
          outcome == "rejected" and "UTF-8" in detail, "%s %s" % (outcome, detail))

    code, probe, env, app, _ = run_case("late_window", {"create_timeout_at": 1, "late_window_reads": 2})
    check("late_window_recovered", "an owned workspace whose window registers late is re-identified and closed at cleanup",
          code == 2 and own_gone(app) and app.counts.get("delete") == 1,
          "exit=%s windows=%s" % (code, sorted(app.windows)))
    code, probe, env, app, _ = run_case("window_never", {"create_timeout_at": 1, "late_window_reads": 99})
    check("window_unknown_residual", "an owned workspace with no identifiable window is reported by id, never closed speculatively",
          code == 2 and not app.counts.get("delete") and "ws-2" in app.ws
          and any("ws-2" in r and "window" in r for r in probe.residuals), "exit=%s" % code)

    code, probe, env, app, _ = run_case("trace_numbers")
    traces = probe.J.get("traces", []) if probe else []
    new = [t.get("aux_numbers_new_since_first_sample") for t in traces]
    check("trace_numbers_honest", "auxiliary window numbers separate pre-existing parked windows from numbers new in the series",
          code == 0 and new == [[6001], [6002], [6003]] and all("new_all_numbers" not in t for t in traces),
          "exit=%s new=%s" % (code, new))

    stdin_dir = os.path.join(FIXTURES, "case-stdin")
    if os.path.isdir(stdin_dir):
        shutil.rmtree(stdin_dir)
    os.makedirs(stdin_dir)
    stdin_cli = os.path.join(stdin_dir, "fake-cli")
    with open(stdin_cli, "w") as handle:
        handle.write("""#!/bin/sh
if IFS= read -r line; then printf '%s\\n' '{"stdin":"data"}'; else printf '%s\\n' '{"stdin":"eof"}'; fi
""")
    os.chmod(stdin_cli, 0o755)
    src_path = os.path.join(stdin_dir, "extracted-probe.py")
    with open(src_path, "w") as handle:
        handle.write(extract_probe_source())
    loader = ("import sys,json;src=open(sys.argv[1]).read();cli=sys.argv[3];sys.argv=['x',sys.argv[2]];"
              "ns={'__name__':'fm05_stdin'};exec(compile(src,'probe','exec'),ns);"
              "cfg=ns['Cfg'](self_test=False,cli_path=cli);r=ns['Real'](cfg).cli(['windows'],10,'stdin');"
              "print(json.dumps([d for _,d in r.docs]))")
    out = subprocess.run([sys.executable, "-I", "-c", loader, src_path, SCRIPT_DIR, stdin_cli], input="inherited\n",
                         capture_output=True, text=True, timeout=60)
    check("cli_stdin_not_inherited", "the exec CLI child never reads the probe's own stdin",
          out.stdout.strip() == '[{"stdin": "eof"}]', out.stdout.strip() + out.stderr.strip()[-80:])

    flags_script = """source "$1"
case $- in *e*) echo ERREXIT;; esac
case $- in *u*) echo NOUNSET;; esac
if [ "$(set -o | /usr/bin/awk '$1=="pipefail"{print $2}')" = on ]; then echo PIPEFAIL; fi
echo DONE
"""
    flags = subprocess.run(["bash", "-c", flags_script, "x", os.path.join(SCRIPT_DIR, "fleet_manager_live_probe.sh")],
                           capture_output=True, text=True, timeout=60)
    check("sourcing_keeps_caller_flags", "sourcing the probe never changes the caller's errexit/nounset/pipefail",
          flags.stdout.split() == ["DONE"], flags.stdout.strip().replace("\n", " "))

    def precondition_of(fn):
        try:
            fn()
        except Precondition as exc:
            return True, str(exc)
        except Exception as exc:
            return False, "%s: %s" % (type(exc).__name__, exc)
        return False, "no exception"

    gdir = os.path.join(FIXTURES, "case-platform")
    if os.path.isdir(gdir):
        shutil.rmtree(gdir)
    os.makedirs(gdir)
    missing = os.path.join(gdir, "no-such-helper")
    broken = os.path.join(gdir, "unreadable-json-helper")
    with open(broken, "w") as handle:
        handle.write("#!/bin/sh\necho 'not json'\n")
    os.chmod(broken, 0o755)
    gcfg = Cfg(self_test=False, cli_path=os.path.join(gdir, "no-such-cli"), run_dir=os.path.join(gdir, "run"),
               record_root=gdir, nonce="platform", run8="platform")
    real = Real(gcfg)
    real.helper_bin = missing
    ok, detail = precondition_of(lambda: real.oneshot(1))
    check("platform_helper_missing", "a missing sampler helper is a precondition failure, not a traceback", ok, detail)
    real.helper_bin = broken
    ok, detail = precondition_of(lambda: real.oneshot(1))
    check("platform_helper_unreadable_json", "unreadable sampler JSON is a precondition failure, not a traceback", ok, detail)
    real.helper_bin = missing
    ok, detail = precondition_of(lambda: real.start_sampler(1))
    check("platform_sampler_missing", "a sampler that cannot start is a precondition failure, not a traceback", ok, detail)
    saved_path = os.environ.get("PATH", "")
    empty = os.path.join(gdir, "empty-path")
    os.makedirs(empty)
    os.environ["PATH"] = empty
    try:
        ok, detail = precondition_of(lambda: real.compile_helper(os.path.join(gdir, "compile")))
    finally:
        os.environ["PATH"] = saved_path
    check("platform_xcrun_missing", "a missing xcrun is a precondition failure, not a traceback", ok, detail)
    ok, detail = precondition_of(lambda: real.cli(["windows"], 5, "spawn"))
    check("platform_cli_missing", "a CLI that cannot be spawned is a precondition failure, not a traceback", ok, detail)


def run_impl_r2_cases(check):
    def real_call(label, body, window=None):
        d = os.path.join(FIXTURES, "case-real-cli-" + label)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        cli = os.path.join(d, "fake-cli")
        with open(cli, "w") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(cli, 0o755)
        cfg = Cfg(self_test=False, cli_path=cli, run_dir=os.path.join(d, "run"), record_root=d, nonce=label, run8=label)
        probe = Probe(Real(cfg), cfg)
        try:
            return "accepted", probe.call("app_settings", {"op": "get", "key": "x"}, label, window=window), cfg
        except ToolError as exc:
            return "rejected", str(exc), cfg

    outcome, detail, cfg = real_call("trailing", "printf '%s\\n' '{\"values\":{\"x\":true}}'\nprintf 'TRAILING-GARBAGE\\n'\n")
    check("real_cli_trailing_garbage", "a valid document followed by trailing stdout garbage is rejected by shipped Real.cli/Probe.call",
          outcome == "rejected", "%s %s" % (outcome, detail))
    evidence = os.path.join(cfg.run_dir, "calls", "001-trailing.json")
    with open(evidence) as handle:
        entry = json.load(handle)
    check("real_cli_malformed_evidence", "the rejected call keeps bounded request evidence with an explicit parse_error field",
          bool(entry.get("parse_error")) and len(entry.get("docs", [])) == 1 and entry.get("cmds"), str(entry.get("parse_error")))
    outcome, detail, _ = real_call("healthy", "printf '%s\\n' '{\"binding\":{\"window_id\":1}}' '{\"values\":{\"x\":true}}'\n"
                                              "echo 'listing workspace error-lab' >&2\n", window=1)
    check("real_cli_healthy_multidoc", "healthy multi-document output with listing text on stderr is accepted",
          outcome == "accepted" and detail == {"values": {"x": True}}, "%s %s" % (outcome, detail))
    outcome, detail, _ = real_call("incomplete", "printf '%s' '{\"values\":{\"x\":'\n")
    check("real_cli_incomplete", "an incomplete document is never accepted", outcome == "rejected", "%s %s" % (outcome, detail))

    policy = {"clientID": "RepoPrompt CLI (Exec)", "allowedOperations": ["create_workspace", "delete_workspace"],
              "createdAt": 5.0, "lastUsedAt": None}
    base = {"autoApproveAll": False, "autoApproveOperations": [], "clientPolicies": {" RepoPrompt CLI (Exec) ": policy}}
    without_created = {k: v for k, v in policy.items() if k != "createdAt"}
    cases = [
        ("approval_top_level_array", [], 2),
        ("approval_policy_array", dict(base, clientPolicies={" RepoPrompt CLI (Exec) ": []}), 2),
        ("approval_missing_required_keys", {"autoApproveAll": True}, 2),
        ("approval_policy_missing_created_at", dict(base, clientPolicies={"repoprompt cli (exec)": without_created}), 2),
        ("approval_unknown_policy_operation", dict(base, clientPolicies={"repoprompt cli (exec)": dict(
            policy, allowedOperations=["create_workspace", "delete_workspace", "bogus"])}), 2),
        ("approval_unknown_global_operation", dict(base, autoApproveOperations=["bogus"]), 2),
        ("approval_string_bool", dict(base, autoApproveAll="false"), 2),
        ("approval_unknown_keys_grant_nothing",
         {"autoApproveAll": False, "autoApproveOperations": [], "clientPolicies": {}, "autoApprove": True}, 2),
        ("approval_valid_with_unrelated_keys", dict(base, unrelated=True, clientPolicies={
            "repoprompt cli (exec)": dict(policy, extra="ignored")}), 0),
    ]
    for name, payload, want in cases:
        code, probe, env, app, _ = run_case(name, {"approval_payload": json.dumps(payload).encode()})
        quiet = want == 0 or (not env.calls and not app.counts)
        check(name, "persisted approval data must match the Swift Codable shape; uncertain data is exit 2 before any CLI call",
              code == want and quiet, "exit=%s calls=%d" % (code, len(env.calls)))


def run_impl_r1_cases(check, own_gone, zero_mutation, record_root, fixtures):
    # 1 clock domain: shipped mono() must match CLOCK_UPTIME_RAW (helper clock) on every installed interpreter
    loader = ("import sys,time;src=open(sys.argv[1]).read();sys.argv=['x',sys.argv[2]];"
              "ns={'__name__':'fm05_clock'};exec(compile(src,'probe','exec'),ns);"
              "print(ns['mono'](),time.clock_gettime(time.CLOCK_UPTIME_RAW))")
    src_path = os.path.join(fixtures, "extracted-probe.py")
    with open(src_path, "w") as handle:
        handle.write(extract_probe_source())
    interpreters = ["/usr/bin/python3", shutil.which("python3")]
    for interp in interpreters:
        out = subprocess.run([interp, "-I", "-c", loader, src_path, SCRIPT_DIR], capture_output=True, text=True)
        try:
            mono_value, raw = (float(x) for x in out.stdout.split())
            same = abs(mono_value - raw) < 5.0
        except ValueError:
            same, mono_value, raw = False, None, None
        check("clock_domain[%s]" % interp, "shipped mono() equals CLOCK_UPTIME_RAW (helper clock) on this interpreter",
              same, "mono=%s uptime=%s" % (mono_value, raw))
    with open(os.path.join(SCRIPT_DIR, "fleet_onscreen_windows.swift")) as handle:
        check("helper_clock", "helper stamps samples with CLOCK_UPTIME_RAW", "CLOCK_UPTIME_RAW" in handle.read())
    code, probe, env, app, _ = run_case("clock_mismatch", {"helper_clock_offset": 361000.0})
    check("clock_mismatch", "sampler/probe clock-domain mismatch is a precondition failure before any mutation",
          code == 2 and zero_mutation(env, app) and any("clock domain" in e for e in probe.errors), "exit=%s" % code)

    # 3 boundary gaps
    base = [{"t": 9.0 + 0.02 * i, "count": 1} for i in range(0, 21)]  # 9.00..9.40
    send_gap = base + [{"t": 10.5 + 0.02 * i, "count": 1} for i in range(0, 200)]
    ok, reason, _ = sample_coverage(send_gap, 10.0, 11.0)
    check("gap_straddles_send", "a gap spanning the request send is inconclusive", not ok, reason)
    pre = [{"t": 9.0 + 0.02 * i, "count": 1} for i in range(0, 120)]  # to 11.38
    end_gap = pre + [{"t": 12.5, "count": 1}]
    ok, reason, _ = sample_coverage(end_gap, 10.0, 10.5)
    check("gap_straddles_end", "a gap spanning response+1.25s is inconclusive", not ok, reason)

    # 4 natural timestamp advance passes, run-state drift fails
    code, probe, env, app, _ = run_case("protected_activity", {"protected_activity": True})
    check("protected_last_modified", "advancing last_modified/item_count of a protected session is not drift",
          code == 0, "exit=%s" % code)
    code, probe, env, app, _ = run_case("protected_state_after_schema", {"protected_state_change": True})
    check("protected_state_real_keys", "run-state drift on real-schema rows still fails", code == 1, "exit=%s" % code)

    # 2/5 retained raw traces, honest visibility wording
    code, probe, env, app, report = run_case("trace_clean")
    traces = probe.J.get("traces", []) if probe else []
    paths = [t.get("path") for t in traces]
    rows = []
    for path in paths:
        if path and os.path.exists(path):
            with open(path) as handle:
                rows += [json.loads(line) for line in handle]
    check("trace_retained", "every open series is retained raw (t/count/numbers/all_numbers) and referenced in the report",
          code == 0 and len(paths) == 3 and any("all_numbers" in r for r in rows)
          and all(p and p in report for p in paths), "exit=%s paths=%s" % (code, len(paths)))
    check("wording_clean", "no-escape wording only when no extra visibility was sampled",
          "no sampled escape" in report and "SAMPLED EXTRA VISIBILITY" not in report)
    code, probe, env, app, report = run_case("trace_escape", {"escape_on_open": True})
    check("wording_escape", "sampled extra visibility is reported, not hidden behind the no-escape sentence",
          code == 0 and "SAMPLED EXTRA VISIBILITY" in report and "no sampled escape" not in report, "exit=%s" % code)
    code, probe, env, app, report = run_case("trace_failed", {"sampler_gap": (0.1, 0.4)}, phase="dw5")
    traces = probe.J.get("traces", []) if probe else []
    check("trace_failed_retained", "an inconclusive open keeps its raw series and report reference",
          code == 2 and traces and traces[0].get("path") and os.path.exists(traces[0]["path"])
          and traces[0]["path"] in report, "exit=%s" % code)

    # 6 wrapper signals reach the shipped Python cleanup
    for tag, sig, want in (("term", signal.SIGTERM, 143), ("int", signal.SIGINT, 130)):
        ready, status, result = run_wrapper_signal(record_root, tag, sig)
        check("wrapper_signal_" + tag, "%s sent to the direct wrapper PID reaches cleanup and exits %d" % (tag.upper(), want),
              ready and status == want and result is not None and result["code"] == want and result["own_gone"]
              and result["fleet_restored"], "status=%s result=%s" % (status, result))

    sourced = subprocess.run(["bash", "-c", 'source "$1"; fm05_main --self-test-no-app --record-root "$2" && rc=0 || rc=$?; echo "AFTER:$rc"',
                              "x", os.path.join(SCRIPT_DIR, "fleet_manager_live_probe.sh"), record_root],
                             capture_output=True, text=True)
    check("sourceable_no_exec", "sourcing fm05_main never execs away the calling shell",
          sourced.stdout.strip().endswith("AFTER:2"), sourced.stdout.strip()[-60:])
    # 7 already-terminal cancel
    code, probe, env, app, _ = run_case("already_terminal", {"already_terminal": True})
    check("already_terminal_cancel", "a cancel racing a finished run is proven terminal by one bounded read, no residual",
          code == 0 and own_gone(app) and not probe.residuals, "exit=%s" % code)
    # 8 timeouts
    code, probe, env, app, _ = run_case("v9_delete_timeout", {"delete_timeout_at": 1}, phase="v9")
    check("v9_delete_timeout", "a v9 first-delete timeout keeps exit 2, never replays the delete, and still cleans up",
          code == 2 and own_gone(app) and app.counts.get("delete") == 3 and app.fleet is False,
          "exit=%s deletes=%s" % (code, app.counts.get("delete")))
    code, probe, env, app, _ = run_case("cleanup_delete_timeout", {"delete_timeout_at": 2})
    check("cleanup_delete_timeout", "a cleanup delete timeout keeps exit 2", code == 2 and app.counts.get("delete") == 3,
          "exit=%s" % code)
    # 9 receipt wording
    code, probe, env, app, report = run_case("receipt_wording", phase="ui")
    check("receipt_wording", "report states round bounds and the buffered-receipt limitation",
          code == 0 and "round start/end" in report and "may collapse" in report, "exit=%s" % code)
    # 10 fake schema parity
    probe_app = FakeApp({}, "parity")
    probe_env = Fake(Cfg(), probe_app, "", {})
    probe_app.sessions.append({"session_id": "S-x", "window_id": 1, "state": "waiting_for_input",
                               "raw_state": "waitingForQuestion", "is_live": True, "name": "n"})
    probe_app.bound = 1
    window = probe_env.windows_doc()[1]["windows"][0]
    session = probe_env.dispatch("agent_manage", {"op": "list_sessions"}, "x")["sessions"][-1]
    listing = probe_env.dispatch("manage_workspaces", {"action": "list"}, "x")["workspaces"][0]
    check("fake_schema_parity", "fake window/session/workspace rows use the documented key sets",
          set(window) == {"window_id", "is_current_window", "workspace", "active_context_id", "tabs"}
          and set(window["tabs"][0]) == {"context_id", "name", "workspace_id", "workspace_name", "is_active", "is_bound",
                                         "repo_paths"}
          and set(session) <= {"session_id", "name", "last_modified", "item_count", "state", "is_live", "raw_state",
                               "agent", "parent_session_id", "is_mcp_originated"}
          and {"session_id", "name", "last_modified", "item_count", "state", "is_live"} <= set(session)
          and set(listing) == {"id", "name", "root_count", "repo_paths", "showing_window_ids", "is_hidden"})
    # 11 small safety fixes
    jdir = os.path.join(fixtures, "case-journal")
    if os.path.isdir(jdir):
        shutil.rmtree(jdir)
    os.makedirs(jdir)
    jcfg = Cfg(run_dir=jdir, record_root=jdir, nonce="j", run8="j")
    jprobe = Probe(Fake(jcfg, FakeApp({}, "j"), "", {}), jcfg)
    jprobe.journal("first")
    loop = []
    loop.append(loop)
    jprobe.J["bad"] = loop
    try:
        jprobe.journal("second")
    except ValueError:
        pass
    try:
        with open(os.path.join(jdir, "journal.json")) as handle:
            intact = json.load(handle)["events"][0]["kind"] == "first"
    except ValueError:
        intact = False
    check("journal_atomic", "a failed journal write leaves the previous journal intact", intact)
    for stderr, passes in (("listing workspace error-lab and warning-zone", True), ("Error: boom", False)):
        sprobe = Probe(Fake(jcfg, FakeApp({}, "s"), "", {}), jcfg)
        sprobe.env.cli = lambda cmds, timeout, label, stderr=stderr: Result(0, [(1.0, {"ok": True})], "", stderr, 0.0, 1.0,
                                                                            False, cmds)
        try:
            sprobe.run_cli(["windows"], "stderr-scan")
            verdict = True
        except ToolError:
            verdict = False
        check("stderr_prefix[%s]" % stderr[:12], "only leading Error:/Warning: lines fail a call", verdict == passes)
    code, probe, env, app, _ = run_case("bad_provenance_shape")
    # provenance must be an object; list is a precondition failure not a crash
    case = os.path.join(FIXTURES, "case-bad_provenance_shape", "home")
    prov = os.path.join(case, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/Resources/"
                              "RepoPromptDebugProvenance.json")
    with open(prov, "w") as handle:
        handle.write("[1]")
    code, probe, env, app, _ = run_case_existing_home("bad_provenance_shape")
    check("provenance_shape", "non-object provenance is exit 2 with no mutation", code == 2 and zero_mutation(env, app),
          "exit=%s" % code)
    info = os.path.join(os.path.dirname(os.path.dirname(prov)), "Info.plist")
    with open(info, "w") as handle:
        handle.write("<plist><dict>")
    code, probe, env, app, _ = run_case_existing_home("bad_provenance_shape")
    check("plist_unparseable", "unparseable Info.plist is exit 2 with no mutation", code == 2 and zero_mutation(env, app),
          "exit=%s" % code)


def self_test_no_app(record_root):
    global FIXTURES
    fixtures = FIXTURES = os.path.join(record_root, "u1", "fixtures")
    os.makedirs(fixtures, exist_ok=True)
    code, probe, env, app, _ = run_case("no_app", pids=[])
    if env.calls or app.counts or probe.mutations:
        print("FAIL: no-app self-test performed CLI/setting/create/start/cancel/delete calls", file=sys.stderr)
        return 1
    print("no-app self-test: production preflight exit %d with zero CLI calls, setting writes or mutations" % code)
    return code


def run_case_existing_home(name):
    case_dir = os.path.join(FIXTURES, "case-" + name)
    home = os.path.join(case_dir, "home")
    record_root = os.path.join(case_dir, "record2")
    os.makedirs(record_root, exist_ok=True)
    nonce = "case-" + name + "-2"
    cfg = Cfg(phase="", record_root=record_root, run_dir=os.path.join(record_root, "runs", nonce), nonce=nonce,
              run8="c0ffee00", start_args_file=write_start_args(case_dir))
    app = FakeApp({}, nonce)
    env = Fake(cfg, app, home, {}, None)
    try:
        code, probe = run(env, cfg)
    except Exception as exc:
        code, probe = "EXC:%s" % type(exc).__name__, None
    return code, probe, env, app, ""


def self_test_wrapper_child(record_root, out_dir):
    global FIXTURES
    FIXTURES = os.path.join(record_root, "u1", "fixtures")
    os.makedirs(out_dir, exist_ok=True)
    code, probe, env, app, _ = run_case("wrapper-child-" + os.path.basename(out_dir), phase="ui", pause_seconds=30.0, real_pause=True)
    result = {"code": code, "own_gone": set(app.windows) == {1} and set(app.ws) == {"ws-prot"},
              "fleet_restored": app.fleet is False, "signal": probe.flags["signal"] if probe else None}
    with open(os.path.join(out_dir, "result.json"), "w") as handle:
        json.dump(result, handle)
    return code


def parse(argv):
    parser = argparse.ArgumentParser(prog="fleet_manager_live_probe.sh")
    parser.add_argument("--ui-phase", action="store_true")
    parser.add_argument("--v9-phase", action="store_true")
    parser.add_argument("--self-test-no-app", action="store_true")
    parser.add_argument("--self-test-fixtures", action="store_true")
    parser.add_argument("--self-test-wrapper-child", metavar="OUT_DIR")
    parser.add_argument("--expect-commit")
    parser.add_argument("--start-args-file")
    parser.add_argument("--record-root", default=DEFAULT_RECORD_ROOT)
    parser.add_argument("--output-root")
    parser.add_argument("--pause-seconds", type=float, default=600.0)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(sys.argv[2:] if argv is None else argv)
    try:
        record_root = canonical_under(DEFAULT_RECORD_ROOT, args.record_root)
    except Precondition as exc:
        print("ERROR: record root: %s" % exc, file=sys.stderr)
        return 2
    if args.self_test_no_app:
        return self_test_no_app(record_root)
    if args.self_test_fixtures:
        return self_test_fixtures(record_root)
    if args.self_test_wrapper_child:
        return self_test_wrapper_child(record_root, args.self_test_wrapper_child)
    if args.ui_phase and args.v9_phase:
        print("--ui-phase and --v9-phase are exclusive", file=sys.stderr)
        return 2
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    run8 = uuid.uuid4().hex[:8]
    nonce = "%s-%s" % (stamp, run8)
    try:
        out = args.output_root or os.path.join(record_root, "runs", nonce)
        run_dir = canonical_under(record_root, out)
    except Precondition as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2
    cfg = Cfg(self_test=False, phase="v9" if args.v9_phase else "ui" if args.ui_phase else "dw5",
              expect_commit=args.expect_commit, record_root=record_root, run_dir=run_dir, nonce=nonce, run8=run8,
              start_args_file=args.start_args_file or os.path.join(record_root, "probe-start-arguments.json"),
              pause_seconds=max(1.0, min(600.0, args.pause_seconds)))
    try:
        env = Real(cfg)
    except Precondition as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2
    code, _ = run(env, cfg)
    return code


if __name__ == "__main__":
    sys.exit(main())
PY

fm05_main() {
	command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; return 2; }
	python3 -I -c "$FM05_PROBE_PY" "$FM05_SCRIPT_DIR" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	# Direct entry only: strict mode here, never on a sourcing caller; exec makes the wrapper PID the Python PID
	# so INT/TERM reach its cleanup handlers.
	set -euo pipefail
	command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }
	exec python3 -I -c "$FM05_PROBE_PY" "$FM05_SCRIPT_DIR" "$@"
fi
