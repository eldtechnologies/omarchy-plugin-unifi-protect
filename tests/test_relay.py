"""End-to-end test of the stream relay against a fake console.

A local TLS server with a throwaway self-signed certificate plays the
console's RTSPS endpoint. The relay sits between it and a plain-socket
client, exactly as it does between a player and a real console.
"""

import hashlib
import os
import sys
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import traceback
import unittest

from helpers import helper as h

FRAMES = [b"$\x00\x00\x04" + b"abcd", b"$\x01\x00\x02" + b"zz", b"$\x00\x00\x03" + b"xyz"]


class FakeConsole:
    """Answers OPTIONS, DESCRIBE, SETUP and PLAY like Protect, then streams."""

    def __init__(self, cert, key):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.server = socket.create_server(("127.0.0.1", 0))
        self.port = self.server.getsockname()[1]
        self.requests = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            conn, _ = self.server.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        try:
            tls = self.context.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            return
        try:
            self.converse(tls)
        except OSError:
            pass  # the client hung up; that ends the test session
        finally:
            tls.close()

    def converse(self, tls):
        reader = tls.makefile("rb")
        base = f"rtsps://127.0.0.1:{self.port}/AbC"
        while True:
            message = h.read_rtsp(reader)
            if message is None:
                return
            _, start, headers, _ = message
            self.requests.append(start)
            method = start.split(" ")[0]
            cseq = h.header_value(headers, "cseq")
            reply = [f"CSeq: {cseq}"]
            body = b""
            if method == "DESCRIBE":
                reply.append(f"Content-Base: {base}/")
                body = f"v=0\r\nm=video 0 RTP/AVP 96\r\na=control:{base}/trackID=0\r\n".encode()
            elif method == "SETUP":
                reply += [f"Transport: {h.header_value(headers, 'transport')}", "Session: 42"]
            tls.sendall(h.encode_rtsp("RTSP/1.0 200 OK", [tuple(r.split(": ", 1)) for r in reply], body))
            if method == "PLAY":
                tls.sendall(b"".join(FRAMES))


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class RelayEndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cert, key = os.path.join(cls.tmp, "c.pem"), os.path.join(cls.tmp, "k.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key,
                        "-out", cert, "-days", "1", "-subj", "/CN=fake-console"],
                       check=True, capture_output=True)
        with open(cert) as handle:
            der = ssl.PEM_cert_to_DER_cert(handle.read())
        cls.pin = hashlib.sha256(der).hexdigest()
        cls.console = FakeConsole(cert, key)
        h.STREAM_PORT = cls.console.port      # the relay dials this "console"
        h.RELAY_IDLE_EXIT = 3600              # never exit mid-test
        config = {"consoles": [
            {"id": "nvr", "name": "NVR", "host": "127.0.0.1", "certSha256": cls.pin},
            {"id": "evil", "name": "Impostor", "host": "127.0.0.1", "certSha256": "0" * 64},
        ]}
        cls.relay = h.Relay(config)
        # Loopback URLs name a route, never Protect's alias.
        cls.routes = {c: h.register_relay_route(c, "/AbC") for c in ("nvr", "evil")}
        threading.Thread(target=cls.relay.serve, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def connect(self):
        sock = socket.create_connection(("127.0.0.1", self.relay.port), timeout=5)
        self.addCleanup(sock.close)
        return sock, sock.makefile("rb")

    def url(self, console="nvr", token=None):
        return (f"rtsp://127.0.0.1:{self.relay.port}/{token or self.relay.token}/{console}/"
                f"{self.routes[console]}")

    def request(self, sock, reader, method, url, cseq, extra=()):
        headers = [("CSeq", str(cseq)), *extra]
        sock.sendall(h.encode_rtsp(f"{method} {url} RTSP/1.0", headers, b""))
        try:
            return h.read_rtsp(reader)
        except TimeoutError:
            # Show where the relay and the fake console are stuck.
            names = {t.ident: t.name for t in threading.enumerate()}
            for ident, frame in sys._current_frames().items():
                print(f"--- thread {names.get(ident, ident)}", file=sys.stderr)
                traceback.print_stack(frame, file=sys.stderr)
            raise

    def test_full_session_is_tunnelled_and_rewritten(self):
        sock, reader = self.connect()
        url = self.url()
        _, start, _, _ = self.request(sock, reader, "OPTIONS", url, 1)
        self.assertEqual(start, "RTSP/1.0 200 OK")

        _, _, headers, body = self.request(sock, reader, "DESCRIBE", url, 2)
        # The player never learns the alias...
        self.assertNotIn("AbC", body.decode() + str(headers))
        # Console URLs in the response point back at the relay...
        self.assertEqual(h.header_value(headers, "content-base"), url + "/")
        self.assertIn(f"a=control:{url}/trackID=0", body.decode())

        # ...UDP is refused locally, never reaching the console...
        _, start, _, _ = self.request(sock, reader, "SETUP", url + "/trackID=0", 3,
                                      [("Transport", "RTP/AVP;unicast;client_port=5000-5001")])
        self.assertTrue(start.startswith("RTSP/1.0 461"), start)

        # ...TCP goes through...
        _, start, _, _ = self.request(sock, reader, "SETUP", url + "/trackID=0", 4,
                                      [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")])
        self.assertEqual(start, "RTSP/1.0 200 OK")
        _, start, _, _ = self.request(sock, reader, "PLAY", url + "/", 5, [("Session", "42")])
        self.assertEqual(start, "RTSP/1.0 200 OK")

        # ...and media arrives byte for byte.
        received = [h.read_rtsp(reader) for _ in FRAMES]
        self.assertEqual(received, [("frame", f) for f in FRAMES])

        # The console only ever saw RTSPS URLs, and no UDP SETUP.
        upstream = [r for r in self.console.requests if "/AbC" in r]
        self.assertTrue(all(f"rtsps://127.0.0.1:{self.console.port}/AbC" in r for r in upstream))
        self.assertEqual(sum(r.startswith("SETUP") for r in self.console.requests), 1)
        self.assertNotIn(self.relay.token, " ".join(self.console.requests))

    def test_unknown_or_foreign_routes_are_refused(self):
        for url in (f"rtsp://127.0.0.1:{self.relay.port}/{self.relay.token}/nvr/AbC",
                    f"rtsp://127.0.0.1:{self.relay.port}/{self.relay.token}/nvr/{self.routes['evil']}"):
            sock, reader = self.connect()
            _, start, _, _ = self.request(sock, reader, "OPTIONS", url, 1)
            self.assertTrue(start.startswith("RTSP/1.0 404"), (url, start))

    def test_idle_connections_cannot_lock_players_out(self):
        hogs = [self.connect() for _ in range(h.RELAY_MAX_PENDING + 2)]
        sock, reader = self.connect()
        _, start, _, _ = self.request(sock, reader, "OPTIONS", self.url(), 1)
        self.assertEqual(start, "RTSP/1.0 200 OK")
        self.assertTrue(hogs)

    def test_oversized_or_silent_clients_are_dropped_before_the_token(self):
        # A huge Content-Length is refused without buffering the body.
        sock, reader = self.connect()
        sock.sendall(b"OPTIONS x RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 2000000000\r\n\r\n")
        self.assertIsNone(h.read_rtsp(reader))
        # So are endless headers.
        sock, reader = self.connect()
        sock.sendall(b"OPTIONS x RTSP/1.0\r\n" + b"X: y\r\n" * (h.RTSP_MAX_HEADERS + 1) + b"\r\n")
        self.assertIsNone(h.read_rtsp(reader))
        # And media frames before any authenticated request.
        sock, reader = self.connect()
        sock.sendall(b"$\x00\x00\x04abcd")
        self.assertIsNone(h.read_rtsp(reader))

    def test_wrong_token_is_refused(self):
        sock, reader = self.connect()
        _, start, _, _ = self.request(sock, reader, "OPTIONS", self.url(token="nope"), 1)
        self.assertTrue(start.startswith("RTSP/1.0 404"), start)

    def test_console_with_a_different_certificate_is_refused(self):
        sock, reader = self.connect()
        _, start, _, _ = self.request(sock, reader, "OPTIONS", self.url(console="evil"), 1)
        self.assertTrue(start.startswith("RTSP/1.0 502"), start)


if __name__ == "__main__":
    unittest.main()
