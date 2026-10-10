"""Alerts: matching, the WebSocket client, and the listener end to end."""

import asyncio
import base64
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

from helpers import helper as h


class Matching(unittest.TestCase):
    def test_smart_detections_match_armed_types_only(self):
        event = {"type": "smartDetectZone", "smartDetectTypes": ["animal", "person"]}
        self.assertEqual(h.alert_kind(event, ["person", "vehicle"]), "person")
        self.assertIsNone(h.alert_kind(event, ["vehicle"]))

    def test_empty_smart_add_does_not_match_yet(self):
        self.assertIsNone(h.alert_kind({"type": "smartDetectZone", "smartDetectTypes": []}, ["person"]))

    def test_ring_and_motion_need_arming(self):
        self.assertEqual(h.alert_kind({"type": "ring"}, ["ring"]), "ring")
        self.assertIsNone(h.alert_kind({"type": "motion"}, h.DEFAULT_TRIGGERS))
        self.assertEqual(h.alert_kind({"type": "motion"}, ["motion"]), "motion")

    def test_audio_and_other_events_never_match(self):
        self.assertIsNone(h.alert_kind({"type": "smartAudioDetect", "smartDetectTypes": ["alrmSpeak"]},
                                       list(h.ALERT_TRIGGERS)))

    def test_event_time_handles_milliseconds(self):
        self.assertEqual(h.event_time(1791700000000), 1791700000)
        self.assertEqual(h.event_time(1791700000), 1791700000)
        self.assertIsNone(h.event_time(None))


def unmask(frame):
    """Decode one masked client frame: (opcode, payload)."""
    length, i = frame[1] & 0x7F, 2
    if length == 126:
        length, i = int.from_bytes(frame[2:4], "big"), 4
    mask = frame[i:i + 4]
    return frame[0] & 0x0F, bytes(b ^ mask[j % 4] for j, b in enumerate(frame[i + 4:i + 4 + length]))


def server_frame(opcode, payload, fin=True):
    length = len(payload)
    head = bytes([(0x80 if fin else 0) | opcode])
    head += bytes([length]) if length < 126 else bytes([126]) + length.to_bytes(2, "big")
    return head + payload


class FakeWriter:
    def __init__(self):
        self.sent = []

    def write(self, data):
        self.sent.append(data)

    async def drain(self):
        pass


class WebSocketFrames(unittest.TestCase):
    def collect(self, data, idle=60):
        async def run():
            reader = asyncio.StreamReader()
            reader.feed_data(data)
            reader.feed_eof()
            writer = FakeWriter()
            out = []
            try:
                async for text in h.ws_messages(reader, writer, idle=idle):
                    out.append(text)
            except asyncio.IncompleteReadError:
                pass
            return out, writer.sent
        return asyncio.run(run())

    def test_client_frames_are_masked(self):
        frame = h.ws_frame(0x9, b"hello")
        self.assertTrue(frame[1] & 0x80)
        self.assertEqual(unmask(frame), (0x9, b"hello"))

    def test_text_fragments_and_ping(self):
        data = (server_frame(0x1, b'{"a":', fin=False) + server_frame(0x9, b"p")
                + server_frame(0x0, b"1}") + server_frame(0x8, b""))
        texts, sent = self.collect(data)
        self.assertEqual(texts, ['{"a":1}'])
        self.assertEqual([unmask(f) for f in sent], [(0xA, b"p")])

    def test_long_message(self):
        body = json.dumps({"x": "y" * 500}).encode()
        texts, _ = self.collect(server_frame(0x1, body) + server_frame(0x8, b""))
        self.assertEqual(texts, [body.decode()])


class ListenerLifecycle(unittest.TestCase):
    def listener(self):
        listener = h.AlertListener()
        listener.alerts = []
        listener.config = {"consoles": []}
        listener.prefs_stamp = "fixed"   # keep refresh() from re-reading files
        listener.refresh = lambda: None
        listener.armed = {"nvr": {"cam1": {"uid": "nvr_cam1", "name": "Front Door",
                                            "consoleName": "NVR", "alerts": ["person", "ring"]}}}
        listener.save = lambda: None
        return listener

    def test_add_then_update_then_end(self):
        lst = self.listener()
        lst.handle("nvr", {"type": "add", "item": {"id": "e1", "modelKey": "event", "type": "smartDetectZone",
                                                   "device": "cam1", "start": 1791700000000, "smartDetectTypes": []}})
        self.assertEqual(lst.alerts, [])   # nothing classified yet
        # Updates may omit the device; the listener remembers it per event.
        lst.handle("nvr", {"type": "update", "item": {"id": "e1", "modelKey": "event", "type": "smartDetectZone",
                                                      "smartDetectTypes": ["person"]}})
        self.assertEqual([(a["kind"], a["camera"], a["end"]) for a in lst.alerts], [("person", "Front Door", None)])
        lst.handle("nvr", {"type": "update", "item": {"id": "e1", "end": 1791700012000}})
        self.assertEqual(lst.alerts[0]["end"], 1791700012)
        self.assertEqual(len(lst.alerts), 1)

    def test_unarmed_cameras_and_other_consoles_are_ignored(self):
        lst = self.listener()
        lst.handle("nvr", {"item": {"id": "e2", "type": "ring", "device": "cam9"}})
        lst.handle("gateway", {"item": {"id": "e3", "type": "ring", "device": "cam1"}})
        self.assertEqual(lst.alerts, [])

    def test_doorbell_ring(self):
        lst = self.listener()
        lst.handle("nvr", {"item": {"id": "e4", "type": "ring", "device": "cam1", "start": 1791700000000}})
        self.assertEqual(lst.alerts[0]["kind"], "ring")


class Notifications(unittest.TestCase):
    def listener(self, enabled=True):
        listener = h.AlertListener()
        listener.config = {"consoles": []}
        listener.notify_enabled = enabled
        listener.sent = []

        async def fake_send(console, camera, alert):
            listener.sent.append((camera["uid"], alert["kind"]))
        listener.send_notification = fake_send
        return listener

    def notify_twice(self, listener, uids):
        camera = {"uid": "", "id": "c", "name": "Door", "consoleName": "NVR"}

        async def run():
            for uid in uids:
                listener.notify("nvr", dict(camera, uid=uid), {"id": uid, "kind": "person", "start": 0})
            await asyncio.sleep(0)
        asyncio.run(run())

    def test_at_most_one_notification_per_camera_per_minute(self):
        lst = self.listener()
        self.notify_twice(lst, ["nvr_a", "nvr_a", "nvr_b"])
        self.assertEqual(lst.sent, [("nvr_a", "person"), ("nvr_b", "person")])

    def test_notifications_can_be_turned_off(self):
        lst = self.listener(enabled=False)
        self.notify_twice(lst, ["nvr_a"])
        self.assertEqual(lst.sent, [])


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class ListenerEndToEnd(unittest.TestCase):
    """A fake console serves the events WebSocket; the listener records alerts."""

    def test_events_over_pinned_websocket(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        cert, key = os.path.join(tmp, "c.pem"), os.path.join(tmp, "k.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key, "-out", cert,
                        "-days", "1", "-subj", "/CN=fake-console"], check=True, capture_output=True)
        with open(cert) as handle:
            pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(handle.read())).hexdigest()
        seen = {}

        async def console(reader, writer):
            head = (await reader.readuntil(b"\r\n\r\n")).decode()
            seen["request"] = head.split("\r\n")[0]
            seen["apikey"] = "X-API-KEY: secret-key" in head
            ws_key = next(l.split(":", 1)[1].strip() for l in head.split("\r\n")
                          if l.lower().startswith("sec-websocket-key:"))
            accept = base64.b64encode(hashlib.sha1((ws_key + h.WS_GUID).encode()).digest()).decode()
            writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            for item in ({"id": "ev1", "modelKey": "event", "type": "smartDetectZone", "device": "cam1",
                          "start": 1791700000000, "smartDetectTypes": []},
                         {"id": "ev1", "modelKey": "event", "type": "smartDetectZone", "device": "cam1",
                          "smartDetectTypes": ["vehicle"]},
                         {"id": "ev2", "modelKey": "event", "type": "motion", "device": "cam1",
                          "start": 1791700001000}):
                writer.write(server_frame(0x1, json.dumps({"type": "add", "item": item}).encode()))
            await writer.drain()
            await asyncio.sleep(5)

        console_config = {"id": "nvr", "name": "NVR", "certSha256": pin, "apiKey": "secret-key"}

        async def run():
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server = await asyncio.start_server(console, "127.0.0.1", 0, ssl=context)
            port = server.sockets[0].getsockname()[1]
            listener = h.AlertListener()
            listener.alerts = []
            listener.config = {"consoles": [dict(console_config, host=f"127.0.0.1:{port}")]}
            listener.refresh = lambda: None
            listener.armed = {"nvr": {"cam1": {"uid": "nvr_cam1", "name": "Front Door",
                                                "consoleName": "NVR", "alerts": ["vehicle"]}}}
            task = asyncio.create_task(listener.watch_console("nvr"))
            for _ in range(50):
                await asyncio.sleep(0.05)
                if listener.alerts:
                    break
            await asyncio.sleep(0.2)
            task.cancel()
            server.close()
            return listener

        listener = asyncio.run(run())
        self.assertEqual(seen["request"], f"GET {h.EVENTS_WS_PATH} HTTP/1.1")
        self.assertTrue(seen["apikey"])
        self.assertEqual([(a["kind"], a["camera"]) for a in listener.alerts], [("vehicle", "Front Door")])
        self.assertEqual(listener.status["nvr"]["connected"], True)
        with open(h.ALERTS_PATH) as handle:
            self.assertEqual(json.load(handle)["alerts"][0]["kind"], "vehicle")


if __name__ == "__main__":
    unittest.main()
