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
3. W zakładce **Klucze API** wklej swój klucz DeepL i/lub ElevenLabs, kliknij
   **Zapisz**, opcjonalnie **Testuj połączenie** (wykonuje realne zapytanie
   REST do DeepL `/v2/usage` lub ElevenLabs `/v1/user`).
4. Otwórz aplikację **Keychain Access** (Dostęp do Pęku kluczy) w macOS,
   wyszukaj `pl.mbgroup.translator`. Powinny być widoczne wpisy typu
   "application password" z kontami `pl.mbgroup.translator.deepl.apikey` i
   `pl.mbgroup.translator.elevenlabs.apikey`.
5. Zamknij i uruchom aplikację ponownie — pola w Ustawieniach powinny się
   wypełnić zapisanymi kluczami (odczyt z Keychain przy otwarciu okna).

## Struktura modułów

```
Sources/MBTranslator/
  App/        — punkt wejścia (MenuBarExtra + Settings scene)
  Services/   — Keychain, logowanie (os.Logger), test połączenia z API
  Settings/   — stan aplikacji współdzielony przez UI (AppState)
  UI/         — widoki SwiftUI (MenuBar, okno Ustawień)
Tests/MBTranslatorTests/
```

Moduły `Audio` (Core Audio, process taps, routing na urządzenia) i
`Pipeline` (DeepL/ElevenLabs, VAD, kolejka TTS) pojawią się w kolejnych
kamieniach milowych (M1–M4) — nie tworzymy ich pustych z wyprzedzeniem.

## Status kamieni milowych

- [x] **M0** — szkielet: `project.yml`, MenuBarExtra, okno ustawień, Keychain, README.
- [ ] M1 — routing audio na VB-Cable.
- [ ] M2 — DeepL PL→EN, napisy live.
- [ ] M3 — mój głos (ElevenLabs) → VB-Cable.
- [ ] M4 — tor B (napisy PL z rozmówcy).
- [ ] M5 — onboarding, skróty, koszty, glosariusz, testy, harness WAV.
- [ ] M6 — własny wirtualny mikrofon, podpis, notaryzacja, Sparkle.
