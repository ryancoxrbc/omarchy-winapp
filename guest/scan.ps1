# Job for `winapp scan`: the programs installed in the VM, with the executable
# each Start Menu shortcut really launches and the file types it opens.

$sh = New-Object -ComObject WScript.Shell
# MSI "advertised" shortcuts point at an icon stub under C:\Windows\Installer;
# Windows Installer knows which file the shortcut really launches.
$wi = New-Object -ComObject WindowsInstaller.Installer
function Get-Prop($o, $name, $a) { $o.GetType().InvokeMember($name, 'GetProperty', $null, $o, $a) }

# --- file types, by the program registered to open them ------------------------
# assoc maps .ext -> ProgID and ftype maps ProgID -> command line; together they
# give the types each executable is the registered handler for.
$typesOf = @{}
function Add-FileType($exe, $ext) {
  $key = $exe.ToLower()
  if (-not $typesOf.ContainsKey($key)) { $typesOf[$key] = New-Object System.Collections.Generic.List[string] }
  $ext = $ext.TrimStart('.').ToLower()
  if ($ext -match '^[a-z0-9_+-]{1,12}$' -and -not $typesOf[$key].Contains($ext)) { $typesOf[$key].Add($ext) }
}

$exeOf = @{}
foreach ($line in (cmd /c ftype 2>$null)) {
  $eq = $line.IndexOf('=')
  if ($eq -lt 1) { continue }
  $command = [Environment]::ExpandEnvironmentVariables($line.Substring($eq + 1))
  if ($command -match '^"([^"]+\.exe)"') { $exeOf[$line.Substring(0, $eq)] = $Matches[1] }
  elseif ($command -match '^(.+?\.exe)(\s|$)') { $exeOf[$line.Substring(0, $eq)] = $Matches[1] }
}
foreach ($line in (cmd /c assoc 2>$null)) {
  $eq = $line.IndexOf('=')
  if ($eq -lt 2) { continue }
  $progId = $line.Substring($eq + 1)
  if ($exeOf.ContainsKey($progId)) { Add-FileType $exeOf[$progId] $line.Substring(0, $eq) }
}

function Get-Types($exe) {
  $types = New-Object System.Collections.Generic.List[string]
  $key = $exe.ToLower()
  if ($typesOf.ContainsKey($key)) { $types.AddRange($typesOf[$key]) }
  # what the program itself declares it can open
  $supported = "Registry::HKEY_CLASSES_ROOT\Applications\$([IO.Path]::GetFileName($exe))\SupportedTypes"
  if (Test-Path -LiteralPath $supported) {
    foreach ($name in (Get-Item -LiteralPath $supported).GetValueNames()) {
      $ext = $name.TrimStart('.').ToLower()
      if ($ext -match '^[a-z0-9_+-]{1,12}$' -and -not $types.Contains($ext)) { $types.Add($ext) }
    }
  }
  if ($types.Count -gt 60) { $types.RemoveRange(60, $types.Count - 60) }
  , $types.ToArray()
}

# --- programs ------------------------------------------------------------------
$dirs = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$seen = @{}
$apps = New-Object System.Collections.Generic.List[object]
foreach ($lnk in (Get-ChildItem $dirs -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | Sort-Object BaseName)) {
  try {
    $shortcut = $sh.CreateShortcut($lnk.FullName)
    $target = $shortcut.TargetPath
    if ($target -like '*\Installer\{*') {
      try {
        $record = Get-Prop $wi 'ShortcutTarget' @($lnk.FullName)
        $target = Get-Prop $wi 'ComponentPath' @((Get-Prop $record 'StringData' @(1)), (Get-Prop $record 'StringData' @(3)))
      } catch { }
    }
    if ($target -notlike '*.exe' -or -not (Test-Path -LiteralPath $target)) { continue }
    $key = ($target + '|' + $shortcut.Arguments).ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $apps.Add([pscustomobject]@{
        name = $lnk.BaseName
        exe  = $target
        args = [string]$shortcut.Arguments
        ext  = (Get-Types $target)
      })
  } catch { }
}

$os = Get-CimInstance Win32_OperatingSystem
$policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
$allow = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' -ErrorAction SilentlyContinue

Write-Result ([pscustomobject]@{
    windows   = [pscustomobject]@{ caption = [string]$os.Caption; version = [string]$os.Version }
    remoteapp = [pscustomobject]@{
      allowUnlisted     = [int]$policy.fAllowUnlistedRemotePrograms
      allowListDisabled = [int]$allow.fDisabledAllowList
    }
    apps      = $apps.ToArray()
  })
