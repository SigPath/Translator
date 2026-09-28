# MB Translator

Natywna aplikacja macOS tłumacząca rozmowy głosowe na żywo w obie strony
(PL→EN dla rozmówcy, EN→PL dla Ciebie), bez botów wchodzących do spotkania —
rozmówca po prostu słyszy Cię przez zwykły mikrofon (wirtualne urządzenie
audio, domyślnie VB-Cable).

Pełny zakres, architektura i kamienie milowe: patrz opis projektu w
historii tej sesji Claude Code oraz decyzje projektowe w
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Wymagania

- macOS 14.2 (Sonoma) lub nowszy, Apple Silicon.
- Xcode 16+ (Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.

## Build i test na Macu

Ten projekt **nie zawiera commitowanego `.xcodeproj`** — jest generowany z
`project.yml` (odtwarzalny build zgodnie z briefem). Wymagane kroki po
sklonowaniu repo lub po każdej zmianie w `project.yml`:

```sh
xcodegen generate
```

Następnie albo otwórz `MBTranslator.xcodeproj` w Xcode i naciśnij Run, albo
z terminala:

```sh
# build
xcodebuild -project MBTranslator.xcodeproj -scheme MBTranslator -configuration Debug build

# testy jednostkowe
xcodebuild -project MBTranslator.xcodeproj -scheme MBTranslator -destination 'platform=macOS' test
```

Przy pierwszym uruchomieniu w Xcode: **Signing & Capabilities → Team** —
wybierz swój darmowy "Personal Team" (Apple ID). Płatne konto Apple
Developer nie jest potrzebne do lokalnego budowania i uruchamiania; będzie
wymagane dopiero na etapie notaryzacji (M6).

> Ta wersja repozytorium (M0) została napisana w środowisku Linux bez
> Xcode/Swift, więc nie mogła zostać tu skompilowana. Powyższe kroki są
> pierwszym rzeczywistym testem kompilacji — jeśli coś nie zbuduje się od
> razu, prawdopodobnie jest to drobny błąd składni do poprawienia.

## Jak sprawdzić zapis kluczy w Keychain

1. Uruchom aplikację (Run w Xcode). Powinna pojawić się ikonka w pasku menu
   (bez ikony w Docku — to zamierzone, `LSUIElement`).
2. Z menu paska menu wybierz **Ustawienia…** (lub `⌘,` gdy okno ustawień ma
   focus).
3. W zakładce **Klucze API** wklej swój klucz Azure Speech + region (np.
   `northeurope`) i/lub klucz ElevenLabs, kliknij **Zapisz**, opcjonalnie
   **Testuj połączenie** (wykonuje realne zapytanie REST: Azure
   `POST https://<region>.api.cognitive.microsoft.com/sts/v1.0/issueToken`
   lub ElevenLabs `GET /v1/user`).
4. Otwórz aplikację **Keychain Access** (Dostęp do Pęku kluczy) w macOS,
   wyszukaj `pl.mbgroup.translator`. Powinny być widoczne wpisy typu
   "application password" z kontami `pl.mbgroup.translator.azurespeech.apikey`,
   `pl.mbgroup.translator.azurespeech.region` i
   `pl.mbgroup.translator.elevenlabs.apikey`.
5. Zamknij i uruchom aplikację ponownie — pola w Ustawieniach powinny się
   wypełnić zapisanymi kluczami (odczyt z Keychain przy otwarciu okna).

## Jak przetestować routing audio na VB-Cable (M1)

Aplikacja wspiera wyłącznie **Microsoft Teams** jako komunikator docelowy
(patrz `docs/DECISIONS.md`, decyzja o zawężeniu zakresu — WhatsApp Desktop i
Zoom nie są już rozwijane).

**Krok 0 — test niezależny od Teams (zrób ten pierwszy):** odizolowuje
ewentualny problem z naszą aplikacją od konfliktu z innym klientem VB-Cable.

1. Zamknij Teams (żeby VB-Cable nie miał jeszcze wynegocjowanego formatu
   przez inny program).
2. Otwórz **QuickTime Player** → File → New Audio Recording.
3. Kliknij małą strzałkę przy przycisku nagrywania → wybierz mikrofon
   **VB-Cable**.
4. Zbuduj i uruchom MB Translator. Ustawienia → zakładka **Audio** — powinno
   automatycznie wykryć VB-Cable. Kliknij **Odtwórz plik testowy**.
5. Natychmiast kliknij nagrywanie w QuickTime, zaczekaj ~2 s, zatrzymaj.
6. Odtwórz nagranie — powinny być słyszalne trzy rosnące dźwięki.

Jeśli krok 0 działa, ale nie działa z Teams otwartym — to sygnał konfliktu z
konkretnym klientem (do zgłoszenia, opisz w jakim momencie negocjacji Teams
się to dzieje). Jeśli krok 0 też nie działa, sprawdź konsolę Xcode pod kątem
błędów Core Audio i wklej je z powrotem.

**Krok 1 — Microsoft Teams:**

1. Teams → Ustawienia → Urządzenia → Mikrofon → wybierz "VB-Cable".
2. Zadzwoń testowo (np. Test Call) i kliknij **Odtwórz plik testowy** w MB
   Translator — rozmówca (lub nagranie testowe Teams) powinien usłyszeć trzy
   rosnące dźwięki.

**Potwierdzone: M1 zaliczone dla Teams** — rozmówca usłyszał pełny plik
testowy. WhatsApp Desktop i Zoom nie są już w zakresie (patrz
`docs/DECISIONS.md`).

## Jak przetestować rozpoznawanie mowy PL→EN (M2a)

M2a to celowo **tylko pipeline, bez UI napisów** (to dopiero M2b) — wynik
sprawdzasz w konsoli Xcode. Start/Stop w MenuBarExtra jest już podłączony
naprawdę: Start włącza mikrofon i sesję Azure, Stop je zatrzymuje.

**Status po ostatnim przebiegu testów** (pełne uzasadnienie techniczne w
`docs/DECISIONS.md`):

- **Potwierdzone naprawione:** parser nagłówków USP (`Path` w wiadomościach
  Azure, np. `turn.start`).
- **Zamknięte jako fałszywy alarm:** "strumień mikrofonu urywa się po jednym
  buforze" — instrumentacja z poprzedniej rundy pokazała 93 wywołania tapu,
  zakończone dokładnie kliknięciem Zatrzymaj, bez żadnego przedwczesnego
  zniszczenia obiektów. To był po prostu zbyt wczesny klik Stop w
  poprzednich testach, nie błąd w kodzie.
- **Potwierdzone naprawione:** ręczny downmix do mono (opisany w poprzedniej
  wersji tej sekcji) — realny test na Macu pokazał niezerowe RMS na obu
  kanałach mikrofonu, czyli capture i konwersja działają poprawnie.
- **Potwierdzone naprawione:** auto-kalibracja progu VAD — realny test
  pokazał próg `50.0`, dokładnie w oczekiwanym zakresie, i Azure zaczął
  poprawnie zwracać narastające `speech.hypothesis` podczas mówienia.
- **Potwierdzone naprawione:** fix `speech.context` zadziałał — **realne
  tłumaczenie działa**. Azure zwraca teraz poprawne wyniki, np.:
  `{"SpeechHypothesis":{"Text":"..."},"TranslationStatus":"Success",
  "Translations":[{"DisplayText":"...","Language":"en"}]}`.
- **Potwierdzone naprawione:** obsługa ścieżki `translation.response` —
  hipotezy robocze (`PL (wersja robocza):`/`EN (wersja robocza):`)
  potwierdzone jako działające w Twoim teście z pauzą ciszy.
- **Ostatnia znaleziona przyczyna (do potwierdzenia):** mimo wyraźnej
  ~2-sekundowej ciszy przed Stop, finalny wynik (`SpeechPhrase`) nigdy nie
  nadszedł. Twoja hipoteza się potwierdziła: nasza bramka VAD w ogóle nie
  wysyłała ciszy do Azure (`gateDecision=skip` — zero bajtów na
  WebSocket), a Azure — jak każdy główny dostawca streamingowego STT —
  wykonuje **własny, serwerowy** VAD/wykrywanie końca wypowiedzi na
  ciągłym strumieniu, który odbiera (potwierdzone wprost w oficjalnej
  dokumentacji Microsoftu: *"Audio input can contain not only voice, but
  also silence... the system continuously determines..."*). Skoro
  przestawaliśmy wysyłać cokolwiek podczas ciszy, serwer nie miał z czego
  wykryć końca wypowiedzi — po prostu czekał dalej. Naprawione: audio jest
  teraz **zawsze wysyłane**, niezależnie od werdyktu VAD; sama detekcja
  (`VoiceActivityGate` przemianowana na `VoiceActivityTracker`, bo już nie
  "bramkuje" niczego) została wyłącznie jako diagnostyka/na potrzeby
  przyszłego wskaźnika UI w M2b.

1. Ustawienia → **Klucze API** → upewnij się, że klucz Azure Speech i region
   są zapisane i że **Testuj połączenie** pokazuje "Połączenie OK" (patrz
   sekcja o Keychain wyżej).
2. `git pull` → `xcodegen generate` → zbuduj i uruchom w Xcode.
3. **Zanim uruchomisz appkę: puść testy jednostkowe** — `Product → Test`
   w Xcode (albo `xcodebuild test -scheme MBTranslator -destination
   'platform=macOS'` z terminala). Nowy test regresyjny
   `realAzureTurnStartMessageParses` w `USPMessageTests.swift` powinien
   przejść na zielono — to bezpośrednie potwierdzenie fixu parsera, zanim
   w ogóle dotkniesz mikrofonu.
4. Kliknij ikonkę MB Translator w pasku menu → **Start**. macOS zapyta o
   dostęp do mikrofonu przy pierwszym uruchomieniu — kliknij **Zezwól**.
5. **Otwórz konsolę Xcode** (View → Debug Area → Activate Console, albo po
   prostu panel na dole podczas Run). Zaraz po kliknięciu **Start**, zanim
   jeszcze zaczniesz mówić, poczekaj ~1 sekundę w ciszy (okno auto-kalibracji
   VAD).
6. Mów wyraźnie po polsku, **prawdziwym, sensownym zdaniem** (nie ciąg
   liczb — jakość rozpoznawania/tłumaczenia modelu Azure jest zauważalnie
   słabsza dla bezsensownych ciągów), np.: *"Testuję tłumaczenie na żywo.
   Dzień dobry, jak się masz? To jest drugie zdanie testowe."* — rób
   krótkie przerwy między zdaniami.
7. **Po ostatnim zdaniu zrób wyraźną ~2-sekundową pauzę ciszy, zanim
   klikniesz Zatrzymaj.** Tym razem w konsoli powinny nadal lecieć linie
   `chunk #N: ... vadVerdict=silence (always sent — VAD no longer gates
   transmission) ...` podczas tej ciszy — czyli audio ciszy faktycznie
   idzie do Azure, zamiast być ucinane.
8. Sprawdź w konsoli:
   ```
   PL (wersja robocza): Testuję tłuma...
   EN (wersja robocza): I'm testing...
   ...
   PL (finalne): Testuję tłumaczenie na żywo.
   EN (finalne): I'm testing live translation.
   ```
   `speech.hypothesis` w tle to normalne i celowo ignorowane. Tym razem
   `PL (finalne):`/`EN (finalne):` powinny się pojawić **w trakcie ciszy**,
   krótko po ostatnim zdaniu — nie dopiero po kliknięciu Zatrzymaj.
9. Kliknij **Zatrzymaj**.

**Wklej mi cały fragment logu obejmujący `Path:translation.response` z
finalnym wynikiem** (surową treść RAW text message, nie tylko
sparsowane `PL (finalne):`/`EN (finalne):`) — to pierwsza okazja, żeby
zobaczyć dokładny kształt `SpeechPhrase`, którego kod na razie obsługuje
przez analogię, a nie bezpośrednią obserwację. Jeśli finalny wynik nadal
się nie pojawi mimo że cisza teraz realnie leci do Azure, to będzie
oznaczać, że jest jeszcze coś innego blokującego finalizację.

**Czego NIE testujemy jeszcze w M2a:** ciągłości po godzinie (limit sesji) i
zachowania po zerwaniu połączenia (np. wyłączeniu Wi-Fi w trakcie) — logika
auto-wznawiania i backoffu jest zaimplementowana zgodnie z opisem w
`docs/DECISIONS.md`, ale nie dało się tego przetestować w środowisku, w
którym to pisałem (brak Maca). Jeśli chcesz, przetestuj to dodatkowo:
wyłącz na chwilę Wi-Fi w trakcie mówienia i sprawdź, czy po jego przywróceniu
tłumaczenie samo wznawia się bez restartu aplikacji.

Jeśli zamiast transkrypcji w konsoli zobaczysz błąd (ikonka w pasku menu
zmieni się na "Błąd") — sprawdź dokładny komunikat w konsoli Xcode (szukaj
`TranslationPipeline` lub `AzureSpeechTranslationService` w kategorii logu)
i wklej go z powrotem.

## Struktura modułów

```
Sources/MBTranslator/
  App/        — punkt wejścia (MenuBarExtra + Settings scene)
  Audio/      — enumeracja urządzeń Core Audio, routing na urządzenie, test tone, mikrofon
  Pipeline/   — SpeechTranslationService, klient Azure (protokół USP), VAD
  Services/   — Keychain, logowanie (os.Logger), test połączenia z API
  Settings/   — stan aplikacji współdzielony przez UI (AppState, AudioSettingsStore)
  UI/         — widoki SwiftUI (MenuBar, okno Ustawień)
Tests/MBTranslatorTests/
```

## Status kamieni milowych

- [x] **M0** — szkielet: `project.yml`, MenuBarExtra, okno ustawień, Keychain, README.
- [x] **M1** — routing testowego pliku audio na VB-Cable, potwierdzone w Microsoft Teams.
- [x] **M2a** — pipeline Azure Speech PL→EN (mikrofon → WebSocket → log konsoli), VAD, auto-wznawianie sesji — do potwierdzenia manualnie (patrz wyżej).
- [ ] M2b — pływający panel napisów (NSPanel), dopiero po potwierdzeniu M2a.
- [ ] M3 — mój głos (ElevenLabs) → VB-Cable.
- [ ] M4 — tor B: przechwytywanie audio Microsoft Teams (Core Audio Process Tap) → napisy PL.
- [ ] M5 — onboarding, skróty, koszty, glosariusz, testy, harness WAV.
- [ ] M6 — własny wirtualny mikrofon, podpis, notaryzacja, Sparkle.
