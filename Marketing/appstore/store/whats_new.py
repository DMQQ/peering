"""Writes release_notes.txt and promotional_text.txt for every locale into upload/metadata/<locale>/."""
import os
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "upload", "metadata")

N = {
"en-US": """• Approve Claude Code from any terminal or editor: switch on the hooks and Allow and Deny buttons appear on your phone.
• Continue a Claude Code conversation you started in a terminal, pause chats and return later, and save your own prompts.
• A finished turn says what it changed and how long it took, with Continue and Reply right in the notification.
• A guide for your first connection, and a warning when the connection is too poor to work over.
• Share an invite code from Settings and you both get free relay time.
• Every feature is now free. Only relay time away from home is limited.
• Putting the app in the background no longer uses up relay time, and the joystick cursor stays in step with your Mac's pointer.
• Smaller fixes and polish.""",
"de-DE": """• Genehmige Claude Code aus jedem Terminal oder Editor: Schalte die Hooks ein, und Erlauben- und Ablehnen-Tasten erscheinen auf deinem iPhone.
• Setze eine Claude-Code-Unterhaltung fort, die du im Terminal begonnen hast, pausiere Chats und kehre später zurück, und speichere eigene Prompts.
• Ein beendeter Durchlauf sagt, was er geändert hat und wie lange er gedauert hat, mit Weiter und Antworten direkt in der Mitteilung.
• Eine Anleitung für die erste Verbindung und eine Warnung, wenn die Verbindung zum Arbeiten zu schlecht ist.
• Teile einen Einladungscode aus den Einstellungen, und ihr beide bekommt kostenlose Relay-Zeit.
• Alle Funktionen sind jetzt kostenlos. Begrenzt ist nur die Relay-Zeit außerhalb deines Netzwerks.
• Läuft die App im Hintergrund, verbraucht sie keine Relay-Zeit mehr, und der Joystick-Cursor folgt dem Zeiger deines Macs.
• Kleinere Korrekturen und Feinschliff.""",
"es-ES": """• Aprueba Claude Code desde cualquier terminal o editor: activa los hooks y aparecerán los botones Permitir y Denegar en tu móvil.
• Continúa una conversación de Claude Code que empezaste en un terminal, pausa chats y vuelve más tarde, y guarda tus propios prompts.
• Un turno terminado indica qué cambió y cuánto tardó, con Continuar y Responder en la propia notificación.
• Una guía para la primera conexión y un aviso cuando la conexión es demasiado mala para trabajar.
• Comparte un código de invitación desde Ajustes y los dos obtenéis tiempo de relay gratis.
• Todas las funciones son ahora gratuitas. Solo se limita el tiempo de relay fuera de casa.
• Poner la app en segundo plano ya no gasta tiempo de relay, y el cursor del joystick sigue al puntero de tu Mac.
• Correcciones menores y mejoras.""",
"fr-FR": """• Approuve Claude Code depuis n'importe quel terminal ou éditeur : active les hooks et des boutons Autoriser et Refuser apparaissent sur ton iPhone.
• Reprends une conversation Claude Code commencée dans un terminal, mets des discussions en pause pour y revenir plus tard, et enregistre tes propres prompts.
• Un tour terminé indique ce qu'il a modifié et le temps qu'il a pris, avec Continuer et Répondre directement dans la notification.
• Un guide pour la première connexion, et un avertissement quand la connexion est trop mauvaise pour travailler.
• Partage un code d'invitation depuis les Réglages et vous gagnez tous les deux du temps de relais gratuit.
• Toutes les fonctions sont désormais gratuites. Seul le temps de relais hors de chez toi est limité.
• Mettre l'app en arrière-plan ne consomme plus de temps de relais, et le curseur du joystick suit le pointeur de ton Mac.
• Petites corrections et améliorations.""",
"it": """• Approva Claude Code da qualsiasi terminale o editor: attiva gli hook e sul telefono compaiono i pulsanti Consenti e Nega.
• Riprendi una conversazione di Claude Code iniziata in un terminale, metti in pausa le chat e torna più tardi, e salva i tuoi prompt.
• Un turno concluso dice cosa ha cambiato e quanto ci ha messo, con Continua e Rispondi direttamente nella notifica.
• Una guida per la prima connessione e un avviso quando la connessione è troppo scadente per lavorare.
• Condividi un codice invito dalle Impostazioni e ricevete entrambi tempo di relay gratis.
• Ogni funzione ora è gratuita. È limitato solo il tempo di relay fuori casa.
• Mettere l'app in background non consuma più tempo di relay, e il cursore del joystick segue il puntatore del tuo Mac.
• Correzioni minori e rifiniture.""",
"pt-BR": """• Aprove o Claude Code de qualquer terminal ou editor: ative os hooks e os botões Permitir e Negar aparecem no seu celular.
• Continue uma conversa do Claude Code que você começou em um terminal, pause conversas para voltar depois e salve seus próprios prompts.
• Uma resposta concluída diz o que mudou e quanto tempo levou, com Continuar e Responder direto na notificação.
• Um guia para a primeira conexão e um aviso quando a conexão está ruim demais para trabalhar.
• Compartilhe um código de convite em Ajustes e vocês dois ganham tempo de relay grátis.
• Todos os recursos agora são gratuitos. Só o tempo de relay fora de casa é limitado.
• Colocar o app em segundo plano não gasta mais tempo de relay, e o cursor do joystick acompanha o ponteiro do seu Mac.
• Pequenas correções e melhorias.""",
"ru": """• Одобряй Claude Code из любого терминала или редактора: включи хуки, и на телефоне появятся кнопки «Разрешить» и «Запретить».
• Продолжай диалог с Claude Code, начатый в терминале, ставь чаты на паузу и возвращайся к ним позже, сохраняй собственные промпты.
• Завершённый ход сообщает, что он изменил и сколько заняло, а «Продолжить» и «Ответить» доступны прямо в уведомлении.
• Подсказки для первого подключения и предупреждение, если соединение слишком плохое для работы.
• Поделись кодом приглашения в настройках, и вы оба получите бесплатное время ретранслятора.
• Теперь все функции бесплатны. Ограничено только время ретранслятора вне дома.
• Приложение в фоне больше не расходует время ретранслятора, а курсор джойстика следует за указателем твоего Mac.
• Мелкие исправления и улучшения.""",
"ja": """• Claude Codeの許可を、どのターミナルやエディタからでも。フックをオンにすると、iPhoneに「許可」と「拒否」のボタンが表示されます。
• ターミナルで始めたClaude Codeの会話を続けたり、チャットを一時停止して後で再開したり、自分のプロンプトを保存したりできます。
• 完了したターンでは、何を変更し、どれくらいかかったかを通知で確認でき、「続ける」と「返信」もそのまま使えます。
• 初回接続のガイドを追加し、接続が悪すぎて作業できないときは警告を表示します。
• 設定から招待コードを共有すると、2人ともリレー時間が無料で増えます。
• すべての機能が無料になりました。制限があるのは、外出先でのリレー時間だけです。
• アプリをバックグラウンドにしてもリレー時間を消費しなくなり、ジョイスティックのカーソルがMacのポインタと同じ位置に表示されます。
• 細かな修正と改善。""",
"ko": """• 어떤 터미널이나 편집기에서든 Claude Code를 승인하세요. 훅을 켜면 iPhone에 허용과 거부 버튼이 나타납니다.
• 터미널에서 시작한 Claude Code 대화를 이어가고, 채팅을 일시 중지했다가 나중에 다시 열고, 나만의 프롬프트를 저장할 수 있습니다.
• 끝난 턴은 무엇을 바꿨는지와 걸린 시간을 알려 주며, 알림에서 바로 계속과 답장을 누를 수 있습니다.
• 첫 연결 가이드가 추가되었고, 연결이 너무 나빠 작업하기 어려우면 경고가 표시됩니다.
• 설정에서 초대 코드를 공유하면 두 사람 모두 릴레이 시간을 무료로 받습니다.
• 이제 모든 기능이 무료입니다. 집 밖에서 쓰는 릴레이 시간만 제한됩니다.
• 앱이 백그라운드에 있어도 릴레이 시간이 소모되지 않고, 조이스틱 커서가 Mac의 포인터와 같은 위치를 유지합니다.
• 소소한 수정과 개선.""",
"zh-Hans": """• 在任何终端或编辑器中批准 Claude Code：开启钩子后，手机上会出现“允许”和“拒绝”按钮。
• 继续在终端里开始的 Claude Code 对话，暂停聊天稍后再回来，并保存你自己的提示词。
• 完成的回合会告诉你改了什么、花了多久，通知里可直接点“继续”和“回复”。
• 新增首次连接指南，连接差到无法工作时会给出提醒。
• 在设置中分享邀请码，你们两人都能获得免费的中继时间。
• 现在所有功能都免费，只有在外使用的中继时间有限制。
• 应用在后台时不再消耗中继时间，摇杆光标也会与 Mac 的指针保持同步。
• 一些细节修复和优化。""",
}
P = {
"en-US": "Approve Claude Code, Codex and OpenCode from your phone, then take over your Mac's screen and terminal. Every feature is free, with no account.",
"de-DE": "Genehmige Claude Code, Codex und OpenCode vom iPhone und übernimm dann Bildschirm und Terminal deines Macs. Alle Funktionen kostenlos, ohne Konto.",
"es-ES": "Aprueba Claude Code, Codex y OpenCode desde el móvil y toma el control de la pantalla y el terminal de tu Mac. Todo es gratis y sin cuenta.",
"fr-FR": "Approuve Claude Code, Codex et OpenCode depuis ton iPhone, puis prends la main sur l'écran et le terminal de ton Mac. Tout est gratuit, sans compte.",
"it": "Approva Claude Code, Codex e OpenCode dal telefono, poi prendi il controllo dello schermo e del terminale del tuo Mac. Tutto gratis, senza account.",
"pt-BR": "Aprove Claude Code, Codex e OpenCode pelo celular e assuma a tela e o terminal do seu Mac. Todos os recursos são gratuitos, sem conta.",
"ru": "Одобряй запросы Claude Code, Codex и OpenCode с телефона и управляй экраном и терминалом своего Mac. Все функции бесплатны, без аккаунта.",
"ja": "Claude Code、Codex、OpenCodeの許可をiPhoneから行い、Macの画面とターミナルもそのまま操作。すべての機能が無料で、アカウントは不要です。",
"ko": "Claude Code, Codex, OpenCode 요청을 iPhone에서 승인하고 Mac의 화면과 터미널까지 바로 제어하세요. 모든 기능이 무료이며 계정이 필요 없습니다.",
"zh-Hans": "在手机上批准 Claude Code、Codex 和 OpenCode 的请求，再接管 Mac 的屏幕和终端。所有功能免费，无需账号。",
}
for loc, promo in P.items():
    assert len(promo) <= 170 and "—" not in promo and "–" not in promo, (loc, len(promo))
    open(f"{OUT}/{loc}/promotional_text.txt", "w").write(promo + "\n")
for loc, text in N.items():
    assert len(text) <= 4000 and "—" not in text and "–" not in text, loc
    os.makedirs(f"{OUT}/{loc}", exist_ok=True)
    open(f"{OUT}/{loc}/release_notes.txt", "w").write(text + "\n")
print("ok", len(N))
