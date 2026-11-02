# zig-bypassdpi

A small, cross-platform **userspace DPI-bypass proxy** written in pure
[Zig](https://ziglang.org) 0.16 — no external dependencies, no kernel driver, no
root/admin.

It runs as a local **SOCKS5 + HTTP CONNECT** proxy. Point your client at it and
it transparently fragments the first TLS **ClientHello** of every `:443`
connection so that a Deep Packet Inspection (DPI) engine cannot reassemble the
**SNI** hostname and therefore cannot match it against a blocklist.

This is a Zig port of the technique used by
[SpoofDPI](https://github.com/xvzc/SpoofDPI) (Go) and
[byedpi](https://github.com/hufrea/byedpi) (C). As far as I know there was no Zig
implementation before this one.

## The technique (why this works)

Many censorship systems block HTTPS by reading the plaintext **SNI** field in the
TLS ClientHello — the very first thing your browser sends after the TCP
handshake. The DPI box watches the stream, finds `server_name = blocked.example`,
and drops or resets the connection.

That inspection assumes the ClientHello arrives as one clean, contiguous chunk.
If instead the ClientHello is delivered as **two (or more) separate TCP
segments**, split *inside* the hostname, a cheap stateless DPI engine sees
`...blo` in one segment and `cked.example...` in the next and never reconstructs
the string. The server's TCP stack reassembles it perfectly, so the real TLS
handshake still completes.

`zig-bypassdpi` does exactly that, entirely in userspace with ordinary BSD
sockets:

1. Accept a SOCKS5 / HTTP CONNECT request and open a TCP connection to the
   target.
2. On the **first** client → upstream write to a `:443` target that looks like a
   TLS ClientHello, compute a split offset and send the record as multiple
   `send()` calls (with `TCP_NODELAY`, so each `send()` is its own segment).
3. Splice the two sides together bytewise for the rest of the connection.

### Split modes (`--mode`)

| Mode        | What it does                                                                 |
|-------------|------------------------------------------------------------------------------|
| `sni`       | Parses the ClientHello, finds the SNI hostname, and splits in the **middle** of it. Most effective. Falls back to `split:1` if parsing fails. **(default)** |
| `split:N`   | Splits after the first `N` bytes (e.g. `split:2`). `N` is clamped to the record length. |

Non-`:443` or non-TLS first writes are passed through untouched.

### About `disorder` (omitted, on purpose)

byedpi/SpoofDPI also offer a `disorder` mode that sends the *second* fragment
first using a deliberately low IP **TTL**, so it dies in the network before
reaching the server while still poisoning the DPI's reassembly. That trick
requires either raw sockets, per-packet TTL control, or an OS packet driver
(WinDivert / NFQUEUE) — none of which are portable, root-free userspace BSD
sockets. A userspace TCP stream is strictly ordered and reassembled by the
kernel, so "reordering" bytes at the socket layer does nothing. Rather than ship
a fake mode, **`disorder` is intentionally not implemented.**

## Build

Requires **Zig 0.16.x**.

```sh
zig build            # produces zig-out/bin/zig-bypassdpi
zig build test       # runs the unit tests
zig build run -- --port 8881 --mode sni
```

## Usage

```
zig-bypassdpi [options]

  --port <N>       Listen port           (default 8881)
  --listen <IP>    Listen address        (default 127.0.0.1)
  --mode <MODE>    Desync split strategy (default sni)
                     sni       split in the middle of the SNI hostname
                     split:N   split after the first N bytes (e.g. split:2)
  -v, --verbose    Log each connection / fragmentation
  -h, --help       Show this help
```

Start it:

```sh
zig-bypassdpi --port 8881 --mode sni
```

Then use it as a proxy.

**SOCKS5** (primary path — note `socks5h` / `--socks5-hostname` so the hostname
is resolved by the proxy, which is required for SNI-splitting to matter):

```sh
curl --socks5-hostname 127.0.0.1:8881 https://example.com
# or
curl --proxy socks5h://127.0.0.1:8881 https://example.com
```

**HTTP CONNECT:**

```sh
curl -x http://127.0.0.1:8881 https://www.google.com
```

**System / browser proxy:** point your OS or browser SOCKS5 proxy setting at
`127.0.0.1:8881`. In Firefox: *Settings → Network Settings → Manual proxy
configuration → SOCKS Host `127.0.0.1` Port `8881`, SOCKS v5*, and tick "Proxy
DNS when using SOCKS v5".

Both protocols are auto-detected on the same port by sniffing the first byte
(`0x05` ⇒ SOCKS5, otherwise HTTP CONNECT).

Stop it with `Ctrl-C`.

## Honest caveats

- **Passing the smoke test proves the proxy works and that the ClientHello is
  fragmented — it does *not* prove it defeats any particular ISP's DPI.** Real
  efficacy depends entirely on the specific DPI implementation and can only be
  confirmed on a network that actually censors you. Some DPI systems buffer and
  reassemble TCP, do out-of-order reassembly, or block on the IP/TLS layer
  instead; against those, simple ClientHello splitting may not be enough. Test on
  your own censored network and try different `--mode` / `split:N` values.
- This tool does **not** encrypt anything or hide your traffic. It only reshapes
  the ClientHello's framing. It is not a VPN and not a substitute for one where
  you need confidentiality.
- No upstream proxy chaining, no authentication, no UDP/ASSOCIATE — it is a
  focused CONNECT tunnel.

## Cross-platform notes

It is written against only the Zig standard library (`std.Io.net`,
`std.posix`, `std.Thread`) — ordinary blocking BSD sockets — so it is portable by
construction.

- **macOS (Apple Silicon):** built and fully tested here — `zig build`,
  `zig build test`, and live SOCKS5 + HTTP CONNECT smokes to `https://example.com`
  and `https://www.google.com` all pass (HTTP 200).
- **Linux / Windows:** the code is std-only and target-agnostic and *should*
  build and run from the same sources. These were **not** verified on this
  machine — treat them as expected-but-unconfirmed. The only platform-specific
  branch is `TCP_NODELAY`, which is applied on POSIX and skipped on Windows
  (`std.posix.setsockopt` is a compile error there); fragmentation still happens
  on Windows via the separate `send()` calls, just without the Nagle override.

## How it's organized

```
src/
├── main.zig     CLI parsing + Ctrl-C handling + startup
├── proxy.zig    accept loop, SOCKS5 / HTTP CONNECT handshakes, the splice (I/O)
├── desync.zig   PURE, unit-tested: TLS ClientHello / SNI parsing + split offsets
└── socks.zig    PURE, unit-tested: SOCKS5 + HTTP CONNECT request parsing
```

The desync and handshake **decisions** live in `desync.zig` / `socks.zig` as pure
functions with `test` blocks (including a real captured ClientHello fixture whose
SNI is asserted at the correct offset). `proxy.zig` routes its production writes
through those same functions, so the tested logic is the shipped logic.

## Credit / prior art

The idea and the split strategies come from these excellent projects — go read
them:

- [SpoofDPI](https://github.com/xvzc/SpoofDPI) — Go
- [byedpi](https://github.com/hufrea/byedpi) — C

`zig-bypassdpi` is an independent Zig implementation of the same userspace
ClientHello-fragmentation idea.

## License

MIT — see [LICENSE](LICENSE).
