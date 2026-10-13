package pl.dmq.peering.session.controller

import pl.dmq.peering.wire.FieldStatePayload

/** Whether the computer's focus is on a text field. [serial] grows with every report, so the same answer twice is still news. */
data class HostTextFocus(val isEditable: Boolean, val serial: Int)

/** What the focused text field last held. [serial] grows with every report. */
data class HostField(val state: FieldStatePayload, val serial: Int)
