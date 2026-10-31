// winapp-agent: opens what winapp asks for inside the Windows desktop.
//
// winapp shows Windows as one desktop in one window. When a Linux file is
// opened with a Windows app, winapp does not make a connection of its own: it
// writes the command line into a folder that the desktop's connection
// redirects (\\tsclient\winappq), and this program, running in that session,
// starts it and brings the window it opens to the front.
//
// It also keeps a list of the app windows that are open in that folder
// (open.txt), so that winapp can say what is still running in Windows when
// its window is closed: closing it does not close the apps.
//
// It is started by a scheduled task at every sign-in and every time a Remote
// Desktop connection reaches the session (guest/apply.ps1 registers it), and
// one copy runs per session. It keeps no state and changes nothing in Windows.
//
// winapp builds this inside the VM with the C# 5 compiler that ships with
// Windows, hence the plain syntax.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class WinappAgent {
  delegate bool EnumProc(IntPtr window, IntPtr unused);

  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc each, IntPtr unused);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint which);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int how);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBox(IntPtr owner, string text, string caption, uint type);

  const int GWL_EXSTYLE = -20, SW_RESTORE = 9, DWMWA_CLOAKED = 14;
  const long WS_EX_TOOLWINDOW = 0x00000080;
  const uint GW_OWNER = 4, KEYEVENTF_KEYUP = 2;
  const byte VK_MENU = 0x12;
  const string Requests = "\\\\tsclient\\winappq";

  static uint self;
  static string reported;

  [STAThread]
  static int Main() {
    SetProcessDPIAware();
    self = (uint)Process.GetCurrentProcess().Id;
    bool first;
    Mutex one = new Mutex(true, "Local\\winapp-agent", out first);
    if (!first) return 0; // this session has one already
    Serve();
    GC.KeepAlive(one);
    return 0;
  }

  // A request is a file of two lines: "open" or "hidden", and a command line.
  // Taking one is a rename, which only one side can win: winapp renames a
  // request nobody took in time, and says so.
  static void Serve() {
    for (int round = 0; ; round++) {
      bool reached = false;
      try {
        if (round % 10 == 0) Report();
        foreach (string request in Directory.GetFiles(Requests, "*.req")) {
          reached = true;
          string taken = request + ".taken";
          try { File.Move(request, taken); } catch (Exception) { continue; }
          string[] lines = File.ReadAllLines(taken);
          try { File.Delete(taken); } catch (Exception) { }
          if (lines.Length < 2 || lines[1].Trim().Length == 0) continue;
          bool hidden = lines[0].Trim() == "hidden";
          string line = lines[1].Trim();
          // on its own thread: a program that cannot be started says so in a
          // box that waits for an answer, and the next request should not
          Thread start = new Thread(delegate() { Open(line, hidden); });
          start.SetApartmentState(ApartmentState.STA);
          start.IsBackground = true;
          start.Start();
        }
        reached = true;
      } catch (Exception) {
        // no such folder in this session (a desktop opened by something other
        // than winapp), or the connection is away for the moment
      }
      Thread.Sleep(reached ? 150 : 1000);
    }
  }

  static void Open(string line, bool hidden) {
    string program, arguments;
    Split(line, out program, out arguments);
    HashSet<IntPtr> before = hidden ? null : Windows();
    try {
      ProcessStartInfo start = new ProcessStartInfo(program, arguments);
      if (hidden) {
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
      } else {
        start.UseShellExecute = true;
      }
      Process.Start(start);
    } catch (Exception error) {
      MessageBox(IntPtr.Zero,
        "Windows could not start\n" + program + "\n\n" + error.Message +
        "\n\nIf the app was moved or removed, run on Linux:  winapp scan",
        "winapp", 0x30 /* warning */ | 0x10000 /* in front */);
      return;
    }
    if (!hidden) Front(Stem(arguments), before);
  }

  // The titles of the apps' windows, one per line, written only when they
  // change. Explorer's are left out: a folder window holds no unsaved work.
  static void Report() {
    StringBuilder list = new StringBuilder();
    foreach (IntPtr window in Windows()) {
      uint process;
      GetWindowThreadProcessId(window, out process);
      string name;
      try { name = Process.GetProcessById((int)process).ProcessName; } catch (Exception) { continue; }
      if (string.Equals(name, "explorer", StringComparison.OrdinalIgnoreCase)) continue;
      list.Append(Title(window).Replace('\n', ' ')).Append('\n');
    }
    string text = list.ToString();
    string path = Path.Combine(Requests, "open.txt");
    if (text == reported && File.Exists(path)) return; // a new connection starts with an empty folder
    File.WriteAllText(path + ".new", text, new UTF8Encoding(false));
    File.Copy(path + ".new", path, true);
    File.Delete(path + ".new");
    reported = text;
  }

  // The window the request opened is brought to the front. Windows lets a
  // program that was started from here come up behind whatever has the focus,
  // and a file that is open already only has its window flash. So: the window
  // whose title names the file, or else the first new window, for 20 seconds.
  static void Front(string stem, HashSet<IntPtr> before) {
    IntPtr newcomer = IntPtr.Zero;
    for (int i = 0; i < 100; i++) {
      IntPtr named = IntPtr.Zero;
      foreach (IntPtr window in Windows()) {
        if (stem != null && Title(window).IndexOf(stem, StringComparison.OrdinalIgnoreCase) >= 0) named = window;
        else if (newcomer == IntPtr.Zero && !before.Contains(window)) newcomer = window;
      }
      if (named != IntPtr.Zero) { Raise(named); return; }
      // without a file to look for, the first new window is the one
      if (stem == null && newcomer != IntPtr.Zero) { Thread.Sleep(300); Raise(newcomer); return; }
      Thread.Sleep(200);
    }
    if (newcomer != IntPtr.Zero) Raise(newcomer);
  }

  static void Raise(IntPtr window) {
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    uint unused;
    uint mine = GetCurrentThreadId(), theirs = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
    bool attached = theirs != 0 && theirs != mine && AttachThreadInput(mine, theirs, true);
    BringWindowToTop(window);
    SetForegroundWindow(window);
    if (attached) AttachThreadInput(mine, theirs, false);
    if (GetForegroundWindow() != window) {
      // a key event of our own is what Windows accepts as the right to do so
      keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
      keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
      SetForegroundWindow(window);
    }
  }

  // Visible, titled top-level windows that are not owned by another, not tool
  // windows and not cloaked: the ones a person would call "the app's window".
  // (Windows keeps some of its own, such as "Windows Input Experience",
  // visible but cloaked, which is how Alt+Tab knows to leave them out.)
  static HashSet<IntPtr> Windows() {
    HashSet<IntPtr> found = new HashSet<IntPtr>();
    EnumWindows(delegate(IntPtr window, IntPtr unused) {
      uint process;
      GetWindowThreadProcessId(window, out process);
      if (process != self && IsWindowVisible(window) && GetWindow(window, GW_OWNER) == IntPtr.Zero &&
          (GetWindowLongPtr(window, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) == 0 && !Cloaked(window) &&
          Title(window).Length > 0)
        found.Add(window);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  static bool Cloaked(IntPtr window) {
    int cloaked;
    return DwmGetWindowAttribute(window, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0;
  }

  static string Title(IntPtr window) {
    StringBuilder text = new StringBuilder(512);
    GetWindowText(window, text, text.Capacity);
    return text.ToString();
  }

  // The name, without its extension, of the last file on a command line:
  // what the app is likely to put in its window's title.
  static string Stem(string arguments) {
    string last = null;
    int at = 0;
    while (at < arguments.Length) {
      string word;
      if (arguments[at] == '"') {
        int end = arguments.IndexOf('"', at + 1);
        if (end < 0) end = arguments.Length;
        word = arguments.Substring(at + 1, Math.Max(0, end - at - 1));
        at = end + 1;
      } else {
        int end = arguments.IndexOf(' ', at);
        if (end < 0) end = arguments.Length;
        word = arguments.Substring(at, end - at);
        at = end + 1;
      }
      if (word.IndexOf('\\') >= 0) last = word;
    }
    if (last == null) return null;
    string stem = Path.GetFileNameWithoutExtension(last.TrimEnd('\\'));
    return stem.Length > 0 ? stem : null;
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
}
