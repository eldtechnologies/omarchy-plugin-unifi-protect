"""Recordings: sign-in, the event list, thumbnails and clip export.

A local TLS server with a throwaway certificate plays the console: the
UniFi OS sign-in and the Protect endpoints the web app uses.
"""

import argparse
import base64
import hashlib
import http.server
import io
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
from unittest import mock

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
    no_role = set()     # tokens of an account that may not see Protect
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
        if self.path == "/api/auth/logout":
            FakeConsole.valid.discard((self.headers.get("Cookie") or "").removeprefix("TOKEN="))
            return self.reply(200, b"{}")
        if self.path != "/api/auth/login":
            return self.reply(404)
        FakeConsole.logins += 1
        if body.get("username") not in ("viewer", "norole") or body.get("password") != FakeConsole.password:
            return self.reply(401, b'{"code":"AUTHENTICATION_FAILED"}')
        token = jwt(time.time() + 7200) + str(FakeConsole.logins)
        (FakeConsole.no_role if body["username"] == "norole" else FakeConsole.valid).add(token)
        self.reply(200, b"{}", [("Set-Cookie", f"TOKEN={token}; path=/; HttpOnly"),
                                ("X-Updated-CSRF-Token", "csrf-1")])

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        FakeConsole.log.append(("GET", url.path))
        if url.path == "/slow":
            # Headers, then a byte now and then: only a total deadline ends it.
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            for _ in range(40):
                try:
                    self.wfile.write(b"x")
                    self.wfile.flush()
                except OSError:
                    return
                time.sleep(0.1)
            return
        if url.path == "/short":
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b"x" * 500)
            self.close_connection = True
            return
        token = (self.headers.get("Cookie") or "").removeprefix("TOKEN=")
        if token in FakeConsole.no_role:
            return self.reply(403)
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
        FakeConsole.no_role.clear()
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

    def test_wrong_password_is_tried_once_and_asks_again(self):
        FakeConsole.password = "changed"
        result = h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertTrue(result["needsLogin"])
        self.assertIn("rejected the username or password", result["loginError"])
        # Other helper processes don't try again either, for a while.
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        with self.assertRaises(h.LoginRejected):
            h.fetch_clip(self.config, f"nvr_{CAMERA}", time.time() - 60, time.time() - 50, "low")
        self.assertEqual(FakeConsole.logins, 1)
        # Signing in again (the `login` command) clears it.
        FakeConsole.password = "right"
        h.save_config(self.config)
        with mock.patch.object(h.sys, "stdin", io.StringIO("viewer\nright\n")), \
                mock.patch.object(h, "poll_cameras"), mock.patch.object(h, "store_login", return_value="file"), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_login(argparse.Namespace(console="nvr", stdin=True, json=True))
        self.assertEqual(len(h.recordings_for(self.config, f"nvr_{CAMERA}")["events"]), 2)
        os.remove(h.CONFIG_PATH)

    def test_a_failed_sign_in_is_never_retried_by_other_requests(self):
        FakeConsole.password = "changed"
        session = h.ProtectSession(self.console, self.config)
        for _ in range(3):
            with self.assertRaises(h.ProtectError):
                session.thumbnail("ev1")
        self.assertEqual(FakeConsole.logins, 1)

    def test_logout_ends_the_session_on_the_console(self):
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertEqual(len(FakeConsole.valid), 1)
        h.save_config(self.config)
        with mock.patch.object(h, "poll_cameras"), mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_logout(argparse.Namespace(console="nvr"))
        self.assertIn(("POST", "/api/auth/logout"), FakeConsole.log)
        self.assertEqual(FakeConsole.valid, set())
        self.assertNotIn("nvr", h.load_sessions())
        os.remove(h.CONFIG_PATH)

    def test_a_mistyped_new_login_keeps_the_saved_logins_failure(self):
        FakeConsole.password = "changed"
        h.recordings_for(self.config, f"nvr_{CAMERA}")       # saved login rejected: 1
        h.save_config(self.config)
        with mock.patch.object(h.sys, "stdin", io.StringIO("viewer\ntypo\n")):
            with self.assertRaises(h.LoginRejected):
                h.cmd_login(argparse.Namespace(console="nvr", stdin=True, json=True))   # 2
        # The saved (rejected) login is still not retried behind the user's back.
        result = h.recordings_for(h.load_config(), f"nvr_{CAMERA}")
        self.assertTrue(result["needsLogin"])
        self.assertEqual(FakeConsole.logins, 2)
        os.remove(h.CONFIG_PATH)

    def test_a_failure_from_the_future_does_not_block(self):
        h.write_json(h.SESSIONS_PATH, {"nvr": {"failed": time.time() + 3600, "error": "x", "rejected": False}})
        self.assertEqual(len(h.recordings_for(self.config, f"nvr_{CAMERA}")["events"]), 2)

    def test_reads_are_bounded_in_time_and_must_be_whole(self):
        session = h.ProtectSession(self.console, self.config)
        started = time.monotonic()
        conn, response = session._send("GET", "/slow", deadline=1)
        with self.assertRaises(h.ProtectError):
            h.read_body(response, 1 << 20)
        conn.finish()
        self.assertLess(time.monotonic() - started, 3)
        conn, response = session._send("GET", "/short")
        with self.assertRaisesRegex(h.ProtectError, "partway|mid-answer"):
            h.read_body(response, 1 << 20)
        conn.finish()

    def test_clip_output_is_private_and_never_follows_a_link(self):
        start = time.time() - 60
        h.save_config(self.config)
        target = os.path.join(tempfile.mkdtemp(), "door.mp4")
        args = argparse.Namespace(camera=f"nvr_{CAMERA}", start=start, end=start + 12, quality="low",
                                  output=target, play=False, title=None, sound="on", json=False)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_clip(args)
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o600)
        victim = target + ".victim"
        open(victim, "w").close()
        link = target + ".link"
        os.symlink(victim, link)
        args.output = link
        with self.assertRaises(h.ProtectError), mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_clip(args)
        self.assertEqual(os.path.getsize(victim), 0)
        os.remove(h.CONFIG_PATH)

    def test_no_login_asks_for_one(self):
        del self.console["loginUser"]
        result = h.recordings_for(self.config, f"nvr_{CAMERA}")
        self.assertTrue(result["needsLogin"])
        self.assertEqual(FakeConsole.log, [])

    def test_a_rejected_login_keeps_the_working_one(self):
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        session_before = h.load_sessions()["nvr"]
        h.save_config(self.config)
        args = argparse.Namespace(console="nvr", stdin=True, json=True)
        with mock.patch.object(h.sys, "stdin", io.StringIO("norole\nright\n")):
            with self.assertRaisesRegex(h.ProtectError, "may not view recordings"):
                h.cmd_login(args)
        # The working account keeps its session: no new sign-in needed.
        self.assertEqual(h.load_sessions()["nvr"], session_before)
        config = h.load_config()
        self.assertEqual(config["consoles"][0]["loginUser"], "viewer")
        self.assertEqual(len(h.recordings_for(config, f"nvr_{CAMERA}")["events"]), 2)
        os.remove(h.CONFIG_PATH)

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

    def test_clip_times_can_come_from_the_environment(self):
        # The panel keeps event times off the command line.
        start = time.time() - 60
        h.save_config(self.config)
        args = argparse.Namespace(camera=f"nvr_{CAMERA}", start=None, end=None, quality="low",
                                  output=None, play=False, title=None, sound="on", json=True)
        event = json.dumps({"start": start, "end": start + 12})
        with mock.patch.dict(os.environ, {"ELD_UNIFI_PROTECT_EVENT": event}), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            h.cmd_clip(args)
        self.assertEqual(json.loads(out.getvalue())["start"], start - h.CLIP_PAD)
        self.assertEqual(int(self.server.last_export["start"][0]), int((start - h.CLIP_PAD) * 1000))
        args.start = None
        with mock.patch.dict(os.environ, {"ELD_UNIFI_PROTECT_EVENT": "nonsense"}):
            with self.assertRaisesRegex(h.ProtectError, "--start"):
                h.cmd_clip(args)
        os.remove(h.CONFIG_PATH)

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

    def test_a_slow_desktop_clock_does_not_cut_the_clip(self):
        # The console says the event ran 1020-1025; this machine thinks it is 1000.
        self.assertEqual(h.clip_window(1020, 1025, now=1000), (1020 - h.CLIP_PAD, 1025 + h.CLIP_PAD))
        start, end = h.clip_window(1020, None, now=1000)
        self.assertGreater(end, start)

    def test_stale_partial_downloads_are_pruned(self):
        os.makedirs(h.CLIPS_DIR, exist_ok=True)
        old, fresh = (os.path.join(h.CLIPS_DIR, f"{n}.mp4.1.part") for n in ("old", "fresh"))
        for path in (old, fresh):
            with open(path, "wb") as handle:
                handle.write(b"x")
        os.utime(old, (1000, 1000))
        h.prune_clips()
        self.assertEqual(os.listdir(h.CLIPS_DIR), ["fresh.mp4.1.part"])
        shutil.rmtree(h.CLIPS_DIR)

    def test_a_locked_keyring_is_a_clean_error(self):
        console = {"id": "locked", "loginStore": "keyring", "loginUser": "viewer"}
        with mock.patch.object(h, "_secret_tool", side_effect=h.KeyringUnavailable("locked")):
            with self.assertRaisesRegex(h.ProtectError, "keyring"):
                h.login_password(console)

    def test_event_kinds(self):
        self.assertEqual(h.event_kind({"type": "smartDetectLine", "smartDetectTypes": ["animal"]}), "animal")
        self.assertEqual(h.event_kind({"type": "smartDetectZone", "smartDetectTypes": []}), "motion")
        self.assertEqual(h.event_kind({"type": "ring"}), "ring")

    def test_session_expiry_comes_from_the_token(self):
        self.assertEqual(h.token_expiry(jwt(1234567890)), 1234567890)
        # With iat, the lifetime counts from this machine's clock.
        claims = base64.urlsafe_b64encode(json.dumps({"iat": 1000, "exp": 8200}).encode()).decode().rstrip("=")
        self.assertAlmostEqual(h.token_expiry(f"e30.{claims}.sig"), time.time() + 7200, delta=5)
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
