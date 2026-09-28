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

## M2a — pipeline Azure Speech PL→EN: **zamknięte, potwierdzone działające**

Pełny, poprawny wynik end-to-end z realnego testu na Macu: wypowiedź "Jadę
zaraz do Konina" → poprawne `speech.endDetected` → finalny
`translation.response` (`SpeechPhrase`, `RecognitionStatus:"Success"`,
`DisplayText:"Jadę zaraz do Konina."`) → `EN (finalne): I'm going to Konin
right away.` → `turn.end` poprawnie domykający pipeline. Sześć niezależnych
błędów znalezionych i naprawionych po drodze — pełna historia w
`docs/DECISIONS.md`. Całe tymczasowe logowanie debugowe (`TEMP (M2a
debug)`) zostało usunięte po potwierdzeniu.

Szybki test regresyjny (nie trzeba już przechodzić przez wszystkie kroki
diagnostyczne z poprzednich rund):
1. `git pull` → `xcodegen generate` → `Product → Test` w Xcode (testy
   jednostkowe powinny przejść na zielono).
2. Zbuduj i uruchom, Start w MenuBarExtra, mów sensownym zdaniem po polsku
   z krótką pauzą ciszy na końcu, Zatrzymaj.
3. W konsoli Xcode powinny pojawić się `PL (finalne):`/`EN (finalne):` z
   poprawnym tłumaczeniem.

## Jak przetestować pływający panel z napisami (M2b)

**Nowość w tej rundzie, jeszcze nieprzetestowana na realnym Macu.** Panel
pokazuje `PL (wersja robocza)`/`PL (finalne)`/`EN (finalne)` na żywo,
unosząc się nad innymi oknami (np. rozmową wideo), bez przejmowania
fokusu — zamiast sprawdzania wyniku tylko w konsoli Xcode. Pełne
uzasadnienie decyzji projektowych (dlaczego `NSPanel` bezpośrednio przez
AppKit, dlaczego stały rozmiar, itd.) w `docs/DECISIONS.md`.

1. `git pull` → `xcodegen generate` → zbuduj i uruchom w Xcode.
2. Kliknij **Start** w MenuBarExtra.
3. **Powinien pojawić się mały, ciemny, zaokrąglony panel** (ok. 560×110pt)
   w dolnej środkowej części ekranu, z napisem "Słucham…". Sprawdź:
   - Czy panel **nie kradnie fokusu** — kliknij w dowolne inne okno/pole
     tekstowe i sprawdź, czy nadal możesz tam pisać bez przełączania się.
   - Czy panel da się **przeciągnąć** (kliknij i przeciągnij w dowolnym
     miejscu tła panelu — nie ma paska tytułu).
   - Czy panel **unosi się nad innymi oknami** (przełącz na inną aplikację
     na pierwszy plan — panel powinien zostać widoczny).
4. Mów po polsku — sprawdź, czy w panelu na żywo pojawia się szara,
   kursywą linia PL (wersja robocza), a po zakończeniu frazy — jaśniejsza
   linia PL (finalne) i pogrubiona EN (finalne).
5. Kliknij **Zatrzymaj** — panel powinien zniknąć.
6. Kliknij **Start** ponownie, sprawdź czy panel pojawia się w tym samym
   miejscu, gdzie go zostawiłeś (jeśli przeciągałeś w kroku 3).
7. **Jeśli masz pod ręką aplikację do rozmów wideo w trybie
   pełnoekranowym** (Teams/Zoom na cały ekran, nie tylko zmaksymalizowane
   okno) — sprawdź, czy panel jest nadal widoczny nad nią. To jedyna
   rzecz w tej implementacji, której nie mogłem zweryfikować bez Maca
   (patrz `docs/DECISIONS.md`, sekcja o `level`/`.floating` vs
   `.screenSaver`) — jeśli panel zniknie w tym trybie, to jest dokładnie
   zlokalizowana, jednolinijkowa poprawka do zrobienia.

**Czego jeszcze nie testujemy w M2b:** trwałości pozycji panelu między
zamknięciami/otwarciami **całej aplikacji** (tylko między Start/Stop w
ramach jednego uruchomienia) — mechanizm (`setFrameAutosaveName`) powinien
to obsłużyć automatycznie, ale warto to też sprawdzić przy okazji.

## Struktura modułów

```
Sources/MBTranslator/
  App/        — punkt wejścia (MenuBarExtra + Settings scene)
  Audio/      — enumeracja urządzeń Core Audio, routing na urządzenie, test tone, mikrofon
  Pipeline/   — SpeechTranslationService, klient Azure (protokół USP), VAD
  Services/   — Keychain, logowanie (os.Logger), test połączenia z API
  Settings/   — stan aplikacji współdzielony przez UI (AppState, AudioSettingsStore)
  UI/         — widoki SwiftUI (MenuBar, okno Ustawień, pływający panel napisów)
Tests/MBTranslatorTests/
```

## Status kamieni milowych

- [x] **M0** — szkielet: `project.yml`, MenuBarExtra, okno ustawień, Keychain, README.
- [x] **M1** — routing testowego pliku audio na VB-Cable, potwierdzone w Microsoft Teams.
- [x] **M2a** — pipeline Azure Speech PL→EN (mikrofon → WebSocket → log konsoli), VAD, auto-wznawianie sesji — **potwierdzone działające end-to-end**.
- [ ] **M2b** — pływający panel napisów (NSPanel) — zaimplementowane, do potwierdzenia manualnie (patrz wyżej).
- [ ] M3 — mój głos (ElevenLabs) → VB-Cable.
- [ ] M4 — tor B: przechwytywanie audio Microsoft Teams (Core Audio Process Tap) → napisy PL.
- [ ] M5 — onboarding, skróty, koszty, glosariusz, testy, harness WAV.
- [ ] M6 — własny wirtualny mikrofon, podpis, notaryzacja, Sparkle.
