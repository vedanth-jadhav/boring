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
        chunk = os.read(stream.fileno(), length - len(result))
        if not chunk:
            return None
        result.extend(chunk)
    return bytes(result)

def report(reason):
    print("Octave native bridge: " + reason, file=sys.stderr, flush=True)

def write_exact(stream, data):
    view = memoryview(data)
    while view:
        try:
            count = os.write(stream.fileno(), view)
        except InterruptedError:
            continue
        if count <= 0:
            raise OSError("native messaging output stopped accepting bytes")
        view = view[count:]

def main():
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(SOCKET)
    pending = bytearray()
    while True:
        readable, _, _ = select.select([sys.stdin.buffer, connection], [], [])
        if sys.stdin.buffer in readable:
            header = read_exact(sys.stdin.buffer, 4)
            if header is None:
                report("browser closed native messaging input")
                return
            size = struct.unpack("<I", header)[0]
            if size > 1024 * 1024:
                report("browser message exceeded 1 MB")
                return
            body = read_exact(sys.stdin.buffer, size)
            if body is None:
                report("browser message ended before its declared size")
                return
            connection.sendall(body + b"\n")
        if connection in readable:
            data = connection.recv(65536)
            if not data:
                report("app closed its socket")
                return
            pending.extend(data)
            while b"\n" in pending:
                line, _, pending = pending.partition(b"\n")
                if line:
                    write_exact(sys.stdout.buffer, struct.pack("<I", len(line)) + line)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        report(f"transport failure: {type(error).__name__}, errno={getattr(error, 'errno', None)}")
