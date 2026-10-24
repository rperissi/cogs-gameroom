#!/usr/bin/env python3
"""A second player for testing a Game Room client with one Apple II.

    python3 bot.py GAME VER [--code CODE] [--name NAME] [--script FILE] [--quiet]

Joins the lobby as a player of GAME protocol version VER and sits at the
table. Every line the other seat sends is printed. By default the bot
answers each line by echoing it back, so your game's receive path gets
exercised with data it already understands. With --script, the bot sends
the file's lines in order instead, one per line it receives (blank lines
and lines starting with # are skipped); "*" in the script means echo.

Without --code the bot takes the public queue for GAME, which means it
will seat against the first real player who shows up. Use a code.

Standard library only. Ctrl-C leaves cleanly so the other seat sees the
room close.
"""
import argparse, sys, time
from lobby_client import Lobby


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game"); ap.add_argument("ver", type=int)
    ap.add_argument("--code", default="")
    ap.add_argument("--name", default="Bot")
    ap.add_argument("--script", help="file of lines to send, one per received line")
    ap.add_argument("--first", action="store_true", help="send the first script line before waiting for anything")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    script = None
    if a.script:
        with open(a.script) as f:
            script = [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]

    me = Lobby(a.game, a.ver, a.name, code=a.code)
    print("joining %s v%d%s as %s ..." % (a.game, a.ver, " code " + a.code if a.code else "", a.name))
    try:
        seat, seed, opp = me.join()
    except KeyboardInterrupt:
        me.leave(); return
    print("seated: seat %d, seed %d, opponent %r" % (seat, seed, opp))

    def reply(line):
        if script is None:
            out = line
        elif not script:
            return
        else:
            out = script.pop(0)
            if out == "*": out = line
        if not a.quiet: print("  -> %s" % out)
        me.send(out)

    try:
        if a.first and script:
            reply("")
        while me.state != "closed":
            for line in me.recv():
                print("<- %s" % line)
                reply(line)
        print("room closed by the other seat")
    except KeyboardInterrupt:
        print("leaving")
    finally:
        me.leave()


if __name__ == "__main__":
    main()
