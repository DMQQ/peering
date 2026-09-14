import Foundation
import Testing

@testable import RemoteCore

@Suite("Input encoding")
struct InputEncodingTests {
    // MARK: - Unicode chunking

    @Test("splits long text into chunks of the requested size")
    func chunksLongText() {
        let chunks = InputEncoding.unicodeChunks("abcdefghijklmnopqrstuvwxyz", maxUnits: 10)

        #expect(chunks.count == 3)
        #expect(chunks[0].count == 10)
        #expect(chunks[1].count == 10)
        #expect(chunks[2].count == 6)
    }

    @Test("empty text produces no events")
    func emptyTextProducesNothing() {
        // A keyboard event carrying no string is still delivered to the focused app.
        // Posting one for empty input is a phantom keystroke.
        #expect(InputEncoding.unicodeChunks("").isEmpty)
    }

    @Test("short text stays in one chunk")
    func shortTextIsOneChunk() {
        let chunks = InputEncoding.unicodeChunks("hi", maxUnits: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0] == Array("hi".utf16))
    }

    @Test("never splits a surrogate pair")
    func doesNotSplitSurrogatePairs() {
        // An emoji is two UTF-16 units. Split across events, each half is an unpaired
        // surrogate — not valid text — and the client would render two replacement
        // characters instead of one emoji.
        let text = String(repeating: "😀", count: 6)  // 12 units
        let chunks = InputEncoding.unicodeChunks(text, maxUnits: 5)

        var rejoined: [UInt16] = []
        for chunk in chunks {
            // Every chunk must independently be valid UTF-16.
            #expect(String(decoding: chunk, as: UTF16.self).contains("\u{FFFD}") == false)
            rejoined += chunk
        }
        #expect(rejoined == Array(text.utf16))
        #expect(chunks.allSatisfy { $0.count <= 4 })
    }

    @Test("a surrogate pair landing exactly on the boundary moves to the next chunk")
    func boundarySurrogateMoves() {
        // "a" + emoji: 1 + 2 = 3 units, limit 2. The pair cannot fit in the first chunk,
        // so the first chunk is just "a".
        let chunks = InputEncoding.unicodeChunks("a😀", maxUnits: 2)

        #expect(chunks[0] == Array("a".utf16))
        #expect(chunks[1] == Array("😀".utf16))
    }

    @Test("every chunk round-trips, for a varied string")
    func roundTripsMixedContent() {
        // Accented Latin, CJK, an emoji with a variation selector, and an astral plane
        // character — the cases that separate a real chunker from a naive one.
        let text = "café 日本語 👍🏽 𝄞 fin"
        let chunks = InputEncoding.unicodeChunks(text, maxUnits: 3)

        let rejoined = chunks.flatMap { $0 }
        #expect(rejoined == Array(text.utf16))

        for chunk in chunks {
            #expect(chunk.count <= 3)
            // A chunk starting with a low surrogate would mean a split pair.
            if let first = chunk.first {
                #expect((0xDC00...0xDFFF).contains(first) == false)
            }
        }
    }

    @Test("an absurd chunk size is raised to two rather than looping forever")
    func degenerateChunkSizeStillProgresses() {
        // maxUnits of 1 cannot clear a surrogate pair. Left alone it would either split the
        // pair or fail to advance; either way the caller hangs or corrupts the text.
        let chunks = InputEncoding.unicodeChunks("😀😀", maxUnits: 1)
        #expect(chunks.flatMap { $0 } == Array("😀😀".utf16))
    }

    // MARK: - Scroll deltas

    @Test("rounds a delta to the nearest integer")
    func roundsScrollDelta() {
        #expect(InputEncoding.wheelValue(3.4) == 3)
        #expect(InputEncoding.wheelValue(3.6) == 4)

        // Halves round away from zero, so the two directions stay symmetric in magnitude.
        // `.toNearestOrEven` would send +2.5 to 2 but -2.5 to -2, making a scroll slightly
        // weaker one way than the other.
        #expect(InputEncoding.wheelValue(2.5) == 3)
        #expect(InputEncoding.wheelValue(-2.5) == -3)
    }

    @Test("a non-finite delta becomes zero instead of crashing")
    func rejectsNonFiniteDeltas() {
        // Int32(Double.nan) traps in Swift. This value comes straight off the network, so
        // without this clamping one malformed packet would kill the host process.
        #expect(InputEncoding.wheelValue(.nan) == 0)
        #expect(InputEncoding.wheelValue(.infinity) == 0)
        #expect(InputEncoding.wheelValue(-.infinity) == 0)
    }

    @Test("an enormous delta clamps instead of trapping")
    func clampsEnormousDeltas() {
        #expect(InputEncoding.wheelValue(1e18) == Int32.max)
        #expect(InputEncoding.wheelValue(-1e18) == Int32.min)
        #expect(InputEncoding.wheelValue(Double(Int32.max) + 1000) == Int32.max)
    }

    @Test("ordinary deltas pass through unchanged")
    func passesOrdinaryDeltas() {
        #expect(InputEncoding.wheelValue(0) == 0)
        #expect(InputEncoding.wheelValue(120) == 120)
        #expect(InputEncoding.wheelValue(-120) == -120)
    }

    // MARK: - Modifier keycodes

    @Test("recognises the modifier keycodes")
    func recognisesModifiers() {
        // Posting an ordinary key-down for one of these leaves the modifier stuck down in
        // every application, with no release event to clear it.
        for code: UInt16 in [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            #expect(InputEncoding.isModifierKeyCode(code))
        }
    }

    @Test("does not mistake ordinary keys for modifiers")
    func ordinaryKeysAreNotModifiers() {
        // 0 = A, 1 = S, 123/124 = the arrow keys used for Spaces, 36 = return.
        for code: UInt16 in [0, 1, 6, 36, 49, 123, 124] {
            #expect(InputEncoding.isModifierKeyCode(code) == false)
        }
    }
}

@Suite("Modifier keycodes")
struct ModifierKeycodeTests {
    @Test("both hands of a modifier map to the same bit")
    func leftAndRightAgree() {
        // Collapsing the two is what keeps a left-Shift release from failing to clear a
        // right-Shift press, so it is worth pinning rather than leaving implicit.
        #expect(InputEncoding.modifierBit(for: 55) == .command)
        #expect(InputEncoding.modifierBit(for: 54) == .command)
        #expect(InputEncoding.modifierBit(for: 56) == .shift)
        #expect(InputEncoding.modifierBit(for: 60) == .shift)
        #expect(InputEncoding.modifierBit(for: 58) == .option)
        #expect(InputEncoding.modifierBit(for: 61) == .option)
        #expect(InputEncoding.modifierBit(for: 59) == .control)
        #expect(InputEncoding.modifierBit(for: 62) == .control)
    }

    @Test("ordinary keys have no modifier bit")
    func ordinaryKeys() {
        // 0 is 'a', 49 is space, 123 is left arrow — the arrow matters because switchSpace
        // sends it with a control flag, so treating it as a modifier would break Spaces.
        for code: UInt16 in [0, 49, 123, 124] {
            #expect(InputEncoding.modifierBit(for: code) == nil)
            #expect(!InputEncoding.isModifierKeyCode(code))
        }
    }

    @Test("caps lock and fn are flags changes but carry no modifier bit")
    func capsLockAndFn() {
        // They are posted as flags changes like the modifiers, but have no bit, so they must
        // not be folded into the tracked modifier state.
        #expect(InputEncoding.isModifierKeyCode(57))
        #expect(InputEncoding.isModifierKeyCode(63))
        #expect(InputEncoding.modifierBit(for: 57) == nil)
        #expect(InputEncoding.modifierBit(for: 63) == nil)
    }

    @Test("every modifier bit is reachable by pressing a key")
    func everyBitIsReachable() {
        let bits: [Modifiers] = [.command, .shift, .option, .control]
        for bit in bits {
            let codes = (UInt16(0)...UInt16(127)).filter { InputEncoding.modifierBit(for: $0) == bit }
            #expect(codes.count == 2)
        }
    }
}
