# fzf + ANSI helpers for the ClaudeContextManager menus.
# Follows the BetterHotkeys Omarchy theme (Win+Shift+T) when it's installed, otherwise uses Hackerman.

[Console]::OutputEncoding = $OutputEncoding = [Text.UTF8Encoding]::new($false)   # no BOM, or fzf's first row breaks
$PSStyle.OutputRendering = 'Ansi'   # otherwise PowerShell strips the colors from rows piped to fzf

# Clear-Host fails when there's no real console window (piped or scripted runs); only clear when there is one
function Clear-Host { if (-not [Console]::IsOutputRedirected) { try { [Console]::Clear() } catch {} } }

$script:esc = [char]27
$script:reset = "$esc[0m"

function Get-Ansi([string]$hex) {
    $r, $g, $b = 1, 3, 5 | ForEach-Object { [Convert]::ToInt32($hex.Substring($_, 2), 16) }
    "$esc[38;2;$r;$g;${b}m"
}

$script:theme = $null
$betterHotkeysTheme = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AutoHotkey\theme-lib.ps1'
if (Test-Path $betterHotkeysTheme) {
    try { . $betterHotkeysTheme; $script:theme = Get-CurrentTheme } catch { $script:theme = $null }
}
if (-not $theme) {
    $script:theme = @{ accent = '#82FB9C'; selection = '#1F253A'; muted = '#2D3450'; dark_foreground = '#6A6E95'
        bright_foreground = '#DDF7FF'; red = '#50F872'; yellow = '#50F7D4' }
}
$script:green = Get-Ansi $theme.accent
$script:dim = Get-Ansi $theme.dark_foreground
$script:bright = Get-Ansi $theme.bright_foreground
$script:warn = Get-Ansi $theme.yellow

$script:fzf = Get-Command fzf -ErrorAction SilentlyContinue
$script:fzf = if ($fzf) { $fzf.Source } else {
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\junegunn.fzf*\fzf.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

$script:fzfStyle = @('--ansi', '--layout=reverse', '--gutter= ', '--border=rounded', '--prompt=  ', '--pointer=>',
    '--info=inline-right', '--header-first', '--delimiter=\t', '--with-nth=1', '--no-sort', '--tiebreak=index',
    ("--color=border:$($theme.muted),label:$($theme.accent),prompt:$($theme.accent),pointer:$($theme.accent)," +
     "header:$($theme.dark_foreground),hl:$($theme.accent),hl+:$($theme.accent),info:$($theme.dark_foreground)," +
     "fg+:$($theme.bright_foreground),bg+:$($theme.selection),gutter:-1,preview-border:$($theme.muted)"))

# Shows rows ("display`tkey`tpreview-file") in fzf. Returns @{ Key = <pressed key or ''>; Row = <key field> }, or $null on Esc.
function Show-Menu([string[]]$Rows, [string]$Label, [string]$Header, [string[]]$Expect = @(), [switch]$Preview) {
    if (-not $fzf) { throw 'The menus need fzf: winget install junegunn.fzf (then open a new terminal).' }
    $fzfArgs = @($fzfStyle) + @("--border-label= $Label ", "--header=$Header")
    if ($Expect) { $fzfArgs += "--expect=$($Expect -join ',')" }
    if ($Preview) {
        # fzf runs previews through cmd and quotes {3} for it
        $fzfArgs += '--preview=if exist {3} (type {3}) else (echo.)', '--preview-window=right,50%,wrap,border-left'
    }
    $out = @($Rows | & $fzf @fzfArgs)
    if (-not $out -or $out.Count -eq 0) { return $null }
    if ($Expect) { $key = $out[0]; $row = if ($out.Count -gt 1) { $out[1] } else { '' } } else { $key = ''; $row = $out[0] }
    if (-not $row -and -not $key) { return $null }
    @{ Key = $key; Row = if ($row) { ($row -split "`t")[1] } else { '' } }
}

# Throws away keys pressed (or terminal replies received) while something was running, so a question
# never answers itself with leftover input
function Clear-PendingInput {
    if ([Console]::IsInputRedirected) { return }
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch {}
}

function Read-Value($label, $default = '') {
    Clear-PendingInput
    $hint = if ($default) { " $dim[$default]$reset" } else { '' }
    Write-Host -NoNewline "  $green$label$reset$hint$green >$reset "
    $value = [Console]::ReadLine()
    $value = if ($null -eq $value) { '' } else { $value.Trim() }
    if ($value) { $value } else { $default }
}

# -Required: no default, Enter alone asks again (for choices that do something outside this PC)
function Read-YesNo($question, [bool]$default = $true, [switch]$Required) {
    if ($Required) {
        if ([Console]::IsInputRedirected) { $a = Read-Value "$question (y/n)"; return $a -match '^y' }
        while ($true) {
            $a = Read-Value "$question (y/n)"
            if ($a -match '^[yn]') { return $a -match '^y' }
            Write-Host "  ${dim}Type y or n.$reset"
        }
    }
    $hint = if ($default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Value "$question ($hint)"
    if (-not $answer) { return $default }
    $answer -match '^y'
}

function Write-Info($text) { Write-Host "  $dim$text$reset" }
function Write-Ok($text) { Write-Host "  $green$text$reset" }
function Write-Warn($text) { Write-Host "  $warn$text$reset" }

function Wait-Key {
    if ([Console]::IsInputRedirected) { return }      # not at a keyboard (piped or scripted)
    Write-Host "`n  ${dim}Press any key...$reset"; [void][Console]::ReadKey($true)
}
