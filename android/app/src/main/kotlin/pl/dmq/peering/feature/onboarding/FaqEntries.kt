package pl.dmq.peering.feature.onboarding

import pl.dmq.peering.R

data class FaqItem(val questionRes: Int, val answerRes: Int)

data class FaqSection(val titleRes: Int, val items: List<FaqItem>)

/** The questions the phone answers, in the iPhone's six sections. Each answer names the string holding it. */
object FaqEntries {
    val sections: List<FaqSection> = listOf(
        FaqSection(
            titleRes = R.string.faq_section_start,
            items = listOf(
                FaqItem(R.string.faq_account_question, R.string.faq_account_answer),
                FaqItem(R.string.faq_pair_question, R.string.faq_pair_answer),
                FaqItem(R.string.faq_mac_needs_question, R.string.faq_mac_needs_answer),
                FaqItem(R.string.faq_away_question, R.string.faq_away_answer),
                FaqItem(R.string.faq_awake_question, R.string.faq_awake_answer),
                FaqItem(R.string.faq_many_question, R.string.faq_many_answer),
                FaqItem(R.string.faq_phones_question, R.string.faq_phones_answer),
            ),
        ),
        FaqSection(
            titleRes = R.string.faq_section_privacy,
            items = listOf(
                FaqItem(R.string.faq_relay_sees_question, R.string.faq_relay_sees_answer),
                FaqItem(R.string.faq_relay_knows_question, R.string.faq_relay_knows_answer),
                FaqItem(R.string.faq_video_servers_question, R.string.faq_video_servers_answer),
                FaqItem(R.string.faq_darken_question, R.string.faq_darken_answer),
                FaqItem(R.string.faq_lock_question, R.string.faq_lock_answer),
                FaqItem(R.string.faq_collect_question, R.string.faq_collect_answer),
            ),
        ),
        FaqSection(
            titleRes = R.string.faq_section_moves,
            items = listOf(
                FaqItem(R.string.faq_clipboard_question, R.string.faq_clipboard_answer),
                FaqItem(R.string.faq_files_question, R.string.faq_files_answer),
                FaqItem(R.string.faq_terminal_question, R.string.faq_terminal_answer),
                FaqItem(R.string.faq_macros_question, R.string.faq_macros_answer),
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
        FaqSection(
            titleRes = R.string.faq_section_trouble,
            items = listOf(
                FaqItem(R.string.faq_verified_question, R.string.faq_verified_answer),
                FaqItem(R.string.faq_black_question, R.string.faq_black_answer),
                FaqItem(R.string.faq_soft_question, R.string.faq_soft_answer),
                FaqItem(R.string.faq_network_question, R.string.faq_network_answer),
                FaqItem(R.string.faq_background_question, R.string.faq_background_answer),
            ),
        ),
        FaqSection(
            titleRes = R.string.faq_section_gaps,
            items = listOf(
                FaqItem(R.string.faq_gaps_question, R.string.faq_gaps_answer),
                FaqItem(R.string.faq_coming_question, R.string.faq_coming_answer),
            ),
        ),
    )
}
