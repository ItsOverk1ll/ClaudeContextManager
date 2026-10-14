# Installs ClaudeContextManager for the current user and runs its setup.
#   pwsh -File install.ps1            install / update, then run setup (first install only)
#   pwsh -File install.ps1 -NoSetup   install / update only
param([switch]$NoSetup)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Host 'ClaudeContextManager needs PowerShell 7. Installing it with winget...'
        winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements
        $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    } else { $pwsh = $pwsh.Source }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
    exit $LASTEXITCODE
}

$root = Join-Path $env:LOCALAPPDATA 'ClaudeContextManager'
$app = Join-Path $root 'app'
$bin = Join-Path $root 'bin'
$firstInstall = -not (Test-Path (Join-Path $env:APPDATA 'ClaudeContextManager\config.json'))

if (-not (Get-Command fzf -ErrorAction SilentlyContinue) -and
    -not (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\junegunn.fzf*\fzf.exe" -ErrorAction SilentlyContinue)) {
    Write-Host '  Installing fzf (the menu UI)...'
    winget install --id junegunn.fzf -e --accept-source-agreements --accept-package-agreements | Out-Null
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host '  Git is not installed; GitHub backup needs it (winget install Git.Git).' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Host '  GitHub CLI is not installed; GitHub backup needs it (winget install GitHub.cli).' }

New-Item -ItemType Directory -Force $app, $bin | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'src\*') $app -Recurse -Force
Set-Content (Join-Path $bin 'ccm.cmd') "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"$app\ccm.ps1`" %*" -Encoding ascii

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', (@($userPath.TrimEnd(';'), $bin) -join ';').TrimStart(';'), 'User')
}
$env:Path = "$env:Path;$bin"
Write-Host "  Installed to $app. The 'ccm' command works in new terminals."

if (-not $NoSetup -and $firstInstall) { & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'ccm.ps1') setup }
