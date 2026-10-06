// winapp-frame: starts a program and then, for as long as the session stays
// connected, tidies the frames of the session's windows so that they sit in a
// tiling desktop like any other window:
//
//   - a main window loses the title bar Windows draws for it (the name and the
//     minimise, maximise and close buttons). A menu bar is a separate part of
//     the window and stays. A program that draws its own title bar, as Office
//     does, has nothing here to remove and is left alone, and so are dialogs,
//     whose title says what they are asking.
//   - every window gets square corners; Windows 11 rounds them, and what shows
//     in the cut-off corners of a remote window is not the Linux desktop.
//
// winapp builds this inside the VM (guest/apply.ps1) with the C# 5 compiler
// that ships with Windows, hence the plain syntax, and starts apps through it.
// It keeps no state and changes nothing that outlives a window.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

static class WinappFrame {
  delegate bool EnumProc(IntPtr window, IntPtr unused);
  delegate void EventProc(IntPtr hook, uint what, IntPtr window, int part, int child, uint thread, uint time);

  [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] struct MSG {
    public IntPtr window; public uint message; public IntPtr wParam, lParam; public uint time; public POINT point;
  }

  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc each, IntPtr unused);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint which);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref POINT point);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int which);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, EventProc proc, uint process, uint thread, uint flags);
  [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr window, UIntPtr id, uint milliseconds, IntPtr proc);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG message, IntPtr window, uint first, uint last);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG message);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBox(IntPtr owner, string text, string caption, uint type);
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
  [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int what, out IntPtr buffer, out int bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);

  const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
  const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_MINIMIZEBOX = 0x00020000,
             WS_MAXIMIZEBOX = 0x00010000, WS_CHILD = 0x40000000, WS_EX_TOOLWINDOW = 0x00000080;
  const uint WM_TIMER = 0x0113, EVENT_OBJECT_SHOW = 0x8002, GW_OWNER = 4;
  const int SM_CYCAPTION = 4, DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_DONOTROUND = 1;

  static bool titleBars, roundedCorners;
  static readonly HashSet<string> keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  static readonly HashSet<IntPtr> squared = new HashSet<IntPtr>();
  static readonly Dictionary<uint, string> names = new Dictionary<uint, string>();
  static DateTime settingsRead;
  static uint self;
  static EventProc onShow; // held here so that it is not collected while Windows calls it

  [STAThread]
  static int Main() {
    SetProcessDPIAware();
    string unused, line;
    Split(Environment.CommandLine, out unused, out line);
    if (line.Length > 0) Launch(line);

    // One of these per session does the tidying. A second one, started for the
    // next app, has done its part by now; it stays only if the first is just
    // leaving.
    bool first;
    Mutex one = new Mutex(true, "Local\\winapp-frame", out first);
    if (!first) {
      try { if (!one.WaitOne(3000)) return 0; } catch (AbandonedMutexException) { }
    }
    Watch();
    GC.KeepAlive(one);
    return 0;
  }

  // "first word" "and the rest": the first word of a command line, without its
  // quotes, and what follows it, as it is.
  static void Split(string line, out string first, out string rest) {
    line = line.Trim();
    int end;
    if (line.StartsWith("\"")) {
      end = line.IndexOf('"', 1);
      if (end < 0) end = line.Length;
      first = line.Substring(1, end - 1);
      rest = end < line.Length ? line.Substring(end + 1).Trim() : "";
    } else {
      end = line.IndexOf(' ');
      if (end < 0) end = line.Length;
      first = line.Substring(0, end);
      rest = line.Substring(end).Trim();
    }
  }

  static void Launch(string line) {
    string program, arguments;
    Split(line, out program, out arguments);
    try {
      ProcessStartInfo start = new ProcessStartInfo(program, arguments);
      start.UseShellExecute = true;
      Process.Start(start);
    } catch (Exception error) {
      MessageBox(IntPtr.Zero,
        "Windows could not start\n" + program + "\n\n" + error.Message +
        "\n\nIf the app was moved or removed, run on Linux:  winapp scan",
        "winapp", 0x30 /* warning */ | 0x10000 /* in front */);
    }
  }

  static void Watch() {
    self = (uint)Process.GetCurrentProcess().Id;
    onShow = OnShow;
    SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, onShow, 0, 0, 0x2 /* skip own process */);
    SetTimer(IntPtr.Zero, UIntPtr.Zero, 500, IntPtr.Zero);
    int away = 0, sweeps = 0;
    MSG message;
    // window events arrive inside GetMessage
    while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
      if (message.message == WM_TIMER) {
        // The session outlives its connection, and nothing is looking at a
        // disconnected one: leave, so that no session is kept alive by this.
        // The next app is started through a new one of these.
        if (Connected()) away = 0;
        else if (++away >= 6) return;
        if (++sweeps % 120 == 0) names.Clear();
        squared.RemoveWhere(delegate(IntPtr window) { return !IsWindow(window); });
        Sweep();
      }
      DispatchMessage(ref message);
    }
  }

  static bool Connected() {
    IntPtr buffer;
    int bytes;
    if (!WTSQuerySessionInformation(IntPtr.Zero, -1 /* this session */, 8 /* its state */, out buffer, out bytes)) return true;
    int state = Marshal.ReadInt32(buffer);
    WTSFreeMemory(buffer);
    return state != 4; // disconnected
  }

  static void OnShow(IntPtr hook, uint what, IntPtr window, int part, int child, uint thread, uint time) {
    if (part == 0 && child == 0 && window != IntPtr.Zero) Tidy(window);
  }

  static void Sweep() {
    LoadSettings();
    EnumWindows(delegate(IntPtr window, IntPtr unused) { Tidy(window); return true; }, IntPtr.Zero);
  }

  static void Tidy(IntPtr window) {
    try {
      long style = GetWindowLongPtr(window, GWL_STYLE).ToInt64();
      if ((style & WS_CHILD) != 0 || !IsWindowVisible(window)) return;
      uint process;
      GetWindowThreadProcessId(window, out process);
      if (process == self) return;

      if (!roundedCorners && squared.Add(window)) {
        int square = DWMWCP_DONOTROUND; // an older Windows does not know this one, and has square corners
        DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, ref square, sizeof(int));
      }

      if (titleBars || (style & WS_CAPTION) != WS_CAPTION) return;
      if ((style & (WS_MINIMIZEBOX | WS_MAXIMIZEBOX)) == 0) return;       // a dialog
      if ((GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) != 0) return; // a floating palette is moved by its bar
      if (GetWindow(window, GW_OWNER) != IntPtr.Zero || IsIconic(window)) return;
      // Whose title bar is it? When Windows draws it, the window's own area
      // starts below it. A program that draws its own has taken that space.
      RECT outer;
      POINT inner = new POINT();
      if (!GetWindowRect(window, out outer) || !ClientToScreen(window, ref inner)) return;
      if (inner.y - outer.top < GetSystemMetrics(SM_CYCAPTION)) return;
      if (keep.Contains(Name(process))) return;

      // The sizing border goes with it: the desktop sizes the window, and a
      // border without a title bar leaves a blank strip along the top.
      SetWindowLongPtr(window, GWL_STYLE, new IntPtr(style & ~(WS_CAPTION | WS_THICKFRAME)));
      SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x1 | 0x2 | 0x4 | 0x10 | 0x20); // same place, size and order; frame changed
    } catch (Exception) {
      // a window that went away while it was being looked at
    }
  }

  static string Name(uint process) {
    string name;
    if (names.TryGetValue(process, out name)) return name;
    try { name = Process.GetProcessById((int)process).ProcessName; } catch (Exception) { name = ""; }
    names[process] = name;
    return name;
  }

  // frame.conf, next to this program: what winapp's settings say. Read again
  // whenever it changes; without it, both are tidied.
  static void LoadSettings() {
    string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "frame.conf");
    try {
      DateTime written = File.GetLastWriteTimeUtc(path);
      if (written == settingsRead) return;
      settingsRead = written;
      titleBars = roundedCorners = false;
      keep.Clear();
      foreach (string entry in File.ReadAllLines(path)) {
        int at = entry.IndexOf('=');
        if (at < 0) continue;
        string name = entry.Substring(0, at).Trim(), value = entry.Substring(at + 1).Trim();
        if (name == "titleBars") titleBars = value == "1";
        else if (name == "roundedCorners") roundedCorners = value == "1";
        else if (name == "keep") {
          foreach (string program in value.Split(';')) {
            if (program.Trim().Length > 0) keep.Add(Path.GetFileNameWithoutExtension(program.Trim()));
          }
        }
      }
    } catch (Exception) {
      // no file, or half written: keep what is in force
    }
  }
}
