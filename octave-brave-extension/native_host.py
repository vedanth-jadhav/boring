#!/usr/bin/env python3
"""Native Messaging framing to the local Boring Notch Unix socket."""
import json
import os
import select
import socket
import struct
import sys

SOCKET = os.path.expanduser("~/Library/Application Support/BoringNotchLocal/octave.sock")

def read_exact(stream, length):
    result = bytearray()
    while len(result) < length:
        chunk = stream.read(length - len(result))
        if not chunk:
            return None
        result.extend(chunk)
    return bytes(result)

def main():
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(SOCKET)
    pending = bytearray()
    while True:
        readable, _, _ = select.select([sys.stdin.buffer, connection], [], [])
        if sys.stdin.buffer in readable:
            header = read_exact(sys.stdin.buffer, 4)
            if header is None:
                return
            size = struct.unpack("<I", header)[0]
            if size > 1024 * 1024:
                return
            body = read_exact(sys.stdin.buffer, size)
            if body is None:
                return
            connection.sendall(body + b"\n")
        if connection in readable:
            data = connection.recv(65536)
            if not data:
                return
            pending.extend(data)
            while b"\n" in pending:
                line, _, pending = pending.partition(b"\n")
                if line:
                    sys.stdout.buffer.write(struct.pack("<I", len(line)) + line)
                    sys.stdout.buffer.flush()

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        pass
