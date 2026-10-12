package pl.dmq.peering.feature.onboarding

import pl.dmq.peering.R

data class FaqItem(val questionRes: Int, val answerRes: Int)

data class FaqSection(val titleRes: Int, val items: List<FaqItem>)

/** The questions the phone answers without a Mac in reach. Each answer names the string holding it. */
object FaqEntries {
    val sections: List<FaqSection> = listOf(
        FaqSection(
            titleRes = R.string.faq_section_start,
            items = listOf(
                FaqItem(R.string.faq_account_question, R.string.faq_account_answer),
                FaqItem(R.string.faq_pair_question, R.string.faq_pair_answer),
                FaqItem(R.string.faq_mac_needs_question, R.string.faq_mac_needs_answer),
            ),
        ),
        FaqSection(
            titleRes = R.string.faq_section_connecting,
            items = listOf(
                FaqItem(R.string.faq_away_question, R.string.faq_away_answer),
                FaqItem(R.string.faq_awake_question, R.string.faq_awake_answer),
            ),
        ),
        FaqSection(
            titleRes = R.string.faq_section_plans,
            items = listOf(
                FaqItem(R.string.faq_free_question, R.string.faq_free_answer),
                FaqItem(R.string.faq_run_out_question, R.string.faq_run_out_answer),
                FaqItem(R.string.faq_subscribe_question, R.string.faq_subscribe_answer),
            ),
        ),
    )
}
