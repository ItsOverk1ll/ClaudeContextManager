# ClaudeContextManager (ccm): collects Claude Code / Claude Desktop context into a Context folder,
# sorts it by project and lets you browse it in an fzf TUI.
#
#   ccm                 open the menu (runs setup the first time)
#   ccm setup           run the setup wizard again
#   ccm sync            sync now  (--quiet, --push, --resort, --background)
#   ccm push            commit and push the Context folder to its GitHub repo
#   ccm import <path>   import a claude.ai data export (.zip or folder) - Claude Desktop chats
#   ccm open            open the Context folder in Explorer
#   ccm uninstall       remove the hook, scheduled task and the ccm / ClaudeContextManager commands (keeps your Context folder)

param([Parameter(Position = 0)][string]$Command = 'menu', [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest = @())

. (Join-Path $PSScriptRoot 'ccm-lib.ps1')
$flags = @($Rest | Where-Object { $_ -like '--*' })
$params = @($Rest | Where-Object { $_ -notlike '--*' })

# The Claude Code hook calls `sync --background`: hand off to a hidden process so the session can exit right away
if ($Command -eq 'sync' -and '--background' -in $flags) {
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process $pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', "`"$PSCommandPath`"", 'sync', '--quiet'
    exit 0
}

. (Join-Path $PSScriptRoot 'ui-lib.ps1')

function Get-Editor {
    if ($env:CCM_EDITOR) { return $env:CCM_EDITOR }
    foreach ($e in 'code', 'notepad++') { if (Get-Command $e -ErrorAction SilentlyContinue) { return $e } }
    'notepad'
}

function Open-File($path) {
    $editor = Get-Editor
    if ($editor -eq 'code') { & code $path } else { Start-Process $editor -ArgumentList "`"$path`"" }
}

#region Setup

function Invoke-Setup {
    Clear-Host
    $config = Get-Config
    Write-Host "`n  ${green}ClaudeContextManager setup$reset`n"
    Write-Info 'Collects context from Claude Code (CLI and the Claude Desktop Code tab), Claude memory and'
    Write-Info 'CLAUDE.md files, and sorts it into one folder per project.'
    Write-Host ''

    $config.ContextDir = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables((Read-Value 'Context folder' $config.ContextDir)))
    $config.AutoSort = Read-YesNo 'Sort context into projects automatically?' $true
    if (-not $config.AutoSort) { Write-Info "New context will go to $Unsorted for you to sort from the menu (Ctrl+V)." }
    $config.Redact = Read-YesNo 'Redact API keys, tokens and passwords in saved context?' $true
    Save-Config $config
    New-Item -ItemType Directory -Force $config.ContextDir | Out-Null

    Write-Host ''
    if (Read-YesNo 'Sync automatically when a Claude Code session ends (adds a hook to ~/.claude/settings.json)?' $true) {
        try { Install-SyncHook; Write-Ok 'Hook added.' } catch { Write-Warn "Couldn't add the hook: $_" }
    } else { Uninstall-SyncHook }
    if (Read-YesNo 'Also sync in the background every 30 minutes (catches Claude Desktop sessions)?' $true) {
        try { Install-SyncTask; Write-Ok 'Scheduled task added.' } catch { Write-Warn "Couldn't add the scheduled task: $_" }
    } else { Uninstall-SyncTask }

    Write-Host "`n  ${dim}Collecting context...$reset"
    Invoke-Sync $config | Out-Null

    Write-Host ''
    Write-Info 'Your context can be backed up to a private GitHub repo (needs the GitHub CLI, gh).'
    Write-Info 'It holds your Claude conversations, so it is always created private.'
    if (Read-YesNo 'Create a private GitHub repo for your context?' $true) { Set-Repo $config }

    Write-Host "`n  ${green}All set.$reset Type ${bright}ClaudeContextManager$reset (or ${bright}ccm$reset) any time to open the menu."
    Write-Info "Claude Desktop chats (not Code sessions) are stored on claude.ai: export them in Claude > Settings >"
    Write-Info "Privacy > Export data, then use Settings > Import in the menu (or: ccm import <zip>)."
    Wait-Key
}

function Set-Repo($config) {
    $problem = Test-GitHubCli
    if ($problem) { Write-Warn $problem; return }
    $default = if ($config.Repo) { ($config.Repo -split '/')[-1] } else { 'BitOfContext' }
    $name = Read-Value 'Repo name' $default
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { Write-Warn 'Repo names can only use letters, numbers, . _ and -'; return }
    try {
        Write-Info "Setting up $name..."
        Initialize-ContextRepo $config $name
        $config.AutoPush = Read-YesNo 'Push to the repo automatically after every sync?' $true
        Save-Config $config
    } catch { Write-Warn "$_" }
}

#endregion

#region Menus

function Get-ProjectStats($config) {
    $index = Read-State $config 'index'
    $stats = @{}
    foreach ($e in $index.Values) {
        $s = $stats[$e.project] ??= @{ Sessions = 0; Memory = 0; Last = '' }
        if ($e.kind -eq 'memory') { $s.Memory++ } else { $s.Sessions++ }
        if ($e.updated -gt $s.Last) { $s.Last = $e.updated }
    }
    foreach ($name in Get-ProjectNames $config) { if (-not $stats.Contains($name)) { $stats[$name] = @{ Sessions = 0; Memory = 0; Last = '' } } }
    $stats
}

function Select-Project($config, $title, $exclude) {
    $stats = Get-ProjectStats $config
    $names = @($stats.Keys | Where-Object { $_ -ne $exclude -and $_ -ne $Global } | Sort-Object)
    $rows = @("$green+ New project$reset`t+new") + @($names | ForEach-Object { "$_`t$_" })
    $pick = Show-Menu $rows $title 'Enter choose  ·  Esc cancel'
    if (-not $pick) { return $null }
    if ($pick.Row -eq '+new') { return (New-ProjectPrompt $config) }
    $pick.Row
}

function New-ProjectPrompt($config) {
    Clear-Host
    Write-Host "`n  ${green}New project$reset  $dim(leave the name empty to cancel)$reset`n"
    $name = Get-SafeName (Read-Value 'Name')
    if (-not $name) { return $null }
    Write-Info 'Folders and keywords help auto-sort: sessions that touch these folders or mention these words land here.'
    $paths = @((Read-Value 'Folders (comma separated, optional)') -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    $keywords = @((Read-Value 'Keywords (comma separated, optional)') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    New-ContextProject $config $name $paths $keywords
    if (Read-YesNo 'Re-sort existing auto-sorted context with the new rules?' $true) { Invoke-Sync $config -Resort | Out-Null; Start-Sleep -Milliseconds 700 }
    $name
}

function Copy-ProjectContext($config, $project) {
    $dir = Join-Path $config.ContextDir (Get-SafeName $project)
    $parts = @()
    foreach ($f in @(Get-ChildItem $dir -File -Filter *.md) + @(Get-ChildItem (Join-Path $dir 'memory') -File -ErrorAction SilentlyContinue)) {
        $parts += "<!-- $($f.Name) -->`n$(Get-Content -LiteralPath $f.FullName -Raw)"
    }
    $text = "Context for project ${project} (from my Context folder: $dir)`n`n" + ($parts -join "`n`n")
    Set-Clipboard -Value $text
    Write-Ok "Copied $($text.Length) characters of $project context (PROJECT.md, docs and memory). Paste it into Claude."
    Start-Sleep -Milliseconds 1200
}

function Show-ProjectMenu($config, $project) {
    while ($true) {
        $index = Read-State $config 'index'
        $dir = Join-Path $config.ContextDir (Get-SafeName $project)
        if (-not (Test-Path $dir)) { return }
        $rows = @()
        foreach ($f in Get-ChildItem $dir -File | Sort-Object { $_.Name -ne 'PROJECT.md' }, Name) {
            $rows += "$green◆$reset $($f.Name)`tfile:$($f.Name)`t$($f.FullName)"
        }
        $sub = Join-Path $dir 'claude-ai-project'
        if (Test-Path $sub) { foreach ($f in Get-ChildItem $sub -File) { $rows += "$green◆$reset claude.ai project / $($f.Name)`tfile:claude-ai-project\$($f.Name)`t$($f.FullName)" } }
        $items = @($index.GetEnumerator() | Where-Object { $_.Value.project -eq $project })
        foreach ($m in $items | Where-Object { $_.Value.kind -eq 'memory' } | Sort-Object { $_.Value.title }) {
            $rows += "$green✎$reset {0,-46} ${dim}memory$reset`t{1}`t{2}" -f (Get-OneLine $m.Value.title 46), $m.Key, (Join-Path $config.ContextDir $m.Value.file)
        }
        foreach ($s in $items | Where-Object { $_.Value.kind -ne 'memory' } | Sort-Object { $_.Value.updated } -Descending) {
            $e = $s.Value
            $src = switch ($e.source) { 'Claude Desktop' { 'Desktop' } 'claude.ai' { 'claude.ai' } default { 'CLI' } }
            $pin = if ($e.auto) { ' ' } else { "$green•$reset" }
            $rows += "$dim$($e.updated.Substring(5, 5))$reset$pin{0,-40} $dim{1,-7}{2,3}p$reset`t{3}`t{4}" -f (Get-OneLine $e.title 40), $src, $e.prompts, $s.Key, (Join-Path $config.ContextDir $e.file)
        }
        $header = "Enter open  ·  Ctrl+V move to project  ·  Ctrl+R resume in Claude  ·  Esc back`n" +
            "Ctrl+Y copy  ·  Ctrl+D remove  ·  Ctrl+O folder  ·  $green•$reset sorted by hand"
        $pick = Show-Menu $rows $project $header -Expect 'ctrl-v', 'ctrl-r', 'ctrl-y', 'ctrl-d', 'ctrl-o' -Preview
        if (-not $pick) { return }
        if ($pick.Key -eq 'ctrl-o') { Start-Process explorer.exe $dir; continue }
        if (-not $pick.Row) { continue }
        $id = $pick.Row
        $path = if ($id -like 'file:*') { Join-Path $dir $id.Substring(5) } else { Join-Path $config.ContextDir $index[$id].file }
        switch ($pick.Key) {
            'ctrl-v' {
                if ($id -like 'file:*') { Write-Warn 'Project docs follow their project folder; move sessions and memory instead.'; Start-Sleep 1; break }
                $to = Select-Project $config "Move to project" $project
                if ($to) { Move-ContextItem $config $id $to }
            }
            'ctrl-r' {
                $e = $index[$id]
                if (-not $e -or $e.kind -ne 'session') { Write-Warn 'Only Claude Code sessions can be resumed.'; Start-Sleep 1; break }
                Clear-Host
                $cwd = if ($e.cwd -and (Test-Path -LiteralPath $e.cwd)) { $e.cwd } else { $HOME }
                Push-Location $cwd
                try { & claude --resume $id } finally { Pop-Location }
            }
            'ctrl-y' { Set-Clipboard -Value (Get-Content -LiteralPath $path -Raw); Write-Ok 'Copied to the clipboard.'; Start-Sleep -Milliseconds 700 }
            'ctrl-d' {
                if ($id -like 'file:*') { break }
                Clear-Host
                if (Read-YesNo "Remove `"$($index[$id].title)`" from the Context folder? It won't be imported again." $false) { Remove-ContextItem $config $id }
            }
            default { Open-File $path }
        }
    }
}

function Show-SettingsMenu {
    while ($true) {
        $config = Get-Config
        $on = { param($v) if ($v) { "$green[on]$reset" } else { "$dim[off]$reset" } }
        $hook = Test-SyncHook
        $task = Test-SyncTask
        $repo = if ($config.Repo) { "$green$($config.Repo)$reset" } else { "${dim}not set up (Enter to create)$reset" }
        $rows = @(
            "Auto-sort new context          $(& $on $config.AutoSort)`tautosort",
            "Redact secrets                 $(& $on $config.Redact)`tredact",
            "Sync when a session ends       $(& $on $hook)  ${dim}Claude Code hook$reset`thook",
            "Background sync every 30 min   $(& $on $task)  ${dim}scheduled task$reset`ttask",
            "GitHub repo                    $repo`trepo",
            "Push after every sync          $(& $on $config.AutoPush)`tautopush",
            "Context folder                 $dim$($config.ContextDir)$reset`tdir",
            "Import claude.ai / Desktop chat export...`timport",
            "Re-sort everything ${dim}(keeps what you sorted by hand)$reset`tresort",
            "Edit project rules ${dim}(.ccm\projects.json: folders + keywords per project)$reset`trules",
            "Run setup again`tsetup"
        )
        $pick = Show-Menu $rows 'Settings' 'Enter toggle / change  ·  Esc back'
        if (-not $pick) { return }
        Clear-Host
        switch ($pick.Row) {
            'autosort' { $config.AutoSort = -not $config.AutoSort; Save-Config $config }
            'redact' { $config.Redact = -not $config.Redact; Save-Config $config; Write-Info 'Applies to context synced from now on (Re-sort everything rewrites all of it).'; Start-Sleep 1 }
            'autopush' { $config.AutoPush = -not $config.AutoPush; Save-Config $config }
            'hook' { if ($hook) { Uninstall-SyncHook } else { Install-SyncHook } }
            'task' { try { if ($task) { Uninstall-SyncTask } else { Install-SyncTask } } catch { Write-Warn "$_"; Wait-Key } }
            'repo' { Set-Repo $config; Wait-Key }
            'dir' {
                $new = Read-Value 'Context folder' $config.ContextDir
                $new = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($new))
                if ($new -ne $config.ContextDir) {
                    if ((Test-Path $config.ContextDir) -and -not (Test-Path $new) -and (Read-YesNo "Move the existing Context folder to $new?" $true)) {
                        Move-Item -LiteralPath $config.ContextDir $new
                    }
                    $config.ContextDir = $new; Save-Config $config
                }
            }
            'import' {
                Write-Host "`n  ${green}Import a claude.ai data export$reset"
                Write-Info 'claude.ai (or Claude Desktop) > Settings > Privacy > Export data. The email link gives you a .zip.'
                $path = Read-Value 'Path to the .zip or extracted folder'
                if ($path) {
                    try { $n = Import-ClaudeExport $config $path; Write-Ok "Imported $n conversation(s)." } catch { Write-Warn "$_" }
                    Wait-Key
                }
            }
            'resort' { Invoke-Sync $config -Resort | Out-Null; Wait-Key }
            'rules' {
                $file = Join-Path (Get-StateDir $config) 'projects.json'
                Open-File $file
                Write-Info 'Save the file, then use Re-sort everything to apply the new rules.'; Start-Sleep 2
            }
            'setup' { Invoke-Setup }
        }
    }
}

function Show-MainMenu {
    if (-not (Test-Configured)) { Invoke-Setup }
    while ($true) {
        $config = Get-Config
        $stats = Get-ProjectStats $config
        $rows = @("$green↻ Sync now$reset`t+sync")
        if ($config.Repo) { $rows += "$green↑ Push to GitHub$reset $dim$($config.Repo)$reset`t+push" }
        $rows += "$green+ New project$reset`t+new", "$green≡ Settings$reset`t+settings"
        # most recently active first, Unsorted and _Global last
        $names = $stats.Keys | Sort-Object @{ e = { $_ -in $Unsorted, $Global } }, @{ e = { $stats[$_].Last }; Descending = $true }
        foreach ($name in $names) {
            $s = $stats[$name]
            $last = if ($s.Last) { $s.Last.Substring(0, 10) } else { '' }
            $label = if ($name -eq $Unsorted -and $s.Sessions) { "$warn$name$reset" } else { $name }
            $pad = ' ' * [Math]::Max(1, 26 - $name.Length)
            $rows += "$label$pad$dim{0,3} sess {1,2} mem  {2}$reset`t{3}`t{4}" -f $s.Sessions, $s.Memory, $last, $name, (Join-Path $config.ContextDir "$(Get-SafeName $name)\PROJECT.md")
        }
        $header = "Enter open  ·  Ctrl+S sync  ·  Ctrl+N new project  ·  Esc quit`nCtrl+R rename/merge  ·  Ctrl+Y copy context  ·  Ctrl+O folder"
        $pick = Show-Menu $rows 'Claude Context' $header -Expect 'ctrl-s', 'ctrl-n', 'ctrl-r', 'ctrl-y', 'ctrl-o' -Preview
        if (-not $pick) { Clear-Host; return }
        $row = $pick.Row
        $isProject = $row -and -not $row.StartsWith('+')
        switch ($pick.Key) {
            'ctrl-s' { $row = '+sync' }
            'ctrl-n' { $row = '+new' }
            'ctrl-o' { Start-Process explorer.exe $(if ($isProject) { Join-Path $config.ContextDir (Get-SafeName $row) } else { $config.ContextDir }); continue }
            'ctrl-y' { if ($isProject) { Copy-ProjectContext $config $row }; continue }
            'ctrl-r' {
                if (-not $isProject) { continue }
                Clear-Host
                Write-Host "`n  ${green}Rename $row$reset  $dim(use an existing project's name to merge into it)$reset`n"
                $new = Get-SafeName (Read-Value 'New name' $row)
                if ($new -and $new -ne $row) { Rename-ContextProject $config $row $new }
                continue
            }
        }
        Clear-Host
        switch ($row) {
            '+sync' { Invoke-Sync $config | Out-Null; Start-Sleep -Milliseconds 900 }
            '+push' { Push-Context $config; Start-Sleep -Milliseconds 1200 }
            '+new' { $n = New-ProjectPrompt $config; if ($n) { Show-ProjectMenu $config $n } }
            '+settings' { Show-SettingsMenu }
            default { Show-ProjectMenu $config $row }
        }
    }
}

#endregion

function Uninstall-Ccm {
    Uninstall-SyncHook
    Uninstall-SyncTask
    $bin = Join-Path $env:LOCALAPPDATA 'ClaudeContextManager\bin'
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $newPath = ($path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin }) -join ';'
    if ($newPath -ne $path) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    $config = Get-Config
    Write-Ok "Removed the hook, scheduled task and the ccm / ClaudeContextManager commands. Your Context folder ($($config.ContextDir)) was kept."
    Write-Info "Delete $(Join-Path $env:LOCALAPPDATA 'ClaudeContextManager') and $AppDataDir to remove the program files and settings."
}

if (-not $fzf -and $Command -eq 'menu') { Write-Warn 'fzf is required for the menu: winget install junegunn.fzf'; exit 1 }

switch ($Command) {
    'menu' { Show-MainMenu }
    'setup' { Invoke-Setup }
    'sync' {
        if (-not (Test-Configured)) { if ('--quiet' -in $flags) { exit 0 }; Invoke-Setup; exit 0 }
        Invoke-Sync (Get-Config) -Quiet:('--quiet' -in $flags) -Resort:('--resort' -in $flags) -Push:('--push' -in $flags) | Out-Null
    }
    'push' { Push-Context (Get-Config) }
    'import' {
        if (-not $params) { Write-Warn 'Usage: ccm import <export .zip or folder>'; exit 1 }
        $n = Import-ClaudeExport (Get-Config) $params[0]; Write-Ok "Imported $n conversation(s)."
    }
    'open' { Start-Process explorer.exe (Get-Config).ContextDir }
    'uninstall' { Uninstall-Ccm }
    default { Get-Content $PSCommandPath | Select-Object -Skip 2 -First 9 | ForEach-Object { $_.TrimStart('#') } }
}
