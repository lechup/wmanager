# wmanager

Provisioning Windows 11 (Home i Pro) do pracy biurowej:

- usuwa bloatware i usługi Microsoftu (Teams, OneDrive, Copilot, Widgets, Xbox, Outlook (new) i inne),
- wyłącza telemetrię (do minimum dozwolonego w edycji), reklamy, sugestie i Binga w wyszukiwarce,
- instaluje Chocolatey i paczki z `choco-reqs.txt`,
- rejestruje cotygodniową aktualizację paczek (domyślnie poniedziałek 12:00),
- wysyła logi do Grafana Cloud Loki i pinguje Healthchecks.io.

Skrypt można uruchamiać wielokrotnie: każdy przebieg doprowadza komputer do stanu z konfiguracji.
Microsoft Store, Edge, Defender i Windows Update zostają.

## Szybki start

1. Skopiuj `provision.config.example.psd1` jako `provision.config.psd1` i uzupełnij (Loki, Healthchecks, źródła listy).
2. Wgraj cały folder na pendrive albo udział sieciowy.
3. Na komputerze uruchom `run.cmd` (sam poprosi o uprawnienia administratora).
4. Podaj nazwę komputera albo naciśnij Enter, żeby zostawić obecną.
5. Po zakończeniu uruchom komputer ponownie.

Nazwę można też podać z góry: `run.cmd -ComputerName BIURO-03`.
Bez konsoli (np. autounattend) pytanie jest pomijane i nazwa zostaje bez zmian.

## Pliki

| Plik | Rola |
| --- | --- |
| `run.cmd` | Uruchamianie dwuklikiem, podnosi uprawnienia, przekazuje parametry |
| `Provision.ps1` | Główny skrypt |
| `Update-Packages.ps1` | Cotygodniowa aktualizacja (zadanie `wmanager-Update`) i ponowienie przy logowaniu (`wmanager-Retry`) |
| `Notify-User.ps1` | Powiadomienie o restarcie i jednorazowa prośba o ustawienie domyślnej przeglądarki (`wmanager-Notify`) |
| `provision.config.example.psd1` | Wzór konfiguracji; prawdziwy `provision.config.psd1` nie trafia do repo |
| `choco-reqs.txt` | Lista paczek |
| `lib\*.ps1` | Etapy: wspólne funkcje, debloat, prywatność, Chocolatey, zadania |
| `tests\` | Testy Pester parsera listy |

Na komputerze wszystko ląduje w `C:\ProgramData\wmanager`:
zapis tylko dla Administrators i SYSTEM, a `provision.config.psd1` (z tokenami) mogą czytać tylko oni.

## Przebieg provisioningu

1. Sprawdzenie Windows 11 i uprawnień, ustalenie nazwy komputera.
2. Punkt przywracania systemu.
3. Kopiowanie plików do `C:\ProgramData\wmanager` i ustawienie uprawnień.
4. Zmiana nazwy komputera (jeśli podana; działa po restarcie).
5. Debloat: aplikacje z listy `RemoveAppx` (dla wszystkich użytkowników i z obrazu), OneDrive, zasady, Edge.
6. Prywatność: telemetria, usługi `DiagTrack` i `dmwappushservice`, reklamy, sugestie, wyszukiwanie tylko lokalne.
7. Chocolatey, źródła paczek, instalacja paczek z listy.
8. Chrome jako domyślna przeglądarka dla nowych kont (DISM); obecni użytkownicy dostają jednorazowo stronę Ustawień.
9. Rejestracja zadań w Harmonogramie (folder `\wmanager\`).

Ustawienia użytkownika trafiają do wszystkich istniejących profili i do profilu domyślnego (nowe konta).

### OneDrive

Jeśli w którymś profilu Pulpit, Dokumenty lub Obrazy są przekierowane do OneDrive,
skrypt **nie usuwa** OneDrive na tym komputerze i zapisuje ostrzeżenie w logu.

## choco-reqs.txt

```
googlechrome !noupdate        # instaluj najnowszą, nie aktualizuj (aktualizuje się sama)
libreoffice-fresh             # najnowsza, aktualizowana co tydzień
libreoffice-fresh@latest      # to samo, zapisane jawnie
7zip@24.8.0                   # przypięta wersja (choco pin), bez aktualizacji
vlc | --params "/NoDesktopShortcut"   # dodatkowe parametry choco
```

- Wersję przypiętą wpisuj dokładnie tak, jak pokazuje ją `choco list` (np. `24.8.0`).
- Zmiana numeru wersji w liście zmienia wersję przy najbliższym przebiegu (także w dół).
- Nowa paczka na liście instaluje się przy najbliższym przebiegu. Paczek usuniętych z listy skrypt nie odinstalowuje.
- Lista jest sprawdzana przed użyciem; błędna linia (nieznana opcja, duplikat) odrzuca całe źródło i skrypt bierze następne.

Źródła listy (`ReqsSources`) są sprawdzane po kolei: URL, udział, plik obok skryptu.
Ostatnia poprawna kopia leży w `C:\ProgramData\wmanager\state\choco-reqs.cache.txt` i jest używana, gdy żadne źródło nie odpowiada.

> Kto może zmienić listę pod URL-em, ten instaluje programy jako SYSTEM na wszystkich komputerach.
> Używaj tylko HTTPS i repo z ograniczonym prawem zapisu.

## Cotygodniowa aktualizacja

- `wmanager-Update` (SYSTEM): termin z `UpdateDays` i `UpdateTime`; po pominiętym terminie rusza zaraz po starcie komputera.
  Pobiera listę, doinstalowuje nowe paczki, aktualizuje paczki bez przypięcia i bez `!noupdate`,
  ponownie uruchamia debloat (`RerunDebloatWeekly`) i poprawia termin, jeśli zmienił się w konfiguracji.
- Paczka, której program działa (`RunningProcessMap`), jest odkładana; `wmanager-Retry` próbuje ponownie 2 minuty po zalogowaniu.
- Gdy potrzebny jest restart, `wmanager-Notify` pokazuje użytkownikowi powiadomienie. Komputer nigdy nie restartuje się sam.

Ręczne uruchomienie: `Start-ScheduledTask -TaskPath '\wmanager\' -TaskName 'wmanager-Update'`.

## Logi i monitoring

- Lokalnie: `C:\ProgramData\wmanager\logs\<provision|update|retry>-RRRR-MM-DD_GGMM.log`, kasowane po `LogRetentionDays` (90 dni).
  Pełne wyjście Chocolatey jest tylko w logu lokalnym (i w `C:\ProgramData\chocolatey\logs`).
- **Grafana Cloud Loki**: na końcu przebiegu skrypt wysyła wpisy przez HTTP (`/loki/api/v1/push`), bez agenta.
  Etykiety: `service_name="wmanager"`, `host`, `job` (`provision`, `update`, `retry`), `level`.
  Gdy Grafana nie odpowiada, partia czeka w `logs\outbox` i idzie przy następnym przebiegu.
  Przykładowe zapytanie: `{service_name="wmanager", level="error"}`.
- **Healthchecks.io**: ping `/start` na początku i sukces albo `/fail` (z końcówką logu) na końcu provisioningu i cotygodniowej aktualizacji.
  Check tworzy się sam przy pierwszym pingu (`?create=1`), nazwa = nazwa komputera (z opcjonalnym `HealthchecksSlugPrefix`).

### Konfiguracja Grafana Cloud

1. Grafana Cloud → Connections → Loki: zapisz URL (np. `https://logs-prod-012.grafana.net`) i numeryczny User.
2. Administration → Cloud access policies: utwórz politykę tylko z zakresem `logs:write` i wygeneruj token.
3. Wpisz `LokiUrl`, `LokiUser`, `LokiToken` w `provision.config.psd1`.

### Konfiguracja Healthchecks.io

1. Utwórz projekt, w ustawieniach projektu wygeneruj **Ping key**.
2. Wpisz go jako `HealthchecksPingKey`.
3. Po pierwszym provisioningu każdy komputer ma swój check. Ustaw w nim **Period 7 dni** i **Grace 2 dni**
   (automatycznie utworzony check ma okres 1 dnia) i podłącz powiadomienie e-mail.

## Testy

Na Windowsie z Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester .\tests
```

Przed wdrożeniem na komputery: maszyny wirtualne z Windows 11 Home i Pro (z migawką), dwukrotne uruchomienie
(drugi przebieg nie może zgłosić błędów), ręczne uruchomienie zadania, pominięty termin, powiadomienie o restarcie,
potem jeden komputer pilotażowy przez tydzień.

## Ograniczenia

- W Home i Pro telemetria schodzi najniżej do poziomu „Wymagane” (1); poziom 0 działa tylko w Enterprise/Education.
- Blokada „doinstalowywania” aplikacji przez system działa tylko w Enterprise/Education, dlatego debloat powtarza się co tydzień.
- Windows 11 nie pozwala skryptem ustawić domyślnej przeglądarki istniejącym użytkownikom; dostają jednorazowo stronę Ustawień.
- Wymaga Chocolatey 2.x (instalowany automatycznie).
