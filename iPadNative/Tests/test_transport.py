"""Exercise the compiled Swift LAN server with TouchBridge's wire format."""
import base64
import hashlib
import hmac
import json
import socket
import struct
import subprocess
import sys
import time

def recv(sock):
    def exact(length):
        data = b""
        while len(data) < length:
            chunk = sock.recv(length-len(data))
            if not chunk:
                return None
            data += chunk
        return data
    header = exact(4)
    return json.loads(exact(struct.unpack("!I", header)[0])) if header else None

def send(sock, message, fragmented=False):
    body = json.dumps(message, ensure_ascii=False).encode()
    packet = struct.pack("!I", len(body)) + body
    if fragmented:
        for part in [packet[:2], packet[2:11], packet[11:]]:
            sock.sendall(part)
    else:
        sock.sendall(packet)

process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, text=True)
try:
    code = process.stdout.readline().strip()
    assert code.startswith("TB1-"), code
    invite = json.loads(base64.urlsafe_b64decode(code[4:]+"="*(-len(code[4:]) % 4)))
    assert invite["format"] == "TouchBridge/1" and invite["network"] == "lan"
    key = invite["key"].encode()

    def connect(**fields):
        sock = socket.create_connection(("127.0.0.1", 8798), timeout=5)
        sock.settimeout(5)
        challenge = recv(sock)
        assert challenge["type"] == "auth_challenge" and len(challenge["nonce"]) == 64
        proof = hmac.new(key, (challenge["nonce"]+"|controller|测试").encode(), hashlib.sha256).hexdigest()
        hello = dict(type="hello", role="controller", name="测试", proof=proof)
        hello.update(fields)
        send(sock, hello, fragmented=True)
        return sock, recv(sock)

    unauthorized, reply = connect(proof="0"*64)
    assert reply is None; unauthorized.close()
    control, welcome = connect()
    assert "touch_events" in welcome["features"]
    assert welcome["peers"][0]["features"] == ["touch_events"]
    other, reply = connect()
    assert reply is None; other.close()
    media, reply = connect(channel="media", parent_id=welcome["client_id"], media_key=welcome["media_key"])
    assert reply == {"type": "welcome", "channel": "media"}

    def touch(phase, gesture="gesture", seq=1, **fields):
        message = dict(type="touch", phase=phase, gesture_id=gesture, seq=seq, sent_at=123.5, x=.2, y=.3)
        message.update(fields); send(control, message); return recv(control)

    assert not touch("move")["ok"]
    assert not touch("down", x=1)["ok"]
    send(control, dict(type="frame_request", sent_at=321.5, accept_jpeg=True))
    started = time.monotonic()
    assert touch("down")["ok"]
    assert not touch("move", gesture="foreign", seq=2)["ok"]
    assert not touch("move", seq=1)["ok"]
    assert touch("move", seq=2)["ok"]
    assert touch("hold", seq=3)["ok"]
    assert touch("up", seq=4)["ok"]
    assert time.monotonic()-started < .8, "screenshot delayed touch acknowledgements"
    assert recv(media)["sent_at"] == 321.5
    send(control, dict(type="latency_probe", sent_at=9.25, probe_id="id"))
    assert recv(control) == dict(type="latency_result", sent_at=9.25, probe_id="id")
    assert touch("down", gesture="timeout")["ok"]
    reply = recv(control)
    assert reply["phase"] == "cancel" and reply["gesture_id"] == "timeout" and not reply["ok"]
    assert not touch("up", gesture="timeout", seq=2)["ok"]
    assert touch("down", gesture="disconnect")["ok"]
    control.close(); assert recv(media) is None; media.close()
    time.sleep(.15)
    control, welcome = connect()
    assert touch("down", gesture="new-session")["ok"]
    assert touch("cancel", gesture="new-session", seq=2)["ok"]
    control.close()
    print("PASS: invitation, HMAC, fragmented frames, exclusive controller, media binding, input ordering, screenshot separation, timeout and disconnect cleanup")
finally:
    process.terminate()
    process.wait(timeout=5)
