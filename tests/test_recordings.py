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
        if url.path == "/proxy/protect/api/cameras":
            oldest = int((time.time() - 86400 * 30) * 1000)
            cameras = [
                {"id": CAMERA, "recordingSettings": {"mode": "always"},
                 "stats": {"video": {"recordingStart": oldest}}},
                {"id": "cam2", "recordingSettings": {"mode": "detections"}, "stats": {"video": {}}},
                {"id": "cam3", "recordingSettings": {"mode": "never"}},
                {"id": "cam4", "recordingSettings": {"mode": "schedule"}},
                {"id": "cam5", "recordingSettings": {"mode": ["always"]}},
                {"id": "../etc", "recordingSettings": {"mode": "always"}},
                "nonsense",
            ]
            return self.reply(200, json.dumps(cameras).encode())
        if url.path.endswith("/recording-snapshot"):
            self.server.last_still = query
            if "/gone/" in url.path:
                return self.reply(404)
            return self.reply(200, JPEG, [("Content-Type", "image/jpeg")])
        if url.path == "/proxy/protect/api/video/export":
            self.server.last_export = query
            if query.get("camera") == ["gone"]:
                return self.reply(404)
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
        context.minimum_version = ssl.TLSVersion.TLSv1_2
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
        for path in (h.SESSIONS_PATH, h.REJECTED_PATH, h.CONFIG_PATH):
            if os.path.exists(path):
                os.remove(path)
        shutil.rmtree(h.CLIPS_DIR, ignore_errors=True)
        shutil.rmtree(h.TIMELINE_DIR, ignore_errors=True)
        self.console = {"id": "nvr", "name": "NVR", "host": f"127.0.0.1:{self.server.server_port}",
                        "certSha256": self.pin, "apiKey": "k", "loginUser": "viewer", "loginPassword": "right"}
        self.config = {"consoles": [self.console]}
        # Sign-ins check the saved config before they keep a session.
        h.save_config(self.config)

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
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_clip(args)
        # The link is replaced by a new private file; what it pointed at is untouched.
        self.assertEqual(os.path.getsize(victim), 0)
        self.assertFalse(os.path.islink(link))
        self.assertEqual(os.stat(link).st_mode & 0o777, 0o600)
        # An existing looser file, or another link to it, keeps nothing.
        os.chmod(target, 0o666)
        other = target + ".hardlink"
        os.link(target, other)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_clip(argparse.Namespace(**dict(vars(args), output=target)))
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o600)
        self.assertNotEqual(os.stat(target).st_ino, os.stat(other).st_ino)
        os.remove(h.CONFIG_PATH)

    def test_a_helper_running_during_logout_leaves_no_session_behind(self):
        h.recordings_for(self.config, f"nvr_{CAMERA}")
        straggler = h.ProtectSession(dict(self.console), self.config)   # started before logout
        with mock.patch.object(h, "poll_cameras"), mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_logout(argparse.Namespace(console="nvr"))
        with self.assertRaises(h.ProtectError):
            straggler.events(CAMERA, time.time() - 3600, time.time())   # re-signs in, then sees the logout
        self.assertNotIn("nvr", h.load_sessions())
        self.assertEqual(FakeConsole.valid, set())      # every token signed out on the console

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

    # ---- timeline ----

    def test_timeline_index_says_where_footage_is(self):
        other = {"id": "gw", "name": "Gateway", "host": "127.0.0.1:1", "certSha256": self.pin, "apiKey": "k"}
        config = {"consoles": [self.console, other]}
        uids = [f"nvr_{CAMERA}", "nvr_cam2", "nvr_cam3", "nvr_cam4", "nvr_cam5", "nvr_unknown", "gw_cam9",
                "nowhere_cam1", "nvr_../etc"]
        index = h.timeline_index(config, uids)["cameras"]
        self.assertEqual({uid: c.get("coverage") for uid, c in index.items()},
                         {f"nvr_{CAMERA}": "always", "nvr_cam2": "events", "nvr_cam3": "never",
                          "nvr_cam4": "unknown", "nvr_cam5": "unknown", "nvr_unknown": "unknown",
                          "gw_cam9": None})
        self.assertAlmostEqual(index[f"nvr_{CAMERA}"]["from"], time.time() - 86400 * 30, delta=5)
        self.assertIsNone(index["nvr_cam2"]["from"])
        # Motion too: on a camera that records detections only, it is footage.
        self.assertIn("motion", self.server.last_query["types"])
        self.assertEqual([e["kind"] for e in index[f"nvr_{CAMERA}"]["events"]], ["vehicle", "ring"])
        self.assertEqual(set(index[f"nvr_{CAMERA}"]["events"][0]), {"kind", "start", "end"})
        # No sign-in on that console: said so, and nothing asked of it.
        self.assertTrue(index["gw_cam9"]["needsLogin"])
        self.assertEqual(index["gw_cam9"]["console"], "gw")

    def test_timeline_index_with_a_rejected_login(self):
        FakeConsole.password = "changed"
        index = h.timeline_index(self.config, [f"nvr_{CAMERA}"])["cameras"]
        self.assertTrue(index[f"nvr_{CAMERA}"]["needsLogin"])
        self.assertIn("rejected", index[f"nvr_{CAMERA}"]["loginError"])
        self.assertEqual(FakeConsole.logins, 1)

    def timeline_server(self):
        out = io.StringIO()
        return h.TimelineServer(self.config, out), out

    def replies(self, out):
        return {r["id"]: r for r in map(json.loads, out.getvalue().splitlines())}

    def test_timeline_stills(self):
        server, out = self.timeline_server()
        at = time.time() - 3600
        paths = []
        for n in range(4):
            server.handle({"id": n, "op": "still", "uid": f"nvr_{CAMERA}", "at": at + n,
                           "quality": "low", "slot": "grid"})
            paths.append(self.replies(out)[n]["path"])
        self.assertEqual(self.server.last_still["channel"], ["2"])
        self.assertEqual(int(self.server.last_still["ts"][0]), int((at + 3) * 1000))
        # A new file each time (the window swaps pictures); only the last two stay.
        self.assertEqual(len(set(paths)), 4)
        self.assertEqual([os.path.exists(p) for p in paths], [False, False, True, True])
        with open(paths[-1], "rb") as handle:
            self.assertEqual(handle.read(), JPEG)
        self.assertEqual(os.stat(paths[-1]).st_mode & 0o777, 0o600)
        self.assertTrue(paths[-1].startswith(h.TIMELINE_DIR + os.sep))
        server.handle({"id": "gone", "op": "still", "uid": "nvr_gone", "at": at, "quality": "low", "slot": "grid"})
        self.assertTrue(self.replies(out)["gone"]["noFootage"])
        for bad in ({"slot": "../x"}, {"quality": "best"}, {"at": "soon"}, {"at": float("nan")},
                    {"at": True}, {"uid": "nvr_../etc"}, {"uid": None}):
            request = dict({"id": "bad", "op": "still", "uid": f"nvr_{CAMERA}", "at": at,
                            "quality": "low", "slot": "grid"}, **bad)
            server.handle(request)
            reply = self.replies(out)["bad"]
            self.assertFalse(reply["ok"], bad)
            self.assertNotIn("noFootage", reply, bad)

    def test_timeline_clips(self):
        server, out = self.timeline_server()
        start = (time.time() - 3600) // 60 * 60
        request = {"id": 1, "op": "clip", "uid": f"nvr_{CAMERA}", "start": start, "end": start + 60,
                   "quality": "low"}
        server.handle(request)
        reply = self.replies(out)[1]
        self.assertEqual((reply["ok"], reply["start"], reply["end"]), (True, start, start + 60))
        self.assertEqual(self.server.last_export["channel"], ["2"])
        self.assertEqual(int(self.server.last_export["start"][0]), int(start * 1000))
        with open(reply["path"], "rb") as handle:
            self.assertEqual(handle.read(), MP4)
        self.assertEqual(os.stat(reply["path"]).st_mode & 0o777, 0o600)
        # The same minute again (played, and fetched ahead): one export.
        exports = sum(1 for _, p in FakeConsole.log if p.endswith("/export"))
        server.handle(dict(request, id=2))
        self.assertEqual(self.replies(out)[2]["path"], reply["path"])
        self.assertEqual(sum(1 for _, p in FakeConsole.log if p.endswith("/export")), exports)
        # No footage is an answer of its own, whichever way the console says it.
        for camera in ("gone", "empty"):
            server.handle(dict(request, id=camera, uid=f"nvr_{camera}"))
            self.assertTrue(self.replies(out)[camera]["noFootage"], camera)
        server.handle(dict(request, id="future", start=time.time() + 600, end=time.time() + 660))
        self.assertTrue(self.replies(out)["future"]["noFootage"])
        for bad in ({"end": start}, {"end": start + 86400}, {"quality": "best"}, {"start": "x"}):
            server.handle(dict(request, id="bad", **bad))
            self.assertFalse(self.replies(out)["bad"]["ok"], bad)
            self.assertNotIn("noFootage", self.replies(out)["bad"], bad)
        self.assertEqual(sorted(os.listdir(os.path.join(server.folder, "clips"))),
                         [os.path.basename(reply["path"])])
        self.assertTrue(server.folder.startswith(h.TIMELINE_DIR + os.sep))
        for folder in (server.folder, os.path.join(server.folder, "clips")):
            self.assertEqual(os.stat(folder).st_mode & 0o777, 0o700)
        self.assertEqual(server.clip_locks, {})
        # Only where footage was asked for does "not found" mean there is none.
        with self.assertRaises(h.NotFound) as raised:
            server.session("nvr")[1].get("/nowhere")
        self.assertNotIsInstance(raised.exception, h.NoFootage)

    def test_timeline_clips_nobody_waits_for_are_not_exported(self):
        server, out = self.timeline_server()
        start = (time.time() - 3600) // 60 * 60
        request = {"op": "clip", "uid": f"nvr_{CAMERA}", "start": start, "end": start + 60, "quality": "low"}
        # The playhead has moved twice since this one was asked for.
        server.note_serial({"serial": 7})
        server.handle(dict(request, id=1, serial=5))
        self.assertTrue(self.replies(out)[1]["superseded"])
        self.assertFalse(any(p.endswith("/export") for _, p in FakeConsole.log))
        server.handle(dict(request, id=2, serial=7))
        self.assertTrue(self.replies(out)[2]["ok"])
        # Once it is there, anyone may have it.
        server.handle(dict(request, id=3, serial=5))
        self.assertTrue(self.replies(out)[3]["ok"])
        for nonsense in (True, "9", 9.5, None):
            server.note_serial({"serial": nonsense})
        self.assertEqual(server.serial, 7)

    def test_one_clip_is_never_exported_twice_at_once(self):
        server, out = self.timeline_server()
        state = {"running": 0, "peak": 0, "calls": 0}
        gate = threading.Lock()

        class Slow:
            def export(self, camera_id, start, end, quality, path):
                with gate:
                    state["running"] += 1
                    state["calls"] += 1
                    state["peak"] = max(state["peak"], state["running"])
                    first = state["calls"] == 1
                time.sleep(0.15)
                with gate:
                    state["running"] -= 1
                if first:
                    raise h.ProtectError("the console stopped sending the clip partway; try again")
                h.write_atomic(path, MP4)

        server.session = lambda console_id: (self.console, Slow())
        start = (time.time() - 3600) // 60 * 60
        request = {"op": "clip", "uid": f"nvr_{CAMERA}", "start": start, "end": start + 60, "quality": "low"}
        threads = []
        for n in range(4):
            threads.append(threading.Thread(target=server.handle, args=(dict(request, id=n),)))
            threads[-1].start()
            time.sleep(0.05)       # the third arrives after the first has failed
        for thread in threads:
            thread.join()
        self.assertEqual(state["peak"], 1)
        self.assertEqual(state["calls"], 2)      # the failure, then one that the rest share
        self.assertEqual(sorted(r["ok"] for r in self.replies(out).values()), [False, True, True, True])
        self.assertEqual(server.clip_locks, {})

    def test_a_long_lived_timeline_recovers_its_sign_in(self):
        server, _ = self.timeline_server()
        _, session = server.session("nvr")
        self.assertIs(server.session("nvr")[1], session)
        # The console was away when it signed in: not held against it forever.
        session.login_error = "cannot reach the console"
        self.assertIs(server.session("nvr")[1], session)         # not hammered either
        with mock.patch.object(h.TimelineServer, "SESSION_RETRY", 0):
            fresh = server.session("nvr")[1]
        self.assertIsNot(fresh, session)
        self.assertIsNone(fresh.login_error)
        # A login given to another console while the window is open is seen.
        other = dict(self.console, id="gw", name="Gateway")
        del other["loginUser"], other["loginPassword"]
        h.save_config({"consoles": [self.console, other]})
        with self.assertRaises(h.LoginRejected):
            server.session("gw")
        h.save_config({"consoles": [self.console, dict(other, loginUser="viewer", loginPassword="right")]})
        os.utime(h.CONFIG_PATH, ns=(1, 1))        # whatever the clock's resolution
        self.assertEqual(server.session("gw")[0]["loginUser"], "viewer")
        with self.assertRaisesRegex(h.ProtectError, "no such console"):
            server.session("elsewhere")

    def test_timeline_without_a_login_asks_for_one(self):
        del self.console["loginUser"], self.console["loginPassword"]
        server, out = self.timeline_server()
        server.handle({"id": 1, "op": "still", "uid": f"nvr_{CAMERA}", "at": time.time() - 60,
                       "quality": "low", "slot": "grid"})
        self.assertTrue(self.replies(out)[1]["needsLogin"])
        self.assertEqual(FakeConsole.logins, 0)

    def test_timeline_serve_answers_each_line(self):
        server, out = self.timeline_server()
        start = (time.time() - 3600) // 60 * 60
        server.serve(wait=True, lines=[
            "not json\n", "[1, 2]\n", json.dumps({"id": 1, "op": "nonsense"}) + "\n",
            json.dumps({"id": 2, "op": "index", "uids": [f"nvr_{CAMERA}", 7]}) + "\n",
            json.dumps({"id": 3, "op": "clip", "uid": f"nvr_{CAMERA}", "start": start, "end": start + 60,
                        "quality": "low"}) + "\n",
            "x" * 70000 + "\n",
        ])
        replies = self.replies(out)
        self.assertEqual(sorted(replies), [1, 2, 3])
        self.assertFalse(replies[1]["ok"])
        self.assertEqual(list(replies[2]["cameras"]), [f"nvr_{CAMERA}"])
        self.assertTrue(replies[3]["ok"])
        # One sign-in for all of it.
        self.assertEqual(FakeConsole.logins, 1)

    def test_old_timeline_clips_are_pruned(self):
        folder = os.path.join(h.TIMELINE_DIR, "1", "clips")
        os.makedirs(folder)
        for n in range(6):
            path = os.path.join(folder, f"{n}.mp4")
            with open(path, "wb") as handle:
                handle.write(b"x" * 10)
            os.utime(path, (1000 + n, 1000 + n))
        with mock.patch.object(h, "TIMELINE_CLIPS_KEEP", 3):
            h.prune_timeline_clips(os.path.dirname(folder), keep_path=os.path.join(folder, "0.mp4"))
        self.assertEqual(sorted(os.listdir(folder)), ["0.mp4", "3.mp4", "4.mp4", "5.mp4"])

    def test_only_dead_timeline_servers_are_swept(self):
        # Each server has a folder named for its pid; one still running
        # (here, our parent stands in) keeps its files.
        alive, dead = str(os.getppid()), "4194999"
        for name in (alive, dead, str(os.getpid()), "stills"):
            os.makedirs(os.path.join(h.TIMELINE_DIR, name, "clips"))
        h.sweep_timeline_dirs()
        self.assertEqual(os.listdir(h.TIMELINE_DIR), [alive])
        server, _ = self.timeline_server()
        os.makedirs(server.folder)
        server.cleanup()
        self.assertEqual(os.listdir(h.TIMELINE_DIR), [alive])


class TimelineRules(unittest.TestCase):
    def test_the_moment_can_come_from_the_environment(self):
        # The panel keeps times off the command line.
        args = argparse.Namespace(at=None)
        with mock.patch.object(h, "open_wall") as opened, \
                mock.patch.dict(os.environ, {"ELD_UNIFI_PROTECT_EVENT": json.dumps({"start": 1234.5, "end": None})}):
            h.cmd_timeline(args)
        opened.assert_called_once_with(args, timeline=True)
        self.assertEqual(args.at, 1234.5)
        for bad in ("nonsense", "{}", json.dumps({"start": "soon"})):
            with mock.patch.object(h, "open_wall"), \
                    mock.patch.dict(os.environ, {"ELD_UNIFI_PROTECT_EVENT": bad}):
                with self.assertRaisesRegex(h.ProtectError, "--at"):
                    h.cmd_timeline(argparse.Namespace(at=None))
        with mock.patch.object(h, "open_wall"):
            with self.assertRaisesRegex(h.ProtectError, "Unix seconds"):
                h.cmd_timeline(argparse.Namespace(at=float("inf")))

    def test_the_timeline_is_not_the_wall(self):
        # Two windows of one Quickshell config, told apart by how they were
        # started: closing one must never close the other.
        self.assertNotEqual(h.WALL_ARGV, h.TIMELINE_ARGV)
        # One file, reached through two folders: two configs to Quickshell.
        for _ in range(2):      # again over the link already there
            h.link_timeline_shell()
        self.assertTrue(os.path.samefile(os.path.join(h.TIMELINE_QML_DIR, "shell.qml"),
                                         os.path.join(h.WALL_DIR, "shell.qml")))
        self.assertEqual(os.listdir(h.TIMELINE_QML_DIR), ["shell.qml"])
        self.assertNotEqual(os.path.realpath(h.TIMELINE_QML_DIR), os.path.realpath(h.WALL_DIR))
        self.assertNotEqual(h.WALL_PID, h.TIMELINE_PID)
        self.assertNotEqual(h.WALL_CONFIG, h.TIMELINE_CONFIG)
        os.makedirs(h.RUNTIME_DIR, mode=0o700, exist_ok=True)
        with open(h.TIMELINE_PID, "w") as handle:
            handle.write(f"{os.getpid()} {h.process_start_time(os.getpid())}")
        try:
            self.assertIsNone(h.running_wall(h.TIMELINE_PID, h.TIMELINE_ARGV))   # this is no Quickshell
            self.assertIsNone(h.running_wall())
        finally:
            os.remove(h.TIMELINE_PID)

    def test_demo_cameras_that_record_detections_only_have_gaps(self):
        session = h.DemoSession({"id": "nvr", "demo": True})
        modes = session.recording_modes()
        garden = h.demo_camera_id("garden")
        self.assertEqual(modes[garden]["coverage"], "events")
        self.assertEqual(modes[h.demo_camera_id("driveway")]["coverage"], "always")
        now = time.time()
        with self.assertRaises(h.NoFootage):
            session.footage(garden, now - 70, now - 65)
        session.footage(h.demo_camera_id("driveway"), now - 70, now - 65)
        event = session.events(garden, now - 86400, now)[0]
        session.footage(garden, event["start"], event["start"] + 2)
        # The events stand still from one listing to the next, so the lanes
        # and the gaps agree, and a detection listed a while ago still plays.
        hour = 1_800_000_000 - 1_800_000_000 % 3600
        first = session.events(garden, hour - 86400 + 60, hour + 60, motion=True)
        later = session.events(garden, hour - 86400 + 3000, hour + 3000, motion=True)
        self.assertEqual([e["start"] for e in first], [e["start"] for e in later])
        self.assertTrue(all(e["start"] < hour for e in first))

    def test_a_demo_clip_plays_whatever_the_gaps(self):
        # `clip` (the panel's recordings) plays any demo event, as before
        # the timeline; only the timeline shows the gaps.
        session = h.DemoSession({"id": "nvr", "demo": True})
        with mock.patch.object(h.shutil, "which", return_value="/usr/bin/ffmpeg"), \
                mock.patch.object(h.subprocess, "run") as run, \
                mock.patch.object(h.os, "chmod"), mock.patch.object(h.os, "replace"):
            session.export(h.demo_camera_id("garden"), time.time() - 70, time.time() - 65, "low",
                           os.path.join(h.RUNTIME_DIR, "x.mp4"))
        run.assert_called_once()


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
