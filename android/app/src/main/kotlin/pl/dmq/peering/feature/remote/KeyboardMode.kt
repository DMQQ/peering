package pl.dmq.peering.feature.remote

/**
 * Which protocol the soft keyboard speaks. Unicode sends the text, so emoji and other scripts arrive intact but no key
 * is pressed and a shortcut never fires. Keycode presses real keys, so shortcuts work, and a character the computer's
 * layout has no key for is still sent as text.
 */
enum class KeyboardMode { UNICODE, KEYCODE }
