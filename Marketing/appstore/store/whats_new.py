"""Writes release_notes.txt for every locale into upload/metadata/<locale>/."""
import os
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "upload", "metadata")

N = {
"en-US": """• New: start your coding agents from your phone. Mac terminals now lists Claude Code, Codex, OpenCode, Hermes, Gemini CLI and Aider, shows only the ones installed on your Mac (with the latest Peering for Mac), and remembers when you last used each.
• Peering now speaks Spanish, French, German, Italian, Portuguese (Brazil), Russian, Japanese, Korean and Simplified Chinese.
• Smaller fixes and polish.""",
"de-DE": """• Neu: Starte deine Coding-Agenten vom iPhone aus. Mac-Terminals listet jetzt Claude Code, Codex, OpenCode, Hermes, Gemini CLI und Aider, zeigt nur die auf deinem Mac installierten (mit dem neuesten Peering für Mac) und merkt sich, wann du sie zuletzt benutzt hast.
• Peering spricht jetzt Spanisch, Französisch, Deutsch, Italienisch, brasilianisches Portugiesisch, Russisch, Japanisch, Koreanisch und vereinfachtes Chinesisch.
• Kleinere Korrekturen und Feinschliff.""",
"es-ES": """• Novedad: inicia tus agentes de código desde el móvil. Terminales del Mac ahora lista Claude Code, Codex, OpenCode, Hermes, Gemini CLI y Aider, muestra solo los instalados en tu Mac (con la última versión de Peering para Mac) y recuerda cuándo usaste cada uno por última vez.
• Peering ahora habla español, francés, alemán, italiano, portugués (Brasil), ruso, japonés, coreano y chino simplificado.
• Correcciones menores y mejoras.""",
"fr-FR": """• Nouveau : lance tes agents de code depuis ton iPhone. Terminaux Mac liste désormais Claude Code, Codex, OpenCode, Hermes, Gemini CLI et Aider, n'affiche que ceux installés sur ton Mac (avec la dernière version de Peering pour Mac) et retient quand tu as utilisé chacun pour la dernière fois.
• Peering parle maintenant espagnol, français, allemand, italien, portugais (Brésil), russe, japonais, coréen et chinois simplifié.
• Petites corrections et améliorations.""",
"it": """• Novità: avvia i tuoi agenti di codice dal telefono. Terminali Mac ora elenca Claude Code, Codex, OpenCode, Hermes, Gemini CLI e Aider, mostra solo quelli installati sul tuo Mac (con l'ultima versione di Peering per Mac) e ricorda quando hai usato ciascuno l'ultima volta.
• Peering ora parla spagnolo, francese, tedesco, italiano, portoghese (Brasile), russo, giapponese, coreano e cinese semplificato.
• Correzioni minori e rifiniture.""",
"pt-BR": """• Novidade: inicie seus agentes de código pelo celular. Terminais do Mac agora lista Claude Code, Codex, OpenCode, Hermes, Gemini CLI e Aider, mostra só os instalados no seu Mac (com o Peering para Mac mais recente) e lembra quando você usou cada um pela última vez.
• O Peering agora fala espanhol, francês, alemão, italiano, português (Brasil), russo, japonês, coreano e chinês simplificado.
• Pequenas correções e melhorias.""",
"ru": """• Новое: запускай своих агентов кода с телефона. «Терминалы Mac» теперь показывают Claude Code, Codex, OpenCode, Hermes, Gemini CLI и Aider, только те, что установлены на твоём Mac (с последней версией Peering для Mac), и помнят, когда ты в последний раз пользовался каждым.
• Peering теперь говорит по-испански, по-французски, по-немецки, по-итальянски, по-португальски (Бразилия), по-русски, по-японски, по-корейски и по-китайски (упрощённое письмо).
• Мелкие исправления и улучшения.""",
"ja": """• 新機能：コーディングエージェントをiPhoneから起動できます。「Macのターミナル」にClaude Code、Codex、OpenCode、Hermes、Gemini CLI、Aiderが並び、Macにインストールされているものだけを表示し（最新のPeering for Macが必要）、最後に使った時期も覚えています。
• Peeringがスペイン語、フランス語、ドイツ語、イタリア語、ポルトガル語（ブラジル）、ロシア語、日本語、韓国語、簡体字中国語に対応しました。
• 細かな修正と改善。""",
"ko": """• 새로운 기능: 코딩 에이전트를 iPhone에서 시작하세요. Mac 터미널에 Claude Code, Codex, OpenCode, Hermes, Gemini CLI, Aider가 나열되고, Mac에 설치된 것만 보여 주며(최신 Peering for Mac 필요) 마지막으로 사용한 시점을 기억합니다.
• Peering이 스페인어, 프랑스어, 독일어, 이탈리아어, 포르투갈어(브라질), 러시아어, 일본어, 한국어, 중국어 간체를 지원합니다.
• 소소한 수정과 개선.""",
"zh-Hans": """• 新功能：在手机上启动你的编程智能体。“Mac 终端”现在列出 Claude Code、Codex、OpenCode、Hermes、Gemini CLI 和 Aider，只显示你的 Mac 上已安装的（需要最新的 Peering for Mac），并记住你上次使用每一个的时间。
• Peering 现已支持西班牙语、法语、德语、意大利语、葡萄牙语（巴西）、俄语、日语、韩语和简体中文。
• 一些细节修复和优化。""",
}
for loc, text in N.items():
    assert len(text) <= 4000 and "—" not in text and "–" not in text, loc
    os.makedirs(f"{OUT}/{loc}", exist_ok=True)
    open(f"{OUT}/{loc}/release_notes.txt", "w").write(text + "\n")
print("ok", len(N))
