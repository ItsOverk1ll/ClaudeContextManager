# Core features on top of the Context folder: Git activity, "where we left off" summaries, and cleanup.
# (Search is a menu in ccm.ps1.) Dot-sourced by ccm-lib.ps1.

#region Git activity

# Each project's git repos (from its folders): recent commits go to <Project>\GIT.md, and PROJECT.md counts the
# commits made during each session. Only re-read when a repo's HEAD changes.
function Get-ProjectRepos($projects, [string]$name) {
    @(@($projects[$name].paths) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ '.git')) } | Select-Object -Unique)
}

function Update-GitActivity($config, $index, $projects, [switch]$Force) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
    $state = Read-State $config 'git'
    $changed = [Collections.Generic.List[string]]::new()
    foreach ($name in @($projects.Keys)) {
        $dir = Join-Path $config.ContextDir (Get-SafeName $name)
        if (-not (Test-Path -LiteralPath $dir)) { continue }      # only projects that have context
        $repos = Get-ProjectRepos $projects $name
        if (-not $repos) { continue }
        $sig = ($repos | ForEach-Object { "$(& git -C $_ rev-parse HEAD 2>$null)" }) -join ','
        if (-not $Force -and $state.Contains($name) -and $state[$name].sig -eq $sig -and (Test-Path -LiteralPath (Join-Path $dir 'GIT.md'))) { continue }
        $commits = foreach ($repo in $repos) {
            $branch = "$(& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)"
            & git -C $repo log -n 150 --date=iso-strict "--pretty=format:%H%x1f%ad%x1f%an%x1f%s" 2>$null | ForEach-Object {
                $f = $_ -split [char]0x1f
                if ($f.Count -ge 4) {
                    [pscustomobject]@{ Repo = $repo; Branch = $branch; Hash = $f[0]; Time = (ConvertTo-DateTime $f[1]); Author = $f[2]; Subject = $f[3] }
                }
            }
        }
        $commits = @($commits | Where-Object Time | Sort-Object Time -Descending)
        $sb = [Text.StringBuilder]::new()
        [void]$sb.AppendLine("# Git activity: $name").AppendLine()
        foreach ($repo in $repos) {
            $rc = @($commits | Where-Object Repo -eq $repo)
            [void]$sb.AppendLine("**$repo** · branch ``$(@($rc)[0].Branch)`` · $($rc.Count) recent commits  ")
        }
        [void]$sb.AppendLine()
        foreach ($day in $commits | Group-Object { $_.Time.ToString('yyyy-MM-dd') }) {
            [void]$sb.AppendLine("## $($day.Name)").AppendLine()
            foreach ($c in $day.Group) {
                $repoTag = if ($repos.Count -gt 1) { " ($(Split-Path $c.Repo -Leaf))" } else { '' }
                [void]$sb.AppendLine("- $($c.Time.ToString('HH:mm')) ``$($c.Hash.Substring(0, 7))``$repoTag $($c.Subject -replace '\|', '/') · $($c.Author)")
            }
            [void]$sb.AppendLine()
        }
        $text = $sb.ToString()
        if ($config.Redact) { $text = Protect-Secrets $text }
        Set-Content -LiteralPath (Join-Path $dir 'GIT.md') -Value $text -Encoding utf8NoBOM -NoNewline
        $state[$name] = [ordered]@{ sig = $sig; commits = @($commits | ForEach-Object { [ordered]@{ t = $_.Time.ToString('yyyy-MM-dd HH:mm'); h = $_.Hash.Substring(0, 7); s = (Get-OneLine $_.Subject 90) } }) }
        $changed.Add($name)
    }
    Write-State $config 'git' $state
    $changed
}

# Commits made while a session was running (from its start until 15 minutes after its last message)
function Get-SessionCommits($gitState, [string]$project, $entry) {
    $g = $gitState[$project]
    if (-not $g -or -not $entry.started) { return @() }
    $from = [datetime]::ParseExact($entry.started, 'yyyy-MM-dd HH:mm', $null)
    $to = [datetime]::ParseExact($entry.updated, 'yyyy-MM-dd HH:mm', $null).AddMinutes(15)
    @(@($g.commits) | Where-Object { $t = [datetime]::ParseExact($_.t, 'yyyy-MM-dd HH:mm', $null); $t -ge $from -and $t -le $to })
}

#endregion

#region Summaries ("where we left off")

$script:SummarizerDir = Join-Path (Split-Path $ConfigFile -Parent) 'summarizer'

# Runs `claude -p` with no tools, no saved session, no user settings (so no hooks fire) and no MCP servers,
# from an empty folder, so a summary never shows up as a session of its own.
function Invoke-ClaudeHeadless([string]$prompt, [string]$stdin, [string]$model, [int]$timeoutSec = 240) {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { throw 'The claude command was not found.' }
    New-Item -ItemType Directory -Force $SummarizerDir | Out-Null
    $psi = [Diagnostics.ProcessStartInfo]::new($claude.Source)
    foreach ($a in '-p', '--no-session-persistence', '--tools', '', '--setting-sources', 'local', '--strict-mcp-config', '--model', $model, $prompt) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $SummarizerDir
    $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($k in @($psi.Environment.Keys | Where-Object { $_ -like 'CLAUDE*' })) { [void]$psi.Environment.Remove($k) }
    $psi.Environment['CCM_SUMMARIZING'] = '1'
    $proc = [Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Write($stdin)
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit($timeoutSec * 1000)) { $proc.Kill($true); throw "claude didn't answer within $timeoutSec seconds." }
    if ($proc.ExitCode -ne 0) { throw "claude failed: $($err.Result.Trim())" }
    $out.Result.Trim()
}

function Update-ProjectSummary($config, [string]$project) {
    $dir = Join-Path $config.ContextDir (Get-SafeName $project)
    $context = Get-AgentContext $config $project @('claude') -RecentSessions 6 -MaxChars 60000 -Exclude 'SUMMARY.md'
    if (-not $context.Trim()) { throw "No Claude context in $project to summarize." }
    $prompt = "On stdin is everything the user's Claude sessions recorded about the project `"$project`" (instruction files, memory, git activity, a list of sessions and digests of the latest ones). " +
        "Write a short 'where we left off' note so the next session can pick up quickly. Markdown, these sections only: " +
        "'## Where we left off' (2-4 sentences on the latest state), '## Open threads' (bullets: unfinished work, open questions, anything waiting on the user), " +
        "'## Next steps' (bullets), '## Key facts' (bullets: decisions, gotchas, paths and commands worth remembering). " +
        "Be specific and use names and paths from the context; only state what it supports; newest information wins over older. No preamble."
    $summary = Invoke-ClaudeHeadless $prompt $context $config.SummaryModel
    if ($config.Redact) { $summary = Protect-Secrets $summary }
    $index = Read-State $config 'index'
    $claudeSessions = @($index.Values | Where-Object { $_.project -eq $project -and $_.kind -ne 'memory' -and (-not $_.agent -or $_.agent -eq 'claude') })
    $latest = @($claudeSessions.updated | Sort-Object)[-1]
    $text = "# Where we left off: $project`n`n_Written by Claude ($($config.SummaryModel)) from $($claudeSessions.Count) session(s), latest $latest. Updated $((Get-Date).ToString('yyyy-MM-dd HH:mm'))._`n`n$summary`n"
    Set-Content -LiteralPath (Join-Path $dir 'SUMMARY.md') -Value $text -Encoding utf8NoBOM -NoNewline
    $state = Read-State $config 'summaries'
    $state[$project] = [ordered]@{ written = (Get-Date).ToString('yyyy-MM-dd HH:mm'); latestSession = $latest }
    Write-State $config 'summaries' $state
    Invoke-WithLock $config { Write-ProjectIndex $project (Read-State $config 'index') (Read-State $config 'projects') $config } | Out-Null
}

# After a sync: refresh summaries of projects with new Claude sessions (if Summaries = auto), at most every
# SummaryMinHours per project
function Update-Summaries($config, [string[]]$projects, [switch]$Quiet) {
    if ($config.Summaries -ne 'auto' -or $env:CCM_SUMMARIZING -or -not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    $index = Read-State $config 'index'
    $state = Read-State $config 'summaries'
    foreach ($p in $projects | Where-Object { $_ -and $_ -notin $Unsorted, $Global } | Select-Object -Unique) {
        $latest = @($index.Values | Where-Object { $_.project -eq $p -and $_.kind -ne 'memory' -and (-not $_.agent -or $_.agent -eq 'claude') } | ForEach-Object updated | Sort-Object)[-1]
        if (-not $latest) { continue }
        $s = $state[$p]
        if ($s) {
            if ($s.latestSession -ge $latest) { continue }
            if (((Get-Date) - [datetime]::ParseExact($s.written, 'yyyy-MM-dd HH:mm', $null)).TotalHours -lt $config.SummaryMinHours) { continue }
        }
        try { Update-ProjectSummary $config $p; if (-not $Quiet) { Write-Ok "Summary updated: $p" } }
        catch { if (-not $Quiet) { Write-Warn "Summary for ${p}: $_" } }
    }
}

#endregion

#region Cleanup

$script:ArchiveDir = Join-Path $env:LOCALAPPDATA 'ClaudeContextManager\archive'

# What a cleanup would do for these projects. Options: OlderThanDays (0 = keep all), Tiny, Compact
function Get-CleanupPlan($config, [string[]]$projects, [hashtable]$options) {
    $index = Read-State $config 'index'
    $cutoff = if ($options.OlderThanDays -gt 0) { (Get-Date).AddDays(-$options.OlderThanDays).ToString('yyyy-MM-dd HH:mm') } else { $null }
    $remove = [Collections.Generic.List[object]]::new()
    $compact = [Collections.Generic.List[object]]::new()
    foreach ($kv in $index.GetEnumerator()) {
        $e = $kv.Value
        if ($e.project -notin $projects -or $e.kind -eq 'memory') { continue }
        $file = Join-Path $config.ContextDir $e.file
        $size = if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).Length } else { 0 }
        $item = [pscustomobject]@{ Id = $kv.Key; Entry = $e; File = $file; Size = $size
            Reason = $(if ($cutoff -and $e.updated -lt $cutoff) { "older than $($options.OlderThanDays) days" } elseif ($options.Tiny -and [int]$e.prompts -le 1) { 'tiny (1 prompt or less)' }) }
        if ($item.Reason) { $remove.Add($item) } elseif ($options.Compact -and -not $e.compact -and $size -gt 0) { $compact.Add($item) }
    }
    [pscustomobject]@{ Remove = $remove; Compact = $compact; RemoveBytes = ($remove | Measure-Object Size -Sum).Sum ?? 0 }
}

# Drops the one-line tool-call summaries from a transcript, keeping prompts and replies
function Get-CompactTranscript([string]$text) { $text -replace '(?m)^- \*[^*\r\n]+\*( `[^\r\n]*`)?\r?\n', '' }

function Invoke-Cleanup($config, [string[]]$projects, [hashtable]$options) {
    $plan = Get-CleanupPlan $config $projects $options
    $archive = $null
    $result = Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $ignored = Read-State $config 'ignored'
        $projectRules = Read-State $config 'projects'
        if ($plan.Remove.Count -and $options.Archive) {
            New-Item -ItemType Directory -Force $ArchiveDir | Out-Null
            $script:lastArchive = Join-Path $ArchiveDir "cleanup-$((Get-Date).ToString('yyyyMMdd-HHmmss')).zip"
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::Open($lastArchive, 'Create')
            try {
                foreach ($r in $plan.Remove) {
                    if (Test-Path -LiteralPath $r.File) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $r.File, ($r.Entry.file -replace '\\', '/')) }
                }
            } finally { $zip.Dispose() }
        }
        foreach ($r in $plan.Remove) {
            Remove-Item -LiteralPath $r.File -ErrorAction SilentlyContinue
            $index.Remove($r.Id)
            $ignored[$r.Id] = "$($r.Entry.title) (cleaned up $((Get-Date).ToString('yyyy-MM-dd')): $($r.Reason))"
        }
        $saved = 0
        foreach ($c in $plan.Compact) {
            $before = Get-Content -LiteralPath $c.File -Raw
            $after = Get-CompactTranscript $before
            Set-Content -LiteralPath $c.File -Value $after -Encoding utf8NoBOM -NoNewline
            $saved += [Text.Encoding]::UTF8.GetByteCount($before) - [Text.Encoding]::UTF8.GetByteCount($after)
            $index[$c.Id].compact = $true      # later re-syncs keep it compact
        }
        Write-State $config 'index' $index
        Write-State $config 'ignored' $ignored
        foreach ($p in $projects) { Write-ProjectIndex $p $index $projectRules $config }
        Remove-EmptyProjects $config
        Write-ContextReadme $index $config
        [pscustomobject]@{ Removed = $plan.Remove.Count; RemovedBytes = $plan.RemoveBytes; Compacted = $plan.Compact.Count; CompactBytes = $saved; Archive = $(if ($plan.Remove.Count -and $options.Archive) { $lastArchive }) }
    }
    if ($null -eq $result) { throw 'A sync is running; try again in a moment.' }
    $result
}

function Format-Bytes([long]$n) {
    if ($n -ge 1MB) { '{0:N1} MB' -f ($n / 1MB) } elseif ($n -ge 1KB) { '{0:N0} KB' -f ($n / 1KB) } else { "$n B" }
}

#endregion
