# One Keyboard (Windows keyboard edition)

> This is the `windows-keyboard` branch: for when the laptop runs Windows. The `main` branch is the other way round (the Mac keyboard types on Windows).

Your Windows laptop's keyboard types on the Mac as soon as you move the Mac's mouse or trackpad. Touch the Windows touchpad or mouse and the keyboard is back on Windows. Each computer keeps its own cursor.

## How it works

- **Windows** (`windows/`): a PowerShell agent with embedded C#. A low-level keyboard hook (`WH_KEYBOARD_LL`) captures keys while the keyboard belongs to the Mac and sends them over TCP (port 24850); Windows itself does not see them. A mouse hook (`WH_MOUSE_LL`) takes the keyboard back when the physical Windows mouse moves.
- **Mac** (`mac/`): a menu bar app (Swift). It types what arrives from Windows (`CGEvent`) and tells Windows when the Mac mouse or trackpad moves. Menu bar icon: `⌨ MAC` (Windows keyboard types on the Mac), `⌨ WIN`, `⌨ -` (no Windows agent connected), `⌨ !` (Accessibility permission missing).

Characters are resolved with the layout of the active Windows window (e.g. Polish Programmers), so AltGr letters such as ą, ę, ż arrive as Unicode regardless of the Mac layout; dead keys are composed too. Shortcuts follow the Mac: Ctrl → Cmd, Alt → Option, Win → Control, Home/End → Cmd+←/→, Ctrl+Home/End → Cmd+↑/↓, Ctrl+←/→ and Ctrl+Backspace → by word (Option). Caps Lock stays on Windows and decides upper case.

Safety: if the connection drops or the Mac goes silent for 7 seconds, the keyboard falls back to Windows. Moving the Windows mouse always brings it back too.

## Installation

Mac:

```sh
./build.sh
cp mac/pl.ghost.jednaklawiatura.plist ~/Library/LaunchAgents/   # start at login
open /Applications/JednaKlawiatura.app
```

Then enable JednaKlawiatura in System Settings → Privacy & Security → Accessibility (needed to type on the Mac). The app is ad-hoc signed, so after every rebuild you have to enable it again (`tccutil reset Accessibility pl.ghost.jednaklawiatura`).

Windows (PowerShell as administrator, so keys also reach the Mac while an admin window is focused on Windows):

```sh
./serwuj-instalator.sh        # on the Mac, prints the command to run
```

```powershell
irm http://MAC_IP:24851/instaluj.ps1 | iex
```

The agent starts by itself after login (scheduled task `JednaKlawiatura`). Log: `%LOCALAPPDATA%\JednaKlawiatura\agent.log`. The installer saves the Mac addresses the agent looks for (home network IP, `.local` name and Tailscale IP if available) to `%LOCALAPPDATA%\JednaKlawiatura\hosts.txt`, one per line; edit it if the Mac's address changes.

Both editions use the same app name, task and port, so installing one replaces the other on both computers. Switch by checking out the other branch and installing again.
