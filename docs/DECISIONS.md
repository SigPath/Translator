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

## M1: routing audio na konkretne urządzenie wyjściowe
- Technika: `AVAudioEngine` + `AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, ...)`
  na `engine.outputNode.audioUnit`, ustawiane **po** dołączeniu/połączeniu węzłów,
  **przed** `engine.start()`. Potwierdzone jako standardowa, produkcyjna technika —
  ten sam wzorzec występuje 1:1 w `AudioKit/AudioKit` (`AVAudioEngine+Devices.swift`,
  `setDevice(id:)`), niezależnie zweryfikowany w wątkach Apple Developer Forums.
  Nie zgadywałem API — dopiero po potwierdzeniu wzorca w co najmniej dwóch
  niezależnych źródłach.
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

## M1: selekcja mikrofonu w WhatsApp Desktop (Mac) — zweryfikowane
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
