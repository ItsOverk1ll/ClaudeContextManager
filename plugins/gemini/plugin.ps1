# Gemini plugin for ClaudeContextManager: adds Google Gemini CLI sessions and GEMINI.md files to the Context
# folder, sorted into the same projects as your other context but kept in each project's gemini\ subfolder.
#
# Reads (GEMINI_CLI_HOME\.gemini, default ~/.gemini):
#   tmp\<project>\chats\session-*.jsonl   one session per file (older versions: session-*.json)
#   tmp\<project>\.project_root           the project folder the sessions ran in
#   GEMINI.md                             global instructions
# A .jsonl session is a log of records: metadata ({sessionId, projectHash, startTime, summary, directories...}),
# messages ({id, timestamp, type: user|gemini|info|error|warning, content, displayContent, toolCalls}),
# and edits: {$set: {...}} (metadata), {$patch: {...}} (update/remove messages), {$rewindTo: id} (drop id and after).

$script:GeminiHome = if ($env:GEMINI_CLI_HOME) { Join-Path $env:GEMINI_CLI_HOME '.gemini' } else { Join-Path $HOME '.gemini' }

function Get-GeminiSessionSources {
    $tmp = Join-Path $GeminiHome 'tmp'
    if (-not (Test-Path $tmp)) { return }
    foreach ($proj in Get-ChildItem $tmp -Directory) {
        $chats = Join-Path $proj.FullName 'chats'
        if (-not (Test-Path $chats)) { continue }
        # only files directly in chats\ (subagent sessions live in subfolders)
        Get-ChildItem $chats -File | Where-Object { $_.Name -like 'session-*.json*' -and $_.Length -gt 0 } | ForEach-Object {
            [pscustomobject]@{ Id = "gemini:$($_.BaseName)"; Kind = 'session'; Path = $_.FullName; Mtime = $_.LastWriteTimeUtc.Ticks; Size = $_.Length
                ProjectDir = $proj.FullName }
        }
    }
}

function Get-GeminiText($content) {
    if ($null -eq $content) { return '' }
    if ($content -is [string]) { return $content }
    (@($content) | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($_ -is [System.Collections.IDictionary] -and $_.text -and -not $_.thought) { $_.text }
    }) -join ''
}

# Replays a session file into @{ Meta; Messages (ordered id -> record) }
function Read-GeminiRecords([string]$path) {
    $meta = @{}
    $messages = [ordered]@{}
    if ($path -like '*.json') {
        $d = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($k in $d.Keys) { if ($k -ne 'messages') { $meta[$k] = $d[$k] } }
        foreach ($m in @($d.messages)) { if ($m.id) { $messages[$m.id] = $m } }
        return @{ Meta = $meta; Messages = $messages }
    }
    $applyPatch = {
        param($p)
        if (-not $p.id -or -not $messages.Contains($p.id)) { return }
        $m = $messages[$p.id]
        if ($p.Contains('content')) { $m.content = $p.content }
        foreach ($tp in @($p.toolCalls)) {
            if (-not $tp) { continue }
            $tc = @($m.toolCalls) | Where-Object { $_.id -eq $tp.id } | Select-Object -First 1
            if ($tc -and $tp.Contains('result')) { $tc.result = $tp.result }
        }
    }
    foreach ($line in [IO.File]::ReadLines($path)) {
        if (-not $line.Trim()) { continue }
        try { $r = $line | ConvertFrom-Json -AsHashtable -Depth 100 } catch { continue }
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        if ($r.Contains('$rewindTo')) {
            $found = $false
            foreach ($id in @($messages.Keys)) { if ($id -eq $r['$rewindTo']) { $found = $true }; if ($found) { $messages.Remove($id) } }
            if (-not $found) { $messages.Clear() }
        } elseif ($r.Contains('$patch')) {
            $p = $r['$patch']
            if ($p.id) { & $applyPatch $p }
            foreach ($u in @($p.updates)) { if ($u) { & $applyPatch $u } }
            foreach ($rid in @($p.removeIds)) { if ($rid -is [string]) { $messages.Remove($rid) } }
        } elseif ($r.Contains('$set')) {
            $set = $r['$set']
            foreach ($k in $set.Keys) {
                if ($k -eq 'messages') { $messages.Clear(); foreach ($m in @($set.messages)) { if ($m.id) { $messages[$m.id] = $m } } }
                else { $meta[$k] = $set[$k] }
            }
        } elseif ($r.id -is [string]) {
            $messages[$r.id] = $r
        } elseif ($r.sessionId) {
            foreach ($k in $r.Keys) { if ($k -ne 'messages') { $meta[$k] = $r[$k] } }
            foreach ($m in @($r.messages)) { if ($m -and $m.id) { $messages[$m.id] = $m } }
        }
    }
    @{ Meta = $meta; Messages = $messages }
}

$script:GeminiWriteTools = 'write_file', 'replace', 'edit', 'write_todos'

function Get-GeminiToolSummary($call, $hits) {
    $a = $call.args
    if ($a -isnot [System.Collections.IDictionary]) { $a = @{} }
    foreach ($k in 'file_path', 'absolute_path', 'path', 'dir_path', 'directory') {
        if ($a[$k] -is [string] -and $a[$k]) { Add-PathHit $hits $a[$k] ($call.name -in $GeminiWriteTools ? 3 : 1) }
    }
    foreach ($p in @($a.paths)) { if ($p -is [string]) { Add-PathHit $hits $p 1 } }
    if ($a.command -is [string]) { foreach ($m in [regex]::Matches($a.command, $PathRegex)) { Add-PathHit $hits $m.Value 1 } }
    $detail = $a.command ?? $a.file_path ?? $a.absolute_path ?? $a.path ?? $a.dir_path ?? $a.pattern ?? $a.query ?? $a.url ?? $a.prompt ?? ''
    if ($detail -isnot [string]) { $detail = "$detail" }
    $name = if ($call.name) { $call.name } else { $call.displayName }
    $detail = Get-OneLine $detail 120
    if ($detail) { "- *$name* ``$($detail -replace '`', "'")``" } else { "- *$name*" }
}

function Read-GeminiSession($source) {
    $rec = Read-GeminiRecords $source.Path
    $meta = $rec.Meta
    if ($meta.kind -eq 'subagent') { return $null }
    $sessionId = if ($meta.sessionId) { "$($meta.sessionId)" } else { $source.Id -replace '^gemini:', '' }
    $rootFile = Join-Path $source.ProjectDir '.project_root'
    $cwd = if (Test-Path -LiteralPath $rootFile) { (Get-Content -LiteralPath $rootFile -Raw).Trim() } elseif ($meta.directories) { "$(@($meta.directories)[0])" } else { '' }
    $s = [ordered]@{ Id = $source.Id; Kind = 'session'; SourcePath = $source.Path; Title = ''; Cwd = $cwd; Branch = ''
        Source = 'Gemini CLI'; Folder = 'gemini'; AssistantName = 'Gemini'; ResumeHint = "gemini --resume $sessionId"
        ShortId = (($sessionId -replace '[^0-9a-zA-Z]', '') -replace '^.*(.{8})$', '$1')
        Started = (ConvertTo-DateTime $meta.startTime); Updated = (ConvertTo-DateTime $meta.lastUpdated)
        Turns = [Collections.Generic.List[object]]::new(); Hits = [Collections.Generic.List[object]]::new()
        UserText = [Text.StringBuilder]::new(); Prompts = 0 }
    $current = $null
    foreach ($m in $rec.Messages.Values) {
        $time = ConvertTo-DateTime $m.timestamp
        if ($time) { if (-not $s.Started -or $time -lt $s.Started) { $s.Started = $time }; if (-not $s.Updated -or $time -gt $s.Updated) { $s.Updated = $time } }
        if ($m.type -eq 'user') {
            # displayContent is what was typed; content can include expanded @file contents
            $text = (Get-GeminiText ($m.displayContent ?? $m.content)).Trim()
            if (-not $text) { continue }
            $s.Prompts++
            [void]$s.UserText.AppendLine($text)
            foreach ($x in [regex]::Matches($text, $PathRegex)) { Add-PathHit $s.Hits $x.Value 1 }
            $current = @{ Role = 'user'; Time = $time; Text = [Collections.Generic.List[string]]::new(); Tools = [Collections.Generic.List[string]]::new() }
            $current.Text.Add($text)
            $s.Turns.Add($current)
        } elseif ($m.type -eq 'gemini') {
            $text = (Get-GeminiText $m.content).Trim()
            $tools = @(foreach ($c in @($m.toolCalls)) { if ($c) { Get-GeminiToolSummary $c $s.Hits } })
            if (-not $text -and -not $tools) { continue }
            if (-not $current -or $current.Role -ne 'assistant') {
                $current = @{ Role = 'assistant'; Time = $time; Text = [Collections.Generic.List[string]]::new(); Tools = [Collections.Generic.List[string]]::new() }
                $s.Turns.Add($current)
            }
            if ($text) { $current.Text.Add($text) }
            foreach ($t in $tools) { $current.Tools.Add($t) }
        }
    }
    $first = $s.Turns | Where-Object Role -eq 'user' | Select-Object -First 1
    $s.Title = if ($meta.summary) { Get-OneLine "$($meta.summary)" 80 } elseif ($first) { Get-OneLine ($first.Text -join ' ') 60 } else { 'Untitled Gemini session' }
    if (-not $s.Started) { $s.Started = [datetime]::new($source.Mtime, 'Utc').ToLocalTime() }
    if (-not $s.Updated) { $s.Updated = $s.Started }
    if ($s.Cwd) { Add-PathHit $s.Hits $s.Cwd 4 }
    $s.UserText = $s.UserText.ToString()
    [pscustomobject]$s
}

# GEMINI.md is Gemini's CLAUDE.md: copy each project's into <Project>\gemini\, the global one into _Global\gemini\
function Copy-GeminiMds($projects, $config) {
    $copy = {
        param($file, $destDir)
        New-Item -ItemType Directory -Force $destDir | Out-Null
        $text = Get-Content -LiteralPath $file -Raw
        if ($config.Redact) { $text = Protect-Secrets $text }
        Set-Content -LiteralPath (Join-Path $destDir 'GEMINI.md') -Value $text -Encoding utf8NoBOM -NoNewline
    }
    $globalFile = Join-Path $GeminiHome 'GEMINI.md'
    if (Test-Path -LiteralPath $globalFile) { & $copy $globalFile (Join-Path $config.ContextDir "$Global\gemini") }
    foreach ($name in $projects.Keys) {
        foreach ($root in @($projects[$name].paths)) {
            if (-not $root) { continue }
            $file = Join-Path $root 'GEMINI.md'
            if (Test-Path -LiteralPath $file) { & $copy $file (Join-Path $config.ContextDir "$(Get-SafeName $name)\gemini") }
        }
    }
}

Register-ContextSource @{
    Name       = 'gemini'
    Label      = 'Gemini'
    Folder     = 'gemini'
    GetSources = { Get-GeminiSessionSources }
    Read       = { param($src, $cache) Read-GeminiSession $src }
    CopyDocs   = { param($projects, $config) Copy-GeminiMds $projects $config }
    Resume     = {
        param($id, $entry)
        if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) { throw 'The gemini command was not found (npm install -g @google/gemini-cli).' }
        $sid = if ($entry.sourcePath) { (Read-GeminiRecords $entry.sourcePath).Meta.sessionId }
        & gemini --resume $(if ($sid) { $sid } else { $id -replace '^gemini:', '' })
    }
}
