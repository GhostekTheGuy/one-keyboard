# Jedna Klawiatura

Klawiatura Maca pisze na Windowsie, kiedy ruszasz myszą Windowsa. Ruszysz gładzikiem Maca i klawiatura wraca na Maca. Każdy komputer zostaje przy swoim kursorze.

## Jak działa

- **Mac** (`mac/`): aplikacja w pasku menu (Swift). Przechwytuje klawiaturę przez event tap i wysyła ją po TCP (port 24850), gdy aktywny jest Windows. Ikona: `⌨ MAC`, `⌨ WIN`, `⌨ -` (brak Windowsa), `⌨ !` (brak uprawnienia Dostępność).
- **Windows** (`windows/`): agent w PowerShellu z wbudowanym C#. Wpisuje znaki przez `SendInput` i zgłasza Macowi ruch fizycznej myszy (hook `WH_MOUSE_LL`).

Znaki liczone są z bieżącego układu Maca (np. Polish Pro), więc polskie litery przechodzą jako Unicode niezależnie od układu Windowsa. Skróty: Cmd → Ctrl, Cmd+←/→ → Home/End, Option+←/→ → skok o słowo.

## Instalacja

Mac:

```sh
./build.sh
cp mac/pl.ghost.jednaklawiatura.plist ~/Library/LaunchAgents/   # autostart
open /Applications/JednaKlawiatura.app
```

Potem włącz JednaKlawiatura w Ustawienia systemowe → Prywatność i ochrona → Dostępność. Aplikacja jest podpisana ad-hoc, więc po każdej przebudowie trzeba to zrobić ponownie (`tccutil reset Accessibility pl.ghost.jednaklawiatura`).

Windows (PowerShell jako administrator, żeby pisać też do okien uruchomionych jako admin):

```sh
./serwuj-instalator.sh        # na Macu, wypisze polecenie
```

```powershell
irm http://IP_MACA:24851/instaluj.ps1 | iex
```

Agent startuje sam po zalogowaniu (zadanie harmonogramu `JednaKlawiatura`). Log: `%LOCALAPPDATA%\JednaKlawiatura\agent.log`. Adresy Maca, których szuka agent, są w parametrze `$Hosts` w `windows/agent.ps1`.
