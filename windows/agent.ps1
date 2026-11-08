# Jedna Klawiatura - strona Windowsa (agent).
# Łączy się z Makiem (port 24850), wpisuje to, co pisze klawiatura Maca,
# i zgłasza Macowi ruch fizycznej myszy Windowsa (wtedy klawiatura Maca przechodzi tutaj).
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
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace JK {
public static class Agent {
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr hwnd, uint a, uint b);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    const uint KEYUP = 2, EXT = 1, UNI = 4;
    static readonly int[] modVk = { 0xA0, 0xA2, 0xA4 }; // bity 1 shift, 2 ctrl, 4 alt

    static HookProc hookRef;
    static Mutex single;
    static volatile bool mouseFlag;
    static int lastX, lastY;
    static double acc;
    static long lastMoveMs, lastSignalMs;
    static readonly object sendLock = new object();
    static NetworkStream stream;
    static string logPath;
    static int heldMods;
    static HashSet<int> downVk = new HashSet<int>();

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
        Log("start, hosty: " + string.Join(", ", hosts));

        Thread ht = new Thread(HookThread); ht.IsBackground = true; ht.Start();
        Thread st = new Thread(SignalThread); st.IsBackground = true; st.Start();

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
                    lock (sendLock) { stream = null; }
                    if (c != null) c.Close();
                    ReleaseAll();
                }
            }
            Thread.Sleep(2000);
        }
    }

    static void Session(TcpClient c) {
        NetworkStream ns = c.GetStream();
        ns.ReadTimeout = 7000;
        lock (sendLock) { stream = ns; }
        Send("H " + Environment.MachineName);
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
                if (line.Length > 0) {
                    try { Handle(line); } catch (Exception e) { Log("blad '" + line + "': " + e.Message); }
                }
            }
            sb.Length = 0;
            sb.Append(all);
        }
    }

    static void Send(string s) {
        lock (sendLock) {
            if (stream == null) return;
            try { byte[] b = Encoding.ASCII.GetBytes(s + "\n"); stream.Write(b, 0, b.Length); } catch { }
        }
    }

    static void Handle(string line) {
        string[] p = line.Split(' ');
        switch (p[0]) {
            case "U": {
                List<ushort> units = new List<ushort>();
                for (int i = 1; i < p.Length; i++) units.Add(Convert.ToUInt16(p[i], 16));
                Unicode(units);
                break;
            }
            case "K":
                Key(int.Parse(p[1]), p[2] == "1", int.Parse(p[3]), p[4] == "1");
                break;
            case "R":
                ReleaseAll();
                break;
        }
    }

    static INPUT KI(ushort vk, ushort scan, uint flags) {
        INPUT i = new INPUT();
        i.type = 1;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = scan;
        i.u.ki.dwFlags = flags;
        return i;
    }

    static INPUT VkInput(int vk, bool down, bool ext) {
        ushort scan = (ushort)MapVirtualKey((uint)vk, 0);
        uint f = (down ? 0 : KEYUP) | (ext ? EXT : 0);
        return KI((ushort)vk, scan, f);
    }

    static void Inject(List<INPUT> l) {
        if (l.Count == 0) return;
        SendInput((uint)l.Count, l.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    static void SetMods(List<INPUT> l, int want) {
        for (int b = 0; b < 3; b++) {
            int bit = 1 << b;
            bool has = (heldMods & bit) != 0, w = (want & bit) != 0;
            if (has && !w) l.Add(VkInput(modVk[b], false, false));
            if (!has && w) l.Add(VkInput(modVk[b], true, false));
        }
        heldMods = want;
    }

    static void Unicode(List<ushort> units) {
        List<INPUT> l = new List<INPUT>();
        if (heldMods != 0) SetMods(l, 0);
        foreach (ushort u in units) l.Add(KI(0, u, UNI));
        foreach (ushort u in units) l.Add(KI(0, u, UNI | KEYUP));
        Inject(l);
    }

    static void Key(int vk, bool down, int mods, bool ext) {
        List<INPUT> l = new List<INPUT>();
        int id = vk | (ext ? 0x10000 : 0);
        if (down) {
            SetMods(l, mods);
            l.Add(VkInput(vk, true, ext));
            downVk.Add(id);
        } else {
            l.Add(VkInput(vk, false, ext));
            downVk.Remove(id);
            if (downVk.Count == 0) SetMods(l, 0);
        }
        Inject(l);
    }

    static void ReleaseAll() {
        List<INPUT> l = new List<INPUT>();
        foreach (int id in downVk) l.Add(VkInput(id & 0xFFFF, false, (id & 0x10000) != 0));
        downVk.Clear();
        SetMods(l, 0);
        Inject(l);
    }

    static void HookThread() {
        hookRef = new HookProc(MouseHook);
        IntPtr h = SetWindowsHookEx(14, hookRef, GetModuleHandle(null), 0);
        if (h == IntPtr.Zero) { Log("SetWindowsHookEx blad " + Marshal.GetLastWin32Error()); return; }
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
    }

    static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
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
            long now = Ms();
            if (mouseFlag) {
                mouseFlag = false;
                if (now - lastSignalMs > 150) { lastSignalMs = now; Send("M"); }
            }
            if (now - lastPing > 2000) { lastPing = now; Send("P"); }
        }
    }
}
}
'@

Add-Type -TypeDefinition $code -Language CSharp
[JK.Agent]::Run($Hosts, $Port, $log)
