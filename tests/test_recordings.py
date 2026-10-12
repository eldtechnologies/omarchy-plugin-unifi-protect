"""Recordings: sign-in, the event list, thumbnails and clip export.

A local TLS server with a throwaway certificate plays the console: the
UniFi OS sign-in and the Protect endpoints the web app uses.
"""

import base64
import hashlib
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

from helpers import helper as h

JPEG = b"\xff\xd8" + b"thumb" + b"\xff\xd9"
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 4000
CAMERA = "cam1"


def jwt(expires):
    claims = base64.urlsafe_b64encode(json.dumps({"exp": expires}).encode()).decode().rstrip("=")
    return f"e30.{claims}.sig"


class FakeConsole(http.server.BaseHTTPRequestHandler):
    server_version = "fake"
    log = []            # (method, path) of every request
    logins = 0
    valid = set()       # session tokens the console accepts
    password = "right"

    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        FakeConsole.log.append(("POST", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/api/auth/login":
            return self.reply(404)
        FakeConsole.logins += 1
        if body.get("username") != "viewer" or body.get("password") != FakeConsole.password:
            return self.reply(401, b'{"code":"AUTHENTICATION_FAILED"}')
        token = jwt(time.time() + 7200) + str(FakeConsole.logins)
        FakeConsole.valid.add(token)
        self.reply(200, b"{}", [("Set-Cookie", f"TOKEN={token}; path=/; HttpOnly"),
                                ("X-Updated-CSRF-Token", "csrf-1")])

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        FakeConsole.log.append(("GET", url.path))
        token = (self.headers.get("Cookie") or "").removeprefix("TOKEN=")
        if token not in FakeConsole.valid:
            return self.reply(401)
        if url.path == "/proxy/protect/api/events":
            self.server.last_query = query
            now = int(time.time() * 1000)
            events = [
                {"id": "ev1", "type": "smartDetectZone", "camera": CAMERA, "start": now - 60000,
                 "end": now - 48000, "smartDetectTypes": ["vehicle"], "score": 91},
                {"id": "ev2", "type": "ring", "camera": CAMERA, "start": now - 3600000, "end": now - 3595000},
                {"id": "other", "type": "ring", "camera": "cam2", "start": now - 5000, "end": now},
                {"id": "../etc", "type": "ring", "camera": CAMERA, "start": now - 5000, "end": now},
            ]
            return self.reply(200, json.dumps(events).encode())
        if url.path.endswith("/thumbnail"):
            return self.reply(200, JPEG, [("Content-Type", "image/jpeg")])
        if url.path == "/proxy/protect/api/video/export":
            self.server.last_export = query
            if query.get("camera") == ["empty"]:
                return self.reply(200, b'{"error":"no recording"}')
            return self.reply(200, MP4, [("Content-Type", "video/mp4")])
        self.reply(404)


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class RecordingsAgainstFakeConsole(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cert, key = os.path.join(cls.tmp, "c.pem"), os.path.join(cls.tmp, "k.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key, "-out", cert,
                        "-days", "1", "-subj", "/CN=fake-console"], check=True, capture_output=True)
        with open(cert) as handle:
            cls.pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(handle.read())).hexdigest()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeConsole)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        FakeConsole.log.clear()
        FakeConsole.logins = 0
        FakeConsole.valid.clear()
        FakeConsole.password = "right"
        for path in (h.SESSIONS_PATH,):
            if os.path.exists(path):
                os.remove(path)
        shutil.rmtree(h.CLIPS_DIR, ignore_errors=True)
        self.console = {"id": "nvr", "name": "NVR", "host": f"127.0.0.1:{self.server.server_port}",
                        "certSha256": self.pin, "apiKey": "k", "loginUser": "viewer", "loginPassword": "right"}
        self.config = {"consoles": [self.console]}

    def test_events_are_filtered_and_classified(self):
        result = h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertEqual([(e["id"], e["kind"]) for e in result["events"]], [("ev1", "vehicle"), ("ev2", "ring")])
        self.assertEqual(self.server.last_query["cameras"], [CAMERA])
        self.assertNotIn("motion", self.server.last_query["types"])
        # Thumbnails are on disk, named by event id, private.
        thumb = result["events"][0]["thumb"]
        self.assertEqual(os.path.basename(thumb), "ev1.jpg")
        with open(thumb, "rb") as handle:
            self.assertEqual(handle.read(), JPEG)

    def test_one_sign_in_is_reused(self):
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertEqual(FakeConsole.logins, 1)
        self.assertEqual(h.load_sessions()["nvr"]["csrf"], "csrf-1")

    def test_expired_session_signs_in_once_more(self):
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        FakeConsole.valid.clear()          # the console forgot the session
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertEqual(FakeConsole.logins, 2)

    def test_wrong_password_is_tried_once(self):
        FakeConsole.password = "changed"
        with self.assertRaisesRegex(h.ProtectError, "rejected the username or password"):
            h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertEqual(FakeConsole.logins, 1)

    def test_no_login_asks_for_one(self):
        del self.console["loginUser"]
        result = h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertTrue(result["needsLogin"])
        self.assertEqual(FakeConsole.log, [])

    def test_clip_export_and_cache(self):
        start = time.time() - 60
        clip = h.fetch_clip(self.config, f"nvr_{CAMERA}", start, start + 12, "medium")
        query = self.server.last_export
        self.assertEqual(query["channel"], ["1"])
        self.assertEqual(int(query["start"][0]), int((start - h.CLIP_PAD) * 1000))
        with open(clip["path"], "rb") as handle:
            self.assertEqual(handle.read(), MP4)
        self.assertEqual(os.stat(clip["path"]).st_mode & 0o777, 0o600)
        exports = sum(1 for _, p in FakeConsole.log if p.endswith("/export"))
        h.fetch_clip(self.config, f"nvr_{CAMERA}", start, start + 12, "medium")
        self.assertEqual(sum(1 for _, p in FakeConsole.log if p.endswith("/export")), exports)

    def test_an_error_page_is_not_saved_as_a_clip(self):
        start = time.time() - 60
        with self.assertRaisesRegex(h.ProtectError, "no video"):
            h.fetch_clip(self.config, "nvr_empty", start, start + 5, "low")
        self.assertEqual([n for n in os.listdir(h.CLIPS_DIR)], [])


class ClipRules(unittest.TestCase):
    def test_window_pads_and_caps(self):
        self.assertEqual(h.clip_window(1000, 1010, now=5000), (1000 - h.CLIP_PAD, 1010 + h.CLIP_PAD))
        start, end = h.clip_window(1000, 9000, now=99999)
        self.assertEqual(end - start, h.CLIP_MAX_SECONDS + 2 * h.CLIP_PAD)

    def test_ongoing_event_takes_what_exists_so_far(self):
        self.assertEqual(h.clip_window(1000, None, now=1020), (1000 - h.CLIP_PAD, 1020))

    def test_event_kinds(self):
        self.assertEqual(h.event_kind({"type": "smartDetectLine", "smartDetectTypes": ["animal"]}), "animal")
        self.assertEqual(h.event_kind({"type": "smartDetectZone", "smartDetectTypes": []}), "motion")
        self.assertEqual(h.event_kind({"type": "ring"}), "ring")

    def test_session_expiry_comes_from_the_token(self):
        self.assertEqual(h.token_expiry(jwt(1234567890)), 1234567890)
        self.assertGreater(h.token_expiry("not-a-jwt"), time.time())

    def test_pruning_keeps_the_newest(self):
        os.makedirs(h.CLIPS_DIR, exist_ok=True)
        for i in range(h.CLIPS_KEEP + 3):
            path = os.path.join(h.CLIPS_DIR, f"{i:03}.mp4")
            with open(path, "wb") as handle:
                handle.write(b"x")
            os.utime(path, (1000 + i, 1000 + i))
        h.prune_clips()
        left = sorted(os.listdir(h.CLIPS_DIR))
        self.assertEqual(len(left), h.CLIPS_KEEP)
        self.assertEqual(left[0], "003.mp4")
        shutil.rmtree(h.CLIPS_DIR)


if __name__ == "__main__":
    unittest.main()
