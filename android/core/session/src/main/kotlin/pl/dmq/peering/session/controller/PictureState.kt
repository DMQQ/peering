package pl.dmq.peering.session.controller

/** What the picture area should show: waiting for the first frame, live, paused by the user, or carried by the fallback. */
enum class PictureState { Connecting, Live, Paused, Fallback }
