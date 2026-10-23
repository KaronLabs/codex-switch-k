#!/usr/bin/env python3
"""A one-connection WebSocket app-server fixture for the process-gate tests."""

import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import time


def receive_exact(connection, count):
    data = b""
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise EOFError
        data += part
    return data


def receive_message(connection):
    first, second = receive_exact(connection, 2)
    assert first & 0x0F == 1
    assert second & 0x80
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(receive_exact(connection, 2), "big")
    elif length == 127:
        length = int.from_bytes(receive_exact(connection, 8), "big")
    mask = receive_exact(connection, 4)
    payload = receive_exact(connection, length)
    return json.loads(bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))


def send_message(connection, message, first_byte=0x81):
    payload = json.dumps(message, separators=(",", ":")).encode()
    header = bytes([first_byte, len(payload)]) if len(payload) < 126 else bytes([first_byte, 126]) + len(payload).to_bytes(2, "big")
    connection.sendall(header + payload)


def serve(connection, scenario, reads):
    handshake = b""
    while b"\r\n\r\n" not in handshake:
        handshake += connection.recv(4096)
        assert len(handshake) < 8192
    headers = dict(
        line.split(": ", 1)
        for line in handshake.decode().split("\r\n")[1:]
        if ": " in line
    )
    key = headers["Sec-WebSocket-Key"]
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    connection.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    ).encode())

    request = receive_message(connection)
    assert request["method"] == "initialize"
    assert request["params"]["clientInfo"]["name"]
    with open(os.environ["FAKE_RPC_TRACE"], "a", encoding="utf-8") as trace:
        trace.write("initialize\n")
    result = {
        "codexHome": str(Path(os.environ["CODEX_SHARED_HOME"])),
        "platformFamily": "unix",
        "platformOs": "linux",
        "userAgent": "fixture",
    }
    send_message(
        connection,
        {"id": True if scenario == "bool-id" else request["id"],
         "result": None if scenario == "null-initialize" else result},
        0xC1 if scenario == "rsv1" else 0x81,
    )
    assert receive_message(connection)["method"] == "initialized"

    while True:
        request = receive_message(connection)
        with open(os.environ["FAKE_RPC_TRACE"], "a", encoding="utf-8") as trace:
            trace.write(request["method"] + "\n")
        if request["method"] == "thread/loaded/list":
            cursor = request.get("params", {}).get("cursor")
            if scenario == "paged" and cursor is None:
                result = {"data": ["thread-idle"], "nextCursor": "next"}
            elif scenario == "paged":
                assert cursor == "next"
                result = {"data": ["thread-active"], "nextCursor": None}
            elif scenario == "empty":
                result = {"data": [], "nextCursor": None}
            elif scenario == "mixed":
                result = {"data": ["thread-idle", "thread-active"], "nextCursor": None}
            else:
                result = {"data": ["thread-1"], "nextCursor": None}
            send_message(connection, {"id": request["id"], "result": result})
        elif request["method"] == "thread/read":
            assert request["params"]["includeTurns"] is False
            thread_id = request["params"]["threadId"]
            reads[0] += 1
            if scenario == "timeout":
                time.sleep(4)
                return
            if scenario == "error":
                send_message(connection, {"id": request["id"], "error": {"code": -32000, "message": "fixture failure"}})
                return
            state = "active" if scenario == "active" or thread_id == "thread-active" or (scenario == "active-then-idle" and reads[0] == 1) else "unknown" if scenario == "unknown" else "idle"
            if scenario == "identity-change":
                record = Path(os.environ["FAKE_PID_RECORD"])
                record.write_text(record.read_text().replace("12345", "99999"))
            if scenario == "stale-pid" and reads[0] == 1:
                Path(os.environ["FAKE_STALE_OLD_DIR"]).rename(os.environ["FAKE_STALE_NEW_DIR"])
            send_message(connection, {"id": request["id"], "result": {"thread": {"id": thread_id, "status": {"type": state}}}})
        else:
            raise AssertionError(request["method"])


def main():
    path, scenario = sys.argv[1:]
    reads = [0]
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(path)
        listener.listen(1)
        while True:
            with listener.accept()[0] as connection:
                try:
                    serve(connection, scenario, reads)
                except EOFError:
                    pass


if __name__ == "__main__":
    main()
