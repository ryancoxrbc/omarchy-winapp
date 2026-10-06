# Job for everything winapp changes or asks inside the VM. in.json may carry:
#   icons     [{id, exe}]                  save each program's icon as icons\<id>.png
#   exists    ["C:\...\app.exe", ...]      report which paths are there
#   registry  [{key, name, type, value}]   per-user settings an app needs
#   remoteapp true                         let RemoteApp start any program
#   smbCache  true                         stop Windows caching the ~/Windows share's listings
#   pin       ["\\tsclient\home", ...]     pin folders to Quick access
#   frame     {stamp, titleBars, roundedCorners, keep[]}
#                                          build the program apps are started through, and its settings
# The result always reports the Windows version and the RemoteApp policy.

$job = Read-Job
$result = [ordered]@{}

# --- icons ---------------------------------------------------------------------
# The shell hands out an icon at any size, with its alpha channel, for anything
# it can show: sharper than the 32-pixel icon ExtractAssociatedIcon stops at.
$iconCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class WinappIcon {
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IShellItemImageFactory {
    [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr bitmap);
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct SIZE { public int cx; public int cy; }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  private static extern void SHCreateItemFromParsingName(
    [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr context, [In] ref Guid iid,
    [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

  [DllImport("gdi32.dll")]
  private static extern bool DeleteObject(IntPtr handle);

  public static void Save(string exe, string png, int size) {
    Guid iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
    IShellItemImageFactory factory;
    SHCreateItemFromParsingName(exe, IntPtr.Zero, ref iid, out factory);
    SIZE wanted;
    wanted.cx = size;
    wanted.cy = size;
    IntPtr handle;
    int hr = factory.GetImage(wanted, 0x4 /* SIIGBF_ICONONLY */, out handle);
    if (hr != 0) throw new COMException("GetImage failed", hr);
    try {
      using (Bitmap raw = Image.FromHbitmap(handle)) {
        Rectangle all = new Rectangle(0, 0, raw.Width, raw.Height);
        // FromHbitmap forgets the alpha channel, but the pixels still carry it
        // (premultiplied): read the same memory again as what it really is.
        BitmapData data = raw.LockBits(all, ImageLockMode.ReadOnly, raw.PixelFormat);
        try {
          using (Bitmap view = new Bitmap(data.Width, data.Height, data.Stride, PixelFormat.Format32bppPArgb, data.Scan0))
          using (Bitmap copy = view.Clone(all, PixelFormat.Format32bppArgb)) {
            Rectangle box = Content(copy);
            // A program with only a small icon gets it in a corner of a large
            // empty bitmap; keep the icon, not the emptiness.
            using (Bitmap cropped = copy.Clone(box, PixelFormat.Format32bppArgb)) {
              cropped.Save(png, ImageFormat.Png);
            }
          }
        } finally {
          raw.UnlockBits(data);
        }
      }
    } finally {
      DeleteObject(handle);
    }
  }

  // The smallest square that holds every pixel that is not fully transparent.
  private static Rectangle Content(Bitmap image) {
    int left = image.Width, top = image.Height, right = -1, bottom = -1;
    for (int y = 0; y < image.Height; y++) {
      for (int x = 0; x < image.Width; x++) {
        if (image.GetPixel(x, y).A != 0) {
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
    }
    if (right < 0) return new Rectangle(0, 0, image.Width, image.Height);
    int side = Math.Max(right - left + 1, bottom - top + 1);
    if (side * 10 >= image.Width * 9) return new Rectangle(0, 0, image.Width, image.Height);
    int cx = Math.Max(0, Math.Min(left - (side - (right - left + 1)) / 2, image.Width - side));
    int cy = Math.Max(0, Math.Min(top - (side - (bottom - top + 1)) / 2, image.Height - side));
    return new Rectangle(cx, cy, side, side);
  }
}
'@

if ($job.icons) {
  Add-Type -AssemblyName System.Drawing
  $hires = $true
  try { Add-Type -TypeDefinition $iconCode -ReferencedAssemblies System.Drawing } catch { $hires = $false }
  $dir = Join-Path $share 'icons'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $icons = [ordered]@{}
  foreach ($item in $job.icons) {
    $png = Join-Path $dir "$($item.id).png"
    if (-not (Test-Path -LiteralPath $item.exe)) { $icons[$item.id] = 'missing'; continue }
    $saved = $false
    if ($hires) {
      try { [WinappIcon]::Save($item.exe, $png, 256); $saved = $true } catch { }
    }
    if (-not $saved) {
      try {
        [System.Drawing.Icon]::ExtractAssociatedIcon($item.exe).ToBitmap().Save($png)
        $saved = $true
      } catch { }
    }
    $icons[$item.id] = $(if ($saved) { 'ok' } else { 'failed' })
  }
  $result.icons = $icons
}

# --- questions -----------------------------------------------------------------
if ($job.exists) {
  $exists = [ordered]@{}
  foreach ($path in $job.exists) { $exists[$path] = [bool](Test-Path -LiteralPath $path) }
  $result.exists = $exists
}

# What the host wrote into the share, read back: proves the redirected folder
# works in both directions.
$probe = Join-Path $share 'probe.txt'
if (Test-Path -LiteralPath $probe) { $result.echo = ([IO.File]::ReadAllText($probe)).Trim() }

# --- settings ------------------------------------------------------------------
if ($job.registry) {
  $applied = 0
  foreach ($entry in $job.registry) {
    & reg.exe add $entry.key /v $entry.name /t $entry.type /d $entry.value /f 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $applied++ }
  }
  $result.registry = $applied
}

if ($job.remoteapp) {
  & reg.exe add 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /v fAllowUnlistedRemotePrograms /t REG_DWORD /d 1 /f 2>&1 | Out-Null
  & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' /v fDisabledAllowList /t REG_DWORD /d 1 /f 2>&1 | Out-Null
}

if ($job.smbCache) {
  # The ~/Windows share (\\host.lan\Data) is served by Samba, which grants SMB3
  # directory leases: Windows then keeps a folder's listing until the server
  # says it changed, and a file written on the Linux side never makes it say
  # so. Measured: a new file stayed invisible indefinitely; with these caches
  # off it shows at once. The setting persists in the guest.
  try {
    Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 -FileNotFoundCacheLifetime 0 -Confirm:$false
    $result.smbCache = 'ok'
  } catch { $result.smbCache = "failed: $($_.Exception.Message)" }
}

if ($job.pin) {
  $pinned = 0
  $shell = New-Object -ComObject Shell.Application
  $quick = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
  $already = @($quick.Items() | ForEach-Object { $_.Path })
  foreach ($folder in $job.pin) {
    if ($already -contains $folder) { continue }
    try {
      $item = $shell.Namespace($folder)
      if ($item) { $item.Self.InvokeVerb('pintohome'); $pinned++ }
    } catch { }
  }
  # the shell pins in the background; leaving at once would lose it
  if ($pinned -gt 0) { Start-Sleep -Milliseconds 1500 }
  $result.pinned = $pinned
}

if ($job.frame) {
  # winapp-frame.exe (frame.cs, sent along with this job) takes the Windows
  # title bar and rounded corners off app windows. It is compiled here, once
  # per version, by the compiler Windows carries; it does nothing unless winapp
  # starts an app through it.
  $frame = [ordered]@{}
  try {
    $dir = Join-Path $env:ProgramData 'winapp'
    $exe = Join-Path $dir 'winapp-frame.exe'
    $stamp = Join-Path $dir 'frame.stamp'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $built = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $stamp) -and
      ([IO.File]::ReadAllText($stamp).Trim() -eq [string]$job.frame.stamp)
    if (-not $built) {
      Get-Process -Name 'winapp-frame' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 300
      Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
      $source = [IO.File]::ReadAllText((Join-Path $share 'frame.cs'), $utf8)
      Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType WindowsApplication
      [IO.File]::WriteAllText($stamp, [string]$job.frame.stamp, $utf8)
    }
    $lines = @(
      "titleBars=$([int][bool]$job.frame.titleBars)"
      "roundedCorners=$([int][bool]$job.frame.roundedCorners)"
      "keep=$(@($job.frame.keep | Where-Object { $_ }) -join ';')"
    )
    [IO.File]::WriteAllLines((Join-Path $dir 'frame.conf'), [string[]]$lines, $utf8)
    $frame.status = 'ok'
  } catch { $frame.status = "failed: $($_.Exception.Message)" }
  $result.frame = $frame
}

# --- always --------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
$allow = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' -ErrorAction SilentlyContinue
$result.windows = [ordered]@{ caption = [string]$os.Caption; version = [string]$os.Version }
$result.remoteapp = [ordered]@{
  allowUnlisted     = [int]$policy.fAllowUnlistedRemotePrograms
  allowListDisabled = [int]$allow.fDisabledAllowList
}

Write-Result ([pscustomobject]$result)
