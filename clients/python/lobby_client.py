#!/usr/bin/env python3
"""Reference client for the CoGS lobby (spec/lobby-v0.1.md). Standard library only.

    from lobby_client import Lobby
    me = Lobby("milestones", 1, "Rob", code="ROB-JOE")
    seat, seed, opp = me.join()      # blocks until paired
    me.send("M 2 33")
    for line in me.recv(): ...       # blocks up to 5 s, yields lines
    me.leave()

Self test (two clients against the live lobby):  python3 lobby_client.py
"""
import json, sys, time, threading, urllib.request, urllib.parse

BASE = "https://lobby.a2cogs.com"


class Lobby:
    def __init__(self, game, ver, name, code="", base=BASE):
        self.base, self.game, self.ver, self.name, self.code = base, game, ver, name, code
        self.t = None; self.after = 0; self.state = None

    def _get(self, path, params, body=None):
        url = self.base + path + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, data=body, method="POST" if body is not None else "GET")
        req.add_header("user-agent", "CoGS-lobby-client/0.1")  # the zone 403s Python-urllib
        if body is not None:
            req.add_header("content-type", "text/plain")
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())

    def join(self, timeout=3600):
        p = {"g": self.game, "v": self.ver, "n": self.name}
        if self.code: p["c"] = self.code
        r = self._get("/v1/join", p)
        if not r.get("ok"): raise RuntimeError("join: %s" % r.get("err"))
        self.t = r["t"]
        end = time.time() + timeout
        while r["s"] == "wait":
            if time.time() > end: self.leave(); raise TimeoutError("nobody came")
            r = self._get("/v1/wait", {"t": self.t})
            if not r.get("ok"): raise RuntimeError("wait: %s" % r.get("err"))
        if r["s"] != "ready": raise RuntimeError("room gone")
        self.state = "open"
        return r["seat"], r["seed"], r["opp"]

    def send(self, *lines):
        body = ("".join(l + "\n" for l in lines)).encode()
        r = self._get("/v1/send", {"t": self.t}, body)
        if not r.get("ok"): raise RuntimeError("send: %s" % r.get("err"))
        return r["n"]

    def recv(self):
        """One poll. Returns the list of new lines (may be empty). Sets state 'closed' when the room ends."""
        r = self._get("/v1/recv", {"t": self.t, "a": self.after})
        if not r.get("ok"): raise RuntimeError("recv: %s" % r.get("err"))
        self.after = r["next"]; self.state = r["s"]
        return [l for l in r["lines"].split("\n") if l]

    def recv_line(self, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            lines = self.recv()
            if lines: return lines[0]
            if self.state == "closed": return None
        raise TimeoutError("no line")

    def leave(self):
        if self.t: self._get("/v1/leave", {"t": self.t})

    def score(self, tag, value, add=False):
        """Post to the leaderboard. Best value kept unless add=True (then summed)."""
        p = {"g": self.game, "n": self.name, "x": tag, "v": int(value)}
        if add: p["m"] = "add"
        r = self._get("/v1/score", p)
        if not r.get("ok"): raise RuntimeError("score: %s" % r.get("err"))

    def top(self, tag="", k=10):
        """Leaderboard rows as [(name, value), ...], best first."""
        r = self._get("/v1/top", {"g": self.game, "x": tag, "k": k})
        rows = []
        for l in r.get("lines", "").split("\n"):
            if l:
                n, v = l.rsplit(" ", 1); rows.append((n, int(v)))
        return rows


def _selftest():
    code = "T%d" % (int(time.time()) % 100000)
    out = {}
    def player(n):
        c = Lobby("lobbytest", 1, n, code=code)
        seat, seed, opp = c.join(timeout=60)
        out[n] = (seat, seed, opp)
        c.send("hello from %s" % n, "seat %d" % seat)
        got = []
        while len(got) < 2:
            got += c.recv()
        out[n + ".got"] = got
        if seat == 1:
            c.leave()
        else:
            # seat 2 should see the close
            while c.state != "closed": c.recv()
            out["closed-seen"] = True
    a = threading.Thread(target=player, args=("Ann",)); b = threading.Thread(target=player, args=("Bob",))
    a.start(); time.sleep(0.5); b.start(); a.join(); b.join()
    print(json.dumps(out, indent=1))
    sa, sb = out["Ann"], out["Bob"]
    assert {sa[0], sb[0]} == {1, 2} and sa[1] == sb[1] and sa[2] == "Bob" and sb[2] == "Ann", "pairing"
    assert out["Ann.got"] == ["hello from Bob", "seat %d" % sb[0]], out["Ann.got"]
    assert out["Bob.got"] == ["hello from Ann", "seat %d" % sa[0]], out["Bob.got"]
    assert out.get("closed-seen"), "close not relayed"
    rooms = Lobby("x", 1, "x")._get("/v1/rooms", {})
    top = Lobby("x", 1, "x")._get("/v1/score", {"g": "lobbytest", "n": "Ann", "v": 42})
    top = Lobby("x", 1, "x")._get("/v1/top", {"g": "lobbytest"})
    print("rooms:", rooms, "top:", top)
    assert "Ann 42" in top["lines"]
    print("LOBBY SELFTEST PASS")


if __name__ == "__main__":
    _selftest()
