"""Helpers for the automated game test suite (stdlib only).

Scenarios drive real game instances in the isolated rig (tools/rig.sh) through
the dev command channel of MtDev.gml. See IMPLEMENT.md, Phase 0.
"""
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
RIG = Path(os.environ.get("MT_RIG") or f"{os.environ.get('XDG_RUNTIME_DIR') or '/tmp'}/mistria-together-rig")
COMPANION = REPO / "target" / "release" / "mistria-together"
RIG_SH = REPO / "tools" / "rig.sh"
FARM_ROOM, FARM_X, FARM_Y = "farm", 800, 800


class Failure(AssertionError):
    pass


_report = {"passed": 0, "failed": 0}


def expect(condition, message):
    if condition:
        _report["passed"] += 1
        print(f"    ok    {message}")
    else:
        _report["failed"] += 1
        print(f"    FAIL  {message}")
        raise Failure(message)


def expect_equal(a, b, message):
    expect(a == b, f"{message} ({a!r} == {b!r})" if a == b else f"{message}: {a!r} != {b!r}")


def digest_diff(a, b, limit=10):
    sa, sb = set(a), set(b)
    return {"only_first": sorted(sa - sb)[:limit], "only_second": sorted(sb - sa)[:limit]}


def expect_same_world(games, where="near", radius=14, timeout=5.0):
    """All games agree on the world digest within `timeout` seconds."""
    deadline = time.time() + timeout
    while True:
        digests = [g.cmd({"cmd": "digest", "scope": where, "radius": radius})["lines"] for g in games]
        if all(d == digests[0] for d in digests[1:]):
            expect(True, f"same world ({where}, {len(digests[0])} entries) on {[g.name for g in games]}")
            return
        if time.time() >= deadline:
            for g, d in zip(games[1:], digests[1:]):
                print(f"    diff {games[0].name} vs {g.name}: {digest_diff(digests[0], d)}")
            expect(False, f"same world ({where})")
        time.sleep(0.5)


def screenshot(game, path):
    """Best effort; never fails a scenario."""
    try:
        subprocess.run(["gamescopectl", "screenshot", str(path)], timeout=5, capture_output=True)
    except Exception:
        pass


class Game:
    def __init__(self, name):
        self.name = name
        self.data = RIG / name / "FieldsOfMistria"
        self.ipc = self.data / "mod_data" / "mistria_together" / "ipc"
        self.seq = 0
        self.proc = None
        self.companion = None
        self.out = RIG / f"{name}.out"
        self.companion_out = RIG / f"{name}.companion.out"

    # -- process control -------------------------------------------------
    def wipe(self):
        shutil.rmtree(self.data / "mod_data", ignore_errors=True)
        shutil.rmtree(self.data / "saves", ignore_errors=True)
        self.seq = 0

    def start(self, mode="new", dev_name=None):
        env = dict(os.environ, MT_RIG=str(RIG), MISTRIA_TOGETHER_DEV=mode,
                   MISTRIA_TOGETHER_DEV_NAME=dev_name or self.name.upper())
        env["MISTRIA_TOGETHER_DEV_LOOK"] = str(int(self.name[1:]) if self.name[1:].isdigit() else 0)
        self.companion = subprocess.Popen(
            [str(COMPANION), "daemon", "--data-dir", str(self.data)],
            stdout=open(self.companion_out, "wb"), stderr=subprocess.STDOUT, start_new_session=True)
        self.proc = subprocess.Popen(
            [str(RIG_SH), "run", self.name], env=env,
            stdout=open(self.out, "wb"), stderr=subprocess.STDOUT, start_new_session=True)

    def stop(self):
        for p in (self.proc, self.companion):
            if p is not None and p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for p in (self.proc, self.companion):
            if p is not None:
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def restart_companion(self):
        if self.companion is not None and self.companion.poll() is None:
            os.killpg(self.companion.pid, signal.SIGTERM)
            self.companion.wait(timeout=10)
        self.companion = subprocess.Popen(
            [str(COMPANION), "daemon", "--data-dir", str(self.data)],
            stdout=open(self.companion_out, "ab"), stderr=subprocess.STDOUT, start_new_session=True)

    # -- observation -----------------------------------------------------
    def state(self):
        path = self.ipc / "dev_state.json"
        for _ in range(5):
            try:
                return json.loads(path.read_text())
            except (OSError, ValueError):
                time.sleep(0.1)
        return {}

    def wait(self, predicate, what, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise Failure(f"{self.name} exited while waiting for {what}")
            st = self.state()
            if predicate(st):
                return st
            time.sleep(0.25)
        raise Failure(f"{self.name}: timed out after {timeout}s waiting for {what}")

    def log(self):
        try:
            return self.out.read_text(errors="replace")
        except OSError:
            return ""

    def cmd(self, command, timeout=10):
        """Send a dev command, wait for its result, return `value`."""
        n = self.seq
        self.seq += 1
        self.ipc.mkdir(parents=True, exist_ok=True)
        tmp = self.ipc / "dev_cmd.tmp"
        tmp.write_text(json.dumps(command))
        os.replace(tmp, self.ipc / f"dev_cmd_{n}.json")
        res_path = self.ipc / f"dev_res_{n}.json"
        deadline = time.time() + timeout
        while time.time() < deadline:
            if res_path.exists():
                try:
                    res = json.loads(res_path.read_text())
                except ValueError:
                    time.sleep(0.05)
                    continue
                if not res.get("ok"):
                    raise Failure(f"{self.name}: command {command} failed: {res.get('error')}")
                return res.get("value")
            time.sleep(0.05)
        raise Failure(f"{self.name}: command {command} timed out after {timeout}s")


def sha256(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Session:
    def __init__(self, games):
        self.all = games
        self.host = games[0]
        self.guests = games[1:]

    def connect(self, addr="127.0.0.1", timeout=40):
        self.host.cmd({"cmd": "menu", "action": "host"})
        for g in self.guests:
            g.cmd({"cmd": "menu", "action": "join", "addr": addr})
        for g in self.all:
            g.wait(lambda s: s.get("online"), "online", timeout)
        for g in self.guests:
            g.wait(lambda s: (s.get("sync") or {}).get("adopted"), "host world adopted", timeout)
        expect(True, f"connected: {[g.name for g in self.all]}")


def join_farmhand(session, guest, name, addr="127.0.0.1", timeout=90):
    """Host is hosting; `guest` is at the title: Join as a farmhand."""
    guest.cmd({"cmd": "title_join", "addr": addr, "name": name})
    guest.wait(lambda s: s.get("in_world"), "guest in the world", timeout)
    guest.wait(lambda s: s.get("online") and (s.get("sync") or {}).get("adopted"),
               "guest online with the host's world", timeout)


def run_scenario(module, players, keep=False, timeout=90):
    """Start fresh instances, run one scenario, always clean up. Returns ok."""
    name = module.NAME
    n = getattr(module, "PLAYERS", 2)
    if players:
        n = players
    games = [Game(f"p{i + 1}") for i in range(n)]
    modes = list(getattr(module, "MODES", None) or ["new"] * n)
    ok = False
    print(f"== {name}")
    try:
        for g, mode in zip(games, modes):
            g.wipe()
            g.start(mode)
        for g, mode in zip(games, modes):
            if mode.startswith("title"):
                g.wait(lambda s: s.get("title"), "title screen", timeout)
            else:
                g.wait(lambda s: s.get("in_world"), "in_world", timeout)
        if getattr(module, "SETUP", None) == "farm":
            for g, mode in zip(games, modes):
                if not mode.startswith("title"):
                    g.cmd({"cmd": "tp", "room": FARM_ROOM, "x": FARM_X, "y": FARM_Y})
            time.sleep(2)
        module.run(Session(games))
        ok = True
    except Failure as e:
        print(f"    FAILED: {e}")
    except Exception as e:  # scenario bug or harness error
        print(f"    ERROR: {type(e).__name__}: {e}")
    finally:
        if not ok:
            save_failure(name, games)
        for g in games:
            g.stop()
    print(f"== {name}: {'PASS' if ok else 'FAIL'}")
    return ok


def save_failure(name, games):
    dest = RIG / "failures" / name
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True, exist_ok=True)
    for g in games:
        for src in (g.out, g.companion_out, g.ipc / "dev_state.json"):
            if src.exists():
                shutil.copy(src, dest / f"{g.name}_{src.name}")
        for log in (g.data / "mod_data").rglob("*.log"):
            shutil.copy(log, dest / f"{g.name}_{log.name}")
    print(f"    artifacts: {dest}")
