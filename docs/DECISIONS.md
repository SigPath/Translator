# Decyzje projektowe

Zapis decyzji podjętych samodzielnie w trakcie budowy, zgodnie z zasadą
"pytaj tylko o to, co naprawdę jest moją decyzją" z briefu.

## Tożsamość aplikacji
- Nazwa: **MB Translator**, bundle ID: `pl.mbgroup.translator` (potwierdzone przez użytkownika).

## Konta / dostępy
- Użytkownik potwierdził aktywne konto DeepL API Growth z dostępem do Voice API oraz konto
  ElevenLabs z Instant Voice Cloning. Budujemy od razu pod realne klucze API (przechowywane
  wyłącznie w Keychain), mocki tylko w testach jednostkowych.

## Wirtualne urządzenie audio (M1+)
- Domyślne i auto-wykrywane: **VB-Cable for Mac** (już zainstalowany i przetestowany przez
  użytkownika). BlackHole pozostaje na liście urządzeń jako opcja manualna, ale nie jest
  wymagany i nie ma dla niego dedykowanej instrukcji instalacji w onboardingu.

## Format audio ElevenLabs TTS (M3)
- Użyjemy **PCM 24 kHz (`pcm_24000`)** jako domyślnego formatu wyjściowego streamingu TTS —
  najwyższa jakość dostępna bez wymogu planu Pro (44.1 kHz wymaga planu Pro+; 16/22.05/24 kHz
  wymagają planu Creator+, który użytkownik i tak potrzebuje do Instant Voice Cloning).
  24 kHz mono jest w pełni wystarczające do rozmowy głosowej i prościej się konwertuje do
  wymagań urządzenia wyjściowego niż 44.1 kHz. Format będzie konfigurowalny, gdyby plan konta
  się zmienił.

## Zmiana silnika STT/MT: DeepL Voice API → Azure AI Speech (Speech Translation)
- Użytkownik ma gotowy, opłacony zasób **Azure AI Speech** (warstwa Standard S0,
  pay-as-you-go, bez rocznego zobowiązania):
  - Region: `northeurope`
  - Endpoint: `https://northeurope.api.cognitive.microsoft.com/`
  - Klucz API: przechowywany wyłącznie w Keychain użytkownika (nigdy w repo/kodzie).
- Decyzja: **od tego momentu Azure AI Speech (Speech Translation, real-time) zastępuje
  DeepL Voice API** jako silnik rozpoznawania mowy i tłumaczenia w Torze A (PL→EN) i
  Torze B (EN→PL). ElevenLabs pozostaje bez zmian jako silnik TTS/klonowania głosu.
  Architektura z protokołem `SpeechTranslationService` (M0) została zaprojektowana
  właśnie pod taką wymianę dostawcy bez przepisywania pipeline'u — ta zmiana to
  pierwszy praktyczny test tego założenia, jeszcze przed napisaniem Pipeline (M2).
- Sekcje "Format wiadomości DeepL Voice API" i "Billing DeepL a cisza w trwającej
  sesji" poniżej są **zachowane jako historyczny zapis** (mogą się przydać, gdyby
  DeepL Voice API miał wrócić jako drugi dostawca), ale **nie są już aktualnym
  planem implementacji** dla M2.

### SDK vs REST/WebSocket bezpośrednio (sprawdzone przed kodowaniem)
- Oficjalny `Microsoft Cognitive Services Speech SDK` dla iOS/macOS/Swift **nie jest
  dostępny przez Swift Package Manager** (potwierdzone: wątek
  `Azure-Samples/cognitive-services-speech-sdk#919` na GitHubie oraz oficjalna
  dokumentacja instalacji). Jedyne oficjalne metody to CocoaPods
  (`pod 'MicrosoftCognitiveServicesSpeech-macOS'`) albo ręczne dodanie pobranego
  binarnego `.xcframework` do projektu Xcode.
- Żadna z tych opcji nie pasuje do wymogu briefu "zależności przez SPM, możliwie
  minimalne": CocoaPods to osobny menedżer zależności obok SPM, a ręczny
  `.xcframework` to niewersjonowany binarny plik do ręcznego aktualizowania.
- **Decyzja: nie używamy oficjalnego Speech SDK.** W M2 zaimplementujemy klienta
  Azure Speech Translation bezpośrednio przez REST (`sts/v1.0/issueToken` do
  wymiany klucza na krótkotrwały token Bearer) + WebSocket, tak samo jak było
  zaplanowane dla DeepL — zero nowych zależności SPM, ta sama architektura
  `SpeechTranslationService`.
- Ryzyko do zaadresowania w M2: protokół WebSocket Azure Speech jest bardziej
  złożony niż DeepL — SDK jest "referencyjną implementacją protokołu", a same
  wiadomości WS mają formę zbliżoną do HTTP (nagłówki typu `Path`, `X-RequestId`,
  `X-Timestamp`, `Content-Type` osadzone w ramce tekstowej/binarnej), udokumentowaną
  jako "Websocket protocol reference" przez Microsoft, ale mniej bezpośrednio
  "kopiuj-wklej" niż czysto-JSON-owy protokół DeepL. Przed napisaniem klienta w M2
  odczytamy tę referencję dokładnie (nie zgadujemy formatu ramek), zamiast opierać
  się wyłącznie na tym podsumowaniu.
- Test połączenia w Ustawieniach (ten krok) celowo używa najprostszego możliwego
  endpointu (`issueToken`), właśnie po to, by zweryfikować klucz/region zero-effort,
  bez wdrażania jeszcze pełnego protokołu WebSocket.

## Format wiadomości DeepL Voice API (HISTORYCZNE — zastąpione przez Azure powyżej)
- `developers.deepl.com` jest zablokowany przez proxy sieciowe tego środowiska deweloperskiego
  (WebFetch → `EGRESS_BLOCKED`). Zamiast zgadywać format, sklonowano
  `https://github.com/DeepL/deepl-python` i odczytano
  `examples/voice/cli/deepl-voice-api-cli.py` (oficjalny przykład referencyjny wskazany w briefie).
- REST: `POST https://api.deepl.com/v3/voice/realtime`, body:
  `{source_media_content_type, source_language, source_language_mode, target_languages, formality, glossary_id}`,
  header `Authorization: DeepL-Auth-Key <key>`. Odpowiedź: `{token, streaming_url, session_id}`.
  WS URI = `streaming_url` + `?token=<token>`.
- WS wysyłka audio: `{"source_media_chunk": {"data": "<base64 PCM>"}}`.
  Koniec strumienia: `{"end_of_source_media": {}}`.
- WS odbiór: `source_transcript_update` i `target_transcript_update` (każdy z listami
  `concluded[]`/`tentative[]` fragmentów tekstu), `end_of_source_transcript`,
  `end_of_target_transcript` (z `language`), `end_of_stream`, `error`.
- Mikrofon w przykładzie referencyjnym używa `audio/pcm;encoding=s16le;rate=16000`, chunk
  ok. 200 ms (6400 bajtów). Będziemy trzymać się tego formatu w M2 (mono PCM16 16 kHz),
  zgodnie z briefem.
- Do zweryfikowania na żywo w M2 po uzyskaniu realnego dostępu: dokładny opis rate limitów
  WebSocketu i ewentualnych kodów błędów — przykład referencyjny nie dokumentuje tego
  wyczerpująco, a `developers.deepl.com/api-reference/voice/websocket-streaming` jest
  niedostępny z tego środowiska.

## Billing DeepL a cisza w trwającej sesji (HISTORYCZNE — patrz sekcja Azure powyżej)
- Potwierdzone: billing DeepL Voice API jest liczony per minuta strumienia audio źródłowego,
  zaokrąglana w górę do pełnej minuty (DeepL Help Center).
- Nie znaleziono jednoznacznego zapisu w dokumentacji (niedostępnej z tego środowiska) ani w
  wyszukiwaniu, czy cisza wysyłana w ramach **trwającej, otwartej** sesji WebSocket jest
  liczona do minut billingowych, czy tylko realny mówiony czas.
- Decyzja: **nie otwieramy nowej sesji DeepL na każdą wypowiedź** (użytkownik wyraźnie to
  wykluczył ze względu na zaokrąglanie w górę — otwieranie/zamykanie sesji co chwilę byłoby
  kosztowne niezależnie od odpowiedzi na powyższe pytanie). Zamiast tego w M2 wdrażamy prosty,
  zachowawczy VAD po stronie klienta, który **wstrzymuje wysyłkę** `source_media_chunk` podczas
  wykrytej ciszy (np. > 300 ms), ale **nie zamyka** WebSocketu — sesja pozostaje otwarta i żywa.
  To rozwiązanie jest bezpieczne niezależnie od reguł billingowych API (nie pogarsza sytuacji,
  a potencjalnie redukuje liczbę minut/obciążenie), i nie fragmentuje ciągłości napisów.
- Do zrobienia w M2: po realnych testach z produkcyjnym kontem porównać zużycie minut z VAD
  włączonym/wyłączonym na panelu użycia DeepL i ewentualnie dostrojić agresywność VAD.

## Regresja: okno Ustawień nie otwierało się z MenuBarExtra
- Zgłoszony problem: kliknięcie "Ustawienia…" w MenuBarExtra przestało otwierać
  okno Ustawień. Zweryfikowałem, czy to jest związane z poprawką `@unchecked
  Sendable` w `AudioSettingsStore` (poprzedni commit) — **nie jest**: ta zmiana
  dotyczyła wyłącznie deklaracji zgodności z protokołem w czasie kompilacji
  (`Sendable`), nie generuje żadnego kodu w czasie działania i nie dotyka
  żadnej ścieżki związanej z otwieraniem okien. Diff tego commitu obejmował
  jeden plik i cztery linijki komentarza + `: @unchecked Sendable` — potwierdzone
  przez `git show`. To osobny problem.
- Rzeczywista przyczyna: `SettingsLink`/`openSettings()` w aplikacjach typu
  "menu bar only" (`LSUIElement`/`NSApplication.ActivationPolicy.accessory`,
  czyli bez ikony w Docku — nasz przypadek od M0) jest **znanym, długotrwałym
  ograniczeniem SwiftUI/AppKit**, niezależnym od naszego kodu: scena Settings
  bywa zażądana bez faktycznej aktywacji aplikacji, więc okno nie wychodzi na
  wierzch (czasem działa, czasem nie — stąd wrażenie "wcześniej działało").
  Potwierdzone w co najmniej trzech niezależnych źródłach: wątek Apple
  Developer Forums #731628 ("Using SettingsLink from MenuBarExtra does not
  activate..."), zgłoszenie Apple Feedback Assistant FB10184971 ("There is no
  way to open the settings window from an app using only MenuBarExtra in
  SwiftUI"), oraz biblioteka `orchetect/SettingsAccess` stworzona specjalnie
  jako obejście tego ograniczenia.
- Poprawka: `MenuBarContentView` zamiast `SettingsLink` używa teraz
  `@Environment(\.openSettings)` + explicit `NSApplication.shared.activate()`
  wywołane **przed** `openSettings()`. Użyto nowego, niedeprecjonowanego
  `activate()` (bez parametrów) zamiast starszego `activate(ignoringOtherApps:)`,
  ponieważ ten drugi jest deprecjonowany od macOS 14 — a nasz deployment target
  to właśnie 14.2+, więc nie ma powodu używać starszego API.

## M1: routing audio na konkretne urządzenie wyjściowe
- Technika: `AVAudioEngine` + `AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, ...)`
  na `engine.outputNode.audioUnit`. Potwierdzone jako standardowa, produkcyjna
  technika — ten sam wzorzec występuje 1:1 w `AudioKit/AudioKit`
  (`AVAudioEngine+Devices.swift`, `setDevice(id:)`), niezależnie zweryfikowany
  w wątkach Apple Developer Forums. Nie zgadywałem API — dopiero po
  potwierdzeniu wzorca w co najmniej dwóch niezależnych źródłach.
  **Kolejność wywołań poprawiona po błędzie opisanym poniżej** — patrz
  "Bugfix: brak dźwięku / HALC_ProxyIOContext StartIO error 35".
- Enumeracja urządzeń: `AudioObjectGetPropertyData` na `kAudioObjectSystemObject`
  (`kAudioHardwarePropertyDevices`), nazwa/UID przez `kAudioObjectPropertyName`/
  `kAudioDevicePropertyDeviceUID` (jako `Unmanaged<CFString>`, żeby poprawnie
  przejąć własność zwróconego `CFStringRef`), liczba kanałów wejścia/wyjścia przez
  `kAudioDevicePropertyStreamConfiguration` w odpowiednim `scope`.
- Wybrane urządzenie wyjściowe jest identyfikowane przez **UID** (stabilny między
  restartami/odłączeniami), nie przez `AudioDeviceID` (może się zmienić). UID jest
  zapisywany w `UserDefaults` (`AudioSettingsStore`), **nie w Keychain** — to nie
  jest sekret, tylko preferencja użytkownika.
- Auto-wykrywanie VB-Cable: dopasowanie nazwy urządzenia zawierającej "VB-Cable"
  lub "VB-Audio" (case-insensitive). Przy pierwszym uruchomieniu (brak zapisanego
  UID) automatycznie wybierany jest pierwszy pasujący device; BlackHole i inne
  urządzenia pozostają na liście do wyboru ręcznego, zgodnie z wcześniejszą decyzją.
- Plik testowy: wygenerowany lokalnie 3-tonowy sygnał (A4→C#5→E5, ~1.45 s, WAV
  PCM16 mono 44.1 kHz) zamiast nagrania mowy — łatwy do jednoznacznego
  rozpoznania przez rozmówcę ("słyszę trzy rosnące dźwięki?") bez potrzeby
  angażowania jeszcze ElevenLabs/Azure na tym etapie. Odtwarzany przez
  `TestTonePlayer` niezależnie od domyślnego wyjścia systemowego.

## Bugfix: brak dźwięku / HALC_ProxyIOContext StartIO error 35
- Zgłoszony problem: "Odtwórz plik testowy" nie dawał dźwięku; w konsoli:
  `HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState
  returned error 35`, powtórzone 3x na kliknięcie. Kontekst: Teams już
  otwarty z mikrofonem = VB-Cable.
- Przyczyna (potwierdzona, nie zgadywana — patrz źródła): kod ustawiał
  `kAudioOutputUnitProperty_CurrentDevice` **po** `engine.attach(playerNode)`
  i `engine.connect(playerNode, to: engine.mainMixerNode, ...)`. Dotykanie
  `engine.mainMixerNode` **przed** zmianą urządzenia powoduje, że
  `AVAudioEngine` tworzy niejawne połączenie mixer→output z formatem
  bieżącym w tamtym momencie (czyli starego/domyślnego urządzenia). Po
  przełączeniu urządzenia to połączenie **nie jest automatycznie
  renegocjowane** — `engine.start()` próbuje wystartować IO na nowym
  urządzeniu (VB-Cable) z formatem odziedziczonym po innym. Jeśli VB-Cable
  ma już wynegocjowaną konkretną częstotliwość próbkowania przez innego
  klienta (Teams — zgodnie z hipotezą użytkownika), niezgodność formatu
  powoduje odmowę `StartIO` (błąd 35 to POSIX `EAGAIN`, "resource
  temporarily unavailable" — typowe dla tego rodzaju konfliktu formatu/HAL).
  Źródła potwierdzające ten wzorzec przyczyny i poprawki (nie zgadywane):
  wątek Apple Developer Forums o ustawianiu `kAudioOutputUnitProperty_
  CurrentDevice` na `inputNode` **przed** odczytem `outputFormat(forBus:)`
  (ta sama zasada dotyczy `outputNode`), oraz PR `sbooth/SFBAudioEngine#979`
  o unikaniu rekonekcji mixer→output przy nieprawidłowym/nieustalonym
  formacie urządzenia.
- Poprawka w `TestTonePlayer`:
  1. **Nowy `AVAudioEngine`/`AVAudioPlayerNode` na każde wywołanie
     `play(deviceID:)`** (zamiast reużywania jednej długo żyjącej instancji)
     — eliminuje całą klasę błędów wynikających z zaszłego stanu grafu po
     poprzednim urządzeniu.
  2. Urządzenie ustawiane jako **pierwsza czynność** na świeżym silniku —
     przed jakimkolwiek dotknięciem `mainMixerNode`/`outputNode`.
  3. Format połączenia mixer→output odczytywany explicite
     (`engine.outputNode.outputFormat(forBus: 0)`) **po** zmianie
     urządzenia, więc odzwierciedla faktyczny aktualny format sprzętu (czyli
     to, na czym już działa VB-Cable, jeśli inny klient go używa) — połączenie
     `mainMixerNode → outputNode` jest tworzone explicite z tym formatem,
     zamiast polegać na niejawnym/domyślnym połączeniu silnika.
     Połączenie `playerNode → mainMixerNode` może bezpiecznie używać formatu
     pliku WAV (44.1 kHz mono) — mixer sam przepróbkowuje wejścia.
  4. Guard przed połączeniem z formatem `sampleRate == 0` (udokumentowany w
     SFBAudioEngine#979 przypadek awarii przy nieustalonym formacie).
- To odpowiada wprost na hipotezy z zgłoszenia: (1) kolejność — teraz
  urządzenie jest ustawiane przed, nie po, konfiguracji węzłów; (2) format —
  teraz explicite dopasowywany do aktualnego stanu urządzenia, nie
  zakładany; (3) konflikt współbieżny z Teams — do zweryfikowania manualnie
  (patrz README, kroki testowe), ale poprawka #3 czyni kod odpornym na to,
  że VB-Cable ma już wynegocjowany format przez innego klienta, więc
  powinna działać w obu scenariuszach (Teams otwarty i zamknięty).
- **Potwierdzone z Teams** (rozmówca usłyszał pełny dźwięk testowy) — patrz
  jednak follow-up niżej, bo problem wrócił z WhatsApp.

## Follow-up bugfix: WhatsApp — "pyknięcie" + StartIO error 35 + IOWorkLoop overload (HISTORYCZNE — WhatsApp poza zakresem, patrz decyzja niżej)
- Zgłoszony problem: z Teams działa w pełni. Z WhatsApp Desktop (VB-Cable
  ustawione jako **domyślny mikrofon systemowy**, WhatsApp w aktywnym
  połączeniu) — tylko krótkie "pyknięcie", nie pełny dźwięk. Konsola:
  `StartIO error 35` (x2) + `IOWorkLoop: skipping cycle due to overload` +
  `IOWorkLoop: ... received an out of order message (got 769 want: 1)`.
- Różnica względem poprzedniego bugfixa: tamten adresował **sample rate**
  (`outputFormat(forBus:)` odczytywany po zmianie urządzenia). Komunikaty
  "overload"/"out of order" na work loopie IO wskazują na dodatkowy,
  nieaddresowany dotąd czynnik: **rozmiar bufora IO
  (`kAudioDevicePropertyBufferFrameSize`)** — to własność na poziomie
  urządzenia (nie per-klient), więc gdy drugi klient (nasz silnik) startuje
  z innym rozmiarem bufora niż już aktywny pierwszy klient (WhatsApp),
  serwer audio dostaje niezgodne żądania na tym samym real-time work loopie.
  Potwierdzone w źródłach (nie zgadywane):
  - Apple Developer Forums / dokumentacja: zalecenie odczytania
    `kAudioDevicePropertyBufferFrameSize` urządzenia i ustawienia
    `kAudioUnitProperty_MaximumFramesPerSlice` na output AudioUnit tak, by
    się zgadzały, dla `AVAudioEngine` w szczególności.
  - Forum VB-Audio (producenta VB-Cable): VB-CABLE ma wewnętrzny bufor
    ok. 2048 sampli i podłączone aplikacje muszą działać w ramach tego
    ograniczenia; niedopasowane rozmiary bufora powodują jitter/niestabilność
    z ich własnego doświadczenia — niezależne potwierdzenie, że to konkretnie
    bufor (nie tylko sample rate) jest częstym źródłem problemów przy wielu
    klientach na wirtualnym kablu.
- Poprawka w `TestTonePlayer`:
  1. Nowa funkcja `matchBufferSize`: odczytuje aktualny
     `kAudioDevicePropertyBufferFrameSize` urządzenia (**nie ustawiamy** go
     na urządzeniu — tylko odczytujemy to, co już jest aktywne, żeby nie
     zakłócić istniejącego klienta) i ustawia
     `kAudioUnitProperty_MaximumFramesPerSlice` na naszym output AudioUnit na
     tę samą wartość. Best-effort — błąd odczytu/zapisu jest logowany, ale
     nie przerywa odtwarzania (retry w kroku 2 i tak łapie resztkowe awarie).
  2. `engine.start()` jest teraz owinięty w retry: 3 próby (od razu, +150 ms,
     +400 ms) zanim zgłosimy błąd — na wypadek, gdy urządzenie jest w trakcie
     renegocjacji między dwoma klientami i chwilowo odmawia `StartIO`.
     Wymagało zmiany `play(deviceID:)` na `async throws` (wywołanie w
     `AudioSettingsTab` przeniesione do istniejącego `Task { }`).
- To odpowiada na hipotezy z tego zgłoszenia: (1) dopasowanie do aktywnego
  formatu — teraz obejmuje też rozmiar bufora, nie tylko sample rate;
  (2) retry z opóźnieniem — dodany; (3) czy WhatsApp jako "pierwszy właściciel"
  ogranicza drugiego klienta inaczej niż Teams — **nie da się tego ustalić z
  tego środowiska (brak Mac/VB-Cable/WhatsApp)**, to wymaga faktycznego testu
  po tej poprawce. Jeśli błąd nadal wystąpi z WhatsApp po tej zmianie, to
  będzie silny sygnał, że to jest granica możliwości sterownika VB-Cable przy
  konkretnie tej kombinacji klientów, nie coś do naprawienia po naszej
  stronie kodu — do zweryfikowania empirycznie, nie zgaduję z góry.

## M1: selekcja mikrofonu w WhatsApp Desktop (Mac) — zweryfikowane (HISTORYCZNE — WhatsApp poza zakresem, patrz decyzja niżej)
- **WhatsApp Desktop nie ma ekranu ustawień audio przed rozpoczęciem połączenia.**
  Wybór mikrofonu/kamery/głośnika jest dostępny wyłącznie **w trakcie trwającego
  połączenia**, pod menu trzech kropek ("⋯"). Źródła: How-To Geek, OSXDaily,
  wewnętrzne strony pomocy WhatsApp — potwierdzone niezależnie w kilku miejscach,
  nie zgadywane.
- **Domyślny wybór mikrofonu przy starcie połączenia = domyślne wejście systemowe
  macOS** (System Settings → Sound → Input), a nie ostatnio używane w WhatsApp.
  Oznacza to dwie praktyczne ścieżki dla użytkownika:
  1. Ustawić VB-Cable jako domyślny mikrofon systemowy w macOS **przed**
     rozpoczęciem rozmowy (i przywrócić poprzedni po rozmowie) — inwazyjne,
     wpływa na wszystkie aplikacje w systemie w tym czasie.
  2. Rozpocząć rozmowę z dowolnym mikrofonem, natychmiast otworzyć menu "⋯" w
     trakcie połączenia i przełączyć mikrofon na VB-Cable ręcznie — mniej
     inwazyjne, ale wymaga jednej dodatkowej czynności przy każdym połączeniu.
  Rekomendacja robocza: droga 2. w onboardingu/instrukcji dla WhatsApp (M5),
  ponieważ nie wymaga zmiany globalnego ustawienia systemowego.
- Kontrast z Teams/Zoom: te aplikacje mają trwały wybór urządzenia wejściowego
  we własnych Ustawieniach (przed połączeniem), więc nie mają tego ograniczenia —
  do potwierdzenia manualnie przy realnym teście w M1/M4, nie zakładam z góry.
- To jest czysto zewnętrzne ograniczenie WhatsApp (nie nasza aplikacja) — nie ma
  z naszej strony żadnego obejścia poza udokumentowaniem instrukcji dla
  użytkownika w onboardingu (M5).

## Zawężenie zakresu: tylko Microsoft Teams (WhatsApp Desktop i Zoom poza zakresem)
- Data: po zaliczeniu M1.
- Decyzja: **aplikacja wspiera odtąd wyłącznie Microsoft Teams** jako
  komunikator docelowy. WhatsApp Desktop i Zoom przestają być obsługiwanymi
  celami — nie inwestujemy dalej czasu w ich wsparcie.
- Powód:
  - **Teams**: test M1 zakończony sukcesem — plik testowy w pełni słyszalny
    u rozmówcy przez VB-Cable, bez dodatkowych obejść. Teams ma trwały,
    per-aplikacyjny wybór mikrofonu we własnych Ustawieniach, więc routing
    audio jest przewidywalny i stabilny.
  - **WhatsApp Desktop**: brak per-aplikacyjnego selektora mikrofonu —
    wymusza dziedziczenie **systemowego domyślnego** wejścia audio (patrz
    sekcje wyżej, HISTORYCZNE), co w praktyce oznacza dzielenie VB-Cable na
    poziomie całego systemu, a nie tylko z jedną aplikacją. To bezpośrednio
    doprowadziło do niestabilności `HALC_ProxyIOContext` (StartIO error 35,
    IOWorkLoop overload/out-of-order message) przy współbieżnym dostępie do
    urządzenia — zaadresowane częściowo (dopasowanie bufora + retry), ale
    fundamentalne ograniczenie architektury WhatsApp (brak kontroli nad
    momentem i sposobem współdzielenia urządzenia) pozostaje. Koszt dalszego
    utrzymania tej ścieżki (dodatkowe obejścia, niepewna stabilność u
    użytkownika) przewyższa wartość wsparcia tego komunikatora.
  - **Zoom**: nigdy nie był priorytetem testowym (patrz ustalenie z M0 —
    priorytet testów integracyjnych to Teams). Brak dedykowanego czasu na
    weryfikację nie jest tym samym co decyzja "nie działa" — po prostu
    świadomie rezygnujemy z inwestowania w jego wsparcie na tym etapie.
- Konsekwencje dla kodu i dokumentacji (wykonane w tym samym commicie):
  - Usunięty `ConversationApp` (enum + `AppState.selectedConversationApp`)
    i Picker "Komunikator" w `MenuBarContentView` — z jednym obsługiwanym
    komunikatorem selektor nie miał sensu jako UI (martwy wybór), więc
    usunięty całkowicie zamiast wyszarzenia opcji.
  - `AudioSettingsTab`/`TestTonePlayer`: teksty i komentarze zawężone do
    Teams.
  - README: instrukcje testowe dla WhatsApp/Zoom usunięte, M1 oznaczone
    jako zaliczone dla zakresu Teams.
  - M4 (Core Audio Process Tap): cel doprecyzowany jako wyłącznie proces
    Microsoft Teams — patrz zaktualizowany opis M4 w README.
- Poprzednie sekcje o WhatsApp (selekcja mikrofonu, bugfix bufora/StartIO)
  **pozostają w tym pliku jako zapis historyczny** (oznaczone
  "HISTORYCZNE" w nagłówkach) — dokumentują realną, zweryfikowaną wiedzę o
  Core Audio i architekturze WhatsApp, która może się przydać, gdyby decyzja
  kiedyś została odwrócona, ale nie opisują już aktualnego zakresu produktu.

## M2a: protokół WebSocket Azure Speech Translation ("USP") — zweryfikowany, nie zgadywany
- Kontekst: `developers.microsoft.com`/`learn.microsoft.com` są zablokowane w tym środowisku
  (jak wcześniej `developers.deepl.com`), a oficjalna dokumentacja i tak kieruje na SDK
  ("Speech translation isn't supported via REST API... You need to use the Speech SDK").
  Ponieważ SDK jest wykluczony (patrz decyzja o SPM wyżej), sklonowano oficjalne, MIT-licencjonowane
  repo `github.com/microsoft/cognitive-services-speech-sdk-js` i odczytano bezpośrednio kod
  źródłowy implementujący protokół — ten sam sposób weryfikacji co wcześniej dla DeepL
  (`deepl-python`) i AVAudioEngine routing (`AudioKit`). Żaden z poniższych szczegółów nie jest
  zgadywany.
- **Endpoint** (`TranslationConnectionFactory.ts`): domyślnie (V2)
  `wss://{region}.stt.speech.microsoft.com/stt/speech/universal/v2` z query params
  `from=<source>`, `to=<target>`, `scenario=interactive`.
- **Autoryzacja** (`CognitiveSubscriptionKeyAuthentication.ts`): nagłówek WS handshake
  `Ocp-Apim-Subscription-Key: <klucz>` bezpośrednio — **bez** wymiany na token przez
  `issueToken`. To inny (prostszy) tryb niż użyty w przycisku "Testuj połączenie" z M0
  (który celowo używa `issueToken` tylko do szybkiej walidacji klucza/regionu bez
  otwierania pełnego WebSocketu) — oba są poprawne, różne zastosowania. Dodatkowo
  nagłówki `X-ConnectionId` i `connectionId` (oba, dokładnie jak w SDK — bez próby
  "poprawiania" tego, co wygląda na duplikat, żeby nie odbiegać od zweryfikowanego wzorca).
- **Framing "USP"** (`WebsocketMessageFormatter.ts`, `SpeechConnectionMessage.Internal.ts`):
  - Tekstowe: `"{Header: value\r\n...}\r\n\r\n{treść}"`.
  - Binarne: `[2-bajtowy big-endian rozmiar nagłówków][nagłówki, każdy "Header: value\r\n"][treść]`.
  - Nagłówki: `Path`, `X-RequestId`, `X-Timestamp`, opcjonalnie `Content-Type`, `X-StreamId`
    (`HeaderNames.ts`).
- **Sekwencja wysyłki** (`ServiceRecognizerBase.ts`): `speech.config` (tekst, JSON telemetryczny —
  patrz `SpeechServiceConfig.ts`, głównie `context.system`/`context.os`, minimalna wersja
  wystarcza), `speech.context` (tekst, `{}` wystarcza dla M2a), potem binarne wiadomości
  `audio`: **pierwsza** z 44-bajtowym nagłówkiem WAV (RIFF/data size = 0, format streamingowy,
  bajt-po-bajcie odtworzony z `AudioStreamFormat.ts`) i `Content-Type: audio/x-wav`, kolejne
  to surowe ramki PCM16 bez `Content-Type`, wszystkie z tym samym `X-StreamId: "1"`. Koniec
  strumienia audio: binarna wiadomość `audio` z pustą treścią (`null`/`nil`).
- **Odbiór** (`TranslationServiceRecognizer.ts` + `ServiceMessages/Translation*.ts`): interesują
  nas ścieżki `translation.hypothesis` (robocza) i `translation.phrase` (finalna, tylko gdy
  `RecognitionStatus == "Success"`), JSON z polami `Text`/`DisplayText` (źródłowy tekst) i
  `Translation.Translations[].Text` (tłumaczenie). Inne ścieżki (`turn.start`, `turn.end`,
  `speech.startDetected/endDetected`, `translation.synthesis*`) są na razie ignorowane (logowane
  na poziomie debug) — nieistotne dla M2a (bez TTS, bez UI napisów), potrzebne dopiero w
  M2b/M3.
- Implementacja w `Sources/MBTranslator/Pipeline/USPMessage.swift` (koder/dekoder ramek) i
  `AzureSpeechTranslationService.swift` (sesja WS), 1:1 z powyższym, z komentarzami wskazującymi
  dokładne pliki źródłowe SDK jako uzasadnienie.

## M2a: auto-wznawianie sesji i VAD — zaimplementowane, częściowo nie do przetestowania tutaj
- Odnawianie sesji: proaktywne po 55 minutach (margines przed udokumentowanym limitem ~1h),
  przez otwarcie nowej sesji WebSocket i kontynuowanie tego samego iteratora audio (bez
  utraty danych z mikrofonu w trakcie przełączenia). **Uproszczenie:** nowe połączenie jest
  otwierane **po** zamknięciu starego (nie równolegle/zachodząco) — nie ma nakładania się
  dwóch aktywnych sesji w trakcie przełączenia. Prawdziwie bezszwowe odnawianie (bez
  najmniejszej przerwy w rozpoznawaniu) wymagałoby równoległego utrzymywania dwóch
  połączeń na krótką chwilę — odłożone jako możliwe dopracowanie, jeśli w testach na żywo
  okaże się zauważalne.
- Błędy połączenia: exponential backoff (2, 4, 8, 16, 30s, capped), rezygnacja po 5 kolejnych
  nieudanych próbach.
- **Uczciwie: nie mogę przetestować ani odnawiania po 55 minutach, ani backoffu w praktyce w
  tym środowisku** (brak Mac/mikrofonu/klucza Azure) — logika jest zaimplementowana zgodnie
  z opisem z briefu i zweryfikowanym protokołem, ale realne zachowanie przy zerwaniu
  połączenia lub długiej sesji wymaga testu na żywo przez użytkownika.
- VAD: reużyty próg i podejście z wcześniejszej decyzji (DeepL/Azure billing) —
  `VoiceActivityGate` wstrzymuje wysyłkę chunków audio po >300ms ciszy (RMS poniżej progu),
  bez zamykania sesji. Rozmiar chunku: ~100ms PCM16 16kHz mono, spójnie z wcześniejszym
  ustaleniem opartym o referencyjny przykład DeepL (Azure nie narzuca w znalezionej
  dokumentacji konkretnego rozmiaru chunku, więc trzymamy się już przyjętej wartości).

## M2a: brak nowego UI — reużyty istniejący przycisk Start/Stop
- Zgodnie z ustaleniem: M2a nie dodaje żadnego nowego UI. Istniejący przycisk Start/Stop w
  MenuBarExtra (dotąd tylko przełączający `appState.isRunning`/`status` bez żadnego efektu)
  jest teraz realnie podłączony do `TranslationPipelineController` — Start uruchamia
  mikrofon + sesję Azure, Stop je zatrzymuje. Błąd pipeline'u (np. brak zapisanych kluczy w
  Keychain) ustawia `appState.status = .error(...)`, co pokazuje się jako stan "Błąd" w menu
  (sama treść błędu nie jest jeszcze pokazywana w UI — tylko w logu/konsoli — to wystarcza na
  ten kamień milowy; czytelne komunikaty błędów w samym UI to zakres M5).
- Wynik (transkrypcja PL, tłumaczenie EN) trafia wyłącznie do `os.Logger` (kategoria
  "TranslationPipeline"), **domyślną prywatnością** (nie `.public`) — czyli widoczne w
  podłączonej konsoli debugowania Xcode (Xcode odtajnia wartości `private` dla aktywnej
  sesji debugowania), ale zredagowane w Console.app/logach systemowych poza Xcode, zgodnie z
  zasadą z briefu "bez logowania treści rozmów w buildzie release". Diagnostyka bez treści
  (błędy, statusy) używa `.public`, tak jak w reszcie kodu.

## Podpis / dystrybucja na etapie developmentu
- Do M6 budujemy z `CODE_SIGN_STYLE: Automatic` bez wymuszonego `DEVELOPMENT_TEAM` — Xcode
  pozwala podpisać i uruchomić lokalnie darmowym "Personal Team" (Apple ID bez płatnego
  członkostwa Developer Program). Hardened Runtime jest włączony od początku (entitlements:
  `audio-input`, `network.client`), ale bez App Sandbox, zgodnie z briefem. Developer ID +
  notaryzacja dopiero w M6.

## Generowane pliki
- `Sources/MBTranslator/Resources/MBTranslator.entitlements` jest generowany przez
  `xcodegen generate` z `project.yml` i nie jest commitowany (patrz `.gitignore`).
  `Info.plist` nie istnieje jako plik — używamy `GENERATE_INFOPLIST_FILE` i kluczy
  `INFOPLIST_KEY_*` bezpośrednio w `project.yml`.

## Środowisko deweloperskie tej sesji
- Ten kamień milowy (M0) został napisany w kontenerze **Linux** w chmurze, bez Xcode/Swift/
  SwiftUI/AppKit/Security frameworks (potwierdzone: brak `swift` w `PATH`). Kod został
  przygotowany i sprawdzony wzrokowo z najwyższą starannością, ale **nie został tu
  skompilowany ani przetestowany** — pierwsza realna kompilacja i pierwszy `xcodegen generate`
  muszą się odbyć na Macu użytkownika (patrz README.md, sekcja "Build i test na Macu").
