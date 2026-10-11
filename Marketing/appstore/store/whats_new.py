"""Writes release_notes.txt and promotional_text.txt for every locale into upload/metadata/<locale>/."""
import os
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "upload", "metadata")

N = {
"en-US": """• New: chat with Claude Code, Codex and OpenCode right from your phone. Approve or deny tool requests, switch between Manual, Auto accept and Auto, attach photos and files, and type @ for files or / for commands.
• A new Agents tab shows every agent running on your Mac with its live activity and plan, next to your terminals.
• Approvals can now reach you as a banner inside the app, plus a new Agents widget and a chat Live Activity.
• Check a chat's context, token use and remaining limits in one sheet.
• Smaller fixes and polish.""",
"de-DE": """• Neu: Chatte direkt vom iPhone mit Claude Code, Codex und OpenCode. Genehmige oder lehne Werkzeuganfragen ab, wechsle zwischen Manuell, Automatisch annehmen und Automatisch, hänge Fotos und Dateien an und tippe @ für Dateien oder / für Befehle.
• Ein neuer Tab „Agenten“ zeigt neben deinen Terminals jeden Agenten auf deinem Mac mit Live-Aktivität und Plan.
• Freigaben erreichen dich jetzt auch als Banner in der App, dazu gibt es ein neues Agenten-Widget und eine Live Activity für den Chat.
• Kontext, Token-Verbrauch und verbleibende Limits eines Chats siehst du in einer Übersicht.
• Kleinere Korrekturen und Feinschliff.""",
"es-ES": """• Novedad: chatea con Claude Code, Codex y OpenCode directamente desde el móvil. Aprueba o rechaza las solicitudes de herramientas, cambia entre Manual, Aceptar automáticamente y Automático, adjunta fotos y archivos, y escribe @ para archivos o / para comandos.
• Una nueva pestaña Agentes muestra, junto a tus terminales, todos los agentes de tu Mac con su actividad en directo y su plan.
• Las aprobaciones ahora también te llegan como banner dentro de la app, y hay un nuevo widget de Agentes y una Live Activity del chat.
• Consulta el contexto, el uso de tokens y los límites restantes de un chat en una sola hoja.
• Correcciones menores y mejoras.""",
"fr-FR": """• Nouveau : discute avec Claude Code, Codex et OpenCode directement depuis ton iPhone. Approuve ou refuse les demandes d'outils, passe de Manuel à Accepter automatiquement ou Automatique, joins des photos et des fichiers, et tape @ pour les fichiers ou / pour les commandes.
• Un nouvel onglet Agents affiche, à côté de tes terminaux, chaque agent de ton Mac avec son activité en direct et son plan.
• Les approbations peuvent aussi arriver sous forme de bannière dans l'app, avec un nouveau widget Agents et une Live Activity pour le chat.
• Consulte le contexte, la consommation de jetons et les limites restantes d'une discussion dans une seule feuille.
• Petites corrections et améliorations.""",
"it": """• Novità: chatta con Claude Code, Codex e OpenCode direttamente dal telefono. Approva o rifiuta le richieste degli strumenti, passa tra Manuale, Accetta automaticamente e Automatico, allega foto e file, e scrivi @ per i file o / per i comandi.
• Una nuova scheda Agenti mostra, accanto ai tuoi terminali, ogni agente sul tuo Mac con la sua attività in tempo reale e il suo piano.
• Le approvazioni ora possono arrivare anche come banner dentro l'app, con un nuovo widget Agenti e una Live Activity per la chat.
• Controlla contesto, consumo di token e limiti rimanenti di una chat in un'unica schermata.
• Correzioni minori e rifiniture.""",
"pt-BR": """• Novidade: converse com Claude Code, Codex e OpenCode direto do celular. Aprove ou negue pedidos de ferramentas, alterne entre Manual, Aceitar automaticamente e Automático, anexe fotos e arquivos, e digite @ para arquivos ou / para comandos.
• Uma nova aba Agentes mostra, ao lado dos seus terminais, cada agente do seu Mac com a atividade ao vivo e o plano.
• As aprovações agora também chegam como banner dentro do app, com um novo widget de Agentes e uma Live Activity do chat.
• Veja o contexto, o uso de tokens e os limites restantes de uma conversa em uma única tela.
• Pequenas correções e melhorias.""",
"ru": """• Новое: общайся с Claude Code, Codex и OpenCode прямо с телефона. Одобряй или отклоняй запросы инструментов, переключайся между режимами «Вручную», «Автопринятие» и «Авто», прикрепляй фото и файлы, вводи @ для файлов или / для команд.
• Новая вкладка «Агенты» показывает рядом с терминалами всех агентов на твоём Mac с их текущей активностью и планом.
• Запросы на одобрение теперь приходят и баннером внутри приложения, а ещё появились виджет «Агенты» и Live Activity для чата.
• Контекст, расход токенов и оставшиеся лимиты чата собраны в одном окне.
• Мелкие исправления и улучшения.""",
"ja": """• 新機能：Claude Code、Codex、OpenCodeとiPhoneから直接チャットできます。ツールの許可・拒否、「手動」「自動承認」「自動」の切り替え、写真やファイルの添付、@でファイル、/でコマンドの入力に対応しています。
• 新しい「エージェント」タブでは、ターミナルと並んで、Macで動作中のすべてのエージェントのリアルタイムの動きとプランを確認できます。
• 承認の依頼をアプリ内のバナーでも受け取れるようになり、エージェント用ウィジェットとチャットのLive Activityも追加されました。
• チャットのコンテキスト、トークン使用量、残りの上限を1つのシートで確認できます。
• 細かな修正と改善。""",
"ko": """• 새로운 기능: iPhone에서 Claude Code, Codex, OpenCode와 바로 대화하세요. 도구 요청을 승인하거나 거부하고, 수동, 자동 수락, 자동 모드를 전환하고, 사진과 파일을 첨부하고, @로 파일을, /로 명령어를 입력할 수 있습니다.
• 새 에이전트 탭에서 터미널 옆에 Mac에서 실행 중인 모든 에이전트의 실시간 활동과 계획을 볼 수 있습니다.
• 승인 요청을 앱 안의 배너로도 받을 수 있고, 에이전트 위젯과 채팅 Live Activity가 새로 추가되었습니다.
• 채팅의 컨텍스트, 토큰 사용량, 남은 한도를 시트 하나에서 확인하세요.
• 소소한 수정과 개선.""",
"zh-Hans": """• 新功能：在手机上直接与 Claude Code、Codex 和 OpenCode 对话。可批准或拒绝工具请求，在“手动”“自动接受”和“自动”之间切换，添加照片和文件，输入 @ 引用文件，输入 / 使用命令。
• 全新的“智能体”标签页会在终端旁显示你的 Mac 上所有智能体的实时动态和计划。
• 审批请求现在也会以应用内横幅的形式送达，并新增智能体小组件和聊天实时活动。
• 在一个面板中查看聊天的上下文、令牌用量和剩余额度。
• 一些细节修复和优化。""",
}
P = {
"en-US": "Approve Claude Code, Codex and OpenCode from your phone, then take over your Mac's screen and terminal when you need to. Free on your own network. No account.",
"de-DE": "Dein Mac in der Hosentasche, mit deinen Coding-Agenten. Chatte mit Claude Code, Codex und OpenCode, genehmige Anfragen und sieh den Bildschirm von überall. Ohne Konto.",
"es-ES": "Tu Mac en el bolsillo, con tus agentes de código. Chatea con Claude Code, Codex y OpenCode, aprueba sus solicitudes y mira la pantalla desde cualquier lugar. Sin cuenta.",
"fr-FR": "Ton Mac dans ta poche, avec tes agents de code. Discute avec Claude Code, Codex et OpenCode, approuve leurs demandes et vois l'écran de n'importe où. Sans compte.",
"it": "Il tuo Mac in tasca, con i tuoi agenti di codice. Chatta con Claude Code, Codex e OpenCode, approva le loro richieste e guarda lo schermo da ovunque. Senza account.",
"pt-BR": "Seu Mac no bolso, com seus agentes de código. Converse com Claude Code, Codex e OpenCode, aprove os pedidos deles e veja a tela de qualquer lugar. Sem conta.",
"ru": "Твой Mac в кармане, вместе с агентами кода. Общайся с Claude Code, Codex и OpenCode, одобряй их запросы и смотри на экран отовсюду. Без аккаунта.",
"ja": "Macをポケットに、コーディングエージェントと一緒に。Claude Code、Codex、OpenCodeとチャットし、リクエストを承認し、どこからでも画面を確認できます。アカウント不要。",
"ko": "주머니 속 Mac과 코딩 에이전트. Claude Code, Codex, OpenCode와 대화하고, 요청을 승인하고, 어디서든 화면을 확인하세요. 계정이 필요 없습니다.",
"zh-Hans": "把 Mac 和你的编程智能体装进口袋。与 Claude Code、Codex 和 OpenCode 对话，批准它们的请求，随处查看屏幕。无需账号。",
}
for loc, promo in P.items():
    assert len(promo) <= 170 and "—" not in promo and "–" not in promo, (loc, len(promo))
    open(f"{OUT}/{loc}/promotional_text.txt", "w").write(promo + "\n")
for loc, text in N.items():
    assert len(text) <= 4000 and "—" not in text and "–" not in text, loc
    os.makedirs(f"{OUT}/{loc}", exist_ok=True)
    open(f"{OUT}/{loc}/release_notes.txt", "w").write(text + "\n")
print("ok", len(N))
