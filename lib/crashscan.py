#!/usr/bin/env python3
import base64
import glob
import gzip
import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone

BASE = "/var/www/pelican/storage/app/crashlog"
EVENTS = os.path.join(BASE, "events")
STATE = os.path.join(BASE, "state")
PANEL_LOGS = "/var/www/pelican/storage/logs"
VOLUMES = "/var/lib/pelican/volumes"
WINDOW = int(os.environ.get("CRASHSCAN_WINDOW", "480"))
RETENTION = 30 * 86400
MAX_EVENT_FILES = 1200
CAPS = {"server": 100, "infra": 200, "audit": 600}
SERVICES = ["mariadb", "redis-server", "php8.3-fpm", "nginx", "docker", "cloudflared", "pelican-queue", "wings"]
META_KEYS = ["id", "ts", "iso", "scope", "source", "server", "name", "level", "exit_code", "oom", "issue", "preview"]
CONSOLE_FILES = [
    os.path.join("logs", "latest.log"),
    os.path.join("logs", "server.log"),
    os.path.join("logs", "console.log"),
    "server.log",
    "latest.log",
    "console.log",
    "screenlog.0",
]
CONSOLE_LINE = re.compile(r"\[(?:ERROR|SEVERE|FATAL)\]|(?:^|\s)(?:ERROR|SEVERE|FATAL|CRITICAL):|panic:|Fatal error|Critical error|OutOfMemoryError|Exception in thread|AssertionError|^Killed$", re.I)
CONSOLE_TS = re.compile(r"^\[\d{2}:\d{2}:\d{2}\]")

EXIT_HINTS = {
    134: "Exit 134 (SIGABRT) - process aborted.",
    137: "Exit 137 (SIGKILL) - killed, usually by the OOM killer (memory limit exceeded).",
    139: "Exit 139 (SIGSEGV) - segmentation fault.",
}

ISSUE_PATTERNS = [
    (re.compile(r"Mod resolution failed|Incompatible mods found|HARD_DEP"), "Mod incompatibility - conflicting or missing mod dependencies (see the resolution details)."),
    (re.compile(r"requires version \d+ or later of 'OpenJDK[^']*' \(java\)"), "A mod requires a newer Java version than the server runs - update the egg's Java/docker image."),
    (re.compile(r"requires version \d+ or later"), "A component requires a newer version than provided - version mismatch."),
    (re.compile(r"java @ \[>="), "A mod/plugin requires a newer Java version."),
    (re.compile(r"OutOfMemoryError|Java heap space|heap space"), "Java ran out of heap memory - raise the memory limit or heap size."),
    (re.compile(r"UnsupportedClassVersionError|class file version \d+"), "Java version mismatch - the server needs a different Java version."),
    (re.compile(r"Unable to access jarfile|no main manifest attribute|Could not find or load main class"), "Startup jar missing or broken - use the Health page repair."),
    (re.compile(r"Invalid or corrupt jarfile"), "Corrupt server jar - reinstall or repair it."),
    (re.compile(r"NoClassDefFoundError: org/apache/logging/log4j|ClassNotFoundException: org\.apache\.logging\.log4j"), "A mod requires log4j classes that are not bundled in this Minecraft/loader version - update or remove the affected mod."),
    (re.compile(r"ClassNotFoundException"), "Missing class/library - the server files are incomplete."),
    (re.compile(r"Could not reserve enough space for object heap|Invalid maximum heap size"), "Heap size misconfigured - lower -Xmx or free memory on the host."),
    (re.compile(r"Address already in use|EADDRINUSE|bind: cannot assign|Failed to bind"), "Port already in use - another process is holding the server port."),
    (re.compile(r"Connection refused|ECONNREFUSED"), "A dependency refused the connection (database/broker unreachable)."),
    (re.compile(r"SIGSEGV|segmentation fault"), "Native crash (segfault) - see the stack trace."),
    (re.compile(r"panic:"), "Runtime panic - see the stack trace in the excerpt."),
    (re.compile(r"No space left on device|disk full"), "Disk full - free space on the host."),
    (re.compile(r"Too many open files"), "File descriptor limit hit (ulimit)."),
    (re.compile(r"Permission denied"), "Permission denied - file ownership/permissions issue."),
    (re.compile(r"FileNotFoundException|No such file or directory"), "Missing file or directory - check the server paths."),
    (re.compile(r"maximum login|Failed to verify username|Moved too quickly"), "Game auth server issue (rate limit or invalid session)."),
    (re.compile(r"Timed out|connect timed out|Read timed out"), "Network timeout."),
    (re.compile(r"Killed by the OOM|oom-kill|Out of memory: Killed process"), "OOM killer on the host."),
    (re.compile(r"cannot open shared object file"), "Missing native library."),
    (re.compile(r"Unknown flag|invalid argument|Usage:"), "Invalid startup arguments - check the egg startup config."),
    (re.compile(r"npm ERR|node:internal"), "Node.js crash."),
    (re.compile(r"Traceback \(most recent call last\)|Fatal Python error"), "Python crash."),
    (re.compile(r"FatalError|Uncaught Error"), "Fatal runtime error."),
    (re.compile(r"SQLSTATE|Connection refused \(SQL"), "Database query error."),
    (re.compile(r"aborted connection|Too many connections"), "Database connection issue."),
    (re.compile(r"upstream timed out|connect\(\) failed"), "Reverse proxy upstream issue."),
    (re.compile(r"connection to origin failed|Failed to connect to origin"), "Tunnel connectivity issue."),
]


def log(msg):
    print("[crashscan] %s" % msg, flush=True)


def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return (out.stdout or "").strip()
    except Exception:
        return ""


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_json(path, data):
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return True
    except Exception:
        return False


def parse_iso(s):
    s = (s or "").strip().replace("Z", "+00:00")
    if not s or s.startswith("0001"):
        return 0
    try:
        return int(datetime.fromisoformat(s).timestamp())
    except ValueError:
        return 0


def first_issue(text):
    if not text:
        return None
    for pattern, hint in ISSUE_PATTERNS:
        if pattern.search(text):
            return hint
    return None


def exit_hint(code):
    if code in EXIT_HINTS:
        return EXIT_HINTS[code]
    if code == 1:
        return "Exited with code 1 - startup or runtime error; check the excerpt."
    if code != 0:
        return "Exited with code %d - see the excerpt." % code
    return None


def content_key(text):
    return hashlib.md5((text or "").encode("utf-8", "replace")).hexdigest()[:16]


def seen_recently(seen, text, now_ts, window=21600):
    key = content_key(text)
    if seen.get(key, 0) > now_ts - window:
        return True
    seen[key] = now_ts
    return False


def make_event(scope, source, level, ts, issue, excerpt, server=None, name=None, exit_code=None, oom=None):
    preview = re.sub(r"\s+", " ", (excerpt or "")[:300]).strip()
    return {
        "id": "%s-%s-%s-%s-%s" % (scope, source, (server or "host")[:8], ts, os.urandom(3).hex()),
        "ts": ts,
        "iso": datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(),
        "scope": scope,
        "source": source,
        "server": server,
        "name": name or "",
        "level": level,
        "exit_code": exit_code,
        "oom": oom,
        "issue": issue,
        "preview": preview,
        "excerpt": excerpt or "",
    }


def store_event(ev):
    payload = dict(ev)
    raw = payload.pop("excerpt", "")
    data = raw.encode("utf-8", "replace")
    payload["excerpt_gz"] = False
    if len(data) > 512:
        gz = gzip.compress(data, 6)
        if len(gz) < int(len(data) * 0.9):
            data = gz
            payload["excerpt_gz"] = True
    payload["excerpt_b64"] = base64.b64encode(data).decode()
    save_json(os.path.join(EVENTS, ev["id"] + ".json"), payload)


def index_add(path, meta, cap, now_ts):
    idx = load_json(path)
    idx["events"] = [meta] + [e for e in idx.get("events", []) if e.get("id") != meta["id"] and e.get("ts", 0) > now_ts - RETENTION]
    idx["events"] = sorted(idx["events"], key=lambda e: -e.get("ts", 0))[:cap]
    save_json(path, idx)


def emit(ev, now_ts):
    store_event(ev)
    meta = {k: ev[k] for k in META_KEYS if k in ev}
    if ev["scope"] == "server" and ev.get("server"):
        index_add(os.path.join(BASE, "index-server-%s.json" % ev["server"]), meta, CAPS["server"], now_ts)
    else:
        index_add(os.path.join(BASE, "index-infra.json"), meta, CAPS["infra"], now_ts)
    index_add(os.path.join(BASE, "audit.json"), meta, CAPS["audit"], now_ts)


def loop_check(ev, now_ts):
    idx = load_json(os.path.join(BASE, "index-server-%s.json" % ev["server"]))
    recent = [e for e in idx.get("events", []) if e.get("ts", 0) > now_ts - 3600]
    if len(recent) >= 2:
        ev["level"] = "critical"
        ev["issue"] = "Crash loop - %d crashes within the last hour. %s" % (len(recent) + 1, ev["issue"] or "")


def server_index(uuid):
    return load_json(os.path.join(BASE, "index-server-%s.json" % uuid))


def scan_containers(servers, state):
    events = []
    for uuid, name in servers.items():
        out = run(["docker", "inspect", "--format", "{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.FinishedAt}}|{{.RestartCount}}", uuid])
        if not out:
            continue
        parts = out.split("|")
        if len(parts) < 5:
            continue
        status = parts[0].strip()
        try:
            exit_code = int(parts[1].strip())
        except ValueError:
            exit_code = 0
        oom = parts[2].strip().lower() == "true"
        fin = parse_iso(parts[3])
        try:
            rc = int(parts[4].strip())
        except ValueError:
            rc = 0
        prev = state.get(uuid, {"fin": 0, "rc": 0})
        crashed = False
        kind = None
        if status in ("exited", "dead") and exit_code not in (0, 143) and fin > prev.get("fin", 0):
            crashed = True
            kind = "exit"
        elif status == "running" and rc > prev.get("rc", 0):
            crashed = True
            kind = "restart"
        if fin > 0:
            prev["fin"] = max(prev.get("fin", 0), fin)
        state[uuid] = {"fin": prev.get("fin", 0), "rc": rc}
        if not crashed:
            continue
        logs = run(["docker", "logs", "--tail", "100", uuid])
        if re.search(r"Out of memory|OOMKilled|oom-kill", logs, re.I):
            oom = True
        issue = None
        level = "error"
        ts = int(time.time())
        if kind == "exit":
            level = "critical" if oom or exit_code in EXIT_HINTS else "error"
            if oom and exit_code != 137:
                issue = "Container was OOM-killed - it hit its memory limit."
            else:
                issue = first_issue(logs) or exit_hint(exit_code)
            if fin > 0:
                ts = fin
        else:
            level = "critical"
            issue = "Crashed and was auto-restarted by the daemon."
        issue = issue or first_issue(logs)
        ev = make_event("server", "container", level, ts, issue, logs, server=uuid, name=name, exit_code=exit_code, oom=oom)
        loop_check(ev, ts)
        events.append(ev)
    return events


def scan_wings_crashes(state, servers, now_ts):
    events = []
    out = run(["journalctl", "-u", "wings", "--since", "%d seconds ago" % WINDOW, "-o", "json", "--no-pager"])
    if not out:
        return events
    cursor = state.get("wings_crash", 0)
    max_ts = cursor
    for line in out.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        ts = int(float(obj.get("__REALTIME_TIMESTAMP", 0)) / 1000000)
        if ts <= cursor:
            continue
        msg = obj.get("MESSAGE") or ""
        if isinstance(msg, list):
            msg = "\n".join(str(part) for part in msg)
        if not re.search(r"entering a crashed state|crash handler", msg):
            continue
        m = re.search(r"server=([0-9a-f-]{36})", msg)
        if not m or m.group(1) not in servers:
            continue
        uuid = m.group(1)
        max_ts = max(max_ts, ts)
        idx = server_index(uuid)
        if any(e.get("source") == "container" and abs(e.get("ts", 0) - ts) < 600 for e in idx.get("events", [])):
            continue
        logs = run(["docker", "logs", "--tail", "60", uuid])
        issue = first_issue(logs) or "Crashed - detected by the daemon crash handler."
        ev = make_event("server", "wings-crash", "critical", ts, issue, logs, server=uuid, name=servers[uuid])
        loop_check(ev, ts)
        events.append(ev)
    state["wings_crash"] = max_ts
    return events


def scan_journals(state):
    events = []
    now_ts = int(time.time())
    for svc in SERVICES:
        out = run(["journalctl", "-u", svc, "--since", "%d seconds ago" % WINDOW, "-p", "warning", "-o", "json", "--no-pager"])
        if not out:
            continue
        entry = state.get(svc)
        if isinstance(entry, int):
            entry = {"last": entry, "seen": {}}
        if not isinstance(entry, dict):
            entry = {"last": 0, "seen": {}}
        last = entry.get("last", 0)
        seen = {k: v for k, v in entry.get("seen", {}).items() if v > now_ts - 86400}
        max_ts = last
        for line in out.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            ts = int(float(obj.get("__REALTIME_TIMESTAMP", 0)) / 1000000)
            if ts <= last:
                continue
            max_ts = max(max_ts, ts)
            prio = int(obj.get("PRIORITY", 4))
            msg = obj.get("MESSAGE") or ""
            if isinstance(msg, list):
                msg = "\n".join(str(part) for part in msg)
            msg = msg.strip()
            if not msg:
                continue
            if svc == "wings" and re.search(r"entering a crashed state|crash handler", msg):
                continue
            if seen_recently(seen, msg, now_ts):
                continue
            level = "critical" if prio <= 2 else ("error" if prio == 3 else "warning")
            scope = "wings" if svc == "wings" else "service"
            events.append(make_event(scope, svc, level, ts, first_issue(msg), msg[:12000]))
        state[svc] = {"last": max_ts, "seen": seen}
    return events


def scan_panel_logs(state):
    events = []
    now_ts = int(time.time())
    header = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] production\.(ERROR|CRITICAL|ALERT|EMERGENCY):")
    try:
        files = sorted(glob.glob(os.path.join(PANEL_LOGS, "laravel*.log")))
    except Exception:
        files = []
    for path in files:
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        key = hashlib.md5(path.encode()).hexdigest()[:16]
        prev = state.get(key, {})
        offset = prev.get("offset")
        seen = {k: v for k, v in prev.get("seen", {}).items() if v > now_ts - 86400}
        if offset is None:
            offset = max(0, size - 1048576)
        if offset > size:
            offset = 0
        if offset >= size:
            state[key] = {"path": path, "offset": size, "seen": seen}
            continue
        try:
            with open(path, "rb") as fh:
                fh.seek(offset)
                data = fh.read(3 * 1048576)
        except OSError:
            continue
        new_offset = offset + len(data)
        chunk = data.decode("utf-8", "replace")
        lines = chunk.split("\n")
        i = 0
        while i < len(lines):
            m = header.match(lines[i])
            if not m:
                i += 1
                continue
            ts = parse_iso(m.group(1).replace(" ", "T") + "+00:00")
            if ts == 0:
                ts = int(time.time())
            level = "error" if m.group(2) == "ERROR" else "critical"
            block = [lines[i]]
            i += 1
            while i < len(lines) and len(block) < 60 and not re.match(r"^\[\d{4}-", lines[i]):
                block.append(lines[i])
                i += 1
            text = "\n".join(block)
            dedupe_text = re.sub(r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*", "", text)
            if seen_recently(seen, dedupe_text, now_ts):
                continue
            issue = first_issue(text) or "Panel error - see the excerpt."
            events.append(make_event("panel", "panel", level, ts, issue, text[:12000]))
        state[key] = {"path": path, "offset": new_offset, "seen": seen}
    return events


def scan_volumes(servers):
    events = []
    cutoff = time.time() - WINDOW
    for uuid in servers:
        vol = os.path.join(VOLUMES, uuid)
        if not os.path.isdir(vol):
            continue
        files = []
        cr = os.path.join(vol, "crash-reports")
        if os.path.isdir(cr):
            try:
                files += [os.path.join(cr, fn) for fn in os.listdir(cr) if fn.endswith(".txt")]
            except OSError:
                pass
        try:
            files += [os.path.join(vol, fn) for fn in os.listdir(vol) if fn.startswith("hs_err_pid") and fn.endswith(".log")]
        except OSError:
            pass
        for path in files[:5]:
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < cutoff or st.st_size > 524288:
                continue
            try:
                with open(path, "r", errors="replace") as fh:
                    text = "\n".join(fh.readlines()[:150])[:20000]
            except OSError:
                continue
            source = "crash-report" if "crash-reports" in path else "hs-err"
            issue = first_issue(text) or "Game server crash report - see the excerpt."
            events.append(make_event("server", source, "critical", int(st.st_mtime), issue, text, server=uuid, name=servers[uuid]))
    return events


def scan_consoles(servers, state, now_ts):
    events = []
    seen = {k: v for k, v in state.get("_seen", {}).items() if v > now_ts - 86400}
    for uuid, name in servers.items():
        idx = server_index(uuid)
        recent = [e for e in idx.get("events", []) if e.get("ts", 0) > now_ts - 600]
        if recent:
            continue
        vol = os.path.join(VOLUMES, uuid)
        if not os.path.isdir(vol):
            continue
        entry = state.get(uuid, {})
        for rel in CONSOLE_FILES:
            path = os.path.join(vol, rel)
            if not os.path.isfile(path):
                continue
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            offset = entry.get(rel)
            if offset is None:
                offset = max(0, size - 262144)
            if offset > size:
                offset = 0
            if offset >= size:
                entry[rel] = size
                continue
            try:
                with open(path, "rb") as fh:
                    fh.seek(offset)
                    data = fh.read(1572864)
            except OSError:
                continue
            new_offset = offset + len(data)
            chunk = data.decode("utf-8", "replace")
            lines = chunk.split("\n")
            i = 0
            while i < len(lines):
                if not CONSOLE_LINE.search(lines[i]):
                    i += 1
                    continue
                block = [lines[i]]
                i += 1
                while i < len(lines) and len(block) < 40 and not CONSOLE_LINE.search(lines[i]) and not CONSOLE_TS.match(lines[i]) and not lines[i].startswith("#"):
                    block.append(lines[i])
                    i += 1
                text = "\n".join(block)
                if seen_recently(seen, text, now_ts):
                    continue
                level = "critical" if re.search(r"FATAL|SEVERE|panic:|OutOfMemory|Fatal error", text, re.I) else "error"
                events.append(make_event("server", "console", level, now_ts, first_issue(text), text[:12000], server=uuid, name=name))
            entry[rel] = new_offset
        state[uuid] = entry
    state["_seen"] = seen
    return events


def prune():
    cutoff = time.time() - RETENTION
    keep = []
    try:
        names = os.listdir(EVENTS)
    except OSError:
        return
    for fn in names:
        path = os.path.join(EVENTS, fn)
        try:
            st = os.stat(path)
        except OSError:
            continue
        if st.st_mtime < cutoff:
            try:
                os.unlink(path)
            except OSError:
                pass
        else:
            keep.append((st.st_mtime, path))
    keep.sort()
    while len(keep) > MAX_EVENT_FILES:
        _, path = keep.pop(0)
        try:
            os.unlink(path)
        except OSError:
            pass


def main():
    os.makedirs(EVENTS, exist_ok=True)
    os.makedirs(STATE, exist_ok=True)
    now_ts = int(time.time())

    servers = {}
    out = run(["mysql", "-N", "-B", "-e", "SELECT s.uuid, COALESCE(s.name,'') FROM pelican.servers s WHERE s.uuid IS NOT NULL;"])
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            servers[parts[0]] = parts[1]

    cs = load_json(os.path.join(STATE, "containers.json"))
    for ev in scan_containers(servers, cs):
        emit(ev, now_ts)
    save_json(os.path.join(STATE, "containers.json"), cs)

    js = load_json(os.path.join(STATE, "journals.json"))
    for ev in scan_wings_crashes(js, servers, now_ts):
        emit(ev, now_ts)
    for ev in scan_journals(js):
        emit(ev, now_ts)
    save_json(os.path.join(STATE, "journals.json"), js)

    ls = load_json(os.path.join(STATE, "logs.json"))
    for ev in scan_panel_logs(ls):
        emit(ev, now_ts)
    save_json(os.path.join(STATE, "logs.json"), ls)

    for ev in scan_volumes(servers):
        emit(ev, now_ts)

    cs2 = load_json(os.path.join(STATE, "consoles.json"))
    for ev in scan_consoles(servers, cs2, now_ts):
        emit(ev, now_ts)
    save_json(os.path.join(STATE, "consoles.json"), cs2)

    prune()

    try:
        total = len(os.listdir(EVENTS))
    except OSError:
        total = 0

    save_json(os.path.join(BASE, "meta.json"), {
        "last_scan": datetime.now(timezone.utc).isoformat(),
        "scanned": now_ts,
        "stored": total,
    })

    log("servers=%d stored=%d window=%d" % (len(servers), total, WINDOW))


if __name__ == "__main__":
    main()
