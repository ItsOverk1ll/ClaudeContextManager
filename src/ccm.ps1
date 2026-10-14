# ClaudeContextManager (ccm): collects Claude Code / Claude Desktop context into a Context folder,
# sorts it by project and lets you browse it in an fzf TUI.
#
#   ccm                 open the menu (runs setup the first time)
#   ccm setup           run the setup wizard again
#   ccm sync            sync now  (--quiet, --push, --resort, --background)
#   ccm push            commit and push the Context folder to its GitHub repo
#   ccm import <path>   import a claude.ai data export (.zip or folder) - Claude Desktop chats
#   ccm open            open the Context folder in Explorer
#   ccm search [words]  search all your context   (--project=<name> to search one project)
#   ccm memory          browse memory files by agent
#   ccm summary <project>   write the project's "where we left off" summary now (--all: every project)
#   ccm cleanup [project ...]   archive old/tiny sessions and shrink transcripts (no project: pick them)
#   ccm plugins         browse plugins (e.g. Codex) and install them
#   ccm plugin install <name>   install or update a plugin   (also: plugin remove <name>, plugin list)
#   ccm uninstall       remove the hook, scheduled task and the ccm / ClaudeContextManager commands (keeps your Context folder)

param([Parameter(Position = 0)][string]$Command = 'menu', [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest = @())

. (Join-Path $PSScriptRoot 'ccm-lib.ps1')
$flags = @($Rest | Where-Object { $_ -like '--*' })
$params = @($Rest | Where-Object { $_ -notlike '--*' })

# The Claude Code hook calls `sync --background`: hand off to a hidden process so the session can exit right away
if ($Command -eq 'sync' -and '--background' -in $flags) {
    if ($env:CCM_SUMMARIZING) { exit 0 }      # a summary's own claude run: never sync from inside it
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process $pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', "`"$PSCommandPath`"", 'sync', '--quiet'
    exit 0
}

. (Join-Path $PSScriptRoot 'ui-lib.ps1')

# "~\Context" or "%USERPROFILE%\Context" -> a full path (relative paths are taken from your home folder)
function Resolve-UserPath([string]$path) {
    $p = [Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"'))
    if ($p -match '^~([\\/]|$)') { $p = $HOME + $p.Substring(1) }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $HOME $p }
    [IO.Path]::GetFullPath($p)
}

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

    $config.ContextDir = Resolve-UserPath (Read-Value 'Context folder' $config.ContextDir)
    $config.AutoSort = Read-YesNo 'Sort context into projects automatically?' $true
    if (-not $config.AutoSort) { Write-Info "New context will go to $Unsorted for you to sort from the menu (Ctrl+V)." }
    $config.Redact = Read-YesNo 'Redact API keys, tokens and passwords in saved context?' $true
    Write-Host ''
    Write-Info "Each project can have a short 'where we left off' summary (shown at the top of PROJECT.md),"
    Write-Info 'written by Claude from your sessions. Automatic mode refreshes it in the background after syncs'
    Write-Info "when a project has new sessions (at most every $($config.SummaryMinHours) hours, using the small $($config.SummaryModel) model and your Claude usage)."
    $config.Summaries = if (Read-YesNo 'Write summaries automatically?' $true) { 'auto' } else { 'manual' }
    if ($config.Summaries -eq 'manual') { Write-Info 'You can write one any time: Ctrl+W in a project.' }
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
    Invoke-Sync $config -NoSummaries | Out-Null      # summaries are written after the questions, in the background

    Write-Host ''
    Write-Info 'Your context can be backed up to a private GitHub repo (needs the GitHub CLI, gh).'
    Write-Info 'It holds your Claude conversations, so it is always created private.'
    if (Read-YesNo 'Create a private GitHub repo for your context?' -Required) { Set-Repo $config }

    if ($config.Summaries -eq 'auto') {
        Write-Info "Writing each project's 'where we left off' summary in the background (they show up in PROJECT.md as they finish)."
        Start-Process (Get-Process -Id $PID).Path -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', "`"$PSCommandPath`"", 'summary', '--all', '--quiet'
    }
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
        if ($e.kind -eq 'memory') { if ($e.project -ne $Unsorted) { $s.Memory++ } } else { $s.Sessions++ }
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
    # Claude's context only; other agents' context stays separate (the OliveBranch plugin can bridge it)
    $text = Get-AgentContext $config $project @('claude') -RecentSessions 3 -MaxChars 200000
    if (-not $text.Trim()) { Write-Warn "No Claude context in $project yet."; Start-Sleep 1; return }
    Set-Clipboard -Value $text
    Write-Ok "Copied $($text.Length) characters of $project Claude context (docs, memory, sessions). Paste it into Claude."
    Start-Sleep -Milliseconds 1200
}

# Ctrl+Enter on a project: choose an agent, then start it in the project's folder with the project's context.
# (Windows Terminal sends Ctrl+Enter as Ctrl+J; Alt+Enter works too.)
$script:LaunchKeys = 'ctrl-j', 'alt-enter'

function Start-ProjectAgent($config, [string]$project) {
    if ($project -in $Unsorted, $Global) { Write-Warn "$project isn't a real project, so there's no folder to open."; Start-Sleep 1; return }
    $folders = @(Get-ProjectFolders $config $project)
    if (-not $folders) { Write-Warn "No folder on disk is linked to $project yet (rename/merge it into a project that has one, or open a session there first)."; Start-Sleep 2; return }
    $agents = @(Get-LaunchAgents)
    if (-not $agents) { Write-Warn 'No agent commands found (is claude on your PATH?).'; Start-Sleep 2; return }
    $rows = $agents | ForEach-Object { "$green$($_.Label)$reset $dim$($_.Command)$reset`t$($_.Name)" }
    $pick = Show-Menu @($rows) "Open $project with" 'Enter choose  ·  Esc back'
    if (-not $pick) { return }
    $agent = $agents | Where-Object Name -eq $pick.Row | Select-Object -First 1
    $folder = $folders[0]
    if ($folders.Count -gt 1) {
        $fp = Show-Menu @($folders | ForEach-Object { "$_`t$_" }) "Which folder?" 'Enter choose  ·  Esc back'
        if (-not $fp) { return }
        $folder = $fp.Row
    }
    Clear-Host
    Write-Info "Starting $($agent.Label) in $folder ..."
    $prompt = Get-LaunchPrompt $config $project $agent
    $agentArgs = @(& $agent.Args $prompt)
    Push-Location $folder
    try { & $agent.Command @agentArgs } catch { Write-Warn "$_"; Wait-Key } finally { Pop-Location }
}

function Show-ProjectActions($config, $project) {
    if (-not $ProjectActions.Count) { return }
    $rows = for ($i = 0; $i -lt $ProjectActions.Count; $i++) { "$(& $ProjectActions[$i].Label $config $project)`t$i" }
    $pick = Show-Menu @($rows) "$project · plugins" 'Enter choose  ·  Esc back'
    if (-not $pick) { return }
    Clear-Host
    & $ProjectActions[[int]$pick.Row].Run $config $project
}

function Show-ProjectMenu($config, $project) {
    while ($true) {
        $index = Read-State $config 'index'
        $dir = Join-Path $config.ContextDir (Get-SafeName $project)
        if (-not (Test-Path $dir)) { return }
        $rows = @()
        $pm = Join-Path $dir 'PROJECT.md'
        if (Test-Path -LiteralPath $pm) { $rows += "$green◆$reset PROJECT.md`tfile:PROJECT.md`t$pm" }
        foreach ($f in Get-ProjectDocs $dir) {
            $label = $f.RelPath -replace '^claude-ai-project\\', 'claude.ai project / ' -replace '\\', ' / '
            $rows += "$green◆$reset $label`tfile:$($f.RelPath)`t$($f.FullName)"
        }
        $items = @($index.GetEnumerator() | Where-Object { $_.Value.project -eq $project })
        foreach ($m in $items | Where-Object { $_.Value.kind -eq 'memory' -and $project -ne $Unsorted } | Sort-Object { $_.Value.title }) {
            $rows += "$green✎$reset {0,-46} ${dim}memory$reset`t{1}`t{2}" -f (Get-OneLine $m.Value.title 46), $m.Key, (Join-Path $config.ContextDir $m.Value.file)
        }
        foreach ($s in $items | Where-Object { $_.Value.kind -ne 'memory' } | Sort-Object { $_.Value.updated } -Descending) {
            $e = $s.Value
            $src = switch ($e.source) { 'Claude Desktop' { 'Desktop' } 'claude.ai' { 'claude.ai' } 'Claude Code CLI' { 'CLI' } default { Get-AgentLabel $e } }
            $pin = if ($e.auto) { ' ' } else { "$green•$reset" }
            $rows += "$dim$($e.updated.Substring(5, 5))$reset$pin{0,-40} $dim{1,-7}{2,3}p$reset`t{3}`t{4}" -f (Get-OneLine $e.title 40), $src, $e.prompts, $s.Key, (Join-Path $config.ContextDir $e.file)
        }
        $header = "Enter open  ·  Ctrl+V move to project  ·  Ctrl+R resume session  ·  Ctrl+F search  ·  Esc back`n" +
            "Ctrl+W write summary  ·  Ctrl+K clean up  ·  Ctrl+Y copy  ·  Ctrl+D remove  ·  Ctrl+O folder  ·  Ctrl+Enter open agent`n" +
            "$(if ($ProjectActions.Count) { 'Ctrl+P plugins  ·  ' })$green•$reset sorted by hand"
        $pick = Show-Menu $rows $project $header -Expect (@('ctrl-v', 'ctrl-r', 'ctrl-y', 'ctrl-d', 'ctrl-o', 'ctrl-p', 'ctrl-w', 'ctrl-k', 'ctrl-f') + $LaunchKeys) -Preview
        if (-not $pick) { return }
        if ($pick.Key -in $LaunchKeys) { Start-ProjectAgent $config $project; continue }
        if ($pick.Key -eq 'ctrl-o') { Start-Process explorer.exe $dir; continue }
        if ($pick.Key -eq 'ctrl-p') { Show-ProjectActions $config $project; continue }
        if ($pick.Key -eq 'ctrl-f') { Show-Search $config $project; continue }
        if ($pick.Key -eq 'ctrl-k') { Invoke-CleanupWizard $config @($project); continue }
        if ($pick.Key -eq 'ctrl-w') { Write-SummaryNow $config $project; continue }
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
                $agent = if ($e.agent) { $e.agent } else { 'claude' }
                $resume = if ($e -and $e.kind -eq 'session' -and $ContextSources.Contains($agent)) { $ContextSources[$agent].Resume }
                if (-not $resume) { Write-Warn 'This item has no session to resume (claude.ai chats and memory files can''t be resumed).'; Start-Sleep 1; break }
                Clear-Host
                $cwd = if ($e.cwd -and (Test-Path -LiteralPath $e.cwd)) { $e.cwd } else { $HOME }
                Push-Location $cwd
                try { & $resume $id $e } catch { Write-Warn "$_"; Wait-Key } finally { Pop-Location }
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

# Memory -> <agent> -> files. Each file is linked to a project (Ctrl+V changes it); "general" = not about one project.
function Show-MemoryMenu($config) {
    while ($true) {
        $index = Read-State $config 'index'
        $mem = @($index.GetEnumerator() | Where-Object { $_.Value.kind -eq 'memory' })
        if (-not $mem) { Clear-Host; Write-Info 'No memory files yet. Claude saves them as it learns about you and your projects.'; Start-Sleep 2; return }
        $groups = $mem | Group-Object { Get-AgentLabel $_.Value } | Sort-Object { $_.Name -ne 'Claude' }, Name
        $rows = foreach ($g in $groups) {
            $folder = Join-Path $config.ContextDir (Join-Path $MemoryRoot (Get-SafeName $g.Name))
            "{0,-14} $dim{1,3} file(s)$reset`t{0}`t{2}" -f $g.Name, $g.Count, $folder
        }
        $pick = Show-Menu @($rows) 'Memory' 'Enter open  ·  Esc back'
        if (-not $pick -or -not $pick.Row) { return }
        Show-AgentMemory $config $pick.Row
    }
}

function Show-AgentMemory($config, [string]$agentLabel) {
    while ($true) {
        $index = Read-State $config 'index'
        $mem = @($index.GetEnumerator() | Where-Object { $_.Value.kind -eq 'memory' -and (Get-AgentLabel $_.Value) -eq $agentLabel } | Sort-Object { $_.Value.title })
        if (-not $mem) { return }
        $rows = foreach ($m in $mem) {
            $e = $m.Value
            $proj = if ($e.project -eq $Unsorted) { "${dim}general$reset" } else { $e.project }
            $pin = if ($e.auto) { ' ' } else { "$green•$reset" }
            "$green✎$reset$pin{0,-40} $dim{1}$reset  {2}`t{3}`t{4}" -f (Get-OneLine $e.title 40), $e.updated.Substring(0, 10), $proj, $m.Key, (Join-Path $config.ContextDir $e.file)
        }
        $header = "Enter open  ·  Ctrl+V link to a project  ·  Ctrl+Y copy  ·  Ctrl+D remove  ·  Ctrl+O folder  ·  Esc back`n" +
            "${dim}Each memory is linked to the project it's about (general = none); it's included in that project's context.$reset"
        $pick = Show-Menu @($rows) "Memory · $agentLabel" $header -Expect 'ctrl-v', 'ctrl-y', 'ctrl-d', 'ctrl-o' -Preview
        if (-not $pick) { return }
        if ($pick.Key -eq 'ctrl-o') { Start-Process explorer.exe (Join-Path $config.ContextDir (Join-Path $MemoryRoot (Get-SafeName $agentLabel))); continue }
        if (-not $pick.Row) { continue }
        $id = $pick.Row
        $path = Join-Path $config.ContextDir $index[$id].file
        switch ($pick.Key) {
            'ctrl-v' {
                $to = Select-Project $config "Link `"$($index[$id].title)`" to" ''
                if ($to) { Move-ContextItem $config $id $to }
            }
            'ctrl-y' { Set-Clipboard -Value (Get-Content -LiteralPath $path -Raw); Write-Ok 'Copied to the clipboard.'; Start-Sleep -Milliseconds 700 }
            'ctrl-d' {
                Clear-Host
                if (Read-YesNo "Remove `"$($index[$id].title)`" from the Context folder? (Claude keeps its own copy; it won't be imported again.)" $false) { Remove-ContextItem $config $id }
            }
            default { Open-File $path }
        }
    }
}

function Write-SummaryNow($config, $project) {
    Clear-Host
    Write-Info "Writing the 'where we left off' summary for $project with Claude ($($config.SummaryModel))..."
    try { Update-ProjectSummary $config $project; Write-Ok 'Done. It is at the top of PROJECT.md (and in SUMMARY.md).' }
    catch { Write-Warn "$_" }
    Start-Sleep -Milliseconds 1200
}

# Full-text search over the Context folder: ripgrep when installed, otherwise Windows' findstr.
# fzf re-runs the search on every keystroke; the preview jumps to the matching line.
function Show-Search($config, [string]$project = '', [string]$query = '') {
    $root = $config.ContextDir
    $scope = if ($project) { "`"$(Get-SafeName $project)`"" } else { '.' }
    $rg = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $rg) {
        # just installed by winget: on the PATH only for terminals opened since, so look where winget puts it
        $rgExe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\BurntSushi.ripgrep*\*\rg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rgExe) { $env:Path = "$($rgExe.DirectoryName);$env:Path"; $rg = $rgExe }
    }
    $mdFiles = if ($project) { '"' + (Get-SafeName $project) + '\*.md"' } else { '*.md' }
    $find = if ($rg) { "rg --line-number --no-heading --color=always --smart-case --fixed-strings --max-columns=300 --max-columns-preview -g *.md -- {q} $scope" }
        else { "findstr /s /i /n /p /c:{q} $mdFiles" }
    $reload = "if {q}==`"`" (echo.) else ($find)"
    $style = @($fzfStyle | Where-Object { $_ -notlike '--delimiter=*' -and $_ -notlike '--with-nth=*' })
    $label = if ($project) { " Search $project " } else { ' Search all context ' }
    $editor = Get-Editor
    while ($true) {
        Push-Location $root
        try {
            $out = @(& $fzf @style '--disabled' '--delimiter=:' "--border-label=$label" "--query=$query" `
                "--header=Type to search  ·  Enter open at the line  ·  Ctrl+O open the project  ·  Esc back$(if (-not $rg) { "`n${dim}Faster search: winget install BurntSushi.ripgrep.MSVC$reset" })" `
                '--expect=ctrl-o' '--print-query' "--bind=start:reload:$reload" "--bind=change:reload:$reload" `
                '--preview=type {1}' '--preview-window=right,55%,wrap,border-left,+{2}-/2')
        } finally { Pop-Location }
        if ($out.Count -lt 3 -or -not $out[2]) { return }
        $query = $out[0]
        $m = [regex]::Match(($out[2] -replace '\e\[[0-9;]*m', ''), '^(.+?):(\d+):')
        if (-not $m.Success) { return }
        $file = Join-Path $root ($m.Groups[1].Value -replace '^\.[\\/]', '')
        $line = $m.Groups[2].Value
        if ($out[1] -eq 'ctrl-o') {
            $proj = ($m.Groups[1].Value -replace '^\.[\\/]', '' -split '[\\/]')[0]
            Show-ProjectMenu $config $proj
            return
        }
        if ($editor -eq 'code') { & code -g "${file}:$line" } else { Open-File $file }
    }
}

function Select-Projects($config, [string]$title) {
    $stats = Get-ProjectStats $config
    $names = @($stats.Keys | Where-Object { $_ -ne $Global } | Sort-Object)
    $rows = $names | ForEach-Object { "{0,-30} $dim{1,3} sessions$reset`t{0}" -f $_, $stats[$_].Sessions }
    $style = @($fzfStyle) + @('--multi', "--border-label= $title ", '--header=Tab select (any number)  ·  Enter done  ·  Esc cancel')
    $out = @($rows | & $fzf @style)
    @($out | Where-Object { $_ } | ForEach-Object { ($_ -split "`t")[1] })
}

function Invoke-CleanupWizard($config, [string[]]$projects) {
    Clear-Host
    if (-not $projects) { Write-Info 'No projects chosen.'; Start-Sleep 1; return }
    Write-Host "`n  ${green}Clean up$reset $dim$($projects -join ', ')$reset`n"
    Write-Info 'Removed sessions are kept in a zip archive (unless you say no) and are never imported again.'
    Write-Host ''
    $days = Read-Value 'Remove sessions not updated in how many days? (0 = keep all)' '180'
    $options = @{
        OlderThanDays = [int]($days -replace '\D', '')
        Tiny = Read-YesNo 'Remove tiny sessions (1 prompt or less)?' $true
        Compact = Read-YesNo 'Shrink the other sessions (drop tool-call lines, keep prompts and replies)?' $false
        Archive = $true
    }
    $plan = Get-CleanupPlan $config $projects $options
    if (-not $plan.Remove.Count -and -not $plan.Compact.Count) { Write-Ok 'Nothing to clean up.'; Wait-Key; return }
    Write-Host ''
    if ($plan.Remove.Count) {
        Write-Host "  Remove $($plan.Remove.Count) session(s), $(Format-Bytes $plan.RemoveBytes):"
        foreach ($r in $plan.Remove | Select-Object -First 12) { Write-Info "  $($r.Entry.updated.Substring(0, 10))  $(Get-OneLine $r.Entry.title 50)  ($($r.Reason))" }
        if ($plan.Remove.Count -gt 12) { Write-Info "  ... and $($plan.Remove.Count - 12) more" }
        $options.Archive = Read-YesNo 'Keep a zip archive of the removed sessions?' $true
    }
    if ($plan.Compact.Count) { Write-Host "  Shrink $($plan.Compact.Count) session(s)." }
    if (-not (Read-YesNo 'Go ahead?' $false)) { Write-Info 'Nothing changed.'; Start-Sleep 1; return }
    try {
        $r = Invoke-Cleanup $config $projects $options
        Write-Ok "Removed $($r.Removed) session(s) ($(Format-Bytes $r.RemovedBytes)), shrank $($r.Compacted) ($(Format-Bytes $r.CompactBytes) saved)."
        if ($r.Archive) { Write-Info "Archive: $($r.Archive)" }
        if ($config.Repo) { Write-Info 'Your GitHub repo keeps old versions in its history; its current files shrink with the next push.' }
    } catch { Write-Warn "$_" }
    Wait-Key
}

function Install-PluginNow($config, $name) {
    try {
        Write-Info "Installing $name..."
        $m = Install-CcmPlugin $config $name
        Write-Ok "Installed $($m.Name) $($m.Version)."
        if (Test-Configured) {
            Write-Info 'Syncing so its context shows up...'
            # a fresh process, so the plugin loads like it will from now on
            & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath sync | Out-Host
        }
    } catch { Write-Warn "$_" }
}

function Remove-PluginNow($config, $name) {
    $keep = Read-YesNo "Keep the $name context already in your Context folder?" $true
    try { Uninstall-CcmPlugin $config $name -RemoveContext:(-not $keep); Write-Ok "Removed $name." } catch { Write-Warn "$_" }
}

function Show-PluginsMenu {
    $config = Get-Config
    Clear-Host
    Write-Info 'Getting the plugin list...'
    try { $catalog = Update-PluginCatalog $config } catch { Write-Warn "$_"; Wait-Key; return }
    while ($true) {
        $installed = @{}
        foreach ($p in Get-InstalledPlugins) { $installed[$p.Name] = $p }
        $rows = foreach ($p in Get-AvailablePlugins $catalog) {
            $state = if (-not $installed.Contains($p.Name)) { "${dim}not installed$reset" }
                elseif ([version]$installed[$p.Name].Version -lt [version]$p.Version) { "$warn[update $($installed[$p.Name].Version) → $($p.Version)]$reset" }
                else { "$green[installed $($p.Version)]$reset" }
            "{0,-10} {1} {2,-38}`t{0}`t{3}" -f $p.Name, $state, (Get-OneLine $p.Description 38), $p.Readme
        }
        $header = "Enter install / update  ·  Ctrl+D remove  ·  Esc back`nOr paste anywhere: ${bright}ClaudeContextManager plugin install <name>$reset"
        $pick = Show-Menu @($rows) 'Plugins' $header -Expect 'ctrl-d' -Preview
        if (-not $pick -or -not $pick.Row) { return }
        Clear-Host
        if ($pick.Key -eq 'ctrl-d') {
            if ($installed.Contains($pick.Row)) { Remove-PluginNow $config $pick.Row } else { Write-Info "$($pick.Row) isn't installed." }
        } else { Install-PluginNow $config $pick.Row }
        Wait-Key
        # reload so the menus see the plugin's source right away
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath menu
        exit 0
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
            "Summaries                      $(if ($config.Summaries -eq 'auto') { "$green[auto]$reset" } else { "$dim[manual]$reset" })  ${dim}'where we left off' notes, model $($config.SummaryModel)$reset`tsummaries",
            "Write summaries for all projects now`tsummarize-all",
            "Clean up projects...  ${dim}(pick projects, then archive old/tiny sessions or shrink them)$reset`tcleanup",
            "Plugins ${dim}(add Codex and other agents' context)$reset`tplugins",
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
                $new = Resolve-UserPath (Read-Value 'Context folder' $config.ContextDir)
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
            'plugins' { Show-PluginsMenu }
            'summaries' {
                $config.Summaries = if ($config.Summaries -eq 'auto') { 'manual' } else { 'auto' }
                $model = Read-Value 'Model for summaries (haiku, sonnet, opus or a full model id)' $config.SummaryModel
                if ($model) { $config.SummaryModel = $model }
                Save-Config $config
            }
            'summarize-all' {
                foreach ($p in (Get-ProjectStats $config).Keys | Where-Object { $_ -notin $Unsorted, $Global }) {
                    Write-Info "Summarizing $p..."
                    try { Update-ProjectSummary $config $p; Write-Ok "  done" } catch { Write-Warn "  $_" }
                }
                Wait-Key
            }
            'cleanup' { Invoke-CleanupWizard $config (Select-Projects $config 'Clean up which projects?') }
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
        $rows += "$green/ Search$reset`t+search", "$green✎ Memory$reset`t+memory", "$green+ New project$reset`t+new", "$green⧉ Plugins$reset`t+plugins", "$green≡ Settings$reset`t+settings"
        # most recently active first, Unsorted and _Global last
        $names = $stats.Keys | Sort-Object @{ e = { $_ -in $Unsorted, $Global } }, @{ e = { $stats[$_].Last }; Descending = $true }
        foreach ($name in $names) {
            $s = $stats[$name]
            $last = if ($s.Last) { $s.Last.Substring(0, 10) } else { '' }
            $label = if ($name -eq $Unsorted -and $s.Sessions) { "$warn$name$reset" } else { $name }
            $pad = ' ' * [Math]::Max(1, 26 - $name.Length)
            $rows += "$label$pad$dim{0,3} sess {1,2} mem  {2}$reset`t{3}`t{4}" -f $s.Sessions, $s.Memory, $last, $name, (Join-Path $config.ContextDir "$(Get-SafeName $name)\PROJECT.md")
        }
        $header = "Enter open  ·  Ctrl+S sync  ·  Ctrl+F search  ·  Ctrl+N new project  ·  Esc quit`nCtrl+R rename/merge  ·  Ctrl+Y copy context  ·  Ctrl+W write summary  ·  Ctrl+K clean up  ·  Ctrl+O folder  ·  Ctrl+Enter open agent"
        $pick = Show-Menu $rows 'Claude Context' $header -Expect (@('ctrl-s', 'ctrl-n', 'ctrl-r', 'ctrl-y', 'ctrl-o', 'ctrl-f', 'ctrl-w', 'ctrl-k') + $LaunchKeys) -Preview
        if (-not $pick) { Clear-Host; return }
        $row = $pick.Row
        $isProject = $row -and -not $row.StartsWith('+')
        if ($pick.Key -in $LaunchKeys) { if ($isProject) { Start-ProjectAgent $config $row }; continue }
        switch ($pick.Key) {
            'ctrl-s' { $row = '+sync' }
            'ctrl-n' { $row = '+new' }
            'ctrl-o' { Start-Process explorer.exe $(if ($isProject) { Join-Path $config.ContextDir (Get-SafeName $row) } else { $config.ContextDir }); continue }
            'ctrl-y' { if ($isProject) { Copy-ProjectContext $config $row }; continue }
            'ctrl-f' { Show-Search $config $(if ($isProject) { $row } else { '' }); continue }
            'ctrl-w' { if ($isProject) { Write-SummaryNow $config $row }; continue }
            'ctrl-k' { Invoke-CleanupWizard $config $(if ($isProject) { @($row) } else { Select-Projects $config 'Clean up which projects?' }); continue }
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
            '+plugins' { Show-PluginsMenu }
            '+search' { Show-Search $config }
            '+memory' { Show-MemoryMenu $config }
            default { Show-ProjectMenu $config $row }
        }
    }
}

#endregion

function Uninstall-Ccm {
    Uninstall-SyncHook
    Uninstall-SyncTask
    # plugins' own hooks and skills point at this program, so take them out too (the plugin files stay)
    $config = Get-Config
    foreach ($name in @($PluginLifecycle.Keys)) {
        $u = $PluginLifecycle[$name].OnUninstall
        if ($u) { try { & $u $config } catch { Write-Warn "Plugin ${name}: $_" } }
    }
    $bin = Join-Path $env:LOCALAPPDATA 'ClaudeContextManager\bin'
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $newPath = ($path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin }) -join ';'
    if ($newPath -ne $path) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    $config = Get-Config
    Write-Ok "Removed the hook, scheduled task and the ccm / ClaudeContextManager commands. Your Context folder ($($config.ContextDir)) was kept."
    Write-Info "Delete $(Join-Path $env:LOCALAPPDATA 'ClaudeContextManager') and $AppDataDir to remove the program files and settings."
}

if (-not $fzf -and $Command -in 'menu', 'plugins', 'search', 'cleanup', 'memory') { Write-Warn 'The menus need fzf: winget install junegunn.fzf (then open a new terminal).'; exit 1 }

# Commands that work on the Context folder need setup first (the menu runs setup itself)
if (-not (Test-Configured) -and ($Command -in 'push', 'import', 'open', 'search', 'summary', 'cleanup', 'memory' -or $PluginCommands.Contains($Command))) {
    if ($Command -eq 'olive' -and $params -and $params[0] -eq 'hook') { exit 0 }     # hooks stay silent
    Write-Warn "ClaudeContextManager isn't set up yet. Run: ClaudeContextManager setup"
    exit 1
}

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
    'plugins' { Show-PluginsMenu }
    'search' { Show-Search (Get-Config) (Get-FlagValue $flags 'project') ($params -join ' ') }
    'memory' { Show-MemoryMenu (Get-Config) }
    'summary' {
        $config = Get-Config
        $targets = if ('--all' -in $flags) { @((Get-ProjectStats $config).Keys | Where-Object { $_ -notin $Unsorted, $Global }) } else { @($params -join ' ') | Where-Object { $_ } }
        if (-not $targets) { Write-Warn 'Usage: ClaudeContextManager summary <project>   (or --all)'; exit 1 }
        foreach ($p in $targets) {
            Write-Info "Summarizing $p..."
            try { Update-ProjectSummary $config $p; Write-Ok "Updated $p\SUMMARY.md" } catch { Write-Warn "$_" }
        }
    }
    'cleanup' {
        $config = Get-Config
        $targets = if ($params) { @($params) } else { Select-Projects $config 'Clean up which projects?' }
        Invoke-CleanupWizard $config $targets
    }
    'plugin' {
        $config = Get-Config
        $action = if ($params.Count) { $params[0] } else { 'list' }
        $name = if ($params.Count -gt 1) { $params[1] } else { '' }
        switch ($action) {
            'install' {
                if (-not $name) { Write-Warn 'Usage: ClaudeContextManager plugin install <name>'; exit 1 }
                Install-PluginNow $config $name
            }
            'update' {
                foreach ($p in Get-InstalledPlugins) { if (-not $name -or $p.Name -eq $name) { Install-PluginNow $config $p.Name } }
            }
            { $_ -in 'remove', 'uninstall' } {
                if (-not $name) { Write-Warn 'Usage: ClaudeContextManager plugin remove <name>'; exit 1 }
                Remove-PluginNow $config $name
            }
            'list' {
                $installed = Get-InstalledPlugins
                Write-Host "  ${green}Installed:$reset $(if ($installed) { ($installed | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', ' } else { 'none' })"
                try {
                    foreach ($p in Get-AvailablePlugins (Update-PluginCatalog $config)) { Write-Host ("  {0,-14} {1,-8} {2}" -f $p.Name, $p.Version, $p.Description) }
                    Write-Info 'Install one with: ClaudeContextManager plugin install <name>'
                } catch { Write-Warn "$_" }
            }
            default { Write-Warn 'Usage: ClaudeContextManager plugin install|update|remove|list [name]' }
        }
    }
    'uninstall' { Uninstall-Ccm }
    default {
        if ($PluginCommands.Contains($Command)) { & $PluginCommands[$Command].Action $params $flags; break }
        Get-Content $PSCommandPath | Select-Object -Skip 2 -First 15 | ForEach-Object { $_.TrimStart('#') }
        foreach ($c in $PluginCommands.Values) { Write-Host "   $($c.Usage)" }
    }
}
