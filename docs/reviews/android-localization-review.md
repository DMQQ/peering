
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

## zh-Hans (Simplified Chinese): strings for a native speaker to review

Android strings in `values-b+zh+Hans/`: 1449 entries (plurals included, with the single CLDR quantity `other`). All 21 files mirror the English ones. Terminology was aligned by hand with the iPhone's zh-Hans (智能体, 中继, 配对, 受信任的…, 串流, 会话, 轻点); strings were not copied mechanically, so near-identical iPhone phrases may differ slightly in wording.

Terminology decisions to confirm:
- "电脑" for the generic computer (the iPhone says "Mac"); "Mac" is kept only where the English says Mac (`connect_pairings_unreadable`).
- "移除" for Forget (as the iPhone), but "忘记登录方式" and "忘记其密钥" in the SSH texts (as the iPhone).
- "存储" for Save and "拷贝" for Copy (Android Chinese often says 保存 and 复制). "轻点" is kept from the iPhone although Android Chinese usually says 点按 or 点击.
- "回合" was avoided: an agent's turn is "一轮" (`agents_turn_*`, `approval_cancelled`, `whatsnew_review_detail`); "空间" for a macOS Space; "马赛克" for Mosaic.
- English technical names kept as is: shell, token, Keycode, Unicode, HEVC, SSH, git, zsh-style terms, Keystore.

Long or technical texts worth a read: `legal_privacy_body`, `legal_terms_body`, `faq_*_answer`, `panel_*_note`, `ssh_signin_key_footer`, `ssh_key_*`, `ssh_changed_help`, `ssh_forward_*_footer`, `settings_invite_message`.

Shorter ones that may read oddly: `agents_jump_to_latest`, `agents_turn_tokens` ("输入 %1$d / 输出 %2$d"), `agents_turn_cost` ("%1$s 美元"), `panel_direct_probing` ("正在试探"), `panel_lock`, `settings_keywords_*` and `panel_keywords_*` (search keywords), `remote_joystick`, `terminal_group_pages`, `terminal_key_*`, `tour_notifications_title` ("shell 在等你时会通知你"), `tour_notification_date` ("9月24日 星期三").

## Russian (ru)

All 1,441 translatable entries of the English files exist in `values-ru/` (715 taken from the iPhone catalog where the English text matches exactly, 726 written fresh, mostly strings with placeholders or Android-only features). Terms follow the iPhone: компьютер for Mac/computer, связать/связанный for pair, доверенные, релей, сеанс, Наблюдение, Space left untranslated, Pro. Plurals use one, few, many, other.

For a native speaker to review:

- Long texts: `legal_privacy_body`, `legal_terms_body`, `faq_*_answer`, `panel_*_note`, `paywall_renewal_note`, `allowance_detail_*`, `ssh_*_footer`, `ssh_key_err_not_private`, `ssh_changed_help`.
- `faq_awake_answer` and `faq_gaps_answer` translate English text that is stale (wake packets and sound now exist); retranslate when the English is corrected.
- Word choices that may read oddly: `agents_turn_tokens` ("вход / выход"), `agents_turn_cost` ("US$ %1$s"), `panel_direct_probing` ("Стучимся на"), `panel_lock`, `settings_invite_message` (invite wording sent to friends), `terminal_group_pages` ("Страницы и концы"), `terminal_key_back_tab`, `ssh_tab_forwards` ("Переадресации"), `agents_state_idle` ("Простой"), `permission_detail_reviewer` ("Модель-проверяющий").
- The agent prompt texts `review_prompt_intro` and `review_prompt_removed` are sent to the agent and use the informal "ты" form of the iPhone prompts for agent suggestions.
- Search keyword lists (`panel_keywords_*`, `settings_keywords_*`) hold Russian words followed by the English ones, so searching in either language works.
- Kept as English on purpose: key names (Enter, Escape, Home, End), Unicode, Keycode, git, diff, push, HEVC, SSH terms, Keystore.
