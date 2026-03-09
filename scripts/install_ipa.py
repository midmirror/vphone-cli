#!/usr/bin/env python3
"""Install an IPA/TIPA into a running vphone VM.

Usage:
    python3 scripts/install_ipa.py <socket_path> <ipa_path>

The socket is created by vphone-cli at {vm_dir}/.vphone.sock when the VM boots.
Protocol: length-prefixed JSON  [uint32 big-endian length][UTF-8 JSON]
"""

import json
import os
import socket
import struct
import sys

CONNECT_TIMEOUT = 5      # seconds
INSTALL_TIMEOUT = 180    # seconds — upload + install can take a while


def _send(sock: socket.socket, payload: bytes) -> None:
    header = struct.pack(">I", len(payload))
    sock.sendall(header + payload)


def _recv(sock: socket.socket) -> dict:
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("connection closed while reading header")
        header += chunk

    length = struct.unpack(">I", header)[0]
    if length == 0 or length > 4 * 1024 * 1024:
        raise ValueError(f"invalid message length: {length}")

    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise ConnectionError("connection closed while reading body")
        body += chunk

    return json.loads(body.decode("utf-8"))


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <socket_path> <ipa_path>", file=sys.stderr)
        return 1

    socket_path = sys.argv[1]
    ipa_path = os.path.abspath(sys.argv[2])

    if not os.path.exists(socket_path):
        print(
            f"[install] VM not running or socket not found: {socket_path}",
            file=sys.stderr,
        )
        return 1

    if not os.path.isfile(ipa_path):
        print(f"[install] IPA file not found: {ipa_path}", file=sys.stderr)
        return 1

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(CONNECT_TIMEOUT)
            try:
                sock.connect(socket_path)
            except (ConnectionRefusedError, FileNotFoundError):
                print(
                    f"[install] VM not running or socket not found: {socket_path}",
                    file=sys.stderr,
                )
                return 1

            # Send install command
            cmd = json.dumps({"t": "ipa_install", "path": ipa_path}).encode("utf-8")
            _send(sock, cmd)
            print(f"[install] installing {os.path.basename(ipa_path)} ...")

            # Wait for result (install can be slow)
            sock.settimeout(INSTALL_TIMEOUT)
            resp = _recv(sock)

        if resp.get("ok"):
            msg = resp.get("msg", "done")
            print(f"[install] {msg}")
            return 0
        else:
            err = resp.get("error", "unknown error")
            print(f"[install] Error: {err}", file=sys.stderr)
            return 1

    except TimeoutError:
        print(
            f"[install] Error: timed out waiting for install to complete "
            f"(>{INSTALL_TIMEOUT}s)",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"[install] Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
