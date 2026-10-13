package pl.dmq.peering.ui.kit

import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

/** A dollar cost with the locale's currency symbol and separators ("$0.12", "0,12 $"). */
fun dollars(amount: Double): String =
    NumberFormat.getCurrencyInstance(Locale.getDefault()).apply { currency = Currency.getInstance("USD") }.format(amount)

/** A figure with two decimals and the locale's separator, for strings that carry their own currency label. */
fun twoDecimals(amount: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 2; maximumFractionDigits = 2 }.format(amount)
