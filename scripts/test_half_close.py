#!/usr/bin/env python3
"""Reproduce the relay deadlock that strands a client in FIN_WAIT_2.

Usage: test_half_close.py [proxy-host] [proxy-port] [target-host]

curl cannot show this bug because it closes both directions at once. A client that
half-closes -- sends its request, shuts down its write side, then waits for the
response and the peer's FIN -- is the case that deadlocked:

  1. the client's FIN reaches the relay, so its upload copy reaches EOF
  2. the relay never forwards that half-close, so the server keeps the connection
     open and the download copy never ends
  3. the relay waits for both directions before closing anything, so it closes
     nothing, and the client sits in FIN_WAIT_2 until it gives up

A pass means the peer's FIN arrived, i.e. recv() returned b"" before the timeout.
A fail means the socket was stranded.
"""

import socket
import sys
import time

TIMEOUT = 25.0


def attempt(proxy_host, proxy_port, target):
    s = socket.create_connection((proxy_host, proxy_port), timeout=10)
    s.settimeout(TIMEOUT)
    try:
        # A plain proxied GET. Absolute-form request line, so this works against
        # an HTTP proxy without CONNECT.
        # keep-alive is the point. With "Connection: close" the server closes on
        # its own, the download direction ends, and the deadlock never appears --
        # which is why curl and a naive probe both pass against a broken relay.
        req = (
            f"GET http://{target}/ HTTP/1.1\r\n"
            f"Host: {target}\r\n"
            "Connection: keep-alive\r\n"
            "User-Agent: lux-half-close-probe\r\n"
            "\r\n"
        ).encode()
        s.sendall(req)

        # The half-close. This is what curl never does.
        s.shutdown(socket.SHUT_WR)

        start = time.time()
        total = 0
        saw_fin = False
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if chunk == b"":
                saw_fin = True
                break
            total += len(chunk)
            if time.time() - start > TIMEOUT:
                break
        return saw_fin, total, time.time() - start
    finally:
        try:
            s.close()
        except OSError:
            pass


def main():
    proxy_host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    proxy_port = int(sys.argv[2]) if len(sys.argv) > 2 else 1090
    target = sys.argv[3] if len(sys.argv) > 3 else "example.com"

    print(f"# proxy  {proxy_host}:{proxy_port}")
    print(f"# target {target}")
    print(f"# a pass needs the peer's FIN within {TIMEOUT:g}s after a half-close\n")

    failures = 0
    for i in range(3):
        try:
            saw_fin, total, elapsed = attempt(proxy_host, proxy_port, target)
        except OSError as e:
            print(f"attempt {i + 1}: connection error: {e}")
            failures += 1
            continue

        if saw_fin:
            print(f"attempt {i + 1}: ok    bytes={total} fin_after={elapsed:.1f}s")
        else:
            print(f"attempt {i + 1}: FAIL  bytes={total} no FIN after {elapsed:.1f}s"
                  f"  <-- stranded, relay never closed the peer")
            failures += 1

    print()
    if failures:
        print(f"FAIL: {failures}/3 half-closed requests were stranded")
        return 1
    print("PASS: every half-closed request received the peer's FIN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
