"""Desktop notifications over D-Bus, against a fake session bus.

Nothing about an alert may appear in a command line, so the helper speaks
D-Bus itself; this checks what it sends and how it reads the answer.
"""

import asyncio
import os
import shutil
import tempfile
import unittest
from unittest import mock

from helpers import helper as h


def parse_notify(raw):
    """The arguments of Notify(susssasa{sv}i) from its raw body."""
    r = h.DBusReader(raw)
    app, replaces, icon, summary, body = r.string(), r.uint32(), r.string(), r.string(), r.string()
    actions, end = [], r.uint32()
    end += r.pos
    while r.pos < end:
        actions.append(r.string())
    hints, length = {}, r.uint32()
    r.align(8)
    end = r.pos + length
    while r.pos < end:
        r.align(8)
        key = r.string()
        hints[key] = r.variant()
    timeout = r.int32()
    return {"app": app, "summary": summary, "body": body, "actions": actions,
            "hints": hints, "timeout": timeout, "replaces": replaces, "icon": icon}


class FakeBus:
    def __init__(self, path, answer="live"):
        self.path, self.answer, self.calls, self.notified = path, answer, [], None

    async def serve(self, reader, writer):
        auth = await reader.readuntil(b"\r\n")
        self.auth = auth
        writer.write(b"OK 0123456789abcdef0123456789abcdef\r\n")
        await reader.readuntil(b"BEGIN\r\n")
        serial = 100
        while True:
            try:
                kind, fields, values, raw = await h.dbus_read(reader)
            except asyncio.IncompleteReadError:
                writer.close()
                return
            member = fields.get(3)
            self.calls.append((member, fields.get(6)))
            serial += 1
            if member == "Hello":
                body = h.DBusWriter(); body.string(":1.42")
                writer.write(self.reply(serial, fields, "s", body))
                # Signals for other things arrive too; they must be ignored.
                writer.write(self.signal(serial + 1, "org.freedesktop.DBus", "NameAcquired", "s", body))
            elif member == "AddMatch":
                writer.write(self.reply(serial, fields, sender="org.freedesktop.DBus"))
            elif member == "GetNameOwner":
                body = h.DBusWriter(); body.string(":1.7")
                writer.write(self.reply(serial, fields, "s", body, sender="org.freedesktop.DBus"))
            elif member == "Notify":
                self.notified = parse_notify(raw)
                body = h.DBusWriter(); body.uint32(7)
                writer.write(self.reply(serial, fields, "u", body))
                other = h.DBusWriter(); other.uint32(6); other.string("live")
                writer.write(self.signal(serial + 1, h.NOTIFY_NAME, "ActionInvoked", "us", other))
                # Someone else on the bus imitating the service is ignored.
                spoof = h.DBusWriter(); spoof.uint32(7); spoof.string("spoofed")
                writer.write(self.signal(serial + 1, h.NOTIFY_NAME, "ActionInvoked", "us", spoof,
                                         sender=":1.666"))
                if self.answer:
                    mine = h.DBusWriter(); mine.uint32(7); mine.string(self.answer)
                    writer.write(self.signal(serial + 2, h.NOTIFY_NAME, "ActionInvoked", "us", mine))
                else:
                    closed = h.DBusWriter(); closed.uint32(7); closed.uint32(2)
                    writer.write(self.signal(serial + 2, h.NOTIFY_NAME, "NotificationClosed", "uu", closed))
            await writer.drain()

    # The bus stamps every message with its sender's unique name.
    @staticmethod
    def reply(serial, fields, signature="", body=None, sender=":1.7"):
        return h.dbus_message(2, serial, [(5, "u", fields["serial"]), (7, "s", sender)], signature,
                              bytes(body.buf) if body else b"")

    @staticmethod
    def signal(serial, interface, member, signature, body, sender=":1.7"):
        return h.dbus_message(4, serial, [(1, "o", h.NOTIFY_PATH), (2, "s", interface), (3, "s", member),
                                          (7, "s", sender)], signature, bytes(body.buf))


class Notifications(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "bus")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_bus(self, answer):
        bus = FakeBus(self.path, answer)

        async def main():
            server = await asyncio.start_unix_server(bus.serve, self.path)
            try:
                with mock.patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": f"unix:path={self.path}"}):
                    return await h.send_desktop_notification(
                        "Person at Front Door", "NVR · 12:34", "/run/x/alerts/e1.jpg", ["live", "Watch live"])
            finally:
                server.close()
                await server.wait_closed()
        return bus, asyncio.run(main())

    def test_notify_carries_the_alert_and_returns_the_action(self):
        bus, chosen = self.run_bus("live")
        self.assertEqual(chosen, "live")
        self.assertEqual(bus.auth, b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
        self.assertEqual([m for m, _ in bus.calls], ["Hello", "AddMatch", "GetNameOwner", "Notify"])
        self.assertEqual(bus.calls[3][1], h.NOTIFY_NAME)
        n = bus.notified
        self.assertEqual((n["app"], n["summary"], n["body"]), ("UniFi Protect", "Person at Front Door", "NVR · 12:34"))
        self.assertEqual(n["actions"], ["live", "Watch live"])
        self.assertEqual(n["hints"], {"urgency": 1, "transient": True,
                                      "image-path": "file:///run/x/alerts/e1.jpg"})
        self.assertEqual(n["timeout"], -1)

    def test_dismissed_notification_returns_none(self):
        _, chosen = self.run_bus(None)
        self.assertIsNone(chosen)

    def test_bus_address(self):
        cases = {
            "unix:path=/run/user/1000/bus": "/run/user/1000/bus",
            "unix:abstract=/tmp/dbus-x,guid=abc": "\0/tmp/dbus-x",
            "tcp:host=localhost,port=1;unix:path=/run/b%20us": "/run/b us",
        }
        for address, path in cases.items():
            with mock.patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": address}):
                self.assertEqual(h.session_bus_path(), path)

    def test_no_names_in_any_command_line(self):
        # The listener must not start notify-send (or anything) with alert text.
        listener = h.AlertListener()
        listener.config = {"consoles": []}
        started = []

        async def run():
            with mock.patch.object(asyncio, "create_subprocess_exec",
                                   side_effect=lambda *a, **k: started.append(a)), \
                    mock.patch.object(h, "send_desktop_notification", return_value=None):
                await listener.send_notification(
                    None, {"uid": "nvr_c", "name": "Front Door", "consoleName": "NVR"},
                    {"id": "e1", "kind": "person", "start": 0})
        asyncio.run(run())
        self.assertEqual(started, [])


if __name__ == "__main__":
    unittest.main()
