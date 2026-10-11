"""Writes crypto.json, wire.json, relay.json and messages.json next to this folder.

These are computed from the written spec in docs/protocol.md, not exported from Swift. Values copied from the Swift
tests carry source "swift-test"; everything else carries "computed" until SPEC-010 confirms it against Swift.
"""
import base64, hashlib, hmac, json, os, struct
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
hx = lambda b: b.hex()
def write(name, obj):
    with open(os.path.join(HERE, name), "w") as f:
        json.dump(obj, f, indent=1); f.write("\n")

def frame(kind, payload=b""):
    return struct.pack(">IB", len(payload) + 1, kind) + payload

def put(b): return struct.pack(">I", len(b)) + b

def transcript(version, cid, sid, ce, se, cn, sn, ident):
    return (put(b"MacCast-Pairing-SAS-v1") + put(struct.pack(">H", version)) + put(cid.encode()) + put(sid.encode())
            + put(ce) + put(se) + put(cn) + put(sn) + put(ident))

def sas(t):
    d = hashlib.sha256(t).digest()
    return "%06d" % (int.from_bytes(d[:4], "big") % 1_000_000)

def commitment(eph, nonce):
    return hashlib.sha256(b"MacCast-Pairing-commit-v1" + eph + nonce).digest()

# ---------------------------------------------------------------- crypto
ce, se, cn, sn, ident = b"\xA1" * 65, b"\xB2" * 65, b"\xC3" * 32, b"\xD4" * 32, b"\xE5" * 65
t = transcript(1, "iphone-15-pro-max", "mac-studio-01", ce, se, cn, sn, ident)
assert sas(t) == "365357", sas(t)
secret16 = bytes(range(16))
proof = hmac.new(secret16, b"MacCast-Pairing-proof-v1" + t, hashlib.sha256).digest()

video_secret = bytes((i * 31 + 7) & 0xFF for i in range(32))
def key(label):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=b"pl.dmq.peering.video-datagram", info=label.encode()).derive(video_secret)
k_c2h, k_h2c = key("video client-to-host"), key("video host-to-client")
token = bytes((i * 7 + 1) & 0xFF for i in range(16))
def seal(k, counter, plaintext):
    nonce = b"\0\0\0\0" + struct.pack(">Q", counter)
    return struct.pack(">Q", counter) + ChaCha20Poly1305(k).encrypt(nonce, plaintext, None)
ping_plain = frame(0x0B, b'{"sequence":1}')
sealed = seal(k_h2c, 1, ping_plain)

priv = ec.derive_private_key(int.from_bytes(hashlib.sha256(b"peering-test-key").digest(), "big"), ec.SECP256R1())
point = priv.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
msg = b"peeringd-host-registration-v1\nA1B2C3D4-0000-4000-8000-000000000001\n1760000000"
sig = priv.sign(msg, ec.ECDSA(hashes.SHA256()))

write("crypto.json", {
  "source": "computed; hkdf, commitment and sealedDatagram were confirmed against Apple CryptoKit on 2026-10-11, the sas code is from a Swift test",
  "sas": {"source": "swift-test PairingSASTests.swift:56 for the code; bytes computed",
          "protocolVersion": 1, "clientID": "iphone-15-pro-max", "serverID": "mac-studio-01",
          "clientEphemeral": hx(ce), "serverEphemeral": hx(se), "clientNonce": hx(cn), "serverNonce": hx(sn),
          "serverIdentity": hx(ident), "transcript": hx(t), "code": "365357"},
  "commitment": {"ephemeral": hx(ce), "nonce": hx(cn), "commitment": hx(commitment(ce, cn))},
  "proof": {"secret": hx(secret16), "transcript": hx(t), "proof": hx(proof)},
  "hkdf": {"secret": hx(video_secret), "salt": "pl.dmq.peering.video-datagram",
           "clientToHostKey": hx(k_c2h), "hostToClientKey": hx(k_h2c)},
  "sealedDatagram": {"direction": "hostToClient", "token": hx(token), "counter": 1, "plaintextFrame": hx(ping_plain),
                     "afterRelay": hx(sealed), "asSent": hx(token + sealed)},
  "replayWindow": {"size": 64, "steps": [
      {"counter": 5, "accepts": True, "commit": True},
      {"counter": 5, "accepts": False},
      {"counter": 3, "accepts": True, "commit": True},
      {"counter": 3, "accepts": False},
      {"counter": 70, "accepts": True, "commit": True},
      {"counter": 5, "accepts": False},
      {"counter": 7, "accepts": True, "commit": False},
      {"counter": 7, "accepts": True, "commit": True},
      {"counter": 8, "accepts": True, "commit": False},
      {"counter": 6, "accepts": False}],
      "note": "accepts is the non-mutating check; commit says whether the datagram then authenticated and was committed. 5 is 65 behind 70, so it is refused."},
  "ecdsa": {"publicKey": hx(point), "message": msg.decode(), "derSignature": hx(sig), "hash": "sha256"},
  "relayProofPayloads": {
      "host": "peeringd-host-registration-v1\nDEV\n1760000000",
      "client": "peeringd-client-registration-v1\nCLI\n1760000000",
      "referralStatus": "peeringd-referral-v1\nstatus\nCLI\n1760000000",
      "referralRedeem": "peeringd-referral-v1\nredeem:ABCD\nCLI\n1760000000"},
})
# ---------------------------------------------------------------- wire
def video_frame(key_, w, h, v, ts, data):
    return struct.pack(">BIIqiI", 1 if key_ else 0, w, h, v, ts, len(data)) + data
vf = video_frame(True, 1920, 1080, 90000, 90000, b"\x00\x00\x00\x02\x65\x88")
payload = bytes(i % 251 for i in range(2500))
def chunks(kind, pl, fid, size):
    n = (len(pl) + size - 1) // size
    return [frame(0x17, bytes([kind]) + struct.pack(">IHH", fid, i, n) + pl[i * size:(i + 1) * size]) for i in range(n)]
c1 = chunks(0x0A, payload, 7, 1024)
c2 = chunks(0x0A, payload[:1500], 8, 1024)
audio = struct.pack(">IIqi", 2, 2, 44100, 44100) + struct.pack("<ffff", 0.5, -0.5, 0.25, -0.25)
write("wire.json", {
  "source": "computed",
  "frames": [
    {"name": "role control", "kind": 1, "payload": "01", "bytes": hx(frame(1, b"\x01"))},
    {"name": "ping", "kind": 11, "payload": hx(b'{"sequence":1}'), "bytes": hx(frame(0x0B, b'{"sequence":1}'))},
    {"name": "empty videoKeyRequest", "kind": 25, "payload": "", "bytes": hx(frame(0x19))}],
  "decoderSplit": {"description": "feed these hex chunks in order; expect the listed frames after each feed",
     "feeds": [hx(frame(1, b"\x01")[:3]), hx(frame(1, b"\x01")[3:] + frame(0x0B, b"{}")[:4]), hx(frame(0x0B, b"{}")[4:])],
     "framesAfterEachFeed": [[], [{"kind": 1, "payload": "01"}], [{"kind": 11, "payload": "7b7d"}]]},
  "decoderErrors": [
    {"name": "zero length", "bytes": "00000000", "error": "zeroLength"},
    {"name": "too large", "bytes": "01000001" + "00", "error": "tooLarge"},
    {"name": "unknown kind", "bytes": hx(struct.pack(">IB", 1, 0x7F)), "error": "unknownKind"}],
  "videoFrame": {"keyframe": True, "width": 1920, "height": 1080, "ptsValue": 90000, "ptsTimescale": 90000,
                 "data": hx(b"\x00\x00\x00\x02\x65\x88"), "bytes": hx(vf), "headerSize": 25},
  "videoFrameErrors": [{"name": "length mismatch", "bytes": hx(vf[:-1]), "error": "lengthMismatch"},
                       {"name": "truncated header", "bytes": hx(vf[:10]), "error": "truncatedHeader"}],
  "audioFrame": {"sampleCount": 2, "channelCount": 2, "ptsValue": 44100, "ptsTimescale": 44100, "bytes": hx(audio)},
  "chunks": {"description": "payload is bytes i % 251 for i in 0..2500; chunk size 1024",
             "payloadLength": 2500, "innerKind": 10, "frameID": 7, "pieces": [hx(c) for c in c1],
             "reassembleOrders": {"inOrder": [0, 1, 2], "reversed": [2, 1, 0]},
             "lossCase": {"deliver": [0, 2], "expectComplete": False},
             "newerFrame": {"frameID": 8, "payloadLength": 1500, "pieces": [hx(c) for c in c2],
                            "scenario": "deliver piece 0 of frame 7, then all of frame 8: only frame 8 completes"}},
})

# ---------------------------------------------------------------- relay
def js(o): return json.dumps(o, sort_keys=True, separators=(",", ":"))
write("relay.json", {
  "source": "computed from RelayProtocolTests.swift literals and protocol.rs",
  "clientMessages": [
    {"name": "registerHost", "json": js({"type": "registerHost", "deviceId": "mac-1", "name": "Studio", "protocolVersion": 3})},
    {"name": "connectToHost free", "json": js({"type": "connectToHost", "hostId": "mac-1", "clientId": "phone-1", "protocolVersion": 3})},
    {"name": "connectToHost plan", "json": js({"type": "connectToHost", "hostId": "mac-1", "clientId": "phone-1", "plan": "relay", "protocolVersion": 3})},
    {"name": "ping", "json": js({"type": "ping"})},
    {"name": "requestPeerAddress", "json": js({"type": "requestPeerAddress", "videoToken": "000102030405060708090a0b0c0d0e0f"})},
    {"name": "hostPresence", "json": js({"type": "hostPresence", "hostId": "mac-1"})},
    {"name": "notifyDevice", "json": js({"type": "notifyDevice", "deviceToken": "ab" * 32, "title": "t", "body": "b"})}],
  "serverMessages": [
    {"name": "sessionReady", "json": '{"type":"sessionReady","controlHost":"relay.getpeering.app","controlPort":20190,"videoHost":"relay.getpeering.app","videoPort":30190,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"}'},
    {"name": "registered", "json": js({"type": "registered", "sessionTtlSeconds": 300})},
    {"name": "hostOffline", "json": js({"type": "hostOffline", "deviceId": "mac-1"})},
    {"name": "peerAddress", "json": js({"type": "peerAddress", "host": "203.0.113.5", "port": 40000})},
    {"name": "hostPresence", "json": js({"type": "hostPresence", "hostId": "mac-1", "online": True})},
    {"name": "pong", "json": js({"type": "pong"})},
    {"name": "error", "json": js({"type": "error", "code": "quotaExceeded", "message": "relay allowance exhausted for this period"})}],
  "tokens": {"valid": ["000102030405060708090a0b0c0d0e0f", "FFFEFDFCFBFAF9F8F7F6F5F4F3F2F1F0"],
             "invalid": ["", "0001", "+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1", "000102030405060708090a0b0c0d0e0g", "000102030405060708090a0b0c0d0e0f00"]},
})

# ---------------------------------------------------------------- messages
def cmd(o): return {"json": js(o)}
msgs = [
 ("clientHello", 0x02, {"clientID": "c-1", "clientName": "iPhone", "protocolVersion": 20, "wantsPairing": False}, "swift-test HandshakeTests.swift:179"),
 ("clientHello flags", 0x02, {"clientID": "c-1", "clientName": "Pixel", "protocolVersion": 20, "wantsPairing": True, "supportsAgentChat": True, "lostPairing": True}, "computed"),
 ("serverHello minimal", 0x03, {"serverID": "server-1", "hostName": "Mac", "protocolVersion": 20, "alreadyPaired": True}, "swift-test HandshakeTests.swift:100"),
 ("serverHello flags", 0x03, {"serverID": "server-1", "hostName": "PC", "protocolVersion": 20, "alreadyPaired": False, "supportsVideoPause": True, "agentChatAgents": ["claude"]}, "computed"),
 ("pairCommit", 0x0E, {"commitment": base64.b64encode(b"\x01" * 32).decode()}, "computed"),
 ("pairReveal", 0x0F, {"ephemeralPublicKey": base64.b64encode(b"\x04" + b"\x02" * 64).decode(), "nonce": base64.b64encode(b"\x03" * 32).decode()}, "computed"),
 ("pairConfirm proof", 0x04, {"accepted": True, "proof": base64.b64encode(b"\x09" * 32).decode()}, "computed"),
 ("pairResult refused", 0x05, {"accepted": False, "reason": "The codes did not match."}, "computed"),
 ("error hostStopped", 0x0D, {"code": "hostStopped", "message": "stopped"}, "computed"),
 ("notice", 0x10, {"message": "The screen is asleep", "symbol": "moon"}, "computed"),
 ("command mouseMove", 0x06, {"mouseMove": {"to": {"x": 0.5, "y": 0.25}}}, "computed"),
 ("command mouseDown", 0x06, {"mouseDown": {"button": 0}}, "computed"),
 ("command scroll", 0x06, {"scroll": {"dx": 0, "dy": -12.5}}, "computed"),
 ("command keyDown", 0x06, {"keyDown": {"keyCode": 36, "modifiers": 1048576}}, "computed"),
 ("command textInput", 0x06, {"textInput": {"_0": "hello"}}, "computed"),
 ("command setVideoEnabled", 0x06, {"setVideoEnabled": {"_0": False}}, "swift-test ProtocolModelTests.swift:341"),
 ("command setStreamQuality", 0x06, {"setStreamQuality": {"fps": 0, "bitrateKbps": 8000}}, "computed"),
 ("command setCaptureSource display", 0x06, {"setCaptureSource": {"_0": {"display": {"_0": 1}}}}, "computed"),
 ("command lockScreen", 0x06, {"lockScreen": {}}, "computed, UNVERIFIED empty payload shape"),
 ("videoConfig h264", 0x09, {"sourceID": "display:1", "codec": "h264", "pixelWidth": 1920, "pixelHeight": 1080,
    "parameterSets": [base64.b64encode(b"\x67\x42").decode(), base64.b64encode(b"\x68\xce").decode()]}, "computed"),
 ("catalog displays only", 0x07, {"displays": [{"id": "display:1", "kind": "display", "title": "Built-in", "source": {"display": {"_0": 1}}, "pixelSize": [1920, 1080], "isManagedVirtualDisplay": False, "isVirtualDisplay": False}]}, "computed, UNVERIFIED CGSize array"),
 ("ping", 0x0B, {"sequence": 7}, "computed"),
 ("videoKey", 0x1A, {"secret": base64.b64encode(video_secret).decode()}, "computed"),
 ("videoTransport", 0x18, {"transport": "control", "reason": "no picture for 3 s"}, "computed"),
]
write("messages.json", {"cases": [{"name": n, "kind": k_, "json": js(o), "frame": hx(frame(k_, js(o).encode())), "source": s} for n, k_, o, s in msgs]})
print("ok")
