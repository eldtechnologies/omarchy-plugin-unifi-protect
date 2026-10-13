"""Unit tests for the parts of the helper that can break quietly."""

import io
import asyncio
import json
import os
import socket
import stat
import time
import unittest
from unittest import mock

from helpers import ROOT, helper as h


class HostParsing(unittest.TestCase):
    def test_bare_address_defaults_to_https_port(self):
        self.assertEqual(h.split_host("192.168.1.1"), ("192.168.1.1", 443))

    def test_scheme_port_and_trailing_slash(self):
        self.assertEqual(h.split_host("https://unifi.local:8443/"), ("unifi.local", 8443))

    def test_bracketed_ipv6(self):
        self.assertEqual(h.split_host("[fe80::1]:443"), ("fe80::1", 443))

    def test_slugify(self):
        self.assertEqual(h.slugify("My NVR #2"), "my-nvr-2")
        self.assertEqual(h.slugify("!!!"), "console")


def camera(console, cam_id, name, mac, state="CONNECTED"):
    return h.summarize_camera(
        {"id": cam_id, "name": name, "mac": mac, "state": state},
        {"id": console, "name": console.upper()},
    )


class Cameras(unittest.TestCase):
    def test_uid_combines_console_and_camera(self):
        self.assertEqual(camera("nvr", "abc", "Gate", "AA")["uid"], "nvr_abc")

    def test_mac_is_normalised(self):
        self.assertEqual(camera("nvr", "a", "Gate", "AA:BB:CC")["mac"], "aabbcc")

    def test_moved_camera_keeps_only_the_connected_copy(self):
        ghost = camera("gateway", "old", "Gate", "AA:BB", state="DISCONNECTED")
        live = camera("nvr", "new", "Gate", "aabb")
        other = camera("gateway", "g", "Garage", "CC")
        merged = h.merge_cameras([ghost, other, live])
        self.assertEqual([c["uid"] for c in merged], ["gateway_g", "nvr_new"])

    def test_distinct_cameras_with_the_same_name_both_stay(self):
        a = camera("gateway", "a", "Gym", "11", state="DISCONNECTED")
        b = camera("nvr", "b", "Gym", "22")
        self.assertEqual(len(h.merge_cameras([a, b])), 2)

    def test_hiding_follows_the_mac(self):
        cams = [camera("nvr", "a", "Gate", "AA"), camera("nvr", "b", "Patio", "BB")]
        h.apply_prefs(cams, {"hideOffline": False, "hidden": ["aa"]})
        self.assertEqual([c["hidden"] for c in cams], [True, False])

    def test_favourite_is_flagged_and_leads(self):
        cams = [camera("nvr", "a", "Gate", "AA"), camera("nvr", "b", "Patio", "BB")]
        h.apply_prefs(cams, {"hidden": [], "favorite": "bb"})
        self.assertEqual([(c["name"], c["favorite"]) for c in cams],
                         [("Patio", True), ("Gate", False)])

    def test_find_cameras_by_uid_id_mac_or_name(self):
        cams = [camera("nvr", "abc", "Front Door", "AA:BB")]
        for wanted in ("nvr_abc", "abc", "aa:bb", "front door"):
            self.assertEqual(len(h.find_cameras(cams, wanted)), 1, wanted)
        self.assertEqual(h.find_cameras(cams, "back door"), [])


class Consoles(unittest.TestCase):
    config = {"consoles": [
        {"id": "gateway", "name": "Gateway", "host": "192.168.1.1", "apiKey": "k1"},
        {"id": "nvr", "name": "NVR", "host": "192.168.1.240", "apiKey": "k2"},
    ]}

    def test_find_console_by_id_name_or_host(self):
        for wanted in ("nvr", "NVR", "192.168.1.240"):
            self.assertEqual(h.find_console(self.config, wanted)["id"], "nvr")

    def test_ambiguous_without_a_name(self):
        with self.assertRaises(h.ProtectError):
            h.find_console(self.config, None)

    def test_resolve_camera_routes_by_uid_prefix(self):
        client, camera_id = h.resolve_camera(self.config, "nvr_abc123")
        self.assertEqual((client.host, camera_id), ("192.168.1.240", "abc123"))


class Files(unittest.TestCase):
    def test_write_atomic_is_private_and_complete(self):
        path = os.path.join(os.environ["XDG_STATE_HOME"], "t", "f.json")
        h.write_atomic(path, '{"a": 1}')
        with open(path) as handle:
            self.assertEqual(json.load(handle), {"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        leftovers = [n for n in os.listdir(os.path.dirname(path)) if ".tmp." in n]
        self.assertEqual(leftovers, [])

    def test_popout_sound_follows_the_flag(self):
        self.assertIn("--mute=no", h.mpv_command("mpv"))
        self.assertIn("--mute=yes", h.mpv_command("mpv", sound=False))

    def test_mpv_command_lines_name_nothing(self):
        # Titles and URLs go on stdin: other users can read command lines.
        for command in (h.mpv_command("mpv"), h.mpv_clip_command("mpv")):
            self.assertIn("--title=${playlist/0/title}", command)
            self.assertIn("--playlist=-", command)
            self.assertFalse([a for a in command if "://" in a or "Door" in a])

    def test_mpv_playlist_carries_title_and_target(self):
        self.assertEqual(h.mpv_playlist("Front\nDoor", "rtsp://127.0.0.1:1/x"),
                         b"#EXTM3U\n#EXTINF:-1,Front Door\nrtsp://127.0.0.1:1/x\n")
        for bad in ("a\nb", "#EXTINF:-1,x"):
            with self.assertRaises(h.ProtectError):
                h.mpv_playlist("t", bad)

    def test_version_comes_from_the_manifest(self):
        with open(ROOT / "manifest.json") as handle:
            manifest = json.load(handle)
        self.assertEqual(h.plugin_version(), manifest["version"])


class RtspParsing(unittest.TestCase):
    def test_interleaved_frame_passes_through_whole(self):
        raw = b"$\x00\x00\x05hello"
        self.assertEqual(h.read_rtsp(io.BytesIO(raw)), ("frame", raw))

    def test_text_message_with_body(self):
        raw = (b"RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 4\r\n\r\nv=0\n"
               b"$\x01\x00\x01x")
        reader = io.BytesIO(raw)
        kind, start, headers, body = h.read_rtsp(reader)
        self.assertEqual((kind, start, body), ("text", "RTSP/1.0 200 OK", b"v=0\n"))
        self.assertEqual(h.header_value(headers, "cseq"), "2")
        self.assertEqual(h.read_rtsp(reader), ("frame", b"$\x01\x00\x01x"))

    def test_truncated_input_ends_cleanly(self):
        self.assertIsNone(h.read_rtsp(io.BytesIO(b"$\x00\x00\x09abc")))
        self.assertIsNone(h.read_rtsp(io.BytesIO(b"")))

    def test_encode_sets_content_length_from_the_body(self):
        out = h.encode_rtsp("DESCRIBE x RTSP/1.0", [("CSeq", "3"), ("Content-Length", "99")], b"abc")
        self.assertEqual(out, b"DESCRIBE x RTSP/1.0\r\nCSeq: 3\r\nContent-Length: 3\r\n\r\nabc")


class RelayRewriting(unittest.TestCase):
    def session(self):
        routes = {"R1": {"console": "nvr", "path": "/AbC"}}
        relay = type("R", (), {"port": 4000, "token": "tok", "consoles": {"nvr": {"id": "nvr"}},
                               "lookup_route": staticmethod(routes.get)})()
        session = object.__new__(h.RelaySession)
        session.relay = relay
        session.route_path = session.alias_path = ""
        session.set_bases({"id": "nvr"}, "192.168.1.240")
        return session

    def test_requests_go_to_the_console_over_rtsps(self):
        s = self.session()
        s.route("rtsp://127.0.0.1:4000/tok/nvr/R1")
        self.assertEqual(s.to_upstream("rtsp://127.0.0.1:4000/tok/nvr/R1/trackID=0"),
                         "rtsps://192.168.1.240:7441/AbC/trackID=0")

    def test_console_urls_in_responses_point_back_at_the_relay(self):
        s = self.session()
        s.route("rtsp://127.0.0.1:4000/tok/nvr/R1")
        for url in ("rtsps://192.168.1.240:7441/AbC/", "rtsp://192.168.1.240:7447/AbC/"):
            self.assertEqual(s.to_client(f"Content-Base: {url}"),
                             "Content-Base: rtsp://127.0.0.1:4000/tok/nvr/R1/")

    def test_the_alias_never_reaches_the_player_in_any_form(self):
        s = self.session()
        s.route("rtsp://127.0.0.1:4000/tok/nvr/R1")
        for text in ("a=control:/AbC/trackID=0", "Location: /AbC", "no such stream AbC"):
            self.assertNotIn("AbC", s.to_client(text))
        self.assertEqual(s.to_client("a=control:/AbC/trackID=0"), "a=control:/R1/trackID=0")

    def test_redirects_and_foreign_urls_never_reach_the_player(self):
        s = self.session()
        s.route("rtsp://127.0.0.1:4000/tok/nvr/R1")
        here = "rtsp://127.0.0.1:4000/tok/nvr/R1/"
        self.assertTrue(s.keeps_player_here("RTSP/1.0 200 OK", [("Content-Base", here)], b"a=control:" + here.encode()))
        self.assertFalse(s.keeps_player_here("RTSP/1.0 302 Moved", [("Location", here)], b""))
        # Spellings FFmpeg still reads as a redirect, or as a URL elsewhere.
        for start in ("RTSP/1.0  302 Moved", "RTSP/1.0\t302 Moved", "RTSP/1.0 0302 Moved",
                      "RTSP/1.0 +302 Moved", "RTSP/1.1 200 OK", "HTTP/1.0 200 OK"):
            self.assertFalse(s.keeps_player_here(start, [], b""), start)
        for value in ("rtsp:198.51.100.7:8554/x", "rtsp:/198.51.100.7/x", "satip:10.0.0.5:554/x",
                      "RTSPH://evil/x"):
            self.assertFalse(s.keeps_player_here("RTSP/1.0 200 OK", [("X", value)], b""), value)
            self.assertFalse(s.keeps_player_here("RTSP/1.0 200 OK", [], b"a=control:" + value.encode()), value)
        for value in ("satip://10.0.0.5:554/x", "rtspu://10.0.0.5/x", "RTSP://evil:554"):
            self.assertFalse(s.keeps_player_here("RTSP/1.0 200 OK", [("Content-Base", value)], b""), value)
        # Path-less console URLs are rewritten to the relay too.
        self.assertEqual(s.to_client("Content-Base: rtsps://192.168.1.240:7441"),
                         "Content-Base: rtsp://127.0.0.1:4000/tok/nvr")

    def test_bare_carriage_returns_end_the_message(self):
        async def parse(data):
            reader = asyncio.StreamReader()
            reader.feed_data(data)
            reader.feed_eof()
            return await h.read_rtsp_async(reader)
        self.assertIsNone(asyncio.run(parse(b"OPTIONS x RTSP/1.0\r\nCSeq: 1\rX: y\r\n\r\n")))
        self.assertIsNotNone(asyncio.run(parse(b"OPTIONS x RTSP/1.0\r\nCSeq: 1\r\n\r\n")))

    def test_the_relay_knows_who_is_calling(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        client = socket.create_connection(server.getsockname())
        accepted, peer = server.accept()
        for sock in (server, client, accepted):
            self.addCleanup(sock.close)
        self.assertEqual(h.loopback_peer_uid(peer, accepted.getsockname()), os.getuid())
        self.assertIsNone(h.loopback_peer_uid(("127.0.0.1", 1), accepted.getsockname()))

    def test_route_requires_the_token_and_a_registered_route(self):
        s = self.session()
        self.assertEqual(s.route("rtsp://127.0.0.1:4000/tok/nvr/R1"), {"id": "nvr"})
        self.assertIsNone(self.session().route("rtsp://127.0.0.1:4000/wrong/nvr/R1"))
        self.assertIsNone(self.session().route("rtsp://127.0.0.1:4000/tok/other/R1"))
        self.assertIsNone(self.session().route("rtsp://127.0.0.1:4000/tok/nvr/AbC"))
        # A session keeps its route.
        self.assertIsNone(s.route("rtsp://127.0.0.1:4000/tok/nvr/R2"))


class RelayLiveness(unittest.TestCase):
    """Only the running relay counts; a listener on its old port does not."""

    def setUp(self):
        os.makedirs(os.path.dirname(h.RELAY_LOCK), exist_ok=True)
        self.lock = open(h.RELAY_LOCK, "a")
        self.addCleanup(self.lock.close)

    def info(self, **changes):
        return dict({"pid": os.getpid(), "started": h.process_start_time(os.getpid()),
                     "port": 1234, "token": "t"}, **changes)

    def test_the_lock_holder_is_the_relay(self):
        import fcntl
        self.assertFalse(h.relay_lock_held())
        self.assertFalse(h.relay_alive(self.info()))
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(fcntl.flock, self.lock, fcntl.LOCK_UN)
        self.assertTrue(h.relay_lock_held())
        self.assertTrue(h.relay_alive(self.info()))
        # A stale relay.json whose pid was reused by another process.
        self.assertFalse(h.relay_alive(self.info(started=1)))
        self.assertFalse(h.relay_alive(self.info(pid=None)))

    def test_a_squatter_on_the_old_port_is_not_the_relay(self):
        squatter = socket.socket()
        squatter.bind(("127.0.0.1", 0))
        squatter.listen(1)
        self.addCleanup(squatter.close)
        self.assertFalse(h.relay_alive(self.info(port=squatter.getsockname()[1])))

    def test_the_relay_stays_while_its_lease_is_fresh(self):
        relay = object.__new__(h.Relay)
        h.write_json(h.RELAY_INFO, {"pid": 1})
        h.write_json(h.RELAY_ROUTES, {})
        with mock.patch.object(h.os, "_exit", side_effect=SystemExit):
            relay.exit_if_unwanted()                       # vouched for just now: stays
            self.assertTrue(os.path.exists(h.RELAY_INFO))
            old = time.time() - h.RELAY_IDLE_EXIT - 5
            os.utime(h.RELAY_INFO, (old, old))
            with h.relay_guard():                          # a helper is vouching: stays
                relay.exit_if_unwanted()
            self.assertTrue(os.path.exists(h.RELAY_INFO))
            with self.assertRaises(SystemExit):            # idle and unclaimed: goes
                relay.exit_if_unwanted()
        self.assertFalse(os.path.exists(h.RELAY_INFO))
        self.assertFalse(os.path.exists(h.RELAY_ROUTES))

    def test_routes_are_stable_and_private(self):
        with h.relay_guard():
            first = h.register_relay_route("nvr", "/AbC")
            self.assertEqual(h.register_relay_route("nvr", "/AbC"), first)
            self.assertNotEqual(h.register_relay_route("nvr", "/Other"), first)
        self.assertNotIn("AbC", first)
        self.assertEqual(stat.S_IMODE(os.stat(h.RELAY_ROUTES).st_mode), 0o600)



class ConsoleInput(unittest.TestCase):
    def test_settings_changes_apply_to_cameras_json_as_it_is_now(self):
        h.save_prefs(h.load_prefs())
        # Two helpers arming different cameras both count...
        h.update_prefs(lambda p: p["alerts"].__setitem__("cam1", ["person"]))
        h.update_prefs(lambda p: p["alerts"].__setitem__("cam2", ["ring"]))
        self.assertEqual(h.load_prefs()["alerts"], {"cam1": ["person"], "cam2": ["ring"]})
        # ...and a quick second click that undoes the first wins.
        h.update_prefs(lambda p: p["alerts"].pop("cam1", None))
        self.assertEqual(h.load_prefs()["alerts"], {"cam2": ["ring"]})
        h.update_prefs(lambda p: p.update(favorite="cam2"))
        h.update_prefs(lambda p: p.update(favorite=""))
        self.assertEqual(h.load_prefs()["favorite"], "")

    def test_quick_clicks_take_effect_in_the_order_made(self):
        import argparse
        h.write_json(h.STATE_PATH, {"cameras": [{"uid": "nvr_cam1", "id": "cam1", "name": "Door",
                                                  "mac": "aabbccddeeff", "consoleName": "NVR"}]})
        h.save_prefs(h.load_prefs())
        # No console is asked before the change: the last camera list will do.
        with mock.patch.object(h, "poll_cameras") as poll, \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            h.cmd_favorite(argparse.Namespace(camera="nvr_cam1", clear=False))
            self.assertEqual(h.load_prefs()["favorite"], "aabbccddeeff")
            h.cmd_favorite(argparse.Namespace(camera=None, clear=True))
        self.assertEqual(h.load_prefs()["favorite"], "")
        self.assertTrue(all(call.args == () for call in poll.call_args_list))   # only refreshes after

    def test_console_addresses_are_ip_addresses_or_host_names(self):
        for good, expected in (("192.168.1.1", "192.168.1.1"), ("https://nvr.local/", "nvr.local"),
                               ("10.0.0.2:443", "10.0.0.2"), ("10.0.0.2:8443", "10.0.0.2:8443"),
                               ("[fd00::1]", "[fd00::1]"), ("unifi", "unifi"),
                               ("UNVR-Pro-Garage2.local", "UNVR-Pro-Garage2.local"), ("my_nvr.lan", "my_nvr.lan")):
            self.assertEqual(h.normalize_host(good), expected)
        for bad in ("abcdefghijklmnopqrstuvwxyz0123456789ABCD", "nvr;rm -rf", "-x", "a b", "h:99999",
                    "192.168.1.1Zq7XkP2mN9vB4cR8tY1wL6hJ3dF5gS0a", "Zq7XkP2mN9vB4cR8tY1wL6hJ3dF5gS0a.lan",
                    "192.168.1.256"):
            with self.assertRaises(h.ProtectError, msg=bad):
                h.normalize_host(bad)

    def test_a_camera_id_can_never_look_like_a_uid(self):
        self.assertIsNone(h.summarize_camera({"id": "nvr_abc"}, {"id": "gw", "name": "GW"}))
        self.assertIsNotNone(h.summarize_camera({"id": "0123456789abcdef01234567"}, {"id": "gw", "name": "GW"}))

    def test_uids_win_over_ids_and_names(self):
        cams = [{"uid": "gw_x", "id": "x", "name": "nvr_cam", "mac": ""},
                {"uid": "nvr_cam", "id": "cam", "name": "Door", "mac": ""}]
        self.assertEqual([c["uid"] for c in h.find_cameras(cams, "nvr_cam")], ["nvr_cam"])

    def test_an_online_camera_is_never_hidden_by_another_consoles_claim(self):
        def cam(uid, online):
            return {"uid": uid, "mac": "aabbccddeeff", "online": online, "consoleName": uid, "name": "Door"}
        both = h.merge_cameras([cam("gw_fake", True), cam("nvr_real", True)])
        self.assertEqual(sorted(c["uid"] for c in both), ["gw_fake", "nvr_real"])
        # Their settings are then keyed by uid, never by the disputed MAC.
        self.assertEqual(sorted(h.camera_key(c) for c in both), ["gw_fake", "nvr_real"])
        moved = h.merge_cameras([cam("gw_old", False), cam("nvr_new", True)])
        self.assertEqual([c["uid"] for c in moved], ["nvr_new"])

    def test_snapshots_of_cameras_no_longer_listed_are_removed(self):
        os.makedirs(h.SNAP_DIR, exist_ok=True)
        for uid in ("nvr_a", "nvr_gone"):
            with open(h.snapshot_path(uid), "wb") as handle:
                handle.write(b"x")
        index = {"nvr_a": 1, "nvr_gone": 1}
        h.refresh_snapshots({"consoles": []}, [{"uid": "nvr_a", "console": "nvr", "online": False}], index)
        self.assertEqual(sorted(os.listdir(h.SNAP_DIR)), sorted(["nvr_a.jpg", os.path.basename(h.SNAP_INDEX)]))
        self.assertEqual(index, {"nvr_a": 1})

class WallPid(unittest.TestCase):
    def test_stop_signals_only_the_process_it_started(self):
        import subprocess
        import sys
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "relay"])
        self.addCleanup(child.kill)
        for _ in range(100):       # until the child runs its own command line
            with open(f"/proc/{child.pid}/cmdline", "rb") as handle:
                if b"relay" in handle.read().split(b"\0"):
                    break
            time.sleep(0.01)
        started = h.process_start_time(child.pid)
        self.assertFalse(h.stop_process(child.pid, started + 1, b"relay"))   # reused pid
        self.assertFalse(h.stop_process(child.pid, started, b"events"))      # other command
        self.assertTrue(h.stop_process(child.pid, started, b"relay"))
        self.assertEqual(child.wait(5), -15)

    def test_a_stale_pid_never_names_another_process(self):
        os.makedirs(os.path.dirname(h.WALL_PID), exist_ok=True)
        me = os.getpid()
        for content in (f"{me} {h.process_start_time(me)}", f"{me}", f"{me} 1", "garbage", ""):
            with open(h.WALL_PID, "w") as handle:
                handle.write(content)
            self.assertIsNone(h.running_wall(), content)
        os.remove(h.WALL_PID)

if __name__ == "__main__":
    unittest.main()
