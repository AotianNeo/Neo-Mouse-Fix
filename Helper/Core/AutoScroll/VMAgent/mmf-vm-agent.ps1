# Mac Mouse Fix VM agent
#
# Runs in a Windows virtual machine (e.g. Parallels Desktop) and tells Mac Mouse Fix's Auto Scroll what's under the guest's cursor, using Windows UI Automation.
# On the Mac, Accessibility can't see into the VM, so without this, Auto Scroll can't tell a tab or a link (where a middle click should stay a normal click) from page content.
# See `GuestAgent` and `isVirtualMachine(_:)` in AutoScroll.swift.
#
# Protocol: TCP, one line per query.
#   "Q"      -> the element under the cursor
#   "Q x y"  -> the element at (x, y), in physical pixels (for testing)
#   "D x y"  -> debugging: each level from the element at (x, y) up – control type, class, UI framework, scroll pattern, process. No names or text.
#   Answer:  "P <type> ..." = pressable (tab, link, button, split button, menu item: a middle click there should go to Windows)
#            "S <type> ..." = inside something that can scroll (an element with a UI Automation scroll pattern that's scrollable)
#            "U ..."        = can't tell: web content that doesn't expose its UI (Chromium / Electron apps with accessibility off, e.g. QQ)
#            "N ..."        = neither (e.g. the desktop, the taskbar)
#            "E ..."        = error
#
# Install (in the VM, as the user):
#   1. Copy this file to %LOCALAPPDATA%\MacMouseFix\mmf-vm-agent.ps1
#   2. Start it at logon:  schtasks /create /f /tn "Mac Mouse Fix VM agent" /sc onlogon /it /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File %LOCALAPPDATA%\MacMouseFix\mmf-vm-agent.ps1"
#   3. Allow the Mac to connect (as administrator):  netsh advfirewall firewall add rule name="Mac Mouse Fix VM agent" dir=in action=allow protocol=TCP localport=47001 remoteip=10.211.55.0/24 profile=any
#      (10.211.55.0/24 is Parallels' shared network.)
#   4. On the Mac, set `vmAgent` in the AutoScroll dict of Mac Mouse Fix's config.plist to "<VM IP>:47001", and restart the helper.
param([int]$port = 47001)
$src = @"
using System; using System.Net; using System.Net.Sockets; using System.IO; using System.Threading; using System.Diagnostics;
using System.Runtime.InteropServices; using System.Windows.Automation;
public static class MmfVmAgent {
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  static readonly ControlType[] pressable = { ControlType.TabItem, ControlType.Hyperlink, ControlType.Button, ControlType.SplitButton, ControlType.MenuItem };
  public static string Classify(int x, int y) {
    var sw = Stopwatch.StartNew();
    AutomationElement e;
    try { e = AutomationElement.FromPoint(new System.Windows.Point(x, y)); } catch (Exception ex) { return "E " + ex.GetType().Name; }
    var walker = TreeWalker.ControlViewWalker;
    var root = AutomationElement.RootElement;
    string path = "";
    /// Walk up from the element under the point: the first pressable or scrollable element decides. (Up to the top-level window – not the desktop.)
    for (int i = 0; i < 30 && e != null && !e.Equals(root); i++) {
      ControlType ct; string className; try { ct = e.Current.ControlType; className = e.Current.ClassName; } catch { break; }
      string name = ct.ProgrammaticName.Replace("ControlType.", "");
      path += (path.Length > 0 ? ">" : "") + name;
      foreach (var p in pressable) if (ct == p) return "P " + name + " " + sw.ElapsedMilliseconds + "ms " + path;
      /// Chromium's web content window itself: we only get it (instead of an element inside) when the app doesn't expose its web UI. (Edge and Chrome do; many Electron apps don't.)
      if (i == 0 && className == "Chrome_RenderWidgetHostHWND") return "U " + name + " " + sw.ElapsedMilliseconds + "ms " + path;
      object scroll;
      try {
        if (e.TryGetCurrentPattern(ScrollPattern.Pattern, out scroll)) {
          var c = ((ScrollPattern)scroll).Current;
          if (c.VerticallyScrollable || c.HorizontallyScrollable) return "S " + name + " " + sw.ElapsedMilliseconds + "ms " + path;
        }
      } catch { }
      try { e = walker.GetParent(e); } catch { break; }
    }
    return "N - " + sw.ElapsedMilliseconds + "ms " + path;
  }
  public static string Describe(int x, int y) {
    var sb = new System.Text.StringBuilder();
    AutomationElement e;
    try { e = AutomationElement.FromPoint(new System.Windows.Point(x, y)); } catch (Exception ex) { return "E " + ex.GetType().Name; }
    var walker = TreeWalker.ControlViewWalker; var root = AutomationElement.RootElement;
    for (int i = 0; i < 30 && e != null && !e.Equals(root); i++) {
      try {
        var c = e.Current; string scroll = "-";
        object sp; if (e.TryGetCurrentPattern(ScrollPattern.Pattern, out sp)) { var sc = ((ScrollPattern)sp).Current; scroll = "v" + (sc.VerticallyScrollable ? 1 : 0) + "h" + (sc.HorizontallyScrollable ? 1 : 0); }
        string proc = "?"; try { proc = Process.GetProcessById(c.ProcessId).ProcessName; } catch { }
        sb.Append(c.ControlType.ProgrammaticName.Replace("ControlType.", "") + "[" + c.ClassName + "," + c.FrameworkId + ",scroll " + scroll + "," + proc + "] > ");
        e = walker.GetParent(e);
      } catch (Exception ex) { sb.Append("(" + ex.GetType().Name + ")"); break; }
    }
    return sb.ToString();
  }
  public static void Serve(int port) {
    SetProcessDpiAwarenessContext(new IntPtr(-4));
    var listener = new TcpListener(IPAddress.Any, port); listener.Start();
    while (true) { var c = listener.AcceptTcpClient(); c.NoDelay = true; var t = new Thread(() => Handle(c)); t.IsBackground = true; t.Start(); }
  }
  static void Handle(TcpClient c) {
    try {
      using (c) using (var s = c.GetStream()) using (var r = new StreamReader(s)) using (var w = new StreamWriter(s)) {
        w.AutoFlush = true; w.NewLine = "\n"; string line;
        while ((line = r.ReadLine()) != null) {
          var parts = line.Trim().Split(' '); int x, y;
          if (parts[0] == "D" && parts.Length >= 3) { w.WriteLine(Describe(int.Parse(parts[1]), int.Parse(parts[2]))); continue; }
          if (parts.Length >= 3) { x = int.Parse(parts[1]); y = int.Parse(parts[2]); } else { POINT p; GetCursorPos(out p); x = p.X; y = p.Y; }
          w.WriteLine(Classify(x, y) + " @" + x + "," + y);
        }
      }
    } catch { }
  }
}
"@
Add-Type -TypeDefinition $src -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase
[MmfVmAgent]::Serve($port)
