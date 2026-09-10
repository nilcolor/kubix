#!/usr/bin/env python3
"""Bounded local smoke of the one app executable's pre-AppKit relay entry.

Run after make build. Only synthetic environment values, owned PTYs and Unix sockets
are used. This is not the future bridge server or an application control interface.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import termios
import time


ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/DerivedData/Build/Products/Debug/kubix.app/Contents/MacOS/kubix"
WORK = ROOT / f".build/p-{os.getpid()}"
NONCE = bytes(range(32))
GENERIC = b"kubix: The terminal connection failed.\n"
ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": str(WORK),
    "TMPDIR": str(ROOT / ".build/tmp"),
    "KUBIX_TERMINAL_SMOKE_DIRECTORY": str(WORK / "unexpected-app-init"),
}


def frame(kind, payload=b""):
    return struct.pack(">BI", kind, len(payload)) + payload


def read_exact(fd, count):
    result = bytearray()
    deadline = time.monotonic() + 5
    while len(result) < count:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([fd], [], [], remaining)[0], "read deadline"
        part = os.read(fd, count - len(result))
        assert part, "unexpected EOF"
        result.extend(part)
    return bytes(result)


def read_frame(peer):
    kind, length = struct.unpack(">BI", read_exact(peer.fileno(), 5))
    assert length <= 65536, "unbounded frame"
    return kind, read_exact(peer.fileno(), length)


def stop_owned(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=4)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=4)


def entry_case(name, terminal_frame=None, cancel_signal=None, close_peer=False, broken_output=False):
    path = WORK / f"{name}.sock"
    assert len(os.fsencode(path)) + 1 <= 104
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.settimeout(5)
    peer = None
    child = None
    controller, terminal = pty.openpty()
    original = termios.tcgetattr(terminal)
    try:
        fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen(1)
        environment = dict(ENV, KUBIX_BRIDGE_SOCK=str(path), KUBIX_BRIDGE_NONCE=NONCE.hex())
        child = subprocess.Popen(
            [str(APP), "--pty-bridge"], stdin=terminal,
            stdout=subprocess.PIPE if broken_output else terminal, stderr=subprocess.PIPE, env=environment,
        )
        peer, _ = listener.accept()
        peer.settimeout(5)
        assert read_frame(peer) == (1, NONCE)
        assert read_frame(peer) == (3, struct.pack(">HH", 80, 24))
        raw = termios.tcgetattr(terminal)
        assert raw[3] & (termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN) == 0
        assert raw[1] & termios.OPOST == 0
        registration = subprocess.run(
            ["/usr/bin/lsappinfo", "find", f"pid={child.pid}"],
            capture_output=True, text=True, timeout=5, env=ENV, check=True,
        )
        assert "ASN:" not in registration.stdout, "relay registered as a GUI application"
        for byte in [b"x", b"\x03", b"\x04", b"\r", b"\n", b"\x00", b"\xff"]:
            os.write(controller, byte)
            assert read_frame(peer) == (2, byte), "input requires Enter or was translated"
        assert not select.select([controller], [], [], 0.05)[0], "local echo"
        fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 41, 123, 0, 0))
        child.send_signal(signal.SIGWINCH)
        assert read_frame(peer) == (3, struct.pack(">HH", 123, 41))
        output = b"raw-output\n\r\x00\xff\x03\x04"
        if broken_output:
            child.stdout.close()
        peer.sendall(frame(2, output))
        if not broken_output:
            assert read_exact(controller, len(output)) == output
        if terminal_frame:
            peer.sendall(terminal_frame)
        if close_peer:
            peer.close()
            peer = None
        if cancel_signal:
            child.send_signal(cancel_signal)
        status = child.wait(timeout=5)
        diagnostic = child.stderr.read()
        child.stderr.close()
        assert termios.tcgetattr(terminal) == original, "termios not exactly restored"
        assert NONCE.hex().encode() not in diagnostic and str(path).encode() not in diagnostic
        assert len(diagnostic) <= 136
        assert not (WORK / "unexpected-app-init").exists(), "entered GUI/native-smoke initialization"
        if terminal_frame and terminal_frame[0] == 5 and not broken_output:
            assert status == terminal_frame[-1] and diagnostic == b""
        else:
            assert status == 74
            expected = b"kubix: The terminal session was cancelled.\n" if cancel_signal else GENERIC
            if terminal_frame and terminal_frame[0] == 6:
                expected = b"kubix: The terminal session failed.\n"
            assert diagnostic == expected, (name, status, diagnostic)
        return {"case": name, "status": status, "pid": child.pid, "restored": True, "gui_registered": False}
    finally:
        if child:
            stop_owned(child)
            if child.stderr and not child.stderr.closed:
                child.stderr.close()
        if peer:
            peer.close()
        listener.close()
        os.close(controller)
        os.close(terminal)
        if path.exists():
            path.unlink()


def main():
    assert APP.is_file(), "Run make build first"
    WORK.mkdir(mode=0o700)
    reports = []
    try:
        for arguments, environment, expected, message in [
            (["--unknown"], ENV, 64, b"usage: kubix [--pty-bridge]\n"),
            (["--pty-bridge", "--unknown"], ENV, 64, b"usage: kubix [--pty-bridge]\n"),
            (["--pty-bridge"], ENV, 74, GENERIC),
            (["--pty-bridge"], dict(ENV, KUBIX_BRIDGE_SOCK="/synthetic/socket",
                                   KUBIX_BRIDGE_NONCE="synthetic-invalid-nonce"), 74, GENERIC),
            (["--pty-bridge"], dict(ENV, KUBIX_BRIDGE_SOCK="/synthetic/socket",
                                   KUBIX_BRIDGE_NONCE=NONCE.hex()), 74, GENERIC),
        ]:
            child = subprocess.run([str(APP)] + arguments, stdin=subprocess.DEVNULL,
                                   capture_output=True, env=environment, timeout=5)
            assert (child.returncode, child.stdout, child.stderr) == (expected, b"", message)
        reports.append({"case": "argument-environment-and-no-TTY-validation", "checks": 5})
        reports.append(entry_case("exit-zero", frame(5, b"\x00")))
        reports.append(entry_case("exit-37", frame(5, b"\x25")))
        reports.append(entry_case("failure", frame(6, b"The terminal session failed.")))
        reports.append(entry_case("eof", close_peer=True))
        reports.append(entry_case("truncated-eof", frame(2, b"partial")[:-2], close_peer=True))
        reports.append(entry_case("sigterm", cancel_signal=signal.SIGTERM))
        reports.append(entry_case("sighup", cancel_signal=signal.SIGHUP))
        reports.append(entry_case("sigint", cancel_signal=signal.SIGINT))
        reports.append(entry_case("broken-output", broken_output=True))
        evidence = ROOT / ".build/validation/task10-entry.json"
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text(json.dumps({"result": "passed", "cases": reports}, indent=2) + "\n")
        print(f"PASS: actual --pty-bridge entry; {len(reports) - 1} PTY sessions + 5 validation cases")
        print(f"Evidence: {evidence}; every owned child exited; no GUI registration")
    finally:
        WORK.rmdir()


if __name__ == "__main__":
    main()
