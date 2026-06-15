"""End-to-end tests for the SOCKS5 / HTTP CONNECT client handshakes in
stratum_miner.py. We spin up a tiny mock proxy server in a thread, point
_connect_via_proxy at it, then echo a JSON line through the tunnel to
prove the client succeeded and the byte stream is intact.

stdlib-only, runnable via:  python3 tests/test_proxy.py
"""
from __future__ import annotations

import os
import socket
import struct
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "src"))

from stratum_miner import (  # noqa: E402
    ProxyConfig,
    _connect_via_proxy,
    parse_proxy_url,
)


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError(f"want {n}, got {len(buf)}")
        buf += chunk
    return buf


def _bind_loopback() -> tuple[socket.socket, int]:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    return s, s.getsockname()[1]


def _origin_server(*, expect_user: str | None = None) -> tuple[int, threading.Event]:
    """A trivial 'pool' that, on connect, expects one JSON line, replies with
    'pong\\n' and exits. Returns (port, ready_event). Used as the *target*
    behind our mock proxy."""
    listener, port = _bind_loopback()
    ready = threading.Event()

    def run() -> None:
        ready.set()
        try:
            conn, _ = listener.accept()
        finally:
            listener.close()
        try:
            line = b""
            while not line.endswith(b"\n"):
                ch = conn.recv(1024)
                if not ch:
                    break
                line += ch
            conn.sendall(b"pong " + line)
        finally:
            conn.close()

    threading.Thread(target=run, daemon=True).start()
    return port, ready


def _socks5_proxy(*, require_auth: bool = False,
                  user: str = "u", password: str = "p") -> tuple[int, threading.Event]:
    listener, port = _bind_loopback()
    ready = threading.Event()

    def serve() -> None:
        ready.set()
        conn, _ = listener.accept()
        listener.close()
        try:
            ver, nm = _recv_exact(conn, 2)
            assert ver == 0x05, f"bad SOCKS version {ver:#x}"
            methods = set(_recv_exact(conn, nm))
            chosen = 0x02 if require_auth else 0x00
            assert chosen in methods, f"client didn't offer method {chosen:#x}"
            conn.sendall(bytes([0x05, chosen]))
            if chosen == 0x02:
                v = _recv_exact(conn, 1)[0]
                assert v == 0x01, f"bad auth version {v:#x}"
                ulen = _recv_exact(conn, 1)[0]
                u = _recv_exact(conn, ulen).decode()
                plen = _recv_exact(conn, 1)[0]
                p = _recv_exact(conn, plen).decode()
                if u == user and p == password:
                    conn.sendall(bytes([0x01, 0x00]))
                else:
                    conn.sendall(bytes([0x01, 0x01]))
                    return
            v, cmd, rsv, atyp = _recv_exact(conn, 4)
            assert v == 0x05 and cmd == 0x01 and rsv == 0x00
            if atyp == 0x03:
                ln = _recv_exact(conn, 1)[0]
                tgt_host = _recv_exact(conn, ln).decode()
            elif atyp == 0x01:
                tgt_host = ".".join(str(b) for b in _recv_exact(conn, 4))
            else:
                raise AssertionError(f"unsupported ATYP {atyp:#x}")
            tgt_port = struct.unpack(">H", _recv_exact(conn, 2))[0]

            upstream = socket.create_connection((tgt_host, tgt_port), timeout=5)
            conn.sendall(bytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))

            stop = threading.Event()
            def pump(a, b):
                try:
                    while not stop.is_set():
                        d = a.recv(4096)
                        if not d:
                            break
                        b.sendall(d)
                except OSError:
                    pass
                finally:
                    try: b.shutdown(socket.SHUT_WR)
                    except OSError: pass
            t1 = threading.Thread(target=pump, args=(conn, upstream), daemon=True)
            t2 = threading.Thread(target=pump, args=(upstream, conn), daemon=True)
            t1.start(); t2.start()
            t1.join(timeout=5); t2.join(timeout=5)
            stop.set()
            try: upstream.close()
            except OSError: pass
        finally:
            try: conn.close()
            except OSError: pass

    threading.Thread(target=serve, daemon=True).start()
    return port, ready


def _http_proxy(*, require_auth: bool = False,
                user: str = "u", password: str = "p") -> tuple[int, threading.Event]:
    listener, port = _bind_loopback()
    ready = threading.Event()

    def serve() -> None:
        ready.set()
        conn, _ = listener.accept()
        listener.close()
        try:
            buf = b""
            while b"\r\n\r\n" not in buf:
                ch = conn.recv(4096)
                if not ch:
                    return
                buf += ch
            head, _, _rest = buf.partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            request = lines[0].decode()
            assert request.startswith("CONNECT "), f"bad request {request!r}"
            hostport = request.split(" ")[1]
            tgt_host, tgt_port_s = hostport.rsplit(":", 1)
            tgt_port = int(tgt_port_s)
            if require_auth:
                auth_ok = any(
                    line.lower().startswith(b"proxy-authorization: basic ")
                    for line in lines[1:]
                )
                if not auth_ok:
                    conn.sendall(b"HTTP/1.1 407 Proxy Auth Required\r\n\r\n")
                    return

            upstream = socket.create_connection((tgt_host, tgt_port), timeout=5)
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

            stop = threading.Event()
            def pump(a, b):
                try:
                    while not stop.is_set():
                        d = a.recv(4096)
                        if not d:
                            break
                        b.sendall(d)
                except OSError:
                    pass
                finally:
                    try: b.shutdown(socket.SHUT_WR)
                    except OSError: pass
            t1 = threading.Thread(target=pump, args=(conn, upstream), daemon=True)
            t2 = threading.Thread(target=pump, args=(upstream, conn), daemon=True)
            t1.start(); t2.start()
            t1.join(timeout=5); t2.join(timeout=5)
            stop.set()
            try: upstream.close()
            except OSError: pass
        finally:
            try: conn.close()
            except OSError: pass

    threading.Thread(target=serve, daemon=True).start()
    return port, ready


def _ping_via_proxy(proxy: ProxyConfig, target_port: int) -> bytes:
    sock = _connect_via_proxy(proxy, "127.0.0.1", target_port, timeout=5.0)
    try:
        sock.settimeout(5.0)
        sock.sendall(b'{"hello":1}\n')
        data = b""
        while True:
            ch = sock.recv(4096)
            if not ch:
                break
            data += ch
        return data
    finally:
        sock.close()


def case(name, fn):
    try:
        fn()
        print(f"  PASS  {name}")
    except Exception as e:
        print(f"  FAIL  {name}: {type(e).__name__}: {e}")
        raise


def test_socks5_no_auth():
    origin_port, origin_ready = _origin_server()
    origin_ready.wait(2.0)
    proxy_port, proxy_ready = _socks5_proxy()
    proxy_ready.wait(2.0)
    cfg = parse_proxy_url(f"socks5://127.0.0.1:{proxy_port}")
    data = _ping_via_proxy(cfg, origin_port)
    assert data == b'pong {"hello":1}\n', f"unexpected {data!r}"


def test_socks5_with_auth():
    origin_port, origin_ready = _origin_server()
    origin_ready.wait(2.0)
    proxy_port, proxy_ready = _socks5_proxy(require_auth=True, user="alice", password="s3cret")
    proxy_ready.wait(2.0)
    cfg = parse_proxy_url(f"socks5://alice:s3cret@127.0.0.1:{proxy_port}")
    data = _ping_via_proxy(cfg, origin_port)
    assert data == b'pong {"hello":1}\n', f"unexpected {data!r}"


def test_http_connect_no_auth():
    origin_port, origin_ready = _origin_server()
    origin_ready.wait(2.0)
    proxy_port, proxy_ready = _http_proxy()
    proxy_ready.wait(2.0)
    cfg = parse_proxy_url(f"http://127.0.0.1:{proxy_port}")
    data = _ping_via_proxy(cfg, origin_port)
    assert data == b'pong {"hello":1}\n', f"unexpected {data!r}"


def test_http_connect_with_auth():
    origin_port, origin_ready = _origin_server()
    origin_ready.wait(2.0)
    proxy_port, proxy_ready = _http_proxy(require_auth=True, user="bob", password="hunter2")
    proxy_ready.wait(2.0)
    cfg = parse_proxy_url(f"http://bob:hunter2@127.0.0.1:{proxy_port}")
    data = _ping_via_proxy(cfg, origin_port)
    assert data == b'pong {"hello":1}\n', f"unexpected {data!r}"


def main() -> int:
    print("running proxy handshake tests ...")
    case("SOCKS5 no auth          ", test_socks5_no_auth)
    case("SOCKS5 user/pass        ", test_socks5_with_auth)
    case("HTTP CONNECT no auth    ", test_http_connect_no_auth)
    case("HTTP CONNECT user/pass  ", test_http_connect_with_auth)
    print("all proxy tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
