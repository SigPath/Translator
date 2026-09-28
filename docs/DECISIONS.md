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

## Bugfix M2a: cisza w konsoli, brak jakiegokolwiek logu, `throwing -10877` w konsoli systemowej
- Zgłoszony problem: status w menu poprawnie zmieniał się na "Tłumaczę", ikonka mikrofonu w
  pasku menu macOS aktywowała się, ale w konsoli Xcode nie pojawiła się **żadna** linia z
  loggera aplikacji (ani wynik, ani błąd) — tylko systemowe `throwing -10877` (`-10877` =
  `kAudioUnitErr_InvalidElement`).
- Diagnoza (potwierdzona wyszukiwaniem realnych zgłoszeń tego samego błędu, nie zgadywana):
  `-10877` przy instalowaniu tapu na `inputNode` na macOS jest dobrze znanym, dokumentowanym
  problemem, gdy tap dostaje format zapytany **osobno** wcześniej
  (`inputNode.outputFormat(forBus: 0)`), który bywa nieaktualny/niezgodny w momencie
  faktycznego instalowania tapu. Kluczowe znalezisko: to niedopasowanie ujawnia się jako
  **wyjątek Objective-C wewnątrz `installTap`**, którego **Swift `do/catch` nie przechwytuje**
  — stąd zero logów z naszego kodu: `engine.start()` nigdy nie zgłasza błędu (bo problem
  siedzi w samym `installTap`, nie w `start()`), a tap po prostu nigdy nie dostarcza realnych
  buforów. To wyjaśnia każdy zaobserwowany symptom naraz: status nie zmienia się na "Błąd"
  (nic nigdy nie throwuje), ikonka mikrofonu się aktywuje (system uznał, że sesja audio
  wystartowała), a strumień audio do Azure jest pusty (`AsyncStream` nigdy nie dostaje
  danych), więc WebSocket nigdy nie ma czego wysłać i nigdy nie przychodzi żadna odpowiedź.
- Poprawka w `MicrophoneCapture`: tap instalowany z **`format: nil`** zamiast osobno
  zapytanego formatu — to udokumentowane, zweryfikowane obejście (AVFAudio używa formatu,
  jaki węzeł faktycznie negocjuje w momencie instalacji, bez ryzyka nieaktualności). Konwerter
  `AVAudioConverter` budowany leniwie **wewnątrz** callbacku tapu, na podstawie `buffer.format`
  każdego bufora (zawsze aktualny z definicji, bo to format bufora, który faktycznie
  nadszedł), a nie z osobnego zapytania z wyprzedzeniem.
- Dodane tymczasowe `print()` (oznaczone `// TEMP (M2a debug)`) w `MicrophoneCapture`,
  `TranslationPipelineController` i `AzureSpeechTranslationService` w kluczowych punktach
  (start, pierwszy bufor z mikrofonu, połączenie WebSocket, wysłane wiadomości init, pierwsza
  odebrana wiadomość) — żeby jednoznacznie zlokalizować, w którym miejscu pipeline faktycznie
  się zatrzymuje, jeśli problem nie zniknie w całości od razu. Do usunięcia po potwierdzeniu,
  że pipeline działa (M2b albo porządki przy okazji M3).
- Usunięty case `MicrophoneCaptureError.converterCreationFailed` (i jego wpis w
  `Localizable.xcstrings`) — konwerter jest teraz tworzony leniwie wewnątrz tapu, więc `start()`
  nie może już zawieść z tego konkretnego powodu; zostawienie tego case'a byłoby martwym kodem.

### Follow-up: mikrofon działa, WebSocket łączy się, ale zero transkrypcji
- Zgłoszony problem (po powyższej poprawce): pełna sekwencja startowa przechodzi poprawnie
  (mikrofon, WebSocket, wysłane `speech.config`/`context`/nagłówek WAV), przychodzi pierwsza
  wiadomość od Azure, i zaraz potem strumień zdarzeń kończy się bez żadnej transkrypcji
  PL/EN — bez informacji, czy ta pierwsza wiadomość to błąd, `turn.start`, czy coś innego, i
  bez wiadomości, dlaczego połączenie/strumień się zakończyły.
- Rozszerzone tymczasowe logowanie (nadal `// TEMP (M2a debug)`, do usunięcia po
  potwierdzeniu): pełna surowa treść **każdej** odebranej wiadomości (nie tylko fakt jej
  odebrania) w `receiveLoop`; jawny powód zakończenia pętli wysyłania w
  `runSingleConnection` (koniec źródła audio / anulowanie / upływ czasu odnowienia sesji /
  błąd wysyłki, z treścią błędu); `closeCode`/`closeReason` z `URLSessionWebSocketTask`
  logowane zarówno po zamknięciu połączenia przez nas, jak i gdy `receive()` rzuci błąd
  (rozłączenie przez serwer); osobna gałąź na wypadek jawnej ścieżki `"error"` w USP.
  `receiveLoop` przebudowany, żeby sam łapał błąd z `receive()` i logował go z kontekstem
  zamiast pozwalać mu cicho przepaść w nigdy nieawaitowanym Tasku.
- Celowo nie zgaduję jeszcze przyczyny (błąd autoryzacji? zły nagłówek WAV? coś w samej
  ramce USP?) — to wymaga zobaczenia surowej odpowiedzi Azure z kolejnego testu, nie da się
  tego rozstrzygnąć z samego opisu symptomów.

### Follow-up: dwa niezależne błędy znalezione dzięki pełnym logom
Surowa treść z logu ujawniła, że pierwsza wiadomość to prawidłowy `turn.start` (nie błąd!),
ale nasz parser jej nie rozpoznał — plus osobny, niezależny błąd w `MicrophoneCapture`.

**Błąd 1 — parser nagłówków USP gubił `Path` (i wszystkie nagłówki poza pierwszym).**
Przyczyna (zweryfikowana, nie zgadywana): `parseHeaders` dzielił tekst na linie przez
`raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" })`. Swift traktuje `"\r\n"` jako
**pojedynczy** "extended grapheme cluster" (`Character`) — to udokumentowana właściwość
Unicode/Swift, nie błąd przeoczenia formatowania. Porównanie `$0 == "\r"` ani `$0 == "\n"`
**nigdy nie dopasowuje się** do połączonego znaku `"\r\n"`, więc `split` nie dzielił linii
wcale — cały tekst nagłówków trafiał do pętli jako jedna "linia", z której wyciągany był
tylko pierwszy klucz (`x-requestid`) z wartością zawierającą dosłownie resztę surowego
tekstu (w tym `Path:turn.start`) sklejoną w środku. Stąd `headers["path"]` było `nil` mimo
że `Path:` widać gołym okiem w logu. Ten sam problem dotyczył `text.range(of: "\r\n\r\n")`
w `parse(text:)` — o ile `range(of:)` samo w sobie nie ma tego problemu (szuka dosłownego
podciągu, nie porównuje znak-po-znaku), to jednak dla spójności i odporności na ewentualny
wariant z samym `\n\n` (bez `\r`) obie funkcje zostały przepisane, żeby najpierw
znormalizować `"\r\n"` → `"\n"` przez `replacingOccurrences` (operacja na treści podciągu,
nieobjęta pułapką grapheme cluster), a dopiero potem dzielić/szukać separatora.
**Ważne:** testy jednostkowe `USPMessageTests`, które napisałem w M2a, były zaprojektowane
poprawnie i **złapałyby ten błąd**, gdyby udało się je uruchomić — nigdy nie miałem tu
Xcode/Swift, więc nigdy faktycznie nie wykonały się przed tym zgłoszeniem. To dodatkowy,
namacalny argument, żeby przy okazji tego builda odpalić `xcodebuild test`, nie tylko `build`
— pierwszy raz w tym projekcie to coś realnie by wyłapało. Dodany dodatkowy test regresyjny
z dokładną, bajt-w-bajt treścią rzeczywistej wiadomości `turn.start` z tego zgłoszenia.

**Błąd 2 — strumień mikrofonu kończył się po jednym buforze (`audio source ended`).**
Diagnoza (architektoniczna, nie zgadywana na poziomie mechanizmu, ale nie zweryfikowana
bezpośrednim dowodem z logu — zaznaczam to uczciwie): `TranslationPipelineController` był
trzymany jako `@State` **wewnątrz `MenuBarContentView`** — czyli w widoku będącym treścią
popovera `MenuBarExtra`. Popover w stylu `.window` typowo bywa **zamykany i odtwarzany od
zera** przy każdym otwarciu/zamknięciu (typowe zachowanie menu — kliknięcie przycisku
zwykle zamyka menu). Gdyby tak się działo, `@State pipeline` (razem z żywym
`AVAudioEngine`/mikrofonem/WebSocketem) zostałby zwolniony przez ARC wkrótce po kliknięciu
Start, akurat wystarczająco szybko, żeby zdążył przelecieć jeden bufor, zanim wszystko
zostało zniszczone — co dokładnie pasuje do obserwacji. Poprawka: `TranslationPipelineController`
przeniesiony do `@State` na poziomie `MBTranslatorApp` (jedna instancja na cały czas życia
procesu, nie popovera) i wstrzykiwany do `MenuBarContentView` jako zwykły `let` parametr.
To poprawka bezpieczna niezależnie od tego, czy dokładnie ten mechanizm jest jedyną
przyczyną — trzymanie długo żyjącego stanu w `@State` widoku o niepewnym cyklu życia jest
błędem architektonicznym samym w sobie, wart naprawienia niezależnie.

### Follow-up: Błąd 2 nadal występuje mimo poprawki `@State` na poziomie `MBTranslatorApp`

Kolejny test wykluczył jedyną teorię z poprzedniej rundy: popover MenuBarExtra pozostał
otwarty przez cały czas (użytkownik nie zamykał menu), a strumień mikrofonu i tak urwał się
po jednym buforze, identycznie jak wcześniej. To dowodzi, że teoria "popover niszczy `@State`"
nie jest (jedyną) przyczyną — albo przeniesienie do `MBTranslatorApp` nie chroni tak, jak
zakładałem, albo przyczyna leży zupełnie gdzie indziej (np. w samym `MicrophoneCapture`/
`AVAudioEngine`, albo w pętli konsumującej strumień w `AzureSpeechTranslationService`).

Przejrzałem ręcznie cały łańcuch (`MicrophoneCapture` tap → `AsyncStream.Continuation` →
`TranslationPipelineController` → `AzureSpeechTranslationService.runSession`/`sendLoop`) i
**nie znalazłem żadnego miejsca w kodzie, które jawnie kończyłoby strumień przedwcześnie** —
jedyne wywołanie `continuation.finish()` jest w `MicrophoneCapture.stop()`, wywoływanym tylko
z: (a) początku `start()` (czyszczenie poprzedniej sesji — no-op przy pierwszym uruchomieniu),
(b) końca `TranslationPipelineController.run()` (już po zakończeniu pętli — skutek, nie
przyczyna), (c) kliknięcia Zatrzymaj (użytkownik go nie kliknął). Skoro `chunkIterator.next()`
zwraca `nil` (a nie po prostu wisi w nieskończoność), to `finish()` musiał się jednak gdzieś
wykonać — a skoro nie widać tego w przejrzanym kodzie, **zamiast zgadywać czwartą teorię bez
dowodu, dodałem w tej rundzie wyłącznie instrumentację diagnostyczną** (zgodnie z prośbą
użytkownika), żeby następny log dał jednoznaczną odpowiedź zamiast kolejnej hipotezy:

- `MicrophoneCapture`: `deinit` z `print` (czy instancja w ogóle ginie), licznik wywołań
  tapu logowany przy **każdym** wywołaniu (nie tylko pierwszym — poprzednio widoczne było
  tylko "first tap buffer", co nie dowodziło, że nie było kolejnych), wynik `continuation.yield()`
  logowany, gdy nie jest zwykłym `.enqueued` (`.terminated`/`.dropped` ujawniłyby, że coś
  innego już zakończyło strumień albo że bufor jest przepełniony), `stop(reason:)` — każde
  wywołanie loguje **kto i dlaczego** je wywołał oraz czy faktycznie wykonuje swoje ciało
  (guard mógł wcześniej cicho nic nie robić), oraz obserwator notyfikacji
  `AVAudioEngineConfigurationChange` (udokumentowana przez Apple przyczyna, dla której silnik/tap
  potrafi po cichu przestać dostarczać audio przy zmianie trasy/urządzenia wejściowego).
- `TranslationPipelineController`: `deinit` z `print` — jeśli wypisze się w trakcie mówienia
  (menu otwarte, Stop nie kliknięty), to bezpośredni dowód, że instancja na poziomie
  `MBTranslatorApp` jednak nie przeżywa tak długo, jak zakładałem, i trzeba szukać dalej
  (np. w samym mechanizmie `@State` dla `Scene`/`App` w tej wersji SwiftUI/macOS).
- `AzureSpeechTranslationService.runSingleConnection`: pętla `sendLoop` loguje teraz każdy
  odebrany chunk (numer, rozmiar), werdykt VAD (wysłany/pominięty jako cisza) i potwierdzenie
  wysłania przez WebSocket — poprzednio widoczny był tylko end-of-loop, więc nie było wiadomo,
  czy w ogóle dotarł więcej niż jeden chunk do tej warstwy.

To pozwoli w jednym kolejnym teście rozstrzygnąć, w którym dokładnie miejscu i dlaczego
strumień się kończy, zamiast zgadywać piąty raz.

### Follow-up: Błąd 2 zamknięty (fałszywy alarm), nowy realny problem — VAD gate odrzuca prawie całe audio jako ciszę

Instrumentacja z poprzedniej rundy dała jednoznaczną odpowiedź: 93 wywołania tapu, strumień
zakończony dokładnie przez `external stop() called` (czyli rzeczywiste kliknięcie Zatrzymaj),
bez żadnego przedwczesnego `DEINIT` ani nieoczekiwanego `stop(reason:)`. **Błąd 2 nie istniał
— w poprzednich testach użytkownik klikał Stop szybciej, niż mu się wydawało.** To potwierdza,
że poprawka `@State` na poziomie `MBTranslatorApp` z wcześniejszej rundy była (przynajmniej)
nieszkodliwa, a fundamentalnie problem leżał gdzie indziej niż w cyklu życia obiektów.

Prawdziwy problem ujawniony przez te same logi: `VoiceActivityGate` wysłał do Azure tylko
chunk #1 i #2, każdy kolejny (#3–#93) odrzucił jako ciszę — mimo ciągłej, wyraźnej mowy przez
kilkanaście sekund. Dwie rzeczy zweryfikowane (nie zgadywane) w tej rundzie:

1. **Realna przyczyna, zweryfikowana z oryginalnego nagłówka Apple (`AVAudioConverter.h`,
   właściwość `downmix`):** `"If YES and channel remapping is necessary, then channels will
   be mixed as appropriate instead of remapped. Default value is NO."` — mikrofon MacBooka
   dostarcza 2 kanały (stereo), a cel konwersji to 1 kanał (mono). Bez ustawienia `downmix`
   (domyślnie `NO`), `AVAudioConverter` przy redukcji liczby kanałów **nie miksuje** sygnału —
   po prostu bierze kanał 0 i **po cichu odrzuca resztę** (to "remapowanie", nie downmix).
   Jeśli kanał 0 wejścia z jakiegoś powodu niesie słabszy/inny sygnał niż realna mowa (np.
   dualne kapsuły mikrofonowe MacBooka, przetwarzanie beamforming/redukcja szumu inaczej
   rozłożone na kanały), efektem jest właśnie prawie-cisza po konwersji, mimo realnej mowy do
   mikrofonu. Naprawione: `converter.downmix = true` ustawiane jawnie w `MicrophoneCapture`
   zaraz po utworzeniu konwertera, żeby konwersja faktycznie miksowała oba kanały zamiast
   po cichu brać tylko jeden.
2. **Próg ciszy (`VoiceActivityDetector.defaultSilenceThreshold = 500`) nigdy nie był
   kalibrowany na realnym sprzęcie** — dobrany bez Maca, jako rozsądna wartość w skali Int16
   PCM (-32768…32767), ale niezweryfikowany. Zamiast zgadywać nową wartość, dodane zostało
   logowanie **rzeczywistego RMS każdego chunku obok werdyktu** (`chunk #N: ... amplitude=X,
   threshold=500, rawVerdict=silence/voice, gateDecision=send/skip`) — jeśli po poprawce
   `downmix` próg nadal będzie źle dobrany, następny log da dokładne liczby do kalibracji,
   zamiast kolejnego zgadywania.

Źródła (odczytane w tej rundzie, nie z pamięci): nagłówek `AVAudioConverter.h` (właściwości
`channelMap` i `downmix`) — https://github.com/zhayong/running/blob/master/Pods/AVFoundation.framework/Frameworks/AVFAudio.framework/Headers/AVAudioConverter.h
(zwierciadło rzeczywistego nagłówka Apple; treść zgodna z oficjalną dokumentacją Apple pod
`developer.apple.com/documentation/avfaudio/avaudioconverter/downmix`).

### Follow-up: `downmix = true` był regresją — amplituda=0.0 dla wszystkich 140 chunków

Kolejny test z dodanym logowaniem RMS ujawnił, że `converter.downmix = true` **nie naprawił**
problemu, tylko go pogłębił: `amplitude=0.0` dla **każdego** z 140 zalogowanych chunków, w tym
chunków #1 i #2, które i tak przeszły przez bramkę VAD (dzięki logice "wyślij, dopóki
`silentDurationMs < 300ms`" — czyli okresowi łaski po cichej wartości, a nie dlatego że
faktycznie niosły realny sygnał). Użytkownik mówił nieprzerwanie po polsku przez ~14 sekund —
realna mowa nie może dać dokładnie zera przez tak długi czas, więc podejrzenie padło albo na
błąd w samym liczeniu RMS, albo na dane wejściowe będące faktycznie samymi zerami.

Ręczna analiza `VoiceActivityDetector.rms` (dzielenie w `Double`, brak obcinania liczb
całkowitych, poprawny `bindMemory(to: Int16.self)` na tym samym buforze, który trafia do
`send(binary:)`) nie wykazała błędu w matematyce RMS. To przesuwa podejrzenie na konwersję w
`MicrophoneCapture`: `converter.downmix = true` polega na wewnętrznej, nieudokumentowanej
macierzy miksowania AVAudioConverter, która (jak wynika z tego testu) w tym konkretnym
przypadku — bufor z tapu bez jawnego `AVAudioChannelLayout` (`format: nil` go nie dostarcza)
— najwyraźniej **liczy się do zera** zamiast realnie zmiksować kanały. To nie jest zgadywanie
nowej teorii bez podstaw: to bezpośredni wniosek z pomiaru (poprzednia runda nie miała jeszcze
logowania amplitudy, więc nigdy nie zaobserwowaliśmy wartości "przed" tym fixem do porównania
— ale korelacja czasowa jest jednoznaczna: pierwszy test z logowaniem RMS to już test *z*
`downmix = true`, i wynik to płaska zero).

**Naprawione przez usunięcie zależności od `AVAudioConverter.downmix` w ogóle.** Zamiast tego:
ręczny, w pełni czytelny downmix do mono (uśrednienie próbek Float32 ze wszystkich kanałów,
klatka po klatce, w zwykłym kodzie Swift, który można zweryfikować wzrokiem), a dopiero
zmiksowany bufor mono trafia do `AVAudioConverter` — teraz już tylko do resamplingu i zmiany
głębi bitowej (Float32 48kHz mono → Int16 16kHz mono), czyli dokładnie tego, co
`AVAudioConverter` obsługuje w sposób prosty i dobrze udokumentowany (bez zmiany liczby
kanałów, więc `channelMap`/`downmix` w ogóle nie wchodzą w grę).

Dodane zabezpieczenie przed jeszcze jedną możliwą przyczyną zera: jeśli dwa kanały mikrofonu są
przesunięte w fazie (realny, choć rzadszy problem przy dualnych układach mikrofonowych z
przetwarzaniem sygnału), to uśrednianie ich **też** dałoby wynik bliski zeru — nie przez błąd w
kodzie, tylko przez fizyczne zniesienie sygnałów. Żeby to odróżnić od "kanały są już ciche u
źródła", dodane zostało logowanie RMS **każdego kanału z osobna, przed zmiksowaniem** (surowe
próbki Float32, nie po konwersji). Dodatkowo, na wyraźną prośbę użytkownika, dodany został
zrzut pierwszych 8 próbek Int16 z dokładnie tego samego bufora, na którym liczone jest RMS w
`AzureSpeechTranslationService` — to ostatecznie rozstrzygnie, czy dane faktycznie są zerami,
czy to jednak coś innego (błąd logowania, zła zmienna itp.).

**Uczciwie:** to jest najbardziej prawdopodobna, zweryfikowana logicznie przyczyna (usunięcie
zależności od nieprzewidywalnego, nieudokumentowanego zachowania biblioteki na rzecz kodu, który
można sprawdzić czytając go), ale — jak zawsze w tym środowisku bez Xcode — nie jest
potwierdzona realną kompilacją i uruchomieniem. Jeśli po tym fixie amplituda nadal będzie
zerowa, kolejny log (per-kanałowe RMS + zrzut próbek) powinien już jednoznacznie wskazać, gdzie
dokładnie ginie sygnał.

### Follow-up: kalibracja VAD — realne dane z Maca, próg `500` był 2–7x za wysoki

Potwierdzone na realnym sprzęcie: ręczny downmix zadziałał (RMS pre-mix niezerowe, capture
mikrofonu poprawny). Z pełnego logu (74 chunki, ~7s):
- cisza tła: `amplitude` ~9–25,
- wyraźna mowa: `amplitude` ~70–243,
- ustawiony próg `500` był więc **2–7x za wysoki** — nawet najgłośniejsza mowa (243) nie
  przekraczała progu, więc `rawVerdict=silence` dla każdego chunku poza pierwszymi dwoma
  (wysłanymi tylko dzięki okresowi łaski po ciszy, nie dlatego że rozpoznane jako mowa).

Poprawki:

1. **Domyślny próg obniżony z `500` do `50`** (`VoiceActivityDetector.defaultSilenceThreshold`)
   — wartość leżąca wyraźnie między zmierzoną ciszą (~9–25) a mową (~70–243), z marginesem.
   Służy teraz jako *dolny limit* (patrz punkt 3), nie jedyny próg.
2. **RMS pozostaje metodą liczenia amplitudy (nie peak), celowo:** RMS odzwierciedla energię
   uśrednioną po całym ~100ms chunku, więc pojedynczy trzask/pyknięcie nie rejestruje się jako
   "mowa" tak jak zrobiłby to peak, a cicha cisza tła z okazjonalnymi pikami też nie wywołuje
   fałszywego alarmu — to standardowy wybór dla tego typu bramkowania (voice activity gating),
   nie przeoczenie. Normalizacja względem pełnej skali Int16 (±32768) sama w sobie **nie**
   rozwiązałaby problemu niezależności od sprzętu/gainu — RMS już działa na stałej, sprzętowo
   niezależnej skali (Int16), a różnice między mikrofonami biorą się z fizycznego gainu/
   odległości/pomieszczenia, nie z jednostek pomiaru. To właśnie dlatego punkt 3
   (auto-kalibracja) jest realnym rozwiązaniem problemu przenośności między urządzeniami, a nie
   sama zmiana jednostki.
3. **Dodana auto-kalibracja progu w `VoiceActivityGate`:** przy starcie sesji gate mierzy poziom
   szumu tła przez pierwsze `calibrationDurationMs` (domyślnie 800ms ≈ 8 chunków po 100ms),
   przepuszczając cały ten dźwięk bez bramkowania (żeby nie zgubić mowy, gdyby użytkownik zaczął
   mówić natychmiast), a potem ustawia próg jako `noiseFloor * noiseMultiplier` (domyślnie
   `3.0`), z dolnym ograniczeniem `max(próg, minimumThreshold)` (domyślnie `50`, czyli
   `VoiceActivityDetector.defaultSilenceThreshold`) — żeby w bardzo cichym pomieszczeniu prawie
   zerowy szum tła nie dał progu bliskiego zeru (co uczyniłoby bramkę nadwrażliwą na najmniejsze
   drgnięcie). Dla danych z logu: `noiseFloor≈17 * 3 = 51` — dokładnie w środku między ciszą a
   mową, bez ręcznego strzelania liczbą. Istniejące testy (`gateStopsSendingAfterSustainedSilence`,
   `gateResumesOnSpeech`) używają teraz `presetThreshold:`, żeby pominąć kalibrację i dalej
   testować czystą logikę bramkowania w izolacji; dodane nowe testy pokrywają samą kalibrację
   (w tym clamp do `minimumThreshold`) i odtwarzają dokładnie scenariusz z tego zgłoszenia
   (szum ~20, mowa ~90, stary sztywny próg `500` by to zgubił).

**Znane ograniczenie, uczciwie nieukryte:** jeśli użytkownik zacznie mówić w ciągu pierwszych
~800ms po kliknięciu Start (w trakcie okna kalibracji), ta mowa zawyży zmierzony "szum tła",
podnosząc końcowy próg wyżej niż powinien być. Rozwiązanie tego (np. odrzucanie outlierów przy
liczeniu średniej) uznane za niewarte dodatkowej złożoności na tym etapie — 800ms to krótkie
okno, a normalny przepływ (kliknięcie Start, chwila, potem mówienie) i tak je pokrywa.

### Follow-up: VAD działa, mowa jest rozpoznawana (`speech.hypothesis`) — ale nigdy nie tłumaczona

Live test na Macu: kalibracja VAD wyszła `50.0` jak przewidziano, a Azure zaczął zwracać
narastające `speech.hypothesis` podczas mówienia — pipeline audio→Azure działa od początku do
końca. Ale w logu nie było ani jednej wiadomości `translation.hypothesis`/`translation.phrase`,
mimo że `handle(path:message:continuation:)` w `AzureSpeechTranslationService` **już od dawna
poprawnie je obsługiwał** (wyciąga `Text`/`Translation.Translations[].Text` przez
`decodeTranslationBody` i loguje jako `PL (finalne):`/`EN (finalne):`) — te ścieżki po prostu
nigdy nie nadchodziły od serwera.

**Rzeczywista przyczyna (zweryfikowana wprost w źródle JS SDK, nie zgadywana):** wysyłana
wiadomość `speech.context` miała treść `"{}"` — pustą. Sprawdzone w
`ServiceRecognizerBase.ts`, metoda `setTranslationJson()`:

```typescript
this.privSpeechContext.getContext().translation = {
  onPassthrough: { action },
  onSuccess: { action },
  output: {
    includePassThroughResults: true,
    interimResults: { mode: Mode.Always }
  },
  targetLanguages: languages,
};
```

— to właśnie ten obiekt `translation` w treści `speech.context` (nie same parametry URL
`from`/`to`, które już wcześniej wysyłaliśmy poprawnie) mówi serwerowi Azure "to jest sesja
tłumaczenia, wysyłaj `translation.*`". Bez niego serwer po prostu robi zwykłe rozpoznawanie
mowy i zwraca tylko `speech.hypothesis`/`speech.phrase` (potwierdzone też przez `output.
includePassThroughResults: true` — to dokładnie ta flaga odpowiada za to, że surowe,
nieprzetłumaczone wyniki rozpoznawania w ogóle się pojawiają, obok tłumaczenia).

`action` pochodzi z `enum NextAction { None = "None", Synthesize = "Synthesize" }`
(`ServiceMessages/Translation/OnSuccess.ts`) — `"Synthesize"` włącza syntezę mowy PO STRONIE
AZURE, czego nie chcemy (ElevenLabs robi TTS, zgodnie z briefem), więc używamy `"None"`, tak jak
SDK robi to domyślnie przy braku skonfigurowanego `translationVoice`. `Mode.Always`
(`ServiceMessages/Translation/InterimResults.ts`) to jedyna sensowna wartość dla wyników
częściowych na żywo.

**Naprawione:** `speechContextMessage` teraz buduje pełny obiekt `translation` z docelowym
językiem (zamiast `"{}"`), z komentarzem cytującym dokładne źródło. Bez zmian w logice
`handle()` dla `translation.hypothesis`/`translation.phrase` — była już poprawna.

**Dodatkowo:** `speech.hypothesis`/`speech.phrase` dostały teraz jawny (nie tylko przez
`default:`) case w `handle()`, świadomie ignorowany — to te same dane źródłowe (PL), które
`translation.hypothesis`/`translation.phrase` i tak niosą we własnym polu `Text`, więc
obsługiwanie ich też dawałoby zdublowane zdarzenia `sourcePartial`/`sourceFinal` na każdą
wypowiedź.

Źródła (odczytane w tej rundzie z rzeczywistego kodu SDK, nie z pamięci):
`ServiceRecognizerBase.ts` (`setTranslationJson`),
`ServiceMessages/Translation/OnSuccess.ts` (`enum NextAction`),
`ServiceMessages/Translation/InterimResults.ts` (`enum Mode`),
`ServiceMessages/TranslationHypothesis.ts` (`ITranslationHypothesis` — potwierdza pola `Text`/
`Translation` zgodne z tym, co już dekodowaliśmy) — wszystko z
`github.com/microsoft/cognitive-services-speech-sdk-js`.

### Follow-up: fix `speech.context` nie pomógł — dalsza weryfikacja punkt po punkcie

Test po poprzednim fixie: nadal wyłącznie `speech.hypothesis`, zero `translation.*`, mimo
~9s ciągłej mowy. To wymagało dokładniejszej weryfikacji niż poprzednio — tym razem przez
GitHub Code Search API (`mcp__github__search_code`), które zwraca bajt-w-bajt fragmenty
rzeczywistych plików z repo, zamiast polegać na streszczeniach modelu przez `WebFetch` (ten
sposób okazał się zawodny w tej rundzie — dla niektórych plików odmawiał dosłownego cytowania
z powodu "copyright" i parafrazował zamiast cytować, co jest nie do zaakceptowania przy
weryfikacji protokołu bajt-po-bajcie). Sprawdzone punkt po punkcie:

1. **Treść JSON `speech.context` — potwierdzona bajt-w-bajt zgodna ze źródłem.** Bezpośredni
   fragment z `ServiceRecognizerBase.ts` przez code search:
   ```typescript
   onPassthrough: { action },
   onSuccess: { action },
   output: {
       includePassThroughResults: true,
       interimResults: { mode: Mode.Always }
   },
   targetLanguages: languages,
   ```
   Nasz wysyłany JSON strukturalnie się zgadza. `SpeechContext.toJSON()` = `JSON.stringify(this.
   privContext)` bez żadnego opakowania (klucz `translation` jest na najwyższym poziomie, nie
   zagnieżdżony pod `context`) — też się zgadza z tym, co wysyłamy.
2. **Endpoint i parametry URL — potwierdzone zgodne.** `TranslationRecognizer` używa
   `TranslationConnectionFactory` (nie osobnej klasy dla V1), domyślnie
   `wss://{region}.stt.speech.microsoft.com/stt/speech/universal/v2` — dokładnie ten sam URL,
   którego używamy. Kolejność wysyłanych wiadomości (`sendSpeechContext` → `sendWaveHeader`)
   też się zgadza z naszą (`speech.config` → `speech.context` → nagłówek WAV).
3. **Region `northeurope` — potwierdzone wspiera Speech Translation** (oficjalna tabela regionów
   Microsoft, `regions.md`) — to wyklucza "zły region" jako przyczynę.
4. **Format kodu języka docelowego — potwierdzone poprawny.** Oficjalna dokumentacja
   (`spx-basics.md`): *"With few exceptions you only specify the language code that precedes
   the locale dash separator... The default language is `en` if you don't specify a
   language."* — nasze `targetLanguages: ["en"]` (bez regionu) jest dokładnie tym, czego
   oczekuje Azure, nie błędem formatu.
5. **Warstwa cenowa F0 (darmowa) — prawdopodobnie nie jest przyczyną**, ale nie da się tego
   wykluczyć zdalnie: F0 ma limit 5h/miesiąc na Speech Translation i limit **1 równoległego
   połączenia** (współdzielony ze zwykłym rozpoznawaniem mowy) — ale dokumentacja nie sugeruje,
   że F0 po cichu wyłącza sam mechanizm tłumaczenia; ograniczenia są ilościowe, nie
   funkcjonalne. To jednak jedyny punkt z całej listy, którego nie da się zweryfikować z
   zewnątrz — wymaga sprawdzenia w Azure Portal albo niezależnego testu (patrz niżej).

**Nic z powyższego nie tłumaczy obserwowanego zachowania.** Zamiast zgadywać szóstą teorię,
dwa konkretne, zweryfikowane kroki na tę rundę:

- **Surowe logowanie bajt-w-bajt** wysyłanej treści `speech.context` (i każdej innej wiadomości
  tekstowej) *bezpośrednio w miejscu wywołania `task.send(...)`* w `AzureSpeechTranslationService.
  send(text:on:)` — to gwarantuje, że widzimy dokładnie to, co faktycznie leci po drucie, a nie
  to, co kod *powinien* wygenerować (odpowiedź na punkt 1 zgłoszenia).
- **Niezależny test przez oficjalne narzędzie Microsoftu (Speech CLI, `spx`)** z tym samym
  kluczem/regionem, bez żadnego naszego kodu pośrodku — jeśli `spx` też nie przetłumaczy, to
  jednoznacznie izoluje problem do konta/subskrypcji (punkt 4 zgłoszenia), niezależnie od
  czegokolwiek w naszej implementacji USP. Jeśli `spx` zadziała, to jednoznacznie wskazuje na
  błąd w naszym protokole — a wtedy surowy log z punktu wyżej da materiał do dalszego
  porównania. Dokładne instrukcje w README.md.

### Follow-up: znaleziony rzeczywisty błąd — `speech.context` miał kompletnie inną strukturę niż powinien

Użytkownik przetestował tłumaczenie niezależnie przez oficjalne Python SDK (`azure-
cognitiveservices-speech`, klasa `TranslationRecognizer`) z tym samym kluczem/regionem —
**zadziałało bez zarzutu**, co jednoznacznie wykluczyło konto/subskrypcję/region jako
przyczynę i wskazało błąd wyłącznie w naszej implementacji protokołu USP.

Zamiast kolejnego porównania kod-do-kodu (poprzednia metoda — czytanie TypeScript przez
`WebFetch` — okazała się zawodna: podsumowujący model czasem parafrazował miejsce zgadywania
literalnego cytowania, a jak się okazało, ŹLE zinterpretowałem/zacytowałem strukturę
`speech.context` dla tego konkretnego endpointu), zweryfikowałem to na poziomie **rzeczywistych
bajtów na przewodzie**, dokładnie jak zaproponował użytkownik:

1. Zainstalowałem lokalnie (w tym kontenerze) oficjalny pakiet `azure-cognitiveservices-speech`
   (`pip install`) — to ten sam natywny "Carbon" core C++, na którym opierają się WSZYSTKIE
   oficjalne bindingi SDK (Python, JS, C#, ...), więc jego zachowanie protokołu jest
   autorytatywne, nie tylko dla Pythona.
2. Napisałem minimalny skrypt z `PushAudioInputStream` (syntetyczne audio, bez mikrofonu) i
   **fałszywym** kluczem subskrypcji — fałszywy klucz nie przeszkadza w obserwacji, bo SDK
   konstruuje i loguje wiadomości USP *przed* tym, jak serwer odrzuci połączenie z błędem
   autoryzacji (żądanie WebSocket upgrade dostaje 403, ale to już PO tym, jak klient zbudował
   `speech.config`/`speech.context`).
3. Włączyłem natywne logowanie protokołu SDK przez `SpeechTranslationConfig.set_property(
   PropertyId.Speech_LogFilename, "...")`.
4. W logu, linia `usp_reco_engine_adapter.cpp:1329`, znalazła się **dokładna, rzeczywista**
   treść `speech.context`, jaką realny klient wysyła dla scenariusza tłumaczenia PL→EN:
   ```json
   {"phraseDetection":{"mode":"INTERACTIVE","language":"pl-PL","onSuccess":{"action":"Translate"},"onInterim":{"action":"Translate"}},"translation":{"targetLanguages":["en"],"output":{"includePassThroughResults":true}},"audio":{"streams":{"1":null}}}
   ```

**To jest fundamentalnie inna struktura niż to, co wysyłaliśmy.** Rzeczywisty przełącznik
trybu tłumaczenia to `phraseDetection.onSuccess`/`onInterim` z `"action":"Translate"` — **nie**
`translation.onSuccess`/`onPassthrough`, jak wcześniej (błędnie) wywnioskowałem z
`ServiceRecognizerBase.setTranslationJson()` w JS SDK. Sam obiekt `translation` niesie tylko
`targetLanguages`/`output.includePassThroughResults` — bez żadnego `onSuccess`/`onPassthrough`
w środku. Dodatkowo `phraseDetection.language` niesie kod języka źródłowego (nie tylko
parametr URL `from=`), a `phraseDetection.mode` powtarza `scenario=interactive` z URL. Log
pokazał też, że prawdziwy `speech.config` zawiera dodatkowo `context.audio.source` z opisem
formatu audio (`type`, `model`, `samplerate`, `bitspersample`, `channelcount` — wszystkie jako
stringi, nie liczby).

Możliwe wyjaśnienie rozbieżności z wcześniejszym czytaniem JS SDK: `ServiceRecognizerBase.
setTranslationJson()` może dotyczyć innej wersji protokołu/endpointu niż `universal/v2`, albo
podsumowujący model przy odczycie TypeScript przez `WebFetch` w poprzedniej rundzie po prostu
błędnie zrekonstruował strukturę (mieszając pola z różnych, powiązanych tematycznie miejsc w
kodzie). Nie da się już tego ustalić z pewnością, ale to już nieistotne — mamy bezpośredni,
autorytatywny dowód z rzeczywistego zachowania natywnego SDK, silniejszy niż jakiekolwiek
czytanie źródła.

**Naprawione:** `speechContextMessage` przebudowany, żeby wysyłać dokładnie tę strukturę
(`phraseDetection` z `language`/`mode`/`onSuccess`/`onInterim`, `translation` z
`targetLanguages`/`output`, `audio.streams`). `speechConfigMessage` dostał dodatkowo
`context.audio.source` dla pełnej zgodności, choć to prawdopodobnie tylko informacyjne (format
audio i tak jest przekazywany przez nagłówek WAV w binarnej wiadomości `audio`).

### Follow-up: potwierdzone działające tłumaczenie — brakowało obsługi ścieżki `translation.response`

Fix `speech.context` zadziałał — Azure zaczął zwracać realne wyniki tłumaczenia. Log z testu
pokazał jednak, że przychodzą pod ścieżką **`Path:translation.response`**, nie
`translation.hypothesis`/`translation.phrase`, których się spodziewaliśmy (i które już
wcześniej poprawnie obsługiwaliśmy — okazuje się, że to schemat dla innej/starszej wersji
protokołu, nieużywanej przez `universal/v2`). Przykładowa treść z realnego testu:
```json
{"SpeechHypothesis":{"Text":"raz 2 10 8 7 6 5 4 ja ty zaraz do konina","PrimaryLanguage":{"Language":"pl-PL"}},"TranslationStatus":"Success","Translations":[{"DisplayText":"once 2 10 8 7 6 5 4 I go to Konin","Language":"en"}]}
```

Zweryfikowane bajt-w-bajt przez GitHub Code Search (fragment z `TranslationServiceRecognizer.ts`):
```typescript
case "translation.response":
    const phrase: { SpeechPhrase: ITranslationPhrase } = JSON.parse(connectionMessage.textBody) as { SpeechPhrase: ITranslationPhrase };
    if (!!phrase.SpeechPhrase) {
        await handleTranslationPhrase(TranslationPhrase.fromTranslationResponse(phrase, ...));
    } else {
        const hypothesis: { SpeechHypothesis: ITranslationHypothesis } = JSON.parse(...) as { SpeechHypothesis: ITranslationHypothesis };
        if (!!hypothesis.SpeechHypothesis) { ... }
    }
```
Czyli: jedna wspólna ścieżka `translation.response`, rozróżnienie hipoteza/finalne po tym,
KTÓRY klucz jest obecny (`SpeechPhrase` sprawdzane najpierw = finalne, inaczej
`SpeechHypothesis` = częściowe) — nie po wartości jakiegoś pola statusu. Dodatkowo
`interface ITranslationPhrase` (w `TranslationPhrase.ts`) ma własne pole `RecognitionStatus`,
którego `ITranslationHypothesis`/`SpeechHypothesis` nie ma — spójne z tym, że wynik częściowy
nie potrzebuje statusu sukcesu/porażki, a finalny tak.

**Uczciwie: dokładny kształt finalnej wiadomości (z `SpeechPhrase`) nie został jeszcze
bezpośrednio zaobserwowany** — użytkownik za każdym razem klikał Stop w trakcie mówienia, więc
mamy na razie tylko próbki `SpeechHypothesis`. Kod obsługujący `SpeechPhrase` jest napisany
przez analogię (ten sam kształt co `SpeechHypothesis`, plus `RecognitionStatus` zgodnie z
`ITranslationPhrase`) i defensywnie — sprawdza `RecognitionStatus` zarówno zagnieżdżone w
`SpeechPhrase`, jak i (fallback) `TranslationStatus` na najwyższym poziomie, więc zadziała
niezależnie od tego, gdzie dokładnie serwer umieści pole statusu. Do potwierdzenia w kolejnym
teście z realną pauzą ciszy przed Stop.

**Naprawione:** dodany `case "translation.response"` w `handle()` (`AzureSpeechTranslationService.
swift`) z nowym typem `TranslationResponseBody` dopasowanym dokładnie do przechwyconego
kształtu. Stare `case "translation.hypothesis", "translation.phrase"` zostawione (wydzielone
do `handleLegacyTranslationMessage`) na wypadek innej wersji protokołu — nieszkodliwe, bo i tak
nieużywane przez nasz endpoint.

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
