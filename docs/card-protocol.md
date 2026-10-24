# The CoGS card from a lobby client's seat

This is the subset of the CoGS card protocol (spec v0.7) a Game Room
client uses: find the card, make sure it is online, issue an HTTPS
request, pull fields out of the JSON reply. The complete protocol (raw
TCP sockets, streaming, block devices, card services, Marinetti link
layer) is in the CoGS documentation; nothing here requires it.

Every byte layout below is what `clients/pascal/msnet.pas` sends and
receives in the shipped Milestones build, so it is tested against the
firmware and the MAME card model.

## Registers

The card occupies the slot's 16 I/O bytes. For slot `n`:

```
base = $C080 + n*$10          6502 / ProDOS 8, bank 0
base = $E0C080 + n*$10        65816 long address, from any bank
```

| Offset | Name | Dir | Use |
|---|---|---|---|
| +0 | DATA | R/W | FIFO. Write pushes one byte to the card. Read pops one byte from the card. Reading when nothing is queued returns $00, so check STATUS first. |
| +1 | STATUS | R | bit 7 RX_AVAIL (a byte is waiting at DATA), bit 6 TX_READY (room to write), bit 4 LINK_UP (Wi-Fi associated with an IP), bit 3 ERROR (sticky until the pending ERROR frame is read). No read side effects. |
| +5 | ID | R | $A2 |
| +6 | VERSION | R | nonzero |

Find the card by scanning slots 1 to 7 for `ID == $A2`, `VERSION != 0`
and `STATUS != $FF` (an empty slot floats high).

Two rules for 65816 code. Never pop DATA with an indexed load while the
index register is 16 bits (`LDA DATA,X` with X 16-bit does an extra read
of the un-carried address, which pops a byte you never see). Use 8-bit
indexes, `LDA [dp]`, or absolute long. And do not use indexed stores
whose target could be DATA (the 6502 family reads the target before a
store).

## Framing

Everything through DATA is a frame:

```
op(1)  len_lo(1)  len_hi(1)  payload[len]
```

Host to card is a command. Card to host is a response or event. The card
answers a command with the matching response opcode (`op | $80`), and
emits events on its own when something happens on a socket. Read frames
whole: pop the three-byte header, then exactly `len` bytes, waiting on
RX_AVAIL for each. Up to 1100 bytes of payload has been enough for the
lobby (replies are small; the longest is a `recv` with many lines).

While waiting for one particular response, other frames can arrive.
Handle or discard them, do not lose sync. The only one a lobby client
must act on is `$93 ERROR` for its own socket or socket `$FF` (global):
treat it as the connection failing.

## Commands used

| Op | Name | Payload | Reply |
|---|---|---|---|
| $03 | WIFI_JOIN | `ssid_len(1) ssid[] psk_len(1) psk[]`; both lengths 0 means use the credentials stored on the card | `$83: result(1)`, 0 = joined |
| $05 | TIME | none | `$85: unix_time(u32 LE)`, 0 = NTP not synced yet |
| $20 | HTTP | see below | `$95 HTTP_DONE: sock(1) status(u16 LE) total_len(u32 LE)` or `$93 ERROR` |
| $32 | JSON_GET | `sock(1) path_len(1) path[]` | `$B2: result(1) value_len(u16 LE) chunk[]` |

Events you may see and can ignore when not using raw sockets: `$91 DATA`
(response bytes of a non-retained request), `$92 CLOSED` (a keep-alive
socket closed, normal), `$94 WIFI_STATE`.

### Bringing the link up

1. If STATUS bit 4 is clear, send `WIFI_JOIN` with two zero lengths and
   wait for `$83` with result 0. The card joins with what the user set
   in its config menu or CDA.
2. Send `TIME` and repeat until the reply is nonzero. Verified TLS needs
   the card's clock, and the card refuses an HTTPS connect with error
   `5 TLS_HANDSHAKE` until NTP has run. This takes a few seconds after
   the join. Milestones caps it at 15 s and tells the user if it fails.

### HTTP ($20 -> $95)

```
sock(1) flags(1) method_len(1) method[] url_len(1) url[]
hdrs_len(u16 LE) hdrs[] body_len(u16 LE) body[]
```

- `sock` is a socket number you pick, 0 to 7. One request at a time per
  socket. The lobby client uses 0. If you make any other request (a log
  sink, say) use another socket, because the retained document is kept
  per socket.
- `flags`: bit 2 (`$04`) RETAIN keeps the decoded response body on the
  card (32 KB max) for `JSON_GET` instead of streaming it back as `$91
  DATA` events. bit 3 (`$08`) KEEP-ALIVE asks the card to reuse the TLS
  connection for the next request to the same host and port, which saves
  a handshake per lobby call. Bits 0 (stream) and 1 (header echo) stay
  clear. Milestones sends `$0C` for calls whose reply it reads and `$08`
  for fire-and-forget (`leave`, `score`).
- `method` is `GET` or `POST`. The URL is the full `https://host/path?query`.
  `hdrs_len` is 0 for the lobby. `body` is the POST body (the move lines for
  `send`), `body_len` 0 for GET.
- The card adds `Host`, `Connection`, `Accept-Encoding: identity`,
  `User-Agent` and `Content-Length`, does DNS, TCP, TLS with certificate
  verification, and de-chunks the response.
- Completion is `$95 HTTP_DONE` with your socket: `status` is the HTTP
  code (expect 200; the lobby answers 4xx with a JSON `ok:0` body) and
  `total_len` is the retained byte count. Failure is `$93 ERROR` with your
  socket or `$FF`: `sock(1) code(1) msg_len(1) msg[]`. Codes you may meet:
  `1 NOT_JOINED`, `2 DNS_FAIL`, `3 CONNECT_TIMEOUT`, `5 TLS_HANDSHAKE`,
  `6 CERT_VERIFY`, `9 BUFFER_OVERRUN`.
- Put a backstop timer on the wait, but make it long. The card times out
  its own requests and reports them as `$93`. The timer only has to catch a
  card that has gone silent, so a generous value (Milestones: 250 s of GS
  ticks) is right; a tight one misfires under an emulator running faster
  than real time.

### JSON_GET ($32 -> $B2)

Pulls one value out of the document retained by the last RETAIN request
on `sock`. `path` is a dotted path: `s`, `seat`, `lines`, `rows[0].n`.
The lobby's replies are flat, so paths are single keys.

Reply `result(1) value_len(u16 LE) chunk[]`, chunked at 1024 bytes;
`value_len` is the full length and repeats in every chunk, so concatenate
until you have that many bytes. `result` 0 means found. `13 NO_RETAINED`
means nothing is retained for this socket, `14 PATH_NOT_FOUND` means the
key is missing (also what you get if the body was not JSON).

Strings come back unescaped; numbers come back as their decimal text (the
lobby's `seed` is up to ten digits, parse it into a 32-bit value); the
`lines` value from `recv` is one string with `\n` already decoded to a
real newline between lines.

## The sequence, in frames

```
find card              read +5 == $A2, +6 != 0, +1 != $FF
if !(STATUS & $10)     $03 len 2  00 00          wait $83 result 0
repeat                 $05 len 0                 wait $85, until nonzero
join                   $20 [00 0C 04 "POST" ulen "https://lobby.a2cogs.com/v1/join?g=..&v=1&n=Rob" 00 00 00 00]
                       wait $95 sock 0 status 200
                       $32 [00 01 "t"]            -> ticket, 16 chars
                       $32 [00 01 "s"]            -> "wait" or "ready"
wait                   $20 GET /v1/wait?t=..&w=5000    then $32 "s"; on "ready" $32 "seat" "seed" "opp"
send                   $20 [00 0C 04 "POST" ulen ".../v1/send?t=.." 00 00 len_lo len_hi "M 2 33\n"]   then $32 "ok"
recv                   $20 GET /v1/recv?t=..&a=N&w=2000  then $32 "lines" "next" "s"
leave                  $20 [00 08 03 "GET" ulen ".../v1/leave?t=.." 00 00 00 00]
```

## Testing without a card

The CoGS build of MAME (shipped inside Ample as "CoGS Co-Processor &
Network Card") models the card with real network access from the host
Mac, including TLS, so a game in an emulated IIgs talks to the live lobby
exactly as on hardware. The Milestones headless test harness runs two of
these against each other.
