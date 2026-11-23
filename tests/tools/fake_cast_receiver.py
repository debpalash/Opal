#!/usr/bin/env python3
"""Fake Chromecast for the native casting integration tests. LOOPBACK ONLY.

Speaks the Cast v2 wire protocol (TLS, u32 length + protobuf CastMessage,
JSON payloads) the way a Default Media Receiver does, and answers an mDNS
PTR query for _googlecast._tcp.local on a unicast UDP port. It never binds
or sends to anything but 127.0.0.1, so tests cannot touch a real device.

    fake_cast_receiver.py --cert C --key K --log LOG [--fail-load]

Prints {"tls_port": N, "mdns_port": M} on stdout once listening. Every frame
received is appended to LOG as one JSON object per line.
"""
import argparse
import json
import socket
import ssl
import struct
import sys
import threading

NS_CONN = "urn:x-cast:com.google.cast.tp.connection"
NS_HEART = "urn:x-cast:com.google.cast.tp.heartbeat"
NS_RECV = "urn:x-cast:com.google.cast.receiver"
NS_MEDIA = "urn:x-cast:com.google.cast.media"
DMR = "CC1AD845"
TRANSPORT = "web-7"


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def encode(source, dest, ns, payload):
    def s(field, val):
        b = val.encode()
        return varint((field << 3) | 2) + varint(len(b)) + b

    body = varint(1 << 3) + varint(0) + s(2, source) + s(3, dest) + s(4, ns) + varint(5 << 3) + varint(0) + s(6, payload)
    return struct.pack(">I", len(body)) + body


def decode(body):
    i, out = 0, {}
    while i < len(body):
        key, shift = 0, 0
        while True:
            b = body[i]; i += 1
            key |= (b & 0x7F) << shift; shift += 7
            if not b & 0x80:
                break
        field, wt = key >> 3, key & 7
        if wt == 0:
            while body[i] & 0x80:
                i += 1
            i += 1
        elif wt == 2:
            ln, shift = 0, 0
            while True:
                b = body[i]; i += 1
                ln |= (b & 0x7F) << shift; shift += 7
                if not b & 0x80:
                    break
            out[field] = body[i:i + ln].decode()
            i += ln
        else:
            raise ValueError("wire type %d" % wt)
    return out.get(2, ""), out.get(3, ""), out.get(4, ""), out.get(6, "")


class Receiver:
    def __init__(self, log_path, fail_load):
        self.lock = threading.Lock()
        self.log = open(log_path, "a", buffering=1)
        self.fail_load = fail_load
        self.app = False
        self.media = None  # dict(state, time, url, duration, id)

    def record(self, entry):
        with self.lock:
            self.log.write(json.dumps(entry) + "\n")

    def receiver_status(self, req):
        apps = [{"appId": DMR, "displayName": "Default Media Receiver", "sessionId": "sess-1", "transportId": TRANSPORT}] if self.app else []
        return json.dumps({"type": "RECEIVER_STATUS", "requestId": req, "status": {"applications": apps, "volume": {"level": 1.0, "muted": False}}})

    def media_status(self, req):
        st = []
        if self.media:
            st = [{"mediaSessionId": self.media["id"], "playerState": self.media["state"], "currentTime": self.media["time"],
                   "media": {"contentId": self.media["url"], "duration": self.media["duration"]}}]
        return json.dumps({"type": "MEDIA_STATUS", "requestId": req, "status": st})

    def handle(self, conn):
        def send(src, dst, ns, payload):
            conn.sendall(encode(src, dst, ns, payload))

        pinged = False
        try:
            while True:
                hdr = conn.recv(4)
                if len(hdr) < 4:
                    return
                (ln,) = struct.unpack(">I", hdr)
                body = b""
                while len(body) < ln:
                    chunk = conn.recv(ln - len(body))
                    if not chunk:
                        return
                    body += chunk
                src, dst, ns, payload = decode(body)
                msg = json.loads(payload) if payload else {}
                self.record({"src": src, "dst": dst, "ns": ns, "msg": msg})
                if not pinged:
                    # Real receivers ping; a sender must answer PONG.
                    pinged = True
                    send("receiver-0", src, NS_HEART, json.dumps({"type": "PING"}))
                t, req = msg.get("type"), msg.get("requestId", 0)
                if ns == NS_RECV and t == "GET_STATUS":
                    send("receiver-0", src, NS_RECV, self.receiver_status(req))
                elif ns == NS_RECV and t == "LAUNCH":
                    if msg.get("appId") != DMR:
                        send("receiver-0", src, NS_RECV, json.dumps({"type": "LAUNCH_ERROR", "requestId": req}))
                        continue
                    self.app = True
                    self.media = None
                    # Real receivers answer a LAUNCH first with an interim status.
                    send("receiver-0", src, NS_RECV, json.dumps({"type": "RECEIVER_STATUS", "requestId": 0, "status": {"applications": []}}))
                    send("receiver-0", src, NS_RECV, self.receiver_status(req))
                elif ns == NS_MEDIA and dst == TRANSPORT:
                    if t == "LOAD":
                        if self.fail_load:
                            send(TRANSPORT, src, NS_MEDIA, json.dumps({"type": "LOAD_FAILED", "requestId": req}))
                            continue
                        m = msg.get("media", {})
                        self.media = {"id": 1, "state": "BUFFERING", "time": float(msg.get("currentTime", 0)),
                                      "url": m.get("contentId", ""), "duration": 5400.0}
                        send(TRANSPORT, src, NS_MEDIA, self.media_status(0))
                        self.media["state"] = "PLAYING"
                        send(TRANSPORT, src, NS_MEDIA, self.media_status(req))
                    elif t == "GET_STATUS":
                        send(TRANSPORT, src, NS_MEDIA, self.media_status(req))
                    elif t in ("PLAY", "PAUSE", "SEEK", "STOP"):
                        if not self.media or msg.get("mediaSessionId") != self.media["id"]:
                            send(TRANSPORT, src, NS_MEDIA, json.dumps({"type": "INVALID_REQUEST", "requestId": req, "reason": "INVALID_MEDIA_SESSION_ID"}))
                            continue
                        if t == "PLAY":
                            self.media["state"] = "PLAYING"
                        elif t == "PAUSE":
                            self.media["state"] = "PAUSED"
                        elif t == "SEEK":
                            self.media["time"] = float(msg.get("currentTime", 0))
                        else:
                            self.media["state"] = "IDLE"
                        status = self.media_status(req)
                        if t == "STOP":
                            self.media = None
                        send(TRANSPORT, src, NS_MEDIA, status)
        except (OSError, ssl.SSLError, ValueError):
            return
        finally:
            conn.close()


def mdns_answer(query, tls_port):
    def name(n):
        return b"".join(bytes([len(l)]) + l.encode() for l in n.split(".")) + b"\x00"

    def rec(owner, rtype, rdata):
        return owner + struct.pack(">HHIH", rtype, 0x8001, 120, len(rdata)) + rdata

    svc = name("_googlecast._tcp.local")
    inst = name("Chromecast-fake01._googlecast._tcp.local")
    host = name("fake01.local")
    txt = b"".join(bytes([len(e)]) + e for e in (b"id=fake01", b"fn=Fake Living Room", b"md=Chromecast"))
    answers = [
        rec(svc, 12, inst),
        rec(inst, 33, struct.pack(">HHH", 0, 0, tls_port) + host),
        rec(inst, 16, txt),
        rec(host, 1, socket.inet_aton("127.0.0.1")),
    ]
    header = query[:2] + struct.pack(">HHHHH", 0x8400, 0, 1, 0, 3)
    return header + b"".join(answers)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--fail-load", action="store_true")
    a = ap.parse_args()

    recv = Receiver(a.log, a.fail_load)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    tls_port = srv.getsockname()[1]

    def mdns_loop():
        while True:
            data, peer = udp.recvfrom(2048)
            recv.record({"mdns_query": data.hex()})
            if b"\x0b_googlecast\x04_tcp\x05local\x00\x00\x0c" in data:
                udp.sendto(mdns_answer(data, tls_port), peer)

    threading.Thread(target=mdns_loop, daemon=True).start()
    print(json.dumps({"tls_port": tls_port, "mdns_port": udp.getsockname()[1]}), flush=True)
    while True:
        raw, _ = srv.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            recv.record({"tls_error": str(e)})
            raw.close()
            continue
        threading.Thread(target=recv.handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
