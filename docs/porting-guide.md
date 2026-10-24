# Adding network play to a turn-based Apple II game

This is the path Milestones 2000 took. It applies to any game where
players take turns and the game state can be reproduced from a seed plus
the sequence of moves: card games, board games, word games, turn-based
strategy. It does not apply to action games; those need the real-time
tier, which is not built yet.

## 1. The model: lockstep

Both machines run the complete game. The lobby gives both the same seed;
each machine shuffles the same deck, rolls the same dice, deals the same
hands. From then on only moves cross the wire. When it is the remote
player's turn, your game waits for their move line and applies it exactly
as if the local player had made it.

This means:

- No server-side rules. The lobby relays bytes.
- Both copies must be deterministic given the seed and the moves. Any
  randomness has to come from your own seeded generator, never from the
  clock or the toolbox's random. Milestones replaced its `random` calls
  with a Park-Miller generator seeded from the lobby seed (`myrand` in `msnet.pas`).
- Both copies must run the same protocol version. Bump `v` on `join`
  whenever a rule or the line format changes.

It also means you can usually reuse the game's existing "computer
opponent" plumbing: the remote player's move arrives and is applied by the
same code that applied the computer's move. Milestones keeps `me` and
`foe` seat indexes so its AI can play either side (that is how the
headless test seats play against each other).

## 2. Who goes first, who is who

`join`/`wait` return `seat` (1 for whoever joined first, 2 for the other)
and the shared `seed`. Decide first move from the seed, not from the seat,
so neither player has a structural advantage:

```
if myrand(2) = netseat then I start else they start
```

`opp` is the other player's name as they typed it. Show it. The score
sheet, prompts and the "X wins" alert all read better with a name than
with "Computer".

## 3. The line protocol

Design the smallest set of lines that carries a move. Milestones uses:

```
M action card       a move: which action (play, discard, coup fourre) on which card
K 0|1               the reply to "you reached the checkpoint, stop or go on?"
Q                   I am leaving the game
```

Keep lines short (the lobby caps a line at 200 bytes) and ASCII. Numbers
as decimal text are easier to produce and parse on an 8-bit machine than
binary. Send one line per `send` call; the lobby keeps the last 256 lines
per direction, so there is slack if a client falls behind briefly.

Treat `s:"closed"` on `recv` the same as a `Q` from the other side.

## 4. The call sequence

Everything goes through the card's `HTTP` command with the RETAIN flag,
then `JSON_GET` to pull fields out of the retained reply. See
[card-protocol.md](card-protocol.md) for bytes.

```
cogsfind                           ID == $A2 in slot 1..7
if not LINK_UP: WIFI_JOIN(empty)   join with the card's stored credentials
TIME until nonzero                 TLS needs the card's clock (NTP)
POST /v1/join?g=..&v=..&n=..[&c=..]   JSON_GET t, s
while s = "wait": GET /v1/wait?t=..&w=5000   JSON_GET s
JSON_GET seat, seed, opp
loop:
  my turn:    POST /v1/send?t=..  body "M 2 33\n"
  their turn: GET /v1/recv?t=..&a=N&w=2000   JSON_GET lines, next, s
GET /v1/leave?t=..
```

Use socket 0 for the lobby and, if your game makes any other HTTP call
(a debug log sink, say), a different socket number. The card keeps one
retained document per socket.

## 5. Waiting without freezing the UI

Long polls block the card for up to `w` milliseconds. A headless or
simple client can pass `w=5000` and sit. An interactive game should keep
its event loop alive: Milestones polls with `w=1000` while waiting for
an opponent and watches the mouse button so a click cancels, and during
play polls `recv` with `w=0` once a second from its idle loop, so the
menus still work while the other player thinks.

Say so in the UI. "Waiting for a player. Click to cancel." The first
tester sat looking at a watch cursor with no idea a click would get him
out.

## 6. Names and codes

Let the player type a name (12 chars max, printable ASCII). URL-escape it
before putting it in the query string: space becomes `+`, and drop `&`,
`#`, `%`, `+`. `msnet.pas` has `addname`.

A room code (`c`, uppercase letters and digits) lets two friends match
each other instead of the public queue. Milestones reads it from an
optional `MSNET` text file next to the program. A dialog works too.

## 7. Scores

When a match ends, each seat can post:

```
POST /v1/score?g=mygame&x=pts&v=5550&n=Rob          best kept
POST /v1/score?g=mygame&x=wins&m=add&v=1&n=Rob      added up
```

`x` is a tag you choose. The lobby page links each game to
`/top?g=mygame`, which lists every tag it has seen. Skip the post for
unattended or AI-driven seats so the board stays people.

## 8. Testing

`clients/python/bot.py` is a second player. Join with a room code from
both sides and the bot echoes your lines, or plays a scripted sequence.

For a real second seat, run your game in an emulator with a CoGS card
model (the CoGS build of MAME in Ample has one, with real TLS) alongside
the physical machine, both pointed at the same room code.

Milestones goes further: an `auto` setting makes the computer play the
local seat, so two headless emulator instances play a complete game
against each other through the live lobby in a couple of minutes, and a
check script confirms both saw the same state every turn. That harness
caught every bug below.

## 9. Things that bit us

**Timeouts in GS ticks are not seconds.** The game waited 20 GS seconds
for a card reply. Under an emulator running unthrottled (28x) a 2 s long
poll is 56 GS seconds, and the game declared the connection dead. The
card already reports its own HTTP failures as `$93 ERROR` events, so the
tick limit is only a backstop. Make it generous (Milestones uses 250 s)
and rely on the error event.

**Keep big strings off the stack.** ORCA/Pascal passes `string[1000]` by
value. Three of those through a deep call chain crashed the machine at
the end of the first deck. The request URL, POST body and reply body are
globals now.

**One program, one segment, 64 KB.** Adding the network layer pushed the
single OMF segment past 64 KB. The linker said nothing; the loader
refused the file with system error $1104. `{$Segment 'MSNET'}` around
the network code split it. `{$StackSize}` also produced an unloadable
file, which is part of why the strings became globals.

**ORCA/Pascal optimizer.** `{$Optimize -1}` cached a local across a
by-reference toolbox call (`OffsetRect` in a loop never saw the update,
the deal animation never ended) and scalar `var` parameters did not write
through. `{$Optimize 0}` did not fit in the code bank. `{$Optimize 3}`
(peephole only) was the setting that worked. Also: functions cannot
return strings, and a string variable compared to a quoted literal is
false; compare by length and characters.

**Verified TLS needs the clock.** The card refuses an HTTPS connect with
`5 TLS_HANDSHAKE` until NTP has set its time, which takes a few seconds
after Wi-Fi joins. Poll `TIME` for a nonzero value before the first
lobby call, with a cap, and tell the user if it never comes.

**Never read the FIFO with a 16-bit indexed load.** On a 65816 with
16-bit index registers, `LDA DATA,X` performs an extra read of the
un-carried address, which pops a byte you never see. Use 8-bit indexes,
long indirect, or absolute loads.

**The lobby page and a card poll are not the same thing.** If a seat
dies without `leave`, its room stays on the "playing" count until the
idle alarm (10 min without a `send` or `recv`) closes it. Always send
`leave` on every exit path you control, including the game's quit.
