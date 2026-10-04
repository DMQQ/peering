"""Writes the localized App Store listing text into upload/metadata/<locale>/ and checks the length limits."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "upload", "metadata")

URLS = "{priv}: https://getpeering.app/privacy\n{terms}: https://getpeering.app/terms"

L = {}

L["de-DE"] = dict(
    name="Peering: Remote Desktop",
    subtitle="Dein Mac-Bildschirm, überall",
    promo="Dein Mac-Bildschirm in der Hosentasche. Einmal im eigenen Netzwerk koppeln, und er gehört dir von überall: direkt, wo es geht, sonst Ende-zu-Ende verschlüsselt.",
    keywords="mac,iphone,fernsteuerung,ssh,terminal,sftp,dateiübertragung,zwischenablage,wake on lan,bildschirm",
    desc="""Dein Mac-Bildschirm auf deinem iPhone.

Peering zeigt das Display deines Macs auf dem iPhone und lässt dich ihn steuern: Zeiger, Tastatur, echte Rechtsklicks und die Apps, die du zu öffnen vergessen hast. Es funktioniert in deinem eigenen Netzwerk und von überall sonst über ein Relay.

Einmal koppeln. Danach erkennen sich die beiden Geräte. Kein Konto, keine Anmeldung und nichts, das auf einem Server gespeichert wird.

SO FÄNGST DU AN

Peering besteht aus zwei Apps. Dies ist die iPhone-Hälfte; die Mac-Hälfte ist ein kostenloser Download auf getpeering.app. Installiere sie auf dem Mac, den du erreichen willst, und öffne sie einmal.

Koppele beide im selben Netzwerk oder netzwerkübergreifend mit dem sechsstelligen Code, den der Mac anzeigt. Danach gehört die Verbindung dir.

WAS ES KANN

• Jedes Display, eine laufende App oder ein einzelnes Fenster, umschaltbar ohne die Sitzung zu trennen
• Zeiger, Tastatur, Scrollrad, Rechtsklick und ein Joystick für alles, was einen braucht
• Auf dem iPad steuert ein Trackpad oder eine Maus den Zeiger des Macs: Hover, Klick, Rechtsklick und Scrollen
• F1 bis F12, Esc, Tab und die Steuertasten, die eine Handytastatur nicht tippen kann
• Zum Zoomen zusammenziehen, den ganzen Bildschirm einpassen oder das iPhone damit füllen
• Beobachtungsmodus, wenn du nur zuschauen willst, ohne Eingaben zu senden
• Ton vom Mac auf dem iPhone
• Bild-in-Bild, eine Live Activity und ein Widget, damit das Sperren des iPhones die Sitzung nicht beendet
• Jeder deiner Spaces, jeweils als antippbares Bild dargestellt
• Bildschirmfotos direkt in Fotos
• Eine App am Mac öffnen, die beim Verbinden noch nicht lief

PRIVAT VON GRUND AUF

• Direkt zwischen den beiden Geräten, wenn das Netzwerk es zulässt, sodass das Bild nie über einen Server läuft
• Ende-zu-Ende verschlüsselt über das Relay, wenn es nicht anders geht
• Jedes Gerät behält seinen eigenen Schlüssel und weist alles ab, was sich als das andere ausgibt
• Face-ID-Sperre, damit ein entsperrtes iPhone kein entsperrter Mac ist

BEHALTE DEINE CODING-AGENTEN IM BLICK

Starte Claude Code, Codex oder einen langen Build auf deinem Mac und geh weg. Wenn eine Shell auf dich wartet, etwa ein Coding-Agent, der um Erlaubnis fragt, ein sudo-Passwort oder eine Ja/Nein-Frage, meldet sich Peering, in Terminal- und iTerm-Fenstern ebenso wie in den eigenen. Tippe auf die Mitteilung und antworte vom iPhone aus.

AUCH EIN TERMINAL UND EIN DATEIBROWSER

• Vollbild-SSH-Sitzungen mit Schlüsseln, Passwörtern und Portweiterleitung
• Ein Dateibrowser auf dem Mac und auf deinen Servern: hochladen, herunterladen, umbenennen, löschen und ausführen, was er auflistet
• Zwischenablage, Makros und Kurzbefehle

KOSTENLOS, UND WAS EIN PLAN DAZUGIBT

Peering ist in deinem eigenen Netzwerk dauerhaft kostenlos: ein Mac, eine Shell auf einmal und jedes Display, jede App und jedes Fenster, die es zeigen kann. Relay und Pro sind dafür da, deinen Mac zu erreichen, wenn du nicht in der Nähe bist.

Warum ein Abonnement statt eines Einmalpreises: Unterwegs wird deine Sitzung über einen Relay-Server geführt, den wir betreiben, und dieser Server kostet jeden Monat Geld, in dem er läuft. Dein eigenes Netzwerk berührt ihn nie, deshalb ist dieser Teil kostenlos.

Peering für Mac ist erforderlich und ein kostenloser Download auf getpeering.app. Ohne sie hat diese App nichts, womit sie sich verbinden könnte.

Abonnements verlängern sich automatisch, sofern sie nicht mindestens 24 Stunden vor Ende des laufenden Zeitraums gekündigt werden, und werden deinem App-Store-Account belastet.

""" + URLS.format(priv="Datenschutzerklärung", terms="Nutzungsbedingungen"),
)

L["es-ES"] = dict(
    name="Peering: Escritorio remoto",
    subtitle="Tu Mac en pantalla, donde sea",
    promo="La pantalla de tu Mac en tu bolsillo. Vincula una vez en tu red y es tuya desde cualquier lugar: directa si la red lo permite, con cifrado de extremo a extremo si no.",
    keywords="mac,iphone,control remoto,compartir pantalla,ssh,terminal,sftp,archivos,portapapeles,wake on lan",
    desc="""La pantalla de tu Mac, en tu iPhone.

Peering muestra la pantalla de tu Mac en el móvil y te deja manejarla: puntero, teclado, clics derechos de verdad y las apps que olvidaste abrir. Funciona en tu propia red y, desde cualquier otro sitio, a través de un relay.

Vincula una vez. Desde entonces los dos dispositivos se reconocen. Sin cuenta, sin iniciar sesión y sin nada guardado en un servidor.

PARA EMPEZAR

Peering son dos apps. Esta es la mitad del iPhone; la mitad del Mac es una descarga gratuita en getpeering.app. Instálala en el Mac al que quieras acceder y ábrela una vez.

Vincúlalos en la misma red, o entre redes con el código de seis dígitos que muestra el Mac. Después, la conexión es tuya.

QUÉ HACE

• Cada pantalla, una app en ejecución o una sola ventana, intercambiables sin cortar la sesión
• Puntero, teclado, rueda de desplazamiento, clic derecho y un joystick para lo que lo pide
• En iPad, un trackpad o un ratón maneja el puntero del Mac: pasar el cursor, clic, clic derecho y desplazamiento
• F1 a F12, Esc, Tab y las teclas de control que un teclado de móvil no puede escribir
• Pellizca para hacer zoom, ajusta toda la pantalla o llena el móvil con ella
• Modo observador, para mirar sin enviar ninguna entrada
• El sonido del Mac, en el móvil
• Imagen en imagen, una Live Activity y un widget, para que bloquear el móvil no termine la sesión
• Todos tus Spaces, cada uno dibujado como una imagen que puedes tocar
• Capturas directas a Fotos
• Abre en el Mac una app que no estaba abierta cuando te conectaste

PRIVADO POR DISEÑO

• Directo entre los dos dispositivos cuando la red lo permite, de modo que la imagen nunca pasa por un servidor
• Cifrado de extremo a extremo a través del relay cuando no es posible
• Cada dispositivo guarda su propia clave y rechaza todo lo que se haga pasar por el otro
• Bloqueo con Face ID, para que un móvil desbloqueado no sea un Mac desbloqueado

VIGILA TUS AGENTES DE CÓDIGO

Inicia Claude Code, Codex o una compilación larga en tu Mac y aléjate. Cuando una shell se detiene a esperarte, ya sea un agente de código que pide permiso, una contraseña de sudo o un sí/no, Peering te avisa, tanto en ventanas de Terminal e iTerm como en las suyas. Toca el aviso y responde desde el móvil.

TAMBIÉN UN TERMINAL Y UN EXPLORADOR DE ARCHIVOS

• Sesiones SSH a pantalla completa con claves, contraseñas y reenvío de puertos
• Un explorador de archivos en el Mac y en tus servidores: sube, descarga, renombra, borra y ejecuta lo que lista
• Portapapeles, macros y comandos rápidos

GRATIS, Y LO QUE AÑADE UN PLAN

Peering es gratis en tu propia red todo el tiempo que quieras: un Mac, una shell a la vez y todas las pantallas, apps y ventanas que pueda mostrar. El relay y Pro sirven para llegar a tu Mac cuando estás lejos.

Por qué una suscripción y no un precio único: lejos de casa, tu sesión la lleva un servidor relay que gestionamos nosotros, y ese servidor cuesta dinero cada mes que está encendido. Tu propia red nunca pasa por él, y por eso esa parte es gratis.

Peering para Mac es necesario y es una descarga gratuita en getpeering.app. Sin él, esta app no tiene nada a lo que conectarse.

Las suscripciones se renuevan automáticamente a menos que se cancelen al menos 24 horas antes del final del periodo en curso, y se cargan a tu cuenta del App Store.

""" + URLS.format(priv="Política de privacidad", terms="Términos de uso"),
)

L["fr-FR"] = dict(
    name="Peering : Bureau à distance",
    subtitle="L'écran de ton Mac partout",
    promo="L'écran de ton Mac dans ta poche. Associe une fois sur ton réseau et il est à toi de n'importe où : en direct quand le réseau le permet, chiffré de bout en bout sinon.",
    keywords="mac,iphone,télécommande,partage d'écran,ssh,terminal,sftp,fichiers,presse-papiers,wake on lan",
    desc="""L'écran de ton Mac, sur ton iPhone.

Peering affiche l'écran de ton Mac sur ton téléphone et te laisse le piloter : pointeur, clavier, vrais clics droits et les apps que tu avais oublié d'ouvrir. Il fonctionne sur ton propre réseau, et de partout ailleurs via un relais.

Associe une seule fois. Ensuite, les deux appareils se reconnaissent. Pas de compte, pas de connexion et rien de stocké sur un serveur.

POUR COMMENCER

Peering se compose de deux apps. Voici la moitié iPhone ; la moitié Mac est un téléchargement gratuit sur getpeering.app. Installe-la sur le Mac que tu veux atteindre et ouvre-la une fois.

Associe-les sur le même réseau, ou entre réseaux avec le code à six chiffres que le Mac affiche. Après cela, la connexion est à toi.

CE QU'IL FAIT

• Chaque écran, une app en cours ou une seule fenêtre, au choix et sans couper la session
• Pointeur, clavier, molette, clic droit et un joystick pour ce qui en demande un
• Sur iPad, un trackpad ou une souris pilote le pointeur du Mac : survol, clic, clic droit et défilement
• F1 à F12, Échap, Tab et les touches de contrôle qu'un clavier de téléphone ne peut pas taper
• Pince pour zoomer, ajuste tout l'écran ou remplis le téléphone avec
• Mode observation, pour regarder sans envoyer de saisie
• Le son du Mac, sur le téléphone
• Image dans l'image, une Live Activity et un widget, pour que verrouiller le téléphone ne mette pas fin à la session
• Tous tes Spaces, chacun affiché comme une image sur laquelle appuyer
• Captures d'écran directement dans Photos
• Ouvre sur le Mac une app qui n'était pas lancée à la connexion

PRIVÉ PAR CONCEPTION

• En direct entre les deux appareils quand le réseau le permet, donc l'image ne passe jamais par un serveur
• Chiffré de bout en bout via le relais quand ce n'est pas possible
• Chaque appareil garde sa propre clé et refuse tout ce qui se fait passer pour l'autre
• Verrouillage par Face ID, pour qu'un téléphone déverrouillé ne soit pas un Mac déverrouillé

GARDE UN ŒIL SUR TES AGENTS DE CODE

Lance Claude Code, Codex ou une longue compilation sur ton Mac et éloigne-toi. Quand un shell s'arrête pour toi, qu'il s'agisse d'un agent de code qui demande une permission, d'un mot de passe sudo ou d'un oui/non, Peering te prévient, dans les fenêtres Terminal et iTerm comme dans les siennes. Touche la bannière et réponds depuis ton téléphone.

AUSSI UN TERMINAL ET UN EXPLORATEUR DE FICHIERS

• Sessions SSH plein écran avec clés, mots de passe et redirection de ports
• Un explorateur de fichiers sur le Mac et sur tes serveurs : envoyer, télécharger, renommer, supprimer et exécuter ce qu'il liste
• Presse-papiers, macros et commandes rapides

GRATUIT, ET CE QU'AJOUTE UNE FORMULE

Peering est gratuit sur ton propre réseau aussi longtemps que tu veux : un Mac, un shell à la fois, et tous les écrans, apps et fenêtres qu'il peut montrer. Le relais et Pro servent à atteindre ton Mac quand tu en es loin.

Pourquoi un abonnement plutôt qu'un prix unique : loin de chez toi, ta session passe par un serveur relais que nous faisons tourner, et ce serveur coûte de l'argent chaque mois où il est allumé. Ton propre réseau ne le touche jamais, c'est pourquoi cette partie est gratuite.

Peering pour Mac est indispensable et se télécharge gratuitement sur getpeering.app. Sans lui, cette app n'a rien à quoi se connecter.

Les abonnements se renouvellent automatiquement sauf annulation au moins 24 heures avant la fin de la période en cours, et sont facturés sur ton compte App Store.

""" + URLS.format(priv="Politique de confidentialité", terms="Conditions d'utilisation"),
)

L["it"] = dict(
    name="Peering: Desktop remoto",
    subtitle="Lo schermo del tuo Mac ovunque",
    promo="Lo schermo del tuo Mac in tasca. Abbina una volta sulla tua rete e sarà tuo da ovunque: diretto dove la rete lo consente, cifrato end to end dove no.",
    keywords="mac,iphone,controllo remoto,condivisione schermo,ssh,terminale,sftp,file,appunti,wake on lan",
    desc="""Lo schermo del tuo Mac, sul tuo iPhone.

Peering mostra lo schermo del tuo Mac sul telefono e ti lascia controllarlo: puntatore, tastiera, veri clic destro e le app che ti eri dimenticato di aprire. Funziona sulla tua rete e, da ogni altro posto, tramite un relay.

Abbina una volta. Da quel momento i due dispositivi si riconoscono. Nessun account, nessun accesso e niente salvato su un server.

PER INIZIARE

Peering è composto da due app. Questa è la metà per iPhone; la metà per Mac è un download gratuito su getpeering.app. Installala sul Mac che vuoi raggiungere e aprila una volta.

Abbinali sulla stessa rete, o tra reti diverse con il codice di sei cifre che mostra il Mac. Dopo, la connessione è tua.

COSA FA

• Ogni schermo, una singola app in esecuzione o una sola finestra, selezionabili senza interrompere la sessione
• Puntatore, tastiera, rotella di scorrimento, clic destro e un joystick per ciò che ne ha bisogno
• Su iPad, un trackpad o un mouse guida il puntatore del Mac: passaggio, clic, clic destro e scorrimento
• Da F1 a F12, Esc, Tab e i tasti di controllo che una tastiera da telefono non può digitare
• Pizzica per ingrandire, adatta tutto lo schermo o riempi il telefono con esso
• Modalità osservatore, per guardare senza inviare input
• L'audio del Mac, sul telefono
• Picture in Picture, una Live Activity e un widget, così bloccare il telefono non chiude la sessione
• Tutti i tuoi Spaces, ognuno mostrato come un'immagine da toccare
• Screenshot direttamente in Foto
• Apri sul Mac un'app che non era in esecuzione quando ti sei connesso

PRIVATO PER COSTRUZIONE

• Direttamente tra i due dispositivi quando la rete lo consente, così l'immagine non passa mai da un server
• Cifrato end to end tramite il relay quando non è possibile
• Ogni dispositivo conserva la propria chiave e rifiuta chiunque dica di essere l'altro
• Blocco con Face ID, perché un telefono sbloccato non sia un Mac sbloccato

TIENI D'OCCHIO I TUOI AGENTI DI CODICE

Avvia Claude Code, Codex o una lunga compilazione sul tuo Mac e allontanati. Quando una shell si ferma in attesa di te, che sia un agente di codice che chiede il permesso, una password sudo o un sì/no, Peering ti avvisa, nelle finestre di Terminale e iTerm come nelle sue. Tocca il banner e rispondi dal telefono.

ANCHE UN TERMINALE E UN BROWSER DI FILE

• Sessioni SSH a schermo intero con chiavi, password e inoltro delle porte
• Un browser di file sul Mac e sui tuoi server: carica, scarica, rinomina, elimina ed esegui ciò che elenca
• Appunti, macro e comandi rapidi

GRATIS, E COSA AGGIUNGE UN PIANO

Peering è gratuito sulla tua rete per tutto il tempo che vuoi: un Mac, una shell alla volta e ogni schermo, app e finestra che può mostrare. Relay e Pro servono a raggiungere il tuo Mac quando sei lontano.

Perché un abbonamento e non un prezzo una tantum: lontano da casa, la tua sessione è trasportata da un server relay che gestiamo noi, e quel server costa denaro ogni mese in cui è acceso. La tua rete non lo tocca mai, ed è per questo che quella parte è gratuita.

Peering per Mac è necessario ed è un download gratuito su getpeering.app. Senza, questa app non ha nulla a cui connettersi.

Gli abbonamenti si rinnovano automaticamente a meno che non vengano annullati almeno 24 ore prima della fine del periodo in corso, e vengono addebitati sul tuo account App Store.

""" + URLS.format(priv="Informativa sulla privacy", terms="Termini d'uso"),
)

L["pt-BR"] = dict(
    name="Peering: Acesso Remoto",
    subtitle="Sua tela do Mac, onde estiver",
    promo="A tela do seu Mac no bolso. Pareie uma vez na sua rede e ela é sua de qualquer lugar: direta onde a rede permite, com criptografia de ponta a ponta onde não.",
    keywords="mac,iphone,controle remoto,compartilhar tela,ssh,terminal,sftp,arquivos,wake on lan",
    desc="""A tela do seu Mac, no seu iPhone.

O Peering mostra a tela do seu Mac no celular e deixa você controlá-la: ponteiro, teclado, cliques com o botão direito de verdade e os apps que você esqueceu de abrir. Funciona na sua própria rede e, de qualquer outro lugar, por um relay.

Pareie uma vez. Dali em diante os dois dispositivos se reconhecem. Sem conta, sem login e nada guardado em servidor.

PARA COMEÇAR

O Peering são dois apps. Este é o do iPhone; o do Mac é um download gratuito em getpeering.app. Instale no Mac que você quer acessar e abra uma vez.

Pareie na mesma rede, ou entre redes diferentes com o código de seis dígitos que o Mac mostra. Depois disso, a conexão é sua.

O QUE ELE FAZ

• Cada tela, um app em execução ou uma única janela, alternáveis sem derrubar a sessão
• Ponteiro, teclado, roda de rolagem, clique direito e um joystick para o que pede um
• No iPad, um trackpad ou mouse controla o ponteiro do Mac: passar o cursor, clicar, clicar com o botão direito e rolar
• F1 a F12, Esc, Tab e as teclas de controle que o teclado de um celular não consegue digitar
• Pinça para dar zoom, ajuste a tela inteira ou preencha o celular com ela
• Modo observador, para assistir sem enviar nenhuma entrada
• O som do Mac, no celular
• Picture in Picture, uma Live Activity e um widget, para que bloquear o celular não encerre a sessão
• Todos os seus Spaces, cada um mostrado como uma imagem em que você pode tocar
• Capturas de tela direto para Fotos
• Abra no Mac um app que não estava aberto quando você se conectou

PRIVADO POR CONSTRUÇÃO

• Direto entre os dois dispositivos quando a rede permite, então a imagem nunca passa por um servidor
• Criptografado de ponta a ponta pelo relay quando não dá
• Cada dispositivo guarda a própria chave e recusa qualquer um que se passe pelo outro
• Bloqueio com Face ID, para que um celular desbloqueado não seja um Mac desbloqueado

FIQUE DE OLHO NOS SEUS AGENTES DE CÓDIGO

Inicie o Claude Code, o Codex ou uma compilação longa no seu Mac e se afaste. Quando um shell para esperando por você, seja um agente de código pedindo permissão, uma senha do sudo ou um sim/não, o Peering avisa, tanto nas janelas do Terminal e do iTerm quanto nas dele. Toque no aviso e responda pelo celular.

TAMBÉM UM TERMINAL E UM NAVEGADOR DE ARQUIVOS

• Sessões SSH em tela cheia com chaves, senhas e encaminhamento de portas
• Um navegador de arquivos no Mac e nos seus servidores: envie, baixe, renomeie, apague e execute o que ele lista
• Área de transferência, macros e comandos rápidos

GRÁTIS, E O QUE UM PLANO ACRESCENTA

O Peering é grátis na sua própria rede pelo tempo que você quiser: um Mac, um shell por vez e todas as telas, apps e janelas que ele puder mostrar. O relay e o Pro servem para alcançar o seu Mac quando você está longe dele.

Por que uma assinatura e não um preço único: longe de casa, a sua sessão é levada por um servidor relay que nós mantemos, e esse servidor custa dinheiro todo mês em que está ligado. A sua própria rede nunca passa por ele, e é por isso que essa parte é grátis.

O Peering para Mac é necessário e é um download gratuito em getpeering.app. Sem ele, este app não tem a que se conectar.

As assinaturas são renovadas automaticamente, a menos que sejam canceladas pelo menos 24 horas antes do fim do período atual, e são cobradas na sua conta da App Store.

""" + URLS.format(priv="Política de privacidade", terms="Termos de uso"),
)

L["ru"] = dict(
    name="Peering: Удалённый доступ",
    subtitle="Экран вашего Mac где угодно",
    promo="Экран Mac у тебя в кармане. Свяжи устройства один раз в своей сети, и он твой отовсюду: напрямую, где сеть позволяет, со сквозным шифрованием, где нет.",
    keywords="mac,iphone,управление,трансляция экрана,ssh,терминал,sftp,передача файлов,буфер обмена,wake on lan",
    desc="""Экран твоего Mac на твоём iPhone.

Peering показывает экран Mac на телефоне и позволяет им управлять: указатель, клавиатура, настоящий правый клик и приложения, которые ты забыл открыть. Работает в твоей собственной сети, а из любого другого места через ретранслятор.

Свяжи один раз. После этого два устройства узнают друг друга. Без аккаунта, без входа и без хранения чего-либо на сервере.

С ЧЕГО НАЧАТЬ

Peering состоит из двух приложений. Это половина для iPhone; половина для Mac бесплатно скачивается на getpeering.app. Установи её на Mac, до которого хочешь добраться, и открой один раз.

Свяжи их в одной сети или между разными сетями с помощью шестизначного кода, который показывает Mac. После этого соединение твоё.

ЧТО УМЕЕТ

• Любой экран, одно запущенное приложение или одно окно, с переключением без разрыва сеанса
• Указатель, клавиатура, колесо прокрутки, правый клик и джойстик там, где он нужен
• На iPad трекпад или мышь управляет указателем Mac: наведение, клик, правый клик и прокрутка
• F1 до F12, Esc, Tab и управляющие клавиши, которые клавиатура телефона набрать не может
• Щипок для масштаба, вписать весь экран или заполнить им телефон
• Режим наблюдения, когда нужно смотреть, ничего не отправляя
• Звук с Mac на телефоне
• «Картинка в картинке», Live Activity и виджет, чтобы блокировка телефона не обрывала сеанс
• Все твои рабочие столы (Spaces), каждый в виде картинки, по которой можно нажать
• Скриншоты сразу в «Фото»
• Открой на Mac приложение, которое не было запущено при подключении

ЧАСТНОЕ ПО УСТРОЙСТВУ

• Напрямую между двумя устройствами, когда сеть позволяет, так что картинка не проходит через сервер
• Со сквозным шифрованием через ретранслятор, когда иначе нельзя
• Каждое устройство хранит свой ключ и отвергает всё, что выдаёт себя за другое
• Блокировка Face ID, чтобы разблокированный телефон не означал разблокированный Mac

СЛЕДИ ЗА СВОИМИ АГЕНТАМИ КОДА

Запусти Claude Code, Codex или долгую сборку на своём Mac и отойди. Когда оболочка останавливается и ждёт тебя, будь то агент кода, просящий разрешение, пароль sudo или вопрос «да/нет», Peering сообщит, и в окнах Терминала и iTerm, и в своих. Нажми на уведомление и ответь с телефона.

А ЕЩЁ ТЕРМИНАЛ И ФАЙЛОВЫЙ МЕНЕДЖЕР

• Полноэкранные сеансы SSH с ключами, паролями и перенаправлением портов
• Файловый менеджер на Mac и на твоих серверах: загрузка, скачивание, переименование, удаление и запуск того, что он показывает
• Буфер обмена, макросы и быстрые команды

БЕСПЛАТНО, И ЧТО ДОБАВЛЯЕТ ПЛАН

Peering бесплатен в твоей собственной сети сколько угодно: один Mac, одна оболочка за раз и все экраны, приложения и окна, которые он может показать. Ретранслятор и Pro нужны, чтобы добраться до Mac, когда тебя нет рядом.

Почему подписка, а не разовая цена: вдали от дома твой сеанс несёт ретрансляционный сервер, который держим мы, и он стоит денег каждый месяц, пока включён. Твоя собственная сеть его не касается, поэтому эта часть бесплатна.

Peering для Mac обязателен и бесплатно скачивается на getpeering.app. Без него этому приложению не к чему подключаться.

Подписки продлеваются автоматически, если не отменить их минимум за 24 часа до конца текущего периода, и оплачиваются через твой аккаунт App Store.

""" + URLS.format(priv="Политика конфиденциальности", terms="Условия использования"),
)

L["ja"] = dict(
    name="Peering: リモートデスクトップ",
    subtitle="どこからでもMacの画面を操作",
    promo="Macの画面をポケットに。自分のネットワークで一度ペアリングすれば、どこからでも使えます。ネットワークが許せば直接、許さなければエンドツーエンド暗号化で接続します。",
    keywords="mac,iphone,リモート,遠隔操作,画面共有,ssh,ターミナル,sftp,ファイル転送,クリップボード,wake on lan",
    desc="""Macの画面を、iPhoneに。

PeeringはMacのディスプレイをiPhoneに表示して、そのまま操作できるようにします。ポインタ、キーボード、本物の右クリック、開き忘れていたアプリも。自分のネットワークの中でも、それ以外の場所からでもリレー経由で動作します。

ペアリングは一度だけ。以後、2台のデバイスはお互いを認識します。アカウントもサインインも不要で、サーバーには何も保存されません。

はじめかた

Peeringは2つのアプリでできています。これはiPhone側です。Mac側はgetpeering.appから無料でダウンロードできます。接続したいMacにインストールして、一度開いてください。

同じネットワーク内で、またはMacが表示する6桁のコードでネットワークをまたいでペアリングします。その後は、接続はあなたのものです。

できること

• すべてのディスプレイ、実行中のアプリ1つ、またはウインドウ1つを、セッションを切らずに切り替え
• ポインタ、キーボード、スクロールホイール、右クリック、必要な場面のためのジョイスティック
• iPadではトラックパッドやマウスでMacのポインタを操作：ホバー、クリック、右クリック、スクロール
• F1からF12、Esc、Tab、スマートフォンのキーボードでは打てないコントロールキー
• ピンチでズーム、画面全体に合わせる、またはiPhoneいっぱいに表示
• 入力を送らずに見るだけの観察モード
• Macの音をiPhoneで再生
• ピクチャインピクチャ、Live Activity、ウィジェットで、iPhoneをロックしてもセッションは終わりません
• すべてのSpacesを、タップできる画像として表示
• スクリーンショットを直接「写真」へ
• 接続時に起動していなかったMacのアプリを開く

設計からプライベート

• ネットワークが許せば2台のデバイス間で直接つながるため、画面はサーバーを経由しません
• それができない場合は、リレー経由でもエンドツーエンド暗号化
• 各デバイスが自分の鍵を持ち、相手になりすますものは拒否
• Face IDロックで、ロック解除したiPhoneがロック解除したMacにならないように

コーディングエージェントを見守る

MacでClaude CodeやCodex、長いビルドを開始して、その場を離れましょう。コーディングエージェントの許可リクエスト、sudoのパスワード、はい/いいえの確認など、シェルがあなたを待って止まると、PeeringがTerminalやiTermのウインドウでも自分のウインドウでも通知します。バナーをタップして、iPhoneから答えられます。

ターミナルとファイルブラウザも

• フルスクリーンのSSHセッション。鍵、パスワード、ポート転送に対応
• Macとサーバーのファイルブラウザでアップロード、ダウンロード、名前変更、削除、一覧にあるものの実行
• クリップボード、マクロ、クイックコマンド

無料で使える範囲と、プランで増えること

Peeringは自分のネットワーク内なら、いつまでも無料です。Mac1台、シェルは同時に1つ、表示できるすべてのディスプレイ、アプリ、ウインドウに対応します。リレーとProは、外出先からMacに接続するためのものです。

買い切りではなくサブスクリプションである理由：自宅の外では、セッションは当社が運用するリレーサーバーが運びます。そのサーバーは稼働している月ごとに費用がかかります。自分のネットワークはそこを通らないので、その部分は無料です。

Mac版Peeringは必須で、getpeering.appから無料でダウンロードできます。これがないと、このアプリには接続先がありません。

サブスクリプションは、現在の期間が終了する24時間以上前にキャンセルしない限り自動的に更新され、App Storeアカウントに請求されます。

""" + URLS.format(priv="プライバシーポリシー", terms="利用規約"),
)

L["ko"] = dict(
    name="Peering: 원격 데스크톱",
    subtitle="어디서나 내 Mac 화면을",
    promo="Mac 화면을 주머니 속에. 내 네트워크에서 한 번 페어링하면 어디서든 쓸 수 있습니다. 네트워크가 허용하면 직접, 아니면 종단 간 암호화로 연결합니다.",
    keywords="mac,iphone,원격 제어,화면 공유,ssh,터미널,sftp,파일 전송,클립보드,wake on lan",
    desc="""내 Mac 화면을 iPhone에서.

Peering은 Mac의 디스플레이를 iPhone에 보여 주고 직접 조작하게 해 줍니다. 포인터, 키보드, 진짜 오른쪽 클릭, 열어 두는 것을 잊은 앱까지. 내 네트워크에서는 물론 다른 어디에서든 릴레이를 통해 작동합니다.

한 번만 페어링하세요. 그 뒤로는 두 기기가 서로를 알아봅니다. 계정도, 로그인도 필요 없고 서버에 저장되는 것도 없습니다.

시작하기

Peering은 두 개의 앱으로 이루어져 있습니다. 이것은 iPhone용이고, Mac용은 getpeering.app에서 무료로 내려받을 수 있습니다. 연결하려는 Mac에 설치하고 한 번 열어 주세요.

같은 네트워크에서, 또는 Mac이 보여 주는 여섯 자리 코드로 다른 네트워크 사이에서 페어링합니다. 그 뒤로 연결은 내 것입니다.

할 수 있는 일

• 모든 디스플레이, 실행 중인 앱 하나, 또는 창 하나를 세션을 끊지 않고 전환
• 포인터, 키보드, 스크롤 휠, 오른쪽 클릭, 필요할 때 쓰는 조이스틱
• iPad에서는 트랙패드나 마우스로 Mac의 포인터를 조작: 호버, 클릭, 오른쪽 클릭, 스크롤
• F1부터 F12, Esc, Tab, 휴대폰 키보드로는 칠 수 없는 제어 키
• 핀치로 확대, 화면 전체 맞춤, 또는 iPhone을 가득 채우기
• 입력을 보내지 않고 지켜보기만 하는 관찰 모드
• Mac의 소리를 iPhone에서
• 화면 속 화면, Live Activity, 위젯으로 iPhone을 잠가도 세션이 끝나지 않습니다
• 모든 Spaces를 탭할 수 있는 이미지로 표시
• 스크린샷을 사진 앱으로 바로 저장
• 연결할 때 실행 중이 아니던 Mac의 앱 열기

설계부터 비공개

• 네트워크가 허용하면 두 기기 사이에서 직접 연결되어 화면이 서버를 거치지 않습니다
• 그럴 수 없을 때는 릴레이를 통해서도 종단 간 암호화
• 각 기기가 자신의 키를 보관하며 상대인 척하는 것은 거부
• Face ID 잠금으로 잠금이 풀린 iPhone이 잠금이 풀린 Mac이 되지 않게

코딩 에이전트를 지켜보세요

Mac에서 Claude Code나 Codex, 오래 걸리는 빌드를 시작하고 자리를 떠나세요. 코딩 에이전트의 권한 요청, sudo 암호, 예/아니요 질문처럼 셸이 나를 기다리며 멈추면 Peering이 터미널과 iTerm 창에서도, 자체 창에서도 알려 줍니다. 배너를 탭해서 iPhone에서 답하세요.

터미널과 파일 브라우저도

• 키, 암호, 포트 포워딩을 지원하는 전체 화면 SSH 세션
• Mac과 내 서버의 파일 브라우저: 업로드, 다운로드, 이름 변경, 삭제, 목록에 있는 것 실행
• 클립보드, 매크로, 빠른 명령

무료와 플랜이 더하는 것

Peering은 내 네트워크에서는 얼마든지 무료입니다. Mac 한 대, 한 번에 셸 하나, 그리고 보여 줄 수 있는 모든 디스플레이, 앱, 창. 릴레이와 Pro는 Mac에서 떨어져 있을 때 Mac에 닿기 위한 것입니다.

일회성 가격이 아니라 구독인 이유: 집 밖에서는 세션을 저희가 운영하는 릴레이 서버가 실어 나르는데, 그 서버는 켜져 있는 매달 비용이 듭니다. 내 네트워크는 그 서버를 전혀 거치지 않으므로 그 부분은 무료입니다.

Mac용 Peering은 필수이며 getpeering.app에서 무료로 내려받을 수 있습니다. 이것이 없으면 이 앱은 연결할 대상이 없습니다.

구독은 현재 기간이 끝나기 최소 24시간 전에 취소하지 않으면 자동으로 갱신되며, App Store 계정으로 청구됩니다.

""" + URLS.format(priv="개인정보 처리방침", terms="이용 약관"),
)

L["zh-Hans"] = dict(
    name="Peering: 远程桌面",
    subtitle="随时随地用你的 Mac 屏幕",
    promo="把 Mac 的屏幕装进口袋。在自己的网络里配对一次，随处都能使用：网络允许时直连，不允许时端到端加密。",
    keywords="mac,iphone,远程控制,屏幕共享,ssh,终端,sftp,文件传输,剪贴板,wake on lan",
    desc="""你的 Mac 屏幕，就在 iPhone 上。

Peering 把 Mac 的显示画面带到手机上，并让你直接操控：指针、键盘、真正的右键点击，还有你忘了打开的 App。在你自己的网络里可用，在其他任何地方则通过中继使用。

只需配对一次。此后两台设备会互相认出对方。无需账户，无需登录，服务器上不保存任何内容。

开始使用

Peering 由两个 App 组成。这是 iPhone 端；Mac 端可在 getpeering.app 免费下载。把它安装在你想连接的 Mac 上，并打开一次。

在同一网络中配对，或通过 Mac 显示的六位数字码跨网络配对。之后，这条连接就属于你。

它能做什么

• 任意显示器、一个正在运行的 App 或单个窗口，切换时不会断开会话
• 指针、键盘、滚轮、右键，以及在需要时使用的摇杆
• 在 iPad 上，触控板或鼠标可操控 Mac 的指针：悬停、点按、右键点按和滚动
• F1 到 F12、Esc、Tab，以及手机键盘无法输入的控制键
• 双指缩放、适应整个屏幕，或让画面铺满手机
• 观察模式，只看不发送任何输入
• 在手机上听到 Mac 的声音
• 画中画、实时活动和小组件，锁定手机也不会结束会话
• 你的每个 Space，都画成一张可点按的图片
• 截图直接存入“照片”
• 打开连接时还没运行的 Mac App

从设计上保护隐私

• 网络允许时在两台设备之间直连，画面绝不经过服务器
• 不允许时通过中继进行端到端加密
• 每台设备保管自己的密钥，拒绝任何冒充对方的内容
• Face ID 锁定，让解锁的手机不等于解锁的 Mac

留意你的编程智能体

在 Mac 上启动 Claude Code、Codex 或耗时较长的构建，然后放心走开。当 shell 停下来等你时，无论是编程智能体请求权限、sudo 密码还是是/否确认，Peering 都会通知你，终端和 iTerm 窗口里的也包括在内。点按通知，用手机回答。

还有终端和文件浏览器

• 全屏 SSH 会话，支持密钥、密码和端口转发
• Mac 和你的服务器上的文件浏览器：上传、下载、重命名、删除，并运行列表中的文件
• 剪贴板、宏和快捷命令

免费，以及方案增加的内容

在你自己的网络里，Peering 可以一直免费使用：一台 Mac，一次一个 shell，以及它能显示的所有显示器、App 和窗口。中继和 Pro 用于在你不在 Mac 身边时连接它。

为什么是订阅而不是一次性买断：离开家之后，你的会话由我们运营的中继服务器承载，这台服务器每开一个月就要花一个月的钱。你自己的网络从不经过它，所以那部分是免费的。

需要 Mac 版 Peering，可在 getpeering.app 免费下载。没有它，这个 App 没有可连接的对象。

订阅会自动续期，除非在当前周期结束至少 24 小时前取消，费用将从你的 App Store 账户扣除。

""" + URLS.format(priv="隐私政策", terms="使用条款"),
)

LIMITS = dict(name=30, subtitle=30, promo=170, keywords=100, desc=4000)
FILES = dict(name="name.txt", subtitle="subtitle.txt", promo="promotional_text.txt", keywords="keywords.txt", desc="description.txt")

bad = False
for loc, d in L.items():
    for k, lim in LIMITS.items():
        n = len(d[k])
        if n > lim:
            print(f"{loc} {k}: {n} > {lim}")
            bad = True
        for ch in ("—", "–"):
            if ch in d[k]:
                print(f"{loc} {k}: has a dash")
                bad = True
    if " " in d["keywords"].replace(", ", ""):
        pass
if bad:
    sys.exit(1)
for loc, d in L.items():
    os.makedirs(f"{OUT}/{loc}", exist_ok=True)
    for k, fn in FILES.items():
        open(f"{OUT}/{loc}/{fn}", "w").write(d[k].strip() + "\n")
print("ok", len(L), "locales")
