package pl.dmq.peering.feature.remote

/** F1 to F12 with their macOS virtual keycodes, as docs/protocol/vectors/keymap.json lists them. */
enum class FunctionKey(val macKeyCode: Int) {
    F1(122),
    F2(120),
    F3(99),
    F4(118),
    F5(96),
    F6(97),
    F7(98),
    F8(100),
    F9(101),
    F10(109),
    F11(103),
    F12(111),
}
