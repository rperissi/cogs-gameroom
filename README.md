# CoGS Game Room

Two-player network play for Apple II games, through a [CoGS](https://a2cogs.com)
card and the lobby at [lobby.a2cogs.com](https://lobby.a2cogs.com).

The lobby pairs two players of the same game, hands both a seat number and
a shared random seed, and relays text lines between them. It does not know
the rules of any game. Your game decides what a move looks like; the lobby
carries it. There are no accounts, nothing to install on a modern machine,
and nothing for you to host.

First title on it: Milestones 2000 Network Version, Ken Franklin's 1990
Mille Bornes for the IIgs, with two-player play added in ORCA/Pascal. Its
network layer is in this repo as the worked example.

## What your game needs

- A CoGS card in the Apple II, joined to Wi-Fi. The card does DNS, TCP,
  TLS and HTTP. Your program talks to it through four I/O registers in
  the slot space with a small framed protocol. Nothing else on the
  machine is involved: no Marinetti, no TCP/IP stack, no drivers.
- Two card commands, `HTTP` and `JSON_GET`. The lobby is designed so that
  is enough: every call is one URL with query parameters, every reply is
  a small flat JSON object, and every reply comes back within five
  seconds. A ProDOS 8 program in 6502 assembly can use it.
- A deterministic game. The usual shape is lockstep: both machines run
  the same game from the same seed and only the moves cross the wire.

## How a match goes

```
POST /v1/join?g=mygame&v=1&n=Rob            -> ticket, "wait" or "ready"
GET  /v1/wait?t=TICKET&w=5000                -> poll until "ready": seat, seed, opp
POST /v1/send?t=TICKET   body "M 2 33\n"     -> your move to the other seat
GET  /v1/recv?t=TICKET&a=N&w=2000            -> their lines, and "closed" if they left
GET  /v1/leave?t=TICKET
POST /v1/score?g=mygame&n=Rob&x=pts&v=5550   -> optional leaderboard
```

Add `&c=CODE` to `join` and you only match someone with the same code.
Without it you are in the public queue for your game id.

The full contract is [spec/lobby-v0.1.md](spec/lobby-v0.1.md).

## In this repo

| Path | What |
|---|---|
| [docs/porting-guide.md](docs/porting-guide.md) | How to add network play to a turn-based game, step by step, with the things that bit us |
| [docs/card-protocol.md](docs/card-protocol.md) | The part of the CoGS card protocol a lobby client uses: registers, framing, `HTTP`, `JSON_GET`, `TIME`, events |
| [spec/lobby-v0.1.md](spec/lobby-v0.1.md) | The lobby API |
| [clients/pascal/msnet.pas](clients/pascal/msnet.pas) | The Milestones network layer, ORCA/Pascal, as shipped. Card access, lobby calls, a line protocol, config file |
| [clients/python/lobby_client.py](clients/python/lobby_client.py) | Reference client, standard library only, with a self test against the live lobby |
| [clients/python/bot.py](clients/python/bot.py) | A second player for testing: joins your game id and answers every line, so you can develop with one Apple II |
| [AGENTS.md](AGENTS.md) | Instructions for AI coding assistants working in a game's source tree |

Bindings for ORCA/C, cc65 and 65816 assembly are planned. Until then
`docs/card-protocol.md` has the byte layouts, and `msnet.pas` shows every
call in order; the code is short.

## Testing without a second Apple II

```
python3 clients/python/bot.py mygame 1 --code DEV1
```

joins the lobby as a player of `mygame` protocol version 1 with room code
`DEV1`. Put the same code in your game and start a network game; the bot
is your opponent and prints every line it gets. By default it echoes each
line back so your receive path gets exercised; `--script moves.txt` sends
a prepared sequence instead.

The lobby page shows who is waiting and playing, and has a leaderboard
link per game.

## Game ids

Pick a short lowercase id (`[a-z0-9-]`, up to 16 chars) and a protocol
version integer. Two clients match only on the same id and version, so
when your line protocol changes, bump the version and old and new copies
never get seated together. Ids are first come, first served; there is no
registry yet. Open an issue here if you want yours listed on the lobby
page with a display name.

## Status

The lobby is v0.1 and live. The turn-based tier (this repo) is the one
that exists. A real-time tier for per-frame traffic (WebSocket from the
card into the lobby) is designed but not built; it will be a separate
spec when it lands.

## License

MIT for everything in this repo. The CoGS card protocol it describes is
documented in the CoGS project.
