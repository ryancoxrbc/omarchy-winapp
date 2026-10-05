# Runs inside the Windows VM. winapp redirects a folder into the session as
# \\tsclient\winapp, puts this file and a job.ps1 in it, and starts this one.
# The job reads in.json and writes its results next to it; this wrapper only
# makes sure the host is never left waiting on a job that threw.
$ErrorActionPreference = 'Stop'
$share = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false

function Read-Job {
  $path = Join-Path $share 'in.json'
  if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json }
}

function Write-Result($value) {
  $json = ConvertTo-Json -InputObject $value -Depth 6 -Compress
  [IO.File]::WriteAllText((Join-Path $share 'out.json'), $json, $utf8)
}

try {
  . (Join-Path $share 'job.ps1')
} catch {
  [IO.File]::WriteAllText((Join-Path $share 'error.txt'), ($_ | Out-String), $utf8)
}
[IO.File]::WriteAllText((Join-Path $share 'done'), 'ok', $utf8)
