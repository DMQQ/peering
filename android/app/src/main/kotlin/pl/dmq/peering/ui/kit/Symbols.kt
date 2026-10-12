package pl.dmq.peering.ui.kit

/** Lookalikes of the SF Symbols the iPhone app draws, named after them. Add here, never reach for a Material icon. */
object Symbols {
    private const val RING = "M12 3a9 9 0 1 0 0.01 0z"
    private const val SHIELD = "M12 3l7 2.6v5.9c0 4.3-2.8 7.6-7 9.5-4.2-1.9-7-5.2-7-9.5V5.6L12 3z"
    private const val PHONE = "M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"

    val macbook by lazy { symbol("macbook", "M5.5 5h13A1.5 1.5 0 0 1 20 6.5V15H4V6.5A1.5 1.5 0 0 1 5.5 5z", "M2.5 18h19") }
    val macbookAndIphone by lazy {
        symbol("macbook.and.iphone", "M14 14V7.5A1.5 1.5 0 0 0 12.5 6h-8A1.5 1.5 0 0 0 3 7.5V15h11", "M1.5 17.5H14", "M16.5 8.5h4A1 1 0 0 1 21.5 9.5v9a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1z")
    }
    val wifi by lazy { symbol("wifi", "M2.5 9.2a14 14 0 0 1 19 0", "M5.6 12.6a9.6 9.6 0 0 1 12.8 0", "M8.8 15.9a5 5 0 0 1 6.4 0", filled = listOf("M12 17.6a1.4 1.4 0 1 0 0.01 0z")) }
    val wifiExclamationmark by lazy { symbol("wifi.exclamationmark", "M2.5 9.2a14 14 0 0 1 19 0", "M5.6 12.6a9.6 9.6 0 0 1 12.8 0", "M8.8 15.9a5 5 0 0 1 6.4 0", "M12 17.5v.01") }
    val number by lazy { symbol("number", "M9.5 4L8 20", "M16.5 4L15 20", "M4.5 9h16", "M3.5 15h16") }
    val shield by lazy { symbol("shield", SHIELD) }
    val checkmarkShield by lazy { symbol("checkmark.shield", SHIELD, "M8.8 12l2.4 2.4 4-4.4") }
    val lockShield by lazy { symbol("lock.shield", SHIELD, "M9.5 12.5h5v3.5h-5z", "M10.3 12.5v-1a1.7 1.7 0 0 1 3.4 0v1") }
    val globe by lazy { symbol("globe", RING, "M3 12h18", "M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9S9.4 5.6 12 3z") }
    val network by lazy { symbol("network", RING, "M3 12h18", "M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9S9.4 5.6 12 3z", "M5 7.5c2 1 4.2 1.5 7 1.5s5-.5 7-1.5", "M5 16.5c2-1 4.2-1.5 7-1.5s5 .5 7 1.5") }
    val dotRadiowavesLeftAndRight by lazy {
        symbol("dot.radiowaves.left.and.right", "M8.8 8.8a4.6 4.6 0 0 0 0 6.4", "M15.2 8.8a4.6 4.6 0 0 1 0 6.4", "M5.9 6a8.6 8.6 0 0 0 0 12", "M18.1 6a8.6 8.6 0 0 1 0 12", filled = listOf("M12 10.4a1.6 1.6 0 1 0 0.01 0z"))
    }
    val arrowClockwise by lazy { symbol("arrow.clockwise", "M19 12a7 7 0 1 1-2.1-5", "M19 4v4.2h-4.2") }
    val ellipsisCircle by lazy { symbol("ellipsis.circle", RING, filled = listOf("M7.6 11a1 1 0 1 0 0.01 0z", "M12 11a1 1 0 1 0 0.01 0z", "M16.4 11a1 1 0 1 0 0.01 0z")) }
    val xmark by lazy { symbol("xmark", "M6 6l12 12", "M18 6L6 18") }
    val chevronRight by lazy { symbol("chevron.right", "M9.5 5l7 7-7 7") }
    val chevronLeft by lazy { symbol("chevron.left", "M14.5 5l-7 7 7 7") }
    val arrowUpRight by lazy { symbol("arrow.up.right", "M7 17L17 7", "M8.5 7H17v8.5") }
    val arrowRight by lazy { symbol("arrow.right", "M4.5 12h15", "M13.5 6l6 6-6 6") }
    val docOnDoc by lazy { symbol("doc.on.doc", "M9 8h9a1.5 1.5 0 0 1 1.5 1.5v10A1.5 1.5 0 0 1 18 21H9a1.5 1.5 0 0 1-1.5-1.5v-10A1.5 1.5 0 0 1 9 8z", "M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v10A1.5 1.5 0 0 0 5.5 17H7.5") }
    val checkmark by lazy { symbol("checkmark", "M5 12.5l4.5 4.5L19 7.5", stroke = 2.1f) }
    val checkmarkCircle by lazy { symbol("checkmark.circle", RING, "M8 12.3l2.8 2.8L16.2 9.4") }
    val arrowDownCircle by lazy { symbol("arrow.down.circle", RING, "M12 7.5v8", "M8.5 12.5l3.5 3.5 3.5-3.5") }
    val exclamationmarkTriangle by lazy { symbol("exclamationmark.triangle", "M12 4L2.8 19.5h18.4L12 4z", "M12 10v4.5", "M12 17.3v.01") }
    val faceid by lazy {
        symbol("faceid", "M4 8.5V6.5A2.5 2.5 0 0 1 6.5 4h2", "M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2", "M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2", "M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2", "M9 9.5v1.5", "M15 9.5v1.5", "M12 9.5v3.2h-.8", "M8.8 15.3c1.9 1.7 4.5 1.7 6.4 0")
    }
    val qrcodeViewfinder by lazy {
        symbol("qrcode.viewfinder", "M4 8.5V6.5A2.5 2.5 0 0 1 6.5 4h2", "M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2", "M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2", "M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2", "M8.5 8.5h2.5v2.5H8.5z", "M13 8.5h2.5v2.5H13z", "M8.5 13h2.5v2.5H8.5z", "M13 13h2.5v2.5H13z")
    }
    val keyboard by lazy { symbol("keyboard", "M4 6.5h16A1.5 1.5 0 0 1 21.5 8v8a1.5 1.5 0 0 1-1.5 1.5H4A1.5 1.5 0 0 1 2.5 16V8A1.5 1.5 0 0 1 4 6.5z", "M6.5 10.2h.01M10 10.2h.01M14 10.2h.01M17.5 10.2h.01M6.5 13.8h.01M17.5 13.8h.01", "M9 14h6") }
    val personCropCircleBadgeXmark by lazy {
        symbol("person.crop.circle.badge.xmark", "M12 3a9 9 0 1 0 0.01 0z", "M12 8a2.6 2.6 0 1 1-0.01 0z", "M6 18c1-2.6 3.3-4 6-4s5 1.4 6 4", "M5.5 14.5l4 4", "M9.5 14.5l-4 4")
    }
    val arrowTriangle2Circlepath by lazy { symbol("arrow.triangle.2.circlepath", "M4.5 11a7.5 7.5 0 0 1 13-4", "M19.5 13a7.5 7.5 0 0 1-13 4", "M18 3v4h-4", "M6 21v-4h4") }
    val display by lazy { symbol("display", "M4 4.5h16A1.5 1.5 0 0 1 21.5 6v9a1.5 1.5 0 0 1-1.5 1.5H4A1.5 1.5 0 0 1 2.5 15V6A1.5 1.5 0 0 1 4 4.5z", "M9 20h6", "M12 16.5V20") }
    val macwindow by lazy { symbol("macwindow", "M4.5 4.5h15A2 2 0 0 1 21.5 6.5v11a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2v-11a2 2 0 0 1 2-2z", "M2.5 9h19", "M6 6.8h.01M8.3 6.8h.01") }
    val squareStack3dUp by lazy { symbol("square.stack.3d.up", "M12 3l8.5 4.2L12 11.4 3.5 7.2 12 3z", "M3.5 11.6L12 15.8l8.5-4.2", "M3.5 16L12 20.2l8.5-4.2") }
    val handPointUpLeft by lazy { symbol("hand.point.up.left", "M8 12V5.2a1.5 1.5 0 0 1 3 0V10l5.2.9a2.6 2.6 0 0 1 2.1 2.8l-.6 4.3a2.6 2.6 0 0 1-2.6 2.2H11a3 3 0 0 1-2.3-1.1L5.2 15.3a1.4 1.4 0 0 1 2-1.9L8 14.2") }
    val cursorarrowMotionlines by lazy { symbol("cursorarrow.motionlines", "M9.5 5l9 5.6-4 1.3 3 4.8-2 1.2-3-4.8-3 2.7L9.5 5z", "M4 7h2.5", "M3 11h2.5", "M4 15h2.5") }
    val command by lazy { symbol("command", "M9 9V6.5A2.5 2.5 0 1 0 6.5 9H9zm0 0h6m-6 0v6m6-6V6.5A2.5 2.5 0 1 1 17.5 9H15zm0 0v6m0 0h2.5a2.5 2.5 0 1 1-2.5 2.5V15zm0 0H9m0 0H6.5A2.5 2.5 0 1 0 9 17.5V15z") }
    val eye by lazy { symbol("eye", "M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z", "M12 9.2a2.8 2.8 0 1 0 0.01 0z") }
    val pip by lazy { symbol("pip", "M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z", "M12.5 13h6a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1h-6a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1z") }
    val lockIphone by lazy { symbol("lock.iphone", PHONE, "M9.8 13h4.4v3.4H9.8z", "M10.6 13v-.9a1.4 1.4 0 0 1 2.8 0V13") }
    val squareGrid2x2 by lazy { symbol("square.grid.2x2", "M4.5 4.5h6v6h-6z", "M13.5 4.5h6v6h-6z", "M4.5 13.5h6v6h-6z", "M13.5 13.5h6v6h-6z") }
    val handTap by lazy { symbol("hand.tap", "M9 14V7.5a1.5 1.5 0 0 1 3 0v4l4 .8a2.4 2.4 0 0 1 1.9 2.6l-.5 3.4a2.4 2.4 0 0 1-2.4 2H12a3 3 0 0 1-2.3-1.1L7.2 16", "M6.2 8.3a4.5 4.5 0 1 1 8.4 2.2") }
    val bellBadge by lazy { symbol("bell.badge", "M6 16.5V11a6 6 0 0 1 6-6", "M4.5 16.5h15", "M10 19.5a2 2 0 0 0 4 0", filled = listOf("M18 4.5a2.5 2.5 0 1 0 0.01 0z")) }
    val infinity by lazy { symbol("infinity", "M12 12c-1.6-2.2-3-3.5-4.8-3.5a3.5 3.5 0 0 0 0 7C9 15.5 10.4 14.2 12 12zm0 0c1.6 2.2 3 3.5 4.8 3.5a3.5 3.5 0 0 0 0-7C15 8.5 13.6 9.8 12 12z") }
    val sparkles by lazy { symbol("sparkles", "M10 4.5c.6 3.6 1.9 5 5.5 5.5-3.6.6-4.9 1.9-5.5 5.5-.6-3.6-1.9-4.9-5.5-5.5C8.1 9.500 9.400 8.100 10 4.500z", "M18 14.5c.3 1.700.9 2.300 2.500 2.500-1.600.3-2.200.9-2.500 2.500-.3-1.600-.9-2.200-2.500-2.500 1.600-.2 2.200-.8 2.500-2.500z") }
    val serverRack by lazy { symbol("server.rack", "M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.500 1.500H5A1.500 1.500 0 0 1 3.500 9V6A1.500 1.500 0 0 1 5 4.500z", "M5 13.500h14a1.500 1.500 0 0 1 1.500 1.500v3A1.500 1.500 0 0 1 19 19.500H5A1.500 1.500 0 0 1 3.500 18v-3A1.500 1.500 0 0 1 5 13.500z", "M7 7.500h.01M7 16.500h.01") }
    val clock by lazy { symbol("clock", RING, "M12 7v5.2l3.3 2") }
    val questionmarkCircle by lazy { symbol("questionmark.circle", RING, "M9.600 9.500a2.500 2.500 0 1 1 3.600 2.200c-.800.400-1.200.900-1.200 1.800", "M12 16.800v.01") }
    val gearshape by lazy {
        symbol("gearshape", "M10.300 3.500h3.400l.5 2.300 1.500.9 2.200-.8 1.700 2.900-1.800 1.600v1.800l1.800 1.600-1.700 2.900-2.200-.8-1.500.9-.5 2.300h-3.400l-.5-2.300-1.500-.9-2.200.8-1.700-2.900 1.800-1.600v-1.800L4.400 8.600l1.700-2.900 2.200.8 1.500-.9.5-2.100z", "M12 9.500a2.500 2.500 0 1 0 0.01 0z")
    }
    val power by lazy { symbol("power", "M12 3.500v8", "M7 6.500a7.500 7.500 0 1 0 10 0") }
    val pencil by lazy { symbol("pencil", "M4 20l1-4.200L16.500 4.300a1.800 1.800 0 0 1 2.500 0l.7.7a1.800 1.800 0 0 1 0 2.500L8.200 19 4 20z", "M14.500 6.300l3.200 3.200") }
    val trash by lazy { symbol("trash", "M4 7h16", "M9.500 7V4.500h5V7", "M6 7l.8 12.500h10.400L18 7", "M10 11v5.500M14 11v5.500") }
    val laptopAndPhoneBadge by lazy { symbol("iphone", PHONE, "M11 18h2") }
    val textAlignLeft by lazy { symbol("text.alignleft", "M4 7h16M4 12h10M4 17h13") }
    val camera by lazy { symbol("camera", "M3.500 8h3l1.500-2.500h8L17.500 8h3A1 1 0 0 1 21.500 9v9a1 1 0 0 1-1 1h-17A1 1 0 0 1 2.500 18V9A1 1 0 0 1 3.500 8z", "M12 10.500a3.200 3.200 0 1 0 0.01 0z") }
}
