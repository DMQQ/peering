
## pt-BR (Brazilian Portuguese): strings for a native speaker to review

Android strings in `values-pt-rBR/`: 1447 entries (plurals included, with one, many and other). About 560 reuse the iPhone's pt-BR from `Localizable.xcstrings` where the English matched exactly; about 890 are fresh translations.

Terminology decisions to confirm:
- "Configurações" is used for Settings (Android convention) where the iPhone says "Ajustes". Affects `nav_settings`, `settings_title`, `remote_dock_settings`, `scan_open_settings`, `settings_search`, and the FAQ and invite texts.
- "computador" for the generic computer (the iPhone says "Mac"); "parear" and "relay" are kept as on the iPhone.
- "turno" for an agent's turn (`agents_queued_next`, `whatsnew_review_detail`, `approval_cancelled`).
- Pairing and access wording: `ssh_lock_passcode` ("Código de acesso"), `ssh_lock_wrong`, `ssh_lock_change`.

Long or technical texts worth a read: `legal_privacy_body`, `legal_terms_body`, `faq_*_answer` (especially `faq_pair_answer`, `faq_files_answer`, `faq_background_answer`, `faq_gaps_answer`), `panel_*_note`, `ssh_signin_key_footer`, `ssh_key_*_footer`, `ssh_changed_help`, `ssh_forward_remote_footer`, `settings_invite_message`.

Shorter ones that may read oddly: `agents_jump_to_latest` ("Ir para a mais recente, %1$d novas"), `agents_turn_tokens` ("%1$d entrada / %2$d saída"), `agents_active_just_now`, `hints_nothing_starts`, `panel_direct_probing` ("Batendo à porta de %1$s"), `files_delete_folder`, `mosaic_picked`, `whatsnew_composer_detail`, `remote_joystick`, `terminal_quick_empty_body`.

## ko (Korean): strings for a native speaker to review

Android strings in `values-ko/`: 1447 entries (plurals included, with the single CLDR quantity `other`). 748 reuse the iPhone's ko from `Localizable.xcstrings` where the English matched exactly; 699 are fresh translations.

Terminology decisions to confirm:
- "컴퓨터" for the generic computer (the iPhone says "Mac"); "페어링", "릴레이" and "신뢰하는 컴퓨터" are kept as on the iPhone.
- "삭제" for Forget (as the iPhone), including `faq_*`, `ssh_changed_help` ("키 삭제").
- "턴" for an agent's turn (`approval_cancelled`, `agents_queued_next`, `bg_channel_agents_description`, `whatsnew_review_detail`); "스페이스" for a macOS Space.
- Courtesy/tag endings use polite "-습니다/-하세요"; particles for placeholders use "(으)로", "을(를)", "이(가)" because the substituted name is unknown.

Long or technical texts worth a read: `legal_privacy_body`, `legal_terms_body`, `faq_*_answer` (especially `faq_pair_answer`, `faq_files_answer`, `faq_background_answer`, `faq_gaps_answer`), `panel_*_note`, `ssh_signin_key_footer`, `ssh_key_*_footer`, `ssh_changed_help`, `ssh_forward_remote_footer`, `settings_invite_message`.

Shorter ones that may read oddly: `agents_jump_to_latest`, `agents_turn_tokens` ("입력 %1$d / 출력 %2$d"), `panel_direct_probing`, `panel_lock` ("컴퓨터 잠금 · 현장에서 해제"), `settings_keywords_*` and `panel_keywords_*` (search keywords, Korean plus a few English terms), `remote_pointer_*_description`, `remote_joystick`, `whatsnew_composer_detail`, `terminal_quick_empty_body`.
