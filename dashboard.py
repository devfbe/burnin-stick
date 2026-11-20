"""burnin-dashboard: memtest-style full-screen status for the burn-in stick.

Reads the events/phase files written by burnin-run and scans the journal
for kernel/hardware events (MCE, Oops, invalid opcode, segfaults,
throttling). Runs on tty1; redraws every two seconds.
"""
import curses
import glob
import json
import os
import platform
import re
import subprocess
import time

STATE = os.environ.get("BURNIN_STATE", "/run/burnin")
TESTS = [
    ("stressapptest", "stressapptest  memory copy/verify, power spikes"),
    ("cpu-icache", "stress-ng      CPU methods + icache, --verify"),
    ("memory", "stress-ng      vm methods, --verify"),
    ("memtester", "memtester      patterns under Linux"),
    ("store-verify", "nix-store      --verify --check-contents"),
    ("ram-blob", "RAM block      256 MiB resident, re-hashed"),
    ("zstd-roundtrip", "zstd           round trip on every core"),
    ("burst", "burst          3 s load / 4 s idle transitions"),
    ("idle", "idle           deep C-states, 10 min"),
]
# (key, label, severity, regex) — severity "err" turns the status red.
EVENT_KINDS = [
    ("mce", "Machine check / HW error", "err",
     re.compile(r"Machine check|Hardware Error|EDAC|mce: \[")),
    ("oops", "Oops / BUG / panic / lockup", "err",
     re.compile(r"Oops|BUG:|general protection fault|Kernel panic|soft lockup|hard LOCKUP|rcu_\w+ (self-)?detected stall|WARNING: CPU")),
    ("opcode", "invalid opcode / segfault", "err",
     re.compile(r"invalid opcode|segfault at|traps:|dumped core|SIGILL|SIGSEGV|SIGBUS")),
    ("thermal", "Thermal throttling", "warn",
     re.compile(r"temperature above threshold|clock throttled")),
    ("oom", "Out of memory kills", "warn",
     re.compile(r"Out of memory|oom-kill")),
]
# Our own processes log their (already counted) failures to the journal.
OWN = re.compile(r" (burnin-run|stress-ng|stressapptest|memtester)(\[\d+\])?: ")


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_events():
    events = []
    try:
        with open(os.path.join(STATE, "events.jsonl")) as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return events


def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def hms(seconds):
    seconds = max(0, int(seconds))
    return "%d:%02d:%02d" % (seconds // 3600, seconds % 3600 // 60, seconds % 60)


class Journal:
    def __init__(self):
        self.cursor = None
        self.counts = {k: 0 for k, _, _, _ in EVENT_KINDS}
        self.last = []

    def poll(self):
        cmd = ["journalctl", "-b", "-q", "--no-pager", "-o", "short-monotonic",
               "--show-cursor"]
        if self.cursor:
            cmd += ["--after-cursor", self.cursor]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return
        for line in out.splitlines():
            if line.startswith("-- cursor: "):
                self.cursor = line[len("-- cursor: "):]
                continue
            if OWN.search(line):
                continue
            for key, _, _, rx in EVENT_KINDS:
                if rx.search(line):
                    self.counts[key] += 1
                    self.last.append(line)
                    self.last = self.last[-3:]
                    break


class Sensors:
    def __init__(self):
        self.temp_max = None
        self.idle_prev = None
        self.idle_share = []

    def temperature(self):
        temps = []
        for hw in glob.glob("/sys/class/hwmon/hwmon*"):
            try:
                with open(os.path.join(hw, "name")) as f:
                    name = f.read().strip()
            except OSError:
                continue
            if name in ("coretemp", "k10temp", "cpu_thermal"):
                for t in glob.glob(os.path.join(hw, "temp*_input")):
                    v = read_int(t)
                    if v is not None:
                        temps.append(v / 1000)
        if not temps:
            for t in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
                v = read_int(t)
                if v is not None:
                    temps.append(v / 1000)
        if not temps:
            return None
        cur = max(temps)
        self.temp_max = cur if self.temp_max is None else max(self.temp_max, cur)
        return cur

    @staticmethod
    def frequencies():
        freqs = []
        for p in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"),
                        key=lambda s: int(re.search(r"cpu(\d+)", s).group(1))):
            v = read_int(p)
            if v is not None:
                freqs.append(v // 1000)
        return freqs

    def idle_states(self):
        """Share of wall time per idle state since the last call, all CPUs."""
        totals = {}
        for st in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*"):
            try:
                with open(os.path.join(st, "name")) as f:
                    name = f.read().strip()
            except OSError:
                continue
            v = read_int(os.path.join(st, "time"))
            if v is not None:
                totals[name] = totals.get(name, 0) + v
        now = time.monotonic()
        ncpu = os.cpu_count() or 1
        if self.idle_prev is not None:
            t0, prev = self.idle_prev
            span = (now - t0) * 1e6 * ncpu
            if span > 0:
                self.idle_share = [(n, 100 * (totals[n] - prev.get(n, 0)) / span)
                                   for n in totals]
        self.idle_prev = (now, totals)
        return self.idle_share


def cpu_info():
    model, microcode = platform.processor() or "?", "?"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name") and model in ("?", "x86_64", ""):
                    model = line.split(":", 1)[1].strip()
                elif line.startswith("microcode"):
                    microcode = line.split(":", 1)[1].strip()
    except OSError:
        pass
    mem = "?"
    try:
        with open("/proc/meminfo") as f:
            kb = int(f.readline().split()[1])
            mem = "%.1f GiB" % (kb / 1048576)
    except (OSError, ValueError, IndexError):
        pass
    return re.sub(r"\s+", " ", model), microcode, mem


def draw(scr, journal, sensors, static):
    scr.erase()
    h, w = scr.getmaxyx()
    width = min(w, 110)
    model, microcode, mem = static
    run = read_json(os.path.join(STATE, "run.json"), {})
    phase = read_json(os.path.join(STATE, "phase.json"), {})
    events = read_events()
    now = time.time()

    def put(y, x, text, attr=0):
        if 0 <= y < h - 1 and x < width:
            try:
                scr.addstr(y, x, text[: max(0, width - x)], attr)
            except curses.error:
                pass

    title = curses.color_pair(1) | curses.A_BOLD
    put(0, 0, (" BURN-IN  ·  %s" % model).ljust(width), title)
    put(0, max(0, width - 26), time.strftime("%Y-%m-%d %H:%M:%S %Z "), title)

    put(2, 1, "Kernel %s   microcode %s   RAM %s   CPUs %d"
        % (os.uname().release, microcode, mem, os.cpu_count() or 0))
    started = run.get("start")
    elapsed = hms(now - started) if started else "starting…"
    put(3, 1, "Elapsed ", curses.A_DIM)
    put(3, 9, elapsed, curses.A_BOLD)
    put(3, 24, "Cycle ", curses.A_DIM)
    put(3, 30, str(phase.get("cycle", 0)), curses.A_BOLD)
    put(3, 38, "Phase ", curses.A_DIM)
    put(3, 44, phase.get("phase", "-"), curses.A_BOLD | curses.color_pair(4))
    dur, pstart = phase.get("duration", 0), phase.get("started", now)
    if dur:
        done = min(1.0, (now - pstart) / dur)
        bar = 30
        fill = int(done * bar)
        put(4, 44, "[" + "#" * fill + "-" * (bar - fill) + "] %s / %s"
            % (hms(now - pstart)[2:] if now - pstart < 3600 else hms(now - pstart),
               hms(dur)[2:] if dur < 3600 else hms(dur)))
    else:
        put(4, 44, "running %s" % hms(now - pstart))

    y = 6
    put(y, 1, "%-50s %6s %6s %6s   %s" % ("TEST", "PASS", "FAIL", "WARN", "LAST"),
        curses.A_UNDERLINE)
    hard_fail = 0
    for key, label in TESTS:
        y += 1
        evs = [e for e in events if e.get("test") == key]
        n = {r: sum(1 for e in evs if e.get("result") == r) for r in ("pass", "fail", "warn")}
        hard_fail += n["fail"]
        put(y, 1, "%-50s %6d" % (label, n["pass"]))
        put(y, 59, "%6d" % n["fail"], curses.color_pair(2) | curses.A_BOLD if n["fail"] else 0)
        put(y, 66, "%6d" % n["warn"], curses.color_pair(3) if n["warn"] else 0)
        if evs:
            last = evs[-1]
            res = last.get("result", "?")
            attr = {"pass": curses.color_pair(5), "fail": curses.color_pair(2) | curses.A_BOLD,
                    "warn": curses.color_pair(3)}.get(res, 0)
            put(y, 76, "%-4s c%d %s" % (res.upper(), last.get("cycle", 0),
                                        time.strftime("%H:%M", time.localtime(last.get("t", 0)))), attr)

    y += 2
    put(y, 1, "KERNEL / HARDWARE EVENTS (journal, this boot)", curses.A_UNDERLINE)
    event_err = 0
    for key, label, sev, _ in EVENT_KINDS:
        y += 1
        c = journal.counts[key]
        if sev == "err":
            event_err += c
        attr = (curses.color_pair(2 if sev == "err" else 3) | curses.A_BOLD) if c else 0
        put(y, 1, "%-50s %6d" % (label, c), attr)
    for line in journal.last:
        y += 1
        put(y, 3, line.strip(), curses.color_pair(3))

    y += 2
    temp = sensors.temperature()
    freqs = sensors.frequencies()
    put(y, 1, "SENSORS", curses.A_UNDERLINE)
    y += 1
    put(y, 1, "CPU temp %s (max %s)   freq MHz %s" % (
        "%.0f°C" % temp if temp is not None else "n/a",
        "%.0f°C" % sensors.temp_max if sensors.temp_max is not None else "n/a",
        " ".join("%4d" % f for f in freqs) or "n/a"))
    y += 1
    idle = sensors.idle_states()
    put(y, 1, "idle states (last 2 s): " + ("  ".join(
        "%s %3.0f%%" % (n, max(0.0, s)) for n, s in idle) or "n/a"))

    y += 2
    if hard_fail or event_err:
        msg = "  ERRORS DETECTED  ·  %d failed tests  ·  %d kernel/hardware events  " % (hard_fail, event_err)
        put(y, 1, msg, curses.color_pair(6) | curses.A_BOLD)
    elif events:
        put(y, 1, "  CLEAN  ·  no errors so far  ", curses.color_pair(7) | curses.A_BOLD)
    else:
        put(y, 1, "  RUNNING  ·  first results pending  ", curses.color_pair(1) | curses.A_BOLD)

    put(h - 2, 1, "Alt+F2: root shell   journalctl -u burnin   logs: %s/logs" % STATE,
        curses.A_DIM)
    scr.refresh()


def main(scr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(2, curses.COLOR_RED, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_CYAN, -1)
    curses.init_pair(5, curses.COLOR_GREEN, -1)
    curses.init_pair(6, curses.COLOR_WHITE, curses.COLOR_RED)
    curses.init_pair(7, curses.COLOR_WHITE, curses.COLOR_GREEN)
    scr.timeout(2000)
    journal, sensors, static = Journal(), Sensors(), cpu_info()
    tick = 0
    while True:
        if tick % 3 == 0:
            journal.poll()
        # Kernel console messages scribble over the screen behind curses'
        # back; force a full repaint every 30 s.
        if tick % 15 == 0:
            scr.clearok(True)
        draw(scr, journal, sensors, static)
        tick += 1
        if scr.getch() == ord("q") and os.environ.get("BURNIN_ALLOW_QUIT"):
            break


curses.wrapper(main)
