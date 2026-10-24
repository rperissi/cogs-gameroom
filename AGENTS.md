# Instructions for AI coding assistants

You are adding two-player network play to an Apple II game, through a
CoGS card and the Game Room lobby at `https://lobby.a2cogs.com`. This
file tells you what to read, what to build, and what not to do. The
human you are working with owns the game; ask them the questions in the
first section before writing code.

## Ask first

1. Which toolchain and target? ORCA/Pascal, ORCA/C, Merlin or another
   65816 assembler on the IIgs; cc65 or ca65 on an 8-bit Apple II under
   ProDOS 8. The register base differs (`$C080+n*$10` in bank 0 for 8-bit,
   `$E0C080+n*$10` long for the IIgs) and so does the string handling.
2. Is the game deterministic? Where does it get randomness? Every
   random draw has to be replaced by one seeded generator fed from the
   lobby seed. If the game uses the clock, the toolbox random, or
   uninitialized memory anywhere that affects play, that has to change.
3. What is a move? Get the list of player decisions that change game
   state. That list becomes the line protocol.
4. Game id and version. Short lowercase id, protocol version 1.

## Read, in this order

1. `README.md` for the shape of a match.
2. `spec/lobby-v0.1.md`, the lobby contract. Every URL and field.
3. `docs/card-protocol.md`, the card bytes: registers, frames, `HTTP`
   with RETAIN and KEEP-ALIVE, `JSON_GET`, `TIME`, `WIFI_JOIN`, events.
4. `docs/porting-guide.md`, the method and the list of things that went
   wrong in the first port. Read the last section twice.
5. `clients/pascal/msnet.pas`, the shipped reference. Even if the target
   is C or assembly, the call order and the byte handling are the model.
   `cogsfind`, `cogsget`, `cogsput`, `cogsframe`, `cogsrecv`, `nethttp`,
   `jsonget`, `netconnect`, `netstart`, `netgetline`, `netsendline`,
   `netclose`, `netscore` are generic. The rest is Milestones.

## Build this

In the game's source, a network layer with these pieces, in its own
segment or module:

- Card access: find the card, read and write the FIFO with STATUS polls,
  send a frame, receive a frame with a tick backstop.
- `connect`: link up if needed (`WIFI_JOIN` with empty credentials),
  wait for `TIME` nonzero, `POST /v1/join`, keep the ticket.
- `wait for opponent`: poll `/v1/wait` with `w=1000` from a loop that
  still services the UI and lets the user cancel. On `ready` store seat,
  seed, opponent name.
- `send line` and `get line`: `/v1/send` and `/v1/recv` with `a=next`
  carried between calls. Buffer received text and hand the game one line
  at a time. `s:"closed"` ends the game.
- `leave`: `/v1/leave` on every exit path, including quit from a menu.
- Optionally `score`: `/v1/score` at the end of a match, skipped for
  AI-driven or unattended seats.

Then the game changes:

- Seed the game's random generator from the lobby seed in a network
  game. Decide who moves first from a draw of that generator, not from
  the seat number.
- When it is the remote seat's turn, block on `get line` (with the UI
  alive) and apply the line through the same code that applies a local
  move.
- When the local player moves, send the line before or as you apply it.
- Show the opponent's name where the game shows a player name.
- A network game menu item, and some way to enter a name and an optional
  room code (a dialog, or a small text config file next to the program).

## Rules

- Use only `HTTP` (with RETAIN and KEEP-ALIVE flags) and `JSON_GET` for
  the lobby. Do not open raw TCP sockets, do not parse JSON on the Apple
  II, do not add a TCP/IP stack.
- Backstop timers on card replies must be long (minutes, not seconds).
  The card reports its own failures as `$93 ERROR` events; the timer
  exists only for a silent card. Short timers misfire under emulators
  that run faster than real time.
- Keep lines ASCII, under 200 bytes, decimal numbers as text.
- 65816: never pop the DATA register with a 16-bit indexed load. No
  indexed stores that could target DATA.
- ORCA/Pascal: functions do not return strings; compare strings by
  length and characters, not against quoted literals; put 1000-byte
  strings in globals, not on the stack; watch the 64 KB segment limit
  (`{$Segment}`); `{$Optimize 3}` is the setting known to work.
- Do not invent lobby endpoints or fields. If the game needs something
  the spec does not have, build it on top of `send`/`recv` lines or
  stop and say so.
- Do not change the game's rules or AI as part of this work.
- No new dependencies, no code generators, no build system changes
  beyond adding the new source file.

## Test

- `python3 clients/python/lobby_client.py` proves the lobby is up and
  your network is fine.
- `python3 clients/python/bot.py GAME 1 --code DEV1` is an opponent that
  echoes. Run the game in an emulator with a CoGS card model (the CoGS
  build of MAME in Ample) or on hardware, start a network game with code
  `DEV1`, and watch the bot print the game's lines.
- Two copies of the game against each other, same code, is the real
  test. If the game has a computer opponent, an "auto" switch that lets
  it play the local seat turns this into an unattended regression test;
  Milestones logs every state change to a TCP sink and a script diffs
  the two seats.

## When you report back

Say what the line protocol is, where the seed enters the game, which
random draws were changed, and what you could not test. Keep uncertainty
visible. Do not claim hardware behavior you only saw in an emulator.
