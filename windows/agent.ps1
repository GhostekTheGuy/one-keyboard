# Jedna Klawiatura (gałąź windows-keyboard) - strona Windowsa (agent).
# Klawiatura tego laptopa pisze na Macu, kiedy ostatnio ruszono myszą Maca (Mac zgłasza "M").
# Ruch fizycznej myszy/gładzika Windowsa oddaje klawiaturę Windowsowi.
# Łączy się z Makiem (port 24850), przechwytuje klawisze hookiem WH_KEYBOARD_LL i wysyła je na Maca.
param(
    [string[]]$Hosts = @(),
    [int]$Port = 24850
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'JednaKlawiatura'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$log = Join-Path $dir 'agent.log'

$code = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace JK {
public static class Agent {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr hwnd, uint a, uint b);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int size, uint flags, IntPtr hkl);

    const uint LLKHF_EXTENDED = 0x01, LLKHF_INJECTED = 0x10, LLKHF_UP = 0x80;

    static HookProc keyRef, mouseRef;
    static Mutex single;
    static string logPath;
    /// klawiatura idzie na Maca (Mac zgłosił ruch swojej myszy)
    static volatile bool onMac;
    static volatile bool connected;
    static volatile bool mouseFlag;
    static int lastX, lastY;
    static double acc;
    static long lastMoveMs;
    static readonly object sendLock = new object();
    static NetworkStream stream;
    static readonly BlockingCollection<string> outbox = new BlockingCollection<string>();

    // stan klawiszy, tylko w wątku hooka
    static bool lShift, rShift, lCtrl, rCtrl, lAlt, rAlt, lWin, rWin;
    /// klawisze wciśnięte, gdy klawiatura była na Macu: vk -> co wysłać przy puszczeniu ("" = nic, tylko połknąć)
    static readonly Dictionary<uint, string> upMsgs = new Dictionary<uint, string>();
    static char deadChar;

    static long Ms() { return DateTime.UtcNow.Ticks / 10000; }

    static void Log(string s) {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + s + Environment.NewLine); } catch { }
    }

    public static void Run(string[] hosts, int port, string log) {
        logPath = log;
        try { if (File.Exists(log) && new FileInfo(log).Length > 1000000) File.Delete(log); } catch { }
        bool created;
        single = new Mutex(true, "Local\\JednaKlawiaturaAgent", out created);
        if (!created) { Log("agent juz dziala - koncze"); return; }
        Log("start (klawiatura Windowsa na Maca), hosty: " + string.Join(", ", hosts));

        Thread ht = new Thread(HookThread); ht.IsBackground = true; ht.Start();
        Thread st = new Thread(SignalThread); st.IsBackground = true; st.Start();
        Thread wt = new Thread(SendThread); wt.IsBackground = true; wt.Start();

        string lastErr = "";
        while (true) {
            foreach (string h in hosts) {
                TcpClient c = null;
                try {
                    c = new TcpClient();
                    IAsyncResult ar = c.BeginConnect(h, port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(3000)) throw new Exception("timeout");
                    c.EndConnect(ar);
                    c.NoDelay = true;
                    Log("polaczono z " + h);
                    lastErr = "";
                    Session(c);
                } catch (Exception e) {
                    string msg = h + ": " + e.Message;
                    if (msg != lastErr) { Log("brak polaczenia " + msg); lastErr = msg; }
                } finally {
                    // bez Maca klawiatura zawsze wraca na Windowsa
                    onMac = false;
                    connected = false;
                    lock (sendLock) { stream = null; }
                    if (c != null) c.Close();
                }
            }
            Thread.Sleep(2000);
        }
    }

    static void Session(TcpClient c) {
        NetworkStream ns = c.GetStream();
        ns.ReadTimeout = 7000;
        lock (sendLock) { stream = ns; }
        connected = true;
        Send("H " + Environment.MachineName);
        Send("F 0");
        StringBuilder sb = new StringBuilder();
        byte[] buf = new byte[4096];
        while (true) {
            int n;
            try { n = ns.Read(buf, 0, buf.Length); }
            catch (IOException) { Log("cisza od Maca - rozlaczam"); return; }
            if (n <= 0) { Log("Mac zamknal polaczenie"); return; }
            sb.Append(Encoding.ASCII.GetString(buf, 0, n));
            string all = sb.ToString();
            int idx;
            while ((idx = all.IndexOf('\n')) >= 0) {
                string line = all.Substring(0, idx).Trim();
                all = all.Substring(idx + 1);
                if (line == "M") ToMac();
                else if (line == "X") ToWindows();
            }
            sb.Length = 0;
            sb.Append(all);
        }
    }

    static void ToMac() {
        if (!connected || onMac) return;
        onMac = true;
        Send("F 1");
    }

    static void ToWindows() {
        if (!onMac) return;
        onMac = false;
        Send("R");
        Send("F 0");
    }

    /// Kolejka zamiast pisania do sieci w hooku: hook musi wrócić w kilka ms, inaczej Windows go odłączy.
    static void Send(string s) { outbox.Add(s); }

    static void SendThread() {
        foreach (string s in outbox.GetConsumingEnumerable()) {
            lock (sendLock) {
                if (stream == null) continue;
                try { byte[] b = Encoding.ASCII.GetBytes(s + "\n"); stream.Write(b, 0, b.Length); } catch { }
            }
        }
    }

    // ---------- klawiatura ----------

    static bool IsModifier(uint vk) {
        return (vk >= 0xA0 && vk <= 0xA5) || vk == 0x5B || vk == 0x5C || vk == 0x10 || vk == 0x11 || vk == 0x12;
    }

    static void TrackModifier(uint vk, bool down) {
        switch (vk) {
            case 0xA0: lShift = down; break;
            case 0xA1: rShift = down; break;
            case 0xA2: lCtrl = down; break;
            case 0xA3: rCtrl = down; break;
            case 0xA4: lAlt = down; break;
            case 0xA5: rAlt = down; break;   // AltGr
            case 0x5B: lWin = down; break;
            case 0x5C: rWin = down; break;
        }
    }

    // zawsze jako klawisz (VK), nigdy jako znak
    static readonly HashSet<uint> special = new HashSet<uint> {
        0x08, 0x09, 0x0D, 0x1B, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E,
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x0C,
    };

    static IntPtr KeyHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode < 0) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
        if ((k.flags & LLKHF_INJECTED) != 0) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        bool up = (k.flags & LLKHF_UP) != 0;
        uint vk = k.vkCode;
        // AltGr wysyła przed sobą sztuczny lewy Ctrl (skan 0x21D): to część AltGr, nie Ctrl
        bool fakeCtrl = vk == 0xA2 && (k.scanCode & 0x200) != 0;
        if (!fakeCtrl) TrackModifier(vk, !up);

        if (up) {
            string msg;
            if (upMsgs.TryGetValue(vk, out msg)) {
                upMsgs.Remove(vk);
                if (msg.Length > 0) Send(msg);
                return (IntPtr)1;
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }

        if (!onMac || !connected) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        // Caps Lock zostaje na Windowsie: jego stan i dioda decydują o wielkich literach
        if (vk == 0x14) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        if (fakeCtrl || IsModifier(vk)) {
            // modyfikatory idą razem z klawiszem (bity mods), osobno nie
            upMsgs[vk] = "";
            return (IntPtr)1;
        }
        try { Forward(vk, k.scanCode, (k.flags & LLKHF_EXTENDED) != 0); }
        catch (Exception e) { Log("blad klawisza " + vk + ": " + e.Message); }
        return (IntPtr)1;
    }

    static void Forward(uint vk, uint scan, bool ext) {
        bool shift = lShift || rShift, ctrl = lCtrl || rCtrl, win = lWin || rWin;
        int mods = (shift ? 1 : 0) | (ctrl ? 2 : 0) | (lAlt ? 4 : 0) | (win ? 8 : 0);
        // skrót (Ctrl, lewy Alt, Win) albo klawisz specjalny: jako VK. AltGr to polskie litery: jako znak
        if (!ctrl && !lAlt && !win && !special.Contains(vk)) {
            string text = Translate(vk, scan);
            if (text == null) { upMsgs[vk] = ""; return; } // klawisz martwy: czekamy na literę
            if (text.Length > 0 && Printable(text)) {
                StringBuilder hex = new StringBuilder("U");
                foreach (char ch in text) hex.Append(' ').Append(((int)ch).ToString("X4"));
                Send(hex.ToString());
                upMsgs[vk] = "";
                return;
            }
        }
        if (rAlt && !ctrl) mods |= 4; // AltGr bez znaku działa jak Option
        string e = ext ? "1" : "0";
        Send("K " + vk + " 1 " + mods + " " + e);
        upMsgs[vk] = "K " + vk + " 0 " + mods + " " + e;
    }

    static bool Printable(string s) {
        foreach (char ch in s) if (ch < 0x20 || ch == 0x7F) return false;
        return true;
    }

    /// Znak z układu aktywnego okna (np. polski programisty). null = klawisz martwy.
    static string Translate(uint vk, uint scan) {
        byte[] state = new byte[256];
        if (lShift || rShift) { state[0x10] = 0x80; state[lShift ? 0xA0 : 0xA1] = 0x80; }
        if (rAlt) { state[0x11] = 0x80; state[0x12] = 0x80; state[0xA2] = 0x80; state[0xA5] = 0x80; }
        if ((GetKeyState(0x14) & 1) != 0) state[0x14] = 0x01;
        IntPtr hkl = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero));
        StringBuilder buf = new StringBuilder(8);
        // flaga 4: nie ruszaj stanu klawiszy martwych w samym Windowsie (Windows 10 1607+)
        int r = ToUnicodeEx(vk, scan, state, buf, buf.Capacity, 4, hkl);
        if (r < 0) {
            deadChar = buf.Length > 0 ? buf[0] : '\0';
            return null;
        }
        string s = r > 0 ? buf.ToString(0, Math.Min(r, buf.Length)) : "";
        if (deadChar != '\0') {
            s = Compose(deadChar, s);
            deadChar = '\0';
        }
        return s;
    }

    // akcent z klawisza martwego -> znak łączący Unicode
    static readonly Dictionary<char, char> combining = new Dictionary<char, char> {
        { '´', '́' }, { '\'', '́' }, { '`', '̀' }, { '^', '̂' }, { 'ˆ', '̂' },
        { '¨', '̈' }, { '"', '̈' }, { '~', '̃' }, { '˜', '̃' }, { 'ˇ', '̌' },
        { '˛', '̨' }, { '˙', '̇' }, { '¸', '̧' }, { '˝', '̋' },
        { '°', '̊' }, { '˚', '̊' }, { '˘', '̆' },
    };

    static string Compose(char dead, string s) {
        if (s.Length == 0 || s == " ") return dead.ToString();
        char comb;
        if (s.Length == 1 && combining.TryGetValue(dead, out comb)) {
            string c = (s + comb).Normalize(NormalizationForm.FormC);
            if (c.Length == 1) return c;
        }
        return dead + s;
    }

    // ---------- mysz ----------

    static void HookThread() {
        keyRef = new HookProc(KeyHook);
        mouseRef = new HookProc(MouseHook);
        IntPtr mod = GetModuleHandle(null);
        if (SetWindowsHookEx(13, keyRef, mod, 0) == IntPtr.Zero) Log("hook klawiatury blad " + Marshal.GetLastWin32Error());
        if (SetWindowsHookEx(14, mouseRef, mod, 0) == IntPtr.Zero) Log("hook myszy blad " + Marshal.GetLastWin32Error());
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
    }

    static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && onMac) {
            MSLLHOOKSTRUCT s = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            if ((s.flags & 1) == 0) { // tylko fizyczna mysz, nie wstrzyknieta
                int msg = wParam.ToInt32();
                if (msg == 0x200) {
                    long now = Ms();
                    if (now - lastMoveMs > 400) { acc = 0; lastX = s.pt.x; lastY = s.pt.y; }
                    lastMoveMs = now;
                    acc += Math.Abs(s.pt.x - lastX) + Math.Abs(s.pt.y - lastY);
                    lastX = s.pt.x; lastY = s.pt.y;
                    if (acc > 20) { mouseFlag = true; acc = 0; }
                } else if (msg == 0x201 || msg == 0x204 || msg == 0x207 || msg == 0x20A || msg == 0x20B || msg == 0x20E) {
                    mouseFlag = true;
                }
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    static void SignalThread() {
        long lastPing = 0;
        while (true) {
            Thread.Sleep(25);
            if (mouseFlag) {
                mouseFlag = false;
                ToWindows(); // ruch myszy Windowsa: klawiatura wraca tutaj
            }
            long now = Ms();
            if (now - lastPing > 2000) { lastPing = now; if (connected) Send("P"); }
        }
    }
}
}
'@

Add-Type -TypeDefinition $code -Language CSharp
[JK.Agent]::Run($Hosts, $Port, $log)
