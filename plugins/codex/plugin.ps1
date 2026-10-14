# Codex plugin for ClaudeContextManager: adds OpenAI Codex CLI sessions and AGENTS.md files to the
# Context folder. They're sorted into the same projects as your Claude context (same folders and
# keywords), but kept separate in each project's codex\ subfolder and their own PROJECT.md table.
#
# Reads (CODEX_HOME, default ~/.codex):
#   sessions\YYYY\MM\DD\rollout-*.jsonl, archived_sessions\   one JSONL rollout per session
#   session_index.jsonl                                       thread names (/rename)
#   AGENTS.md                                                 global instructions
# Rollout lines are {timestamp, type, payload}: session_meta (id, cwd, git), turn_context (cwd),
# response_item (message / function_call / custom_tool_call / local_shell_call / web_search_call...).
# Older rollouts put the meta fields on the first line and response items directly on later lines.

$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }

function Get-CodexThreadNames {
    $names = @{}
    $file = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path $file)) { return $names }
    foreach ($line in [IO.File]::ReadLines($file)) {
        try { $d = $line | ConvertFrom-Json -AsHashtable; if ($d.id -and $d.thread_name) { $names["$($d.id)"] = $d.thread_name } } catch {}
    }
    $names
}

function Get-CodexSessionSources {
    foreach ($sub in 'sessions', 'archived_sessions') {
        $dir = Join-Path $CodexHome $sub
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Recurse -File -Filter 'rollout-*.jsonl' | Where-Object Length -gt 0 | ForEach-Object {
            $id = if ($_.BaseName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { $Matches[1] } else { $_.BaseName }
            [pscustomobject]@{ Id = "codex:$id"; Kind = 'session'; Path = $_.FullName; Mtime = $_.LastWriteTimeUtc.Ticks; Size = $_.Length }
        }
    }
}

# Codex adds its own scaffolding as user messages (AGENTS.md, environment context); drop it
function Get-CodexPrompt([string]$text) {
    $t = $text -replace '(?s)<(environment_context|user_instructions|INSTRUCTIONS|turn_aborted|user_shell_command)>.*?</\1>', ''
    $t = $t -replace '(?m)^# AGENTS\.md instructions for .*$', ''
    $t.Trim()
}

function Get-CodexCommandText($command) {
    if ($command -is [string]) { return $command }
    $parts = @($command)
    # ["bash", "-lc", "<script>"] / ["powershell", "-Command", "<script>"] -> the script
    if ($parts.Count -ge 3 -and $parts[1] -in '-lc', '-c', '-Command', '/c') { return $parts[-1] }
    $parts -join ' '
}

function Add-CodexCommandHits($hits, [string]$command) {
    foreach ($m in [regex]::Matches($command, $PathRegex)) { Add-PathHit $hits $m.Value 1 }
}

# apply_patch input: "*** Update File: src/app.py" etc. Paths are relative to the session folder.
function Add-CodexPatchHits($hits, [string]$patch, [string]$cwd) {
    $files = foreach ($m in [regex]::Matches($patch, '(?m)^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$')) {
        $f = ($m.Groups[1].Value, $m.Groups[2].Value | Where-Object { $_ } | Select-Object -First 1).Trim()
        if (-not [IO.Path]::IsPathRooted($f) -and $cwd) { $f = Join-Path $cwd $f }
        Add-PathHit $hits $f 3
        $f
    }
    @($files)
}

function Get-CodexToolSummary($p, $hits, [string]$cwd) {
    $name = $p.name
    $detail = ''
    switch ($p.type) {
        'function_call' {
            $a = try { $p.arguments | ConvertFrom-Json -AsHashtable -Depth 50 } catch { @{} }
            if ($null -eq $a) { $a = @{} }
            if ($a.workdir) { Add-PathHit $hits $a.workdir 1 }
            if ($null -ne ($a.command ?? $a.cmd)) {
                $detail = Get-CodexCommandText ($a.command ?? $a.cmd)
                Add-CodexCommandHits $hits $detail
            } elseif ($a.input -is [string] -and $a.input -match '\*\*\* Begin Patch') {
                $detail = (Add-CodexPatchHits $hits $a.input ($a.workdir ?? $cwd)) -join ', '
            } else {
                foreach ($k in 'path', 'file_path') { if ($a[$k] -is [string]) { Add-PathHit $hits $a[$k] 1; $detail = $a[$k] } }
                if (-not $detail) { $detail = $a.query ?? $a.url ?? $a.description ?? '' }
            }
        }
        'custom_tool_call' {
            if ($p.input -match '\*\*\* Begin Patch') { $detail = (Add-CodexPatchHits $hits $p.input $cwd) -join ', ' }
            else { $detail = $p.input }
        }
        'local_shell_call' {
            $name = 'shell'
            if ($p.action.working_directory) { Add-PathHit $hits $p.action.working_directory 1 }
            $detail = Get-CodexCommandText $p.action.command
            Add-CodexCommandHits $hits $detail
        }
        'web_search_call' { $name = 'web_search'; $detail = $p.action.query ?? '' }
        default { return $null }
    }
    if ($detail -isnot [string]) { $detail = "$detail" }
    $detail = Get-OneLine $detail 120
    if ($detail) { "- *$name* ``$($detail -replace '`', "'")``" } else { "- *$name*" }
}

function Read-CodexSession($source, $names) {
    $codexId = $source.Id -replace '^codex:', ''
    $s = [ordered]@{ Id = $source.Id; Kind = 'session'; SourcePath = $source.Path; Title = ''; Cwd = ''; Branch = ''
        Source = 'Codex'; Folder = 'codex'; AssistantName = 'Codex'; ResumeHint = "codex resume $codexId"
        ShortId = ($codexId -replace '-', '')[-8..-1] -join ''   # Codex ids are time-based (UUIDv7): use the random end
        Started = $null; Updated = $null; Turns = [Collections.Generic.List[object]]::new()
        Hits = [Collections.Generic.List[object]]::new(); UserText = [Text.StringBuilder]::new(); Prompts = 0 }
    $cwd = ''
    $current = $null
    foreach ($line in [IO.File]::ReadLines($source.Path)) {
        if (-not $line) { continue }
        try { $d = $line | ConvertFrom-Json -AsHashtable -Depth 100 } catch { continue }
        $time = ConvertTo-DateTime $d.timestamp
        # new format wraps everything in {type, payload}; old format has bare items and a meta first line
        if ($d.Contains('payload')) { $kind = $d.type; $p = $d.payload }
        elseif ($d.type) { $kind = 'response_item'; $p = $d }
        else { $kind = 'session_meta'; $p = $d }
        if ($p -isnot [System.Collections.IDictionary]) { continue }
        switch ($kind) {
            'session_meta' {
                if ($p.cwd) { $cwd = "$($p.cwd)"; if (-not $s.Cwd) { $s.Cwd = $cwd } }
                if ($p.git -and $p.git.branch) { $s.Branch = $p.git.branch }
                if (-not $time) { $time = ConvertTo-DateTime $p.timestamp }
            }
            'turn_context' { if ($p.cwd) { $cwd = "$($p.cwd)"; if (-not $s.Cwd) { $s.Cwd = $cwd } } }
        }
        if ($time) { if (-not $s.Started) { $s.Started = $time }; $s.Updated = $time }
        if ($kind -ne 'response_item') { continue }

        $role = $null; $text = ''; $tool = $null
        if ($p.type -eq 'message') {
            if ($p.role -notin 'user', 'assistant') { continue }      # developer/system instructions
            $role = $p.role
            $text = (@($p.content) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.type -in 'input_text', 'output_text', 'text' } |
                ForEach-Object { $_.text }) -join "`n`n"
            if ($role -eq 'user') {
                $text = Get-CodexPrompt $text
                if (-not $text) { continue }
                $s.Prompts++
                [void]$s.UserText.AppendLine($text)
                Add-CodexCommandHits $s.Hits $text
            } else { $text = $text.Trim(); if (-not $text) { continue } }
        } else {
            $tool = Get-CodexToolSummary $p $s.Hits $cwd
            if (-not $tool) { continue }
            $role = 'assistant'
        }

        if ($current -and $current.Role -eq 'assistant' -and $role -eq 'assistant') {
            if ($text) { $current.Text.Add($text) }
            if ($tool) { $current.Tools.Add($tool) }
        } else {
            $current = @{ Role = $role; Time = $time; Text = [Collections.Generic.List[string]]::new(); Tools = [Collections.Generic.List[string]]::new() }
            if ($text) { $current.Text.Add($text) }
            if ($tool) { $current.Tools.Add($tool) }
            $s.Turns.Add($current)
        }
    }
    $first = $s.Turns | Where-Object Role -eq 'user' | Select-Object -First 1
    $s.Title = if ($names[$codexId]) { $names[$codexId] } elseif ($first) { Get-OneLine ($first.Text -join ' ') 60 } else { 'Untitled Codex session' }
    if (-not $s.Started) { $s.Started = [datetime]::new($source.Mtime, 'Utc').ToLocalTime(); $s.Updated = $s.Started }
    if ($s.Cwd) { Add-PathHit $s.Hits $s.Cwd 4 }
    $s.UserText = $s.UserText.ToString()
    [pscustomobject]$s
}

# AGENTS.md is Codex's CLAUDE.md: copy each project's into <Project>\codex\, the global one into _Global\codex\
function Copy-CodexAgentsMds($projects, $config) {
    $copy = {
        param($file, $destDir)
        New-Item -ItemType Directory -Force $destDir | Out-Null
        $text = Get-Content -LiteralPath $file -Raw
        if ($config.Redact) { $text = Protect-Secrets $text }
        Set-Content -LiteralPath (Join-Path $destDir (Split-Path $file -Leaf)) -Value $text -Encoding utf8NoBOM -NoNewline
    }
    foreach ($f in 'AGENTS.md', 'AGENTS.override.md') {
        $globalFile = Join-Path $CodexHome $f
        if (Test-Path -LiteralPath $globalFile) { & $copy $globalFile (Join-Path $config.ContextDir "$Global\codex") }
    }
    foreach ($name in $projects.Keys) {
        foreach ($root in @($projects[$name].paths)) {
            if (-not $root) { continue }
            foreach ($f in 'AGENTS.md', 'AGENTS.override.md') {
                $file = Join-Path $root $f
                if (Test-Path -LiteralPath $file) { & $copy $file (Join-Path $config.ContextDir "$(Get-SafeName $name)\codex") }
            }
        }
    }
}

Register-ContextSource @{
    Name       = 'codex'
    Label      = 'Codex'
    Folder     = 'codex'
    GetSources = { Get-CodexSessionSources }
    Read       = {
        param($src, $cache)
        if (-not $cache.Contains('Names')) { $cache.Names = Get-CodexThreadNames }
        Read-CodexSession $src $cache.Names
    }
    CopyDocs   = { param($projects, $config) Copy-CodexAgentsMds $projects $config }
    Resume     = {
        param($id, $entry)
        if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { throw 'The codex command was not found (npm install -g @openai/codex).' }
        & codex resume ($id -replace '^codex:', '')
    }
}
