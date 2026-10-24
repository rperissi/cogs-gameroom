# CoGS Lobby v0.1

A matchmaking and relay service for Apple II games played through a CoGS
card. `https://lobby.a2cogs.com`. The lobby pairs two players of the same
game, hands both a seat number and a shared seed, and relays opaque text
lines between them. It never interprets a game's lines; the game's
protocol is the game's business.

Status: v0.1, live since 2026-10-23. Reference client: Milestones 2000
Network Version (`clients/pascal/msnet.pas`). The server is a Cloudflare
Worker with Durable Objects, run by the CoGS project.

## 1. Design constraints

- Zero management. One Cloudflare Worker plus one Durable Object. No
  servers, no accounts, no friend lists.
- Works with the card's HTTP command and JSON_GET and nothing else, so a
  ProDOS 8 client in assembly can use it: every request is a fixed URL
  with query parameters, bodies are plain text, every response is one
  small flat JSON object with short keys.
- Every response returns within 5 seconds, including the long polls. The
  card's keep-alive path drops a connection that has shown no first byte
  in 8 s (`HTTP_KA_STALL_MS`).
- Turn based. One line per move is the shape; this tier is not for
  per-tic traffic. A real-time tier (WebSocket into a Durable Object,
  with a WS socket mode in firmware) is a separate spec.

## 2. Identifiers

- `g` game id: 1 to 16 chars, `[a-z0-9-]`. Chosen by the game author,
  e.g. `milestones`.
- `v` protocol version: integer 1 to 999. Two clients match only on the
  same `g` and `v`, so a v2 client is never seated against a v1.
- `c` room code: optional, 1 to 16 chars, `[A-Z0-9-]`, uppercased by the
  server. Two friends who type the same code match each other and nobody
  else. No code means the public queue for that game.
- `n` name: 1 to 12 chars of printable ASCII, `+` decodes to space.
- `t` ticket: issued by `join`, 16 chars `[a-z0-9]`. Identifies one
  player in one game and is the only credential. Every later call takes
  `t`. Unguessable, single use, dies with the room.
- `id` card id: optional, up to 24 chars, the card's unique id. Used
  only for rate limiting and the fleet count, never shown.

## 3. Endpoints

All responses are `200 application/json` with `ok` 1 or 0. A 0 carries
`err` (short word). Malformed requests are `400`. Nothing needs a header
beyond what the card injects. GET and POST are both accepted everywhere;
POST is required only where a body is sent.

### join

`POST /v1/join?g=milestones&v=1&n=Rob[&c=ROB-JOE][&id=...]`

Enters the queue for (g, v, c). If someone compatible is already waiting
the match happens now.

```
{"ok":1,"t":"k3j9...","s":"wait","w":1}
{"ok":1,"t":"k3j9...","s":"ready","seat":2,"seed":1839201,"opp":"Joe"}
```

`w` is the number of players waiting in that queue including you.

### wait

`GET /v1/wait?t=TICKET`

Long poll, returns as soon as the match happens or after 5 s. Also the
heartbeat: a waiting ticket that has not called `wait` for 30 s is
dropped. `&w=MS` caps the wait (0 to 5000; 0 answers at once), so a
client that wants to keep its own UI alive can poll briefly and often.

```
{"ok":1,"s":"wait","w":1}
{"ok":1,"s":"ready","seat":1,"seed":1839201,"opp":"Joe"}
{"ok":1,"s":"gone"}
```

`seat` is 1 for the player who joined first. `seed` is a positive 31-bit
integer, the same for both seats. `opp` is the other player's name.

### send

`POST /v1/send?t=TICKET` with a `text/plain` body of one or more
newline-terminated lines.

```
{"ok":1,"n":7}
{"ok":0,"err":"closed"}
```

`n` is the count of lines the server now holds from this seat. A line is
at most 200 bytes; a body at most 32 lines. Lines are opaque bytes except
that `\n` ends a line and `\r` is stripped.

### recv

`GET /v1/recv?t=TICKET&a=AFTER`

Lines from the opponent with sequence greater than `a` (first call
`a=0`). Long poll: returns when at least one line is available, when the
room state changes, or after 5 s. `&w=MS` caps the wait as in `wait`.

```
{"ok":1,"s":"open","next":3,"lines":"M 2 33\nK 1\n"}
{"ok":1,"s":"open","next":3,"lines":""}
{"ok":1,"s":"closed","next":3,"lines":""}
```

`next` is the value to pass as `a` on the next call. `lines` is the
concatenated text. The server keeps the last 256 lines per direction; a
client that falls further behind gets `err:"lost"`. `s:"closed"` means the
opponent left or the room expired; the client should treat it like a
`Q` from the other side.

### leave

`GET /v1/leave?t=TICKET`

Leaves the queue or the room. The opponent's next `recv` returns
`s:"closed"`. `{"ok":1}` always.

### rooms (public, for the waiting page)

`GET /v1/rooms[?g=milestones]`

```
{"ok":1,"waiting":1,"playing":2,"played":41,"games":"milestones:1:2:41,doom:0:0:0"}
```

`games` is `g:waiting:playing:played` per game, comma separated;
`played` is the count of rooms ever opened for that game. Only public
queue entries count as waiting; room-code entries count but are not
named. Cached 5 s at the edge.

### score and top (leaderboards)

`POST /v1/score?g=doom&n=Rob&v=4231[&x=E1M1][&m=add]` body ignored.
`v` is an integer, higher is better, `x` is an optional 16-char tag (a
level, a mode, or a stat name such as `pts` or `wins`). One row per
(g, n, x). Without `m` the row keeps the best value seen; with `m=add`
the value is added to the row, which is how a win counter or a games
played counter works.

```
{"ok":1}
```

`GET /v1/top?g=doom[&x=E1M1][&k=10]`

```
{"ok":1,"lines":"Rob 4231\nJoe 3900\n"}
```

`k` caps the rows (default 10, max 50). Lines are `name value`, best
first.

`GET /top?g=doom` is the same data as an HTML page, one table per tag,
linked from the lobby's front page for every game it knows a title for.
Open an issue in the Game Room repo to have a game id given a title and
tag labels there; unknown ids still get a page with the raw tag names.

## 4. Lifecycle and limits

- Queue entry: expires 30 s after the last `wait`. `leave` removes it.
- Room: created at match, two seats, closed when either seat leaves or
  after 10 min with no `send` or `recv` from either seat, or after 6 h.
- Ticket reuse after close: `err:"gone"`.
- Rate limit: 10 `join` per minute per card id or IP; 4 polls per second
  per ticket. Over the limit is `429`.
- Sizes: query string under 512 bytes; `send` body under 8 KB; every
  response under 8 KB so it fits a JSON_GET retained document with room
  to spare.

## 5. Client sketch (card commands only)

```
HTTP POST https://lobby.a2cogs.com/v1/join?g=milestones&v=1&n=Rob  flags=RETAIN
  JSON_GET "t"  -> ticket      JSON_GET "s" -> wait | ready
loop while s = wait:
  HTTP GET /v1/wait?t=...  flags=RETAIN ; JSON_GET "s"
JSON_GET "seat", "seed", "opp"
play:
  HTTP POST /v1/send?t=...  body "M 2 33\n"
  HTTP GET  /v1/recv?t=...&a=N  flags=RETAIN ; JSON_GET "lines", "next", "s"
HTTP GET /v1/leave?t=...
```

Set the HTTP command's keep-alive flag (bit 3, `$08`) on every call so
the TLS session is reused; the server answers within 5 s so the card
never hits its 8 s stall cutoff.

## 6. What the lobby does not do

No identity, no friends, no chat, no spectators, no more than two seats,
no server-side game logic, no persistence of games. A game that needs
those builds them on top of `send`/`recv` or waits for a later version.
