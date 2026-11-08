# One Keyboard

Your Mac keyboard types on Windows as soon as you move the Windows mouse. Touch the Mac trackpad and the keyboard is back on the Mac. Each computer keeps its own cursor.

## How it works

- **Mac** (`mac/`): a menu bar app (Swift). It captures the keyboard with an event tap and sends it over TCP (port 24850) while Windows is active. Menu bar icon: `⌨ MAC`, `⌨ WIN`, `⌨ -` (no Windows agent connected), `⌨ !` (Accessibility permission missing).
- **Windows** (`windows/`): a PowerShell agent with embedded C#. It types characters with `SendInput` and reports physical mouse movement back to the Mac (`WH_MOUSE_LL` hook).

Characters are resolved with the Mac's current keyboard layout (e.g. Polish Pro), so accented letters arrive as Unicode regardless of the Windows layout. Shortcuts: Cmd → Ctrl, Cmd+←/→ → Home/End, Option+←/→ → jump by word.

## Installation

Mac:

```sh
./build.sh
cp mac/pl.ghost.jednaklawiatura.plist ~/Library/LaunchAgents/   # start at login
open /Applications/JednaKlawiatura.app
```

Then enable JednaKlawiatura in System Settings → Privacy & Security → Accessibility. The app is ad-hoc signed, so after every rebuild you have to enable it again (`tccutil reset Accessibility pl.ghost.jednaklawiatura`).

Windows (PowerShell as administrator, so it can also type into windows running as admin):

```sh
./serwuj-instalator.sh        # on the Mac, prints the command to run
```

```powershell
irm http://MAC_IP:24851/instaluj.ps1 | iex
```

The agent starts by itself after login (scheduled task `JednaKlawiatura`). Log: `%LOCALAPPDATA%\JednaKlawiatura\agent.log`. The Mac addresses the agent looks for are in the `$Hosts` parameter in `windows/agent.ps1`.
