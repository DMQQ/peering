# Protocol test vectors

Shared by the Kotlin and Rust implementations. Regenerate with `python3 tools/gen_vectors.py` and `python3 tools/gen_keymap.py`
(needs the `cryptography` package). The files are checked in so a change to a value shows up as a diff.

| File | Contents |
|---|---|
| `messages.json` | control messages: name, frame kind, compact sorted-key JSON, full framed bytes (hex), source |
| `crypto.json` | SAS transcript and code, commitment, pairing proof, HKDF keys, one sealed datagram, replay window steps, an ECDSA signature, relay proof payload strings |
| `wire.json` | frame bytes, split delivery, decoder errors, video and audio frame headers, chunk sequences |
| `relay.json` | relay signalling messages (sorted keys) and token validity cases |
| `keymap.json` | macOS keycode to Windows scancode, modifier policy, Android key code to macOS keycode |

Confidence. The SAS code `365357` comes from `PairingSASTests.swift:56`. The HKDF keys, the commitment and the sealed datagram
were recomputed with Apple CryptoKit and match. Everything else is computed from the written spec and has not been exported
from Swift yet (task SPEC-010). JSON key order in `messages.json` is sorted for stability; Swift's order is unspecified, so
implementations MUST compare parsed JSON, not text, for control messages. Relay messages are compared as text because both
sides sort keys.
