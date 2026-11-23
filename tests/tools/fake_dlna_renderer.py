#!/usr/bin/env python3
"""Fake DLNA / UPnP AV media renderer for the native casting tests. LOOPBACK ONLY.

Answers an SSDP M-SEARCH on a unicast UDP port, serves a device description
(chunked, with a relative AVTransport controlURL) and handles the AVTransport
SOAP actions SetAVTransportURI, Play, Pause, Stop, Seek, GetTransportInfo and
GetPositionInfo. Binds and answers 127.0.0.1 only.

    fake_dlna_renderer.py --log LOG

Prints {"ssdp_port": N, "http_port": M} once listening. Every SOAP action is
appended to LOG as one JSON object per line.
"""
import argparse
import html
import json
import re
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AVT = "urn:schemas-upnp-org:service:AVTransport:1"

DESCRIPTION = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
 <specVersion><major>1</major><minor>0</minor></specVersion>
 <device>
  <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
  <friendlyName>Fake Bedroom TV &amp; Soundbar</friendlyName>
  <UDN>uuid:fake-renderer-0001</UDN>
  <serviceList>
   <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/RC</controlURL></service>
   <service>
    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
    <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
    <controlURL>control/AVTransport1</controlURL>
    <eventSubURL>/upnp/event/AVTransport1</eventSubURL>
   </service>
  </serviceList>
 </device>
</root>
"""


def hms(secs):
    secs = int(secs)
    return "%d:%02d:%02d" % (secs // 3600, secs % 3600 // 60, secs % 60)


def parse_hms(text):
    h, m, s = text.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


class State:
    lock = threading.Lock()
    uri = ""
    meta = ""
    transport = "NO_MEDIA_PRESENT"
    position = 0.0
    log = None


def envelope(action, body):
    return ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            '<u:%sResponse xmlns:u="%s">%s</u:%sResponse></s:Body></s:Envelope>' % (action, AVT, body, action))


def fault(code, desc):
    return ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>'
            '<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>'
            '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>%d</errorCode>'
            '<errorDescription>%s</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>' % (code, desc))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path != "/dev/desc.xml":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = DESCRIPTION.encode()
        self.send_response(200)
        self.send_header("Content-Type", 'text/xml; charset="utf-8"')
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        half = len(body) // 2
        for part in (body[:half], body[half:]):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
        self.wfile.write(b"0\r\n\r\n")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        xml = self.rfile.read(n).decode()
        soap_action = self.headers.get("SOAPACTION", "").strip('"')
        action = soap_action.split("#")[-1]
        args = {k: html.unescape(v) for k, v in re.findall(r"<(\w+)>(.*?)</\1>", xml, re.S) if k not in ("s:Body",)}
        if self.path != "/dev/control/AVTransport1" or not soap_action.startswith(AVT + "#"):
            return self.reply(500, fault(401, "Invalid Action"))
        with State.lock:
            State.log.write(json.dumps({"action": action, "args": args, "content_type": self.headers.get("Content-Type", "")}) + "\n")
            State.log.flush()
            if action == "SetAVTransportURI":
                State.uri, State.meta = args.get("CurrentURI", ""), args.get("CurrentURIMetaData", "")
                State.transport, State.position = "STOPPED", 0.0
                return self.reply(200, envelope(action, ""))
            if action == "Play":
                if not State.uri:
                    return self.reply(500, fault(701, "Transition not available"))
                State.transport = "PLAYING"
                return self.reply(200, envelope(action, ""))
            if action == "Pause":
                if State.transport != "PLAYING":
                    return self.reply(500, fault(701, "Transition not available"))
                State.transport = "PAUSED_PLAYBACK"
                return self.reply(200, envelope(action, ""))
            if action == "Stop":
                State.transport, State.position = "STOPPED", 0.0
                return self.reply(200, envelope(action, ""))
            if action == "Seek":
                if args.get("Unit") != "REL_TIME":
                    return self.reply(500, fault(710, "Seek mode not supported"))
                State.position = parse_hms(args.get("Target", "0:00:00"))
                return self.reply(200, envelope(action, ""))
            if action == "GetTransportInfo":
                return self.reply(200, envelope(action, "<CurrentTransportState>%s</CurrentTransportState>"
                                                "<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>" % State.transport))
            if action == "GetPositionInfo":
                return self.reply(200, envelope(action, "<Track>1</Track><TrackDuration>1:30:00</TrackDuration>"
                                                "<TrackURI>%s</TrackURI><RelTime>%s</RelTime>" % (html.escape(State.uri), hms(State.position))))
        return self.reply(500, fault(401, "Invalid Action"))

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", 'text/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    State.log = open(a.log, "a")
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    http_port = httpd.server_address[1]
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))

    def ssdp_loop():
        while True:
            data, peer = udp.recvfrom(2048)
            text = data.decode(errors="replace")
            with State.lock:
                State.log.write(json.dumps({"ssdp": text}) + "\n")
                State.log.flush()
            if text.startswith("M-SEARCH * HTTP/1.1") and 'MAN: "ssdp:discover"' in text:
                resp = ("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n"
                        "LOCATION: http://127.0.0.1:%d/dev/desc.xml\r\nSERVER: Fake/1 UPnP/1.0 Fake/1\r\n"
                        "ST: %s\r\nUSN: uuid:fake-renderer-0001::%s\r\n\r\n" % (http_port, AVT, AVT))
                udp.sendto(resp.encode(), peer)

    threading.Thread(target=ssdp_loop, daemon=True).start()
    print(json.dumps({"ssdp_port": udp.getsockname()[1], "http_port": http_port}), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
