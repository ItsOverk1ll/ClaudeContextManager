# ClaudeContextManager core: gathers context from Claude Code (CLI and the Claude Desktop Code tab),
# Claude memory files, CLAUDE.md files and claude.ai data exports, sorts it into per-project folders,
# and backs the Context folder up to a private GitHub repo.
#
# Context folder layout:
#   <Project>\PROJECT.md          generated overview (sessions, memory, sources)
#   <Project>\CLAUDE.md           copy of the project's CLAUDE.md
#   <Project>\memory\*.md         Claude memory files that belong to the project
#   <Project>\sessions\*.md       one Markdown transcript per session/conversation
#   .ccm\index.json               every item: id -> project, file, source, timestamps
#   .ccm\overrides.json           manual sorting (id -> project); always wins over auto-sort
#   .ccm\projects.json            project rules: name -> { paths, keywords }
#   .ccm\ignored.json             ids removed from the context, never re-imported
#   <Project>\<agent>\...         context from plugin sources (e.g. codex\sessions), kept apart from Claude's
#
# Context sources are pluggable: the built-in one reads Claude; plugins (see the Plugins branch) call
# Register-ContextSource to add other agents. Plugins live in %APPDATA%\ClaudeContextManager\plugins.

$ErrorActionPreference = 'Stop'
$script:AppDataDir = Join-Path $env:APPDATA 'ClaudeContextManager'
$script:ConfigFile = if ($env:CCM_CONFIG) { $env:CCM_CONFIG } else { Join-Path $AppDataDir 'config.json' }
$script:ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$script:DesktopDir = Join-Path $env:APPDATA 'Claude'
$script:Unsorted = 'Unsorted'
$script:Global = '_Global'
$script:CcmVersion = '1.1.0'
$script:PluginDir = Join-Path (Split-Path $ConfigFile -Parent) 'plugins'
$script:ContextSources = [ordered]@{}

# Adds a context source. Keys:
#   Name       short id, stored with every item (index 'agent')         e.g. 'codex'
#   Label      shown in menus and PROJECT.md                            e.g. 'Codex'
#   Folder     subfolder of each project for its files ('' = project root)
#   GetSources { -> objects with Id, Kind ('session'|'memory'), Path, Mtime, Size }
#   Read       { param($src, $cache) -> item (see Read-Session); $cache is a hashtable kept for one sync }
#   CopyDocs   { param($projects, $config) } optional: copy per-project docs (CLAUDE.md, AGENTS.md...)
#   Resume     { param($id, $entry) } optional: reopen a session (runs in the session's folder)
function Register-ContextSource([hashtable]$source) {
    if (-not $source.Name -or -not $source.GetSources -or -not $source.Read) { throw 'Register-ContextSource needs Name, GetSources and Read' }
    if (-not $source.Contains('Label')) { $source.Label = $source.Name }
    if (-not $source.Contains('Folder')) { $source.Folder = '' }
    $script:ContextSources[$source.Name] = $source
}

function Get-AgentLabel($entry) {
    $agent = if ($entry.agent) { $entry.agent } else { 'claude' }
    if ($ContextSources.Contains($agent)) { $ContextSources[$agent].Label } else { $agent }
}

#region Config and state

function Get-DefaultConfig {
    [ordered]@{
        ContextDir  = Join-Path $HOME 'Context'
        AutoSort    = $true
        Redact      = $true
        AutoPush    = $false
        Repo        = ''
        MinScore    = 4
        PluginRepo  = 'ItsOverk1ll/ClaudeContextManager'
        PluginBranch = 'Plugins'
        # Folders Claude Code gets launched from for any kind of task: a session's cwd here says nothing about its project
        GenericDirs = @($HOME, (Join-Path $HOME 'Claude'), (Join-Path $HOME '.local\bin'), [Environment]::GetFolderPath('Desktop'))
    }
}

function Get-Config {
    $config = Get-DefaultConfig
    if (Test-Path $ConfigFile) {
        $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in $saved.Keys) { $config[$k] = $saved[$k] }
    }
    $config
}

function Save-Config($config) {
    New-Item -ItemType Directory -Force (Split-Path $ConfigFile -Parent) | Out-Null
    $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigFile -Encoding utf8NoBOM
}

function Test-Configured { Test-Path $ConfigFile }

function Get-StateDir($config) { Join-Path $config.ContextDir '.ccm' }

function Read-State($config, $name) {
    $file = Join-Path (Get-StateDir $config) "$name.json"
    if (Test-Path $file) {
        $raw = Get-Content $file -Raw
        if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json -AsHashtable -Depth 100) }
    }
    [ordered]@{}
}

function Write-State($config, $name, $data) {
    $dir = Get-StateDir $config
    New-Item -ItemType Directory -Force $dir | Out-Null
    # Sorted keys keep the git diffs of the Context repo small
    $sorted = [ordered]@{}
    foreach ($k in ($data.Keys | Sort-Object)) { $sorted[$k] = $data[$k] }
    $sorted | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $dir "$name.json") -Encoding utf8NoBOM
}

#endregion

#region Text helpers

$script:SecretPatterns = @(
    'sk-ant-[A-Za-z0-9_\-]{20,}', 'sk-[A-Za-z0-9]{32,}', 'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{40,}',
    'AKIA[0-9A-Z]{16}', 'xox[abprs]-[A-Za-z0-9\-]{10,}', 'AIza[0-9A-Za-z_\-]{35}', 'eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    '(?i)(?<=(password|passwd|secret|api[_-]?key|token)\s*[=:]\s*["'']?)[^\s"'',;]{6,}'
)

function Protect-Secrets([string]$text) {
    foreach ($p in $SecretPatterns) { $text = [regex]::Replace($text, $p, '[REDACTED]') }
    $text
}

function Get-Slug([string]$text, [int]$max = 50) {
    $slug = ($text.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt $max) { $slug = $slug.Substring(0, $max).TrimEnd('-') }
    if ($slug) { $slug } else { 'untitled' }
}

function Get-SafeName([string]$name) { ($name -replace '[\\/:*?"<>|]', '-').Trim(' .') }

function Get-OneLine([string]$text, [int]$max = 80) {
    $line = ($text -replace '\s+', ' ').Trim()
    if ($line.Length -gt $max) { $line.Substring(0, $max - 1) + '…' } else { $line }
}

# Removes the scaffolding Claude Code wraps around prompts (system reminders, slash-command markup)
function Get-CleanPrompt([string]$text) {
    $text = $text -replace '(?s)<system-reminder>.*?</system-reminder>', ''
    $text = $text -replace '(?s)<local-command-(stdout|stderr|caveat)>.*?</local-command-\1>', ''
    if ($text -match '<command-name>(.*?)</command-name>') {
        $cmd = $Matches[1]
        $args_ = if ($text -match '(?s)<command-args>(.*?)</command-args>') { $Matches[1].Trim() } else { '' }
        $text = "$cmd $args_".Trim()
    }
    $text.Trim()
}

function ConvertTo-DateTime($value) {
    if ($null -eq $value -or $value -eq '') { return $null }
    if ($value -is [datetime]) { return $value.ToLocalTime() }
    if ($value -is [long] -or $value -is [int] -or "$value" -match '^\d{12,}$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$value).LocalDateTime
    }
    try { ([datetimeoffset]::Parse("$value", [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { $null }
}

#endregion

#region Sources

# Claude Desktop's Code tab keeps its own session metadata (title, cwd) next to the CLI transcript it drives
function Get-DesktopSessionInfo {
    $map = @{}
    foreach ($dirName in 'claude-code-sessions', 'local-agent-mode-sessions') {
        $dir = Join-Path $DesktopDir $dirName
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Recurse -Filter 'local_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $d = Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable
                if ($d.cliSessionId) { $map[$d.cliSessionId] = @{ Title = $d.title; Cwd = $d.originCwd ?? $d.cwd } }
            } catch {}
        }
    }
    $map
}

function Get-SessionSources {
    $projects = Join-Path $ClaudeDir 'projects'
    if (-not (Test-Path $projects)) { return }
    Get-ChildItem $projects -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Filter *.jsonl -File | Where-Object Length -gt 0 | ForEach-Object {
            [pscustomobject]@{ Id = $_.BaseName; Kind = 'session'; Path = $_.FullName; Mtime = $_.LastWriteTimeUtc.Ticks; Size = $_.Length }
        }
    }
}

function Get-MemorySources {
    $projects = Join-Path $ClaudeDir 'projects'
    if (-not (Test-Path $projects)) { return }
    Get-ChildItem $projects -Directory | ForEach-Object {
        $mem = Join-Path $_.FullName 'memory'
        if (Test-Path $mem) {
            Get-ChildItem $mem -Filter *.md -File | Where-Object Name -ne 'MEMORY.md' | ForEach-Object {
                [pscustomobject]@{ Id = "memory:$($_.Directory.Parent.Name)/$($_.BaseName)"; Kind = 'memory'; Path = $_.FullName
                    Mtime = $_.LastWriteTimeUtc.Ticks; Size = $_.Length }
            }
        }
    }
}

#endregion

#region Parsing

$script:PathRegex = '(?i)(?:(?<![\w/.:])[a-z]:[\\/]|(?<![\w/.:~-])/[a-z]/|(?<![\w/])~[\\/])[^\s"''`|;<>*?\r\n(){}\[\],]+'

function Add-PathHit($hits, [string]$path, [int]$weight) {
    if (-not $path) { return }
    $hits.Add([pscustomobject]@{ Path = $path; Weight = $weight })
}

function Get-ToolSummary($block, $hits) {
    $name = $block.name
    $in = $block.input
    if ($null -eq $in) { $in = @{} }
    $writeTools = 'Edit', 'Write', 'MultiEdit', 'NotebookEdit'
    foreach ($key in 'file_path', 'notebook_path', 'path') {
        if ($in[$key] -is [string]) { Add-PathHit $hits $in[$key] ($name -in $writeTools ? 3 : 1) }
    }
    $detail = $in.file_path ?? $in.notebook_path ?? $in.command ?? $in.pattern ?? $in.url ?? $in.query ?? $in.description ?? $in.prompt ?? $in.skill ?? ''
    if ($in.command -is [string]) {
        foreach ($m in [regex]::Matches($in.command, $PathRegex)) { Add-PathHit $hits $m.Value 1 }
    }
    if ($detail -isnot [string]) { $detail = '' }
    $detail = Get-OneLine $detail 120
    if ($detail) { "- *$name* ``$($detail -replace '`', "'")``" } else { "- *$name*" }
}

# Reads a Claude Code transcript (.jsonl) into a session object: metadata, condensed turns, path hits for sorting
function Read-Session($source, $desktopInfo) {
    $s = [ordered]@{ Id = $source.Id; Kind = 'session'; SourcePath = $source.Path; Title = ''; AiTitle = ''; CustomTitle = ''
        Cwd = ''; Branch = ''; Entry = ''; Started = $null; Updated = $null; Turns = [Collections.Generic.List[object]]::new()
        Hits = [Collections.Generic.List[object]]::new(); UserText = [Text.StringBuilder]::new(); Prompts = 0 }
    $current = $null
    foreach ($line in [IO.File]::ReadLines($source.Path)) {
        if (-not $line) { continue }
        try { $d = $line | ConvertFrom-Json -AsHashtable -Depth 100 } catch { continue }
        switch ($d.type) {
            'custom-title' { $s.CustomTitle = $d.customTitle; continue }
            'ai-title' { $s.AiTitle = $d.aiTitle; continue }
            'summary' { if (-not $s.AiTitle) { $s.AiTitle = $d.summary }; continue }
        }
        if ($d.type -notin 'user', 'assistant') { continue }
        if ($d.isSidechain -or $d.isMeta -or $d.isCompactSummary) { continue }
        if (-not $s.Cwd -and $d.cwd) { $s.Cwd = $d.cwd }
        if (-not $s.Branch -and $d.gitBranch -and $d.gitBranch -ne 'HEAD') { $s.Branch = $d.gitBranch }
        if (-not $s.Entry -and $d.entrypoint) { $s.Entry = $d.entrypoint }
        $time = ConvertTo-DateTime $d.timestamp
        if ($time) { if (-not $s.Started) { $s.Started = $time }; $s.Updated = $time }

        $content = $d.message.content
        $texts = [Collections.Generic.List[string]]::new()
        $tools = [Collections.Generic.List[string]]::new()
        if ($content -is [string]) { $texts.Add($content) }
        else {
            foreach ($block in @($content)) {
                if ($block -isnot [System.Collections.IDictionary]) { continue }
                switch ($block.type) {
                    'text' { $texts.Add($block.text) }
                    'tool_use' { $tools.Add((Get-ToolSummary $block $s.Hits)) }
                }
            }
        }
        $text = ($texts -join "`n`n")
        if ($d.type -eq 'user') {
            $text = Get-CleanPrompt $text
            if (-not $text) { continue }          # tool results and pure scaffolding
            $s.Prompts++
            [void]$s.UserText.AppendLine($text)
            foreach ($m in [regex]::Matches($text, $PathRegex)) { Add-PathHit $s.Hits $m.Value 1 }
        } else { $text = $text.Trim() }
        if (-not $text -and $tools.Count -eq 0) { continue }

        # Claude Code writes one record per content block, so consecutive assistant records form one turn
        if ($current -and $current.Role -eq $d.type -and $d.type -eq 'assistant') {
            if ($text) { $current.Text.Add($text) }
            $current.Tools.AddRange($tools)
        } else {
            $current = @{ Role = $d.type; Time = $time; Text = [Collections.Generic.List[string]]::new(); Tools = $tools }
            if ($text) { $current.Text.Add($text) }
            $s.Turns.Add($current)
        }
    }
    $info = $desktopInfo[$source.Id]
    $s.Source = if ($info -or $s.Entry -eq 'claude-desktop') { 'Claude Desktop' } else { 'Claude Code CLI' }
    if ($info -and $info.Cwd) { $s.Cwd = $info.Cwd }
    $firstPrompt = ($s.Turns | Where-Object Role -eq 'user' | Select-Object -First 1)
    $s.Title = $s.CustomTitle, $s.AiTitle, $info.Title | Where-Object { $_ } | Select-Object -First 1
    if (-not $s.Title) { $s.Title = if ($firstPrompt) { Get-OneLine ($firstPrompt.Text -join ' ') 60 } else { 'Untitled session' } }
    if (-not $s.Started) { $s.Started = [datetime]::new($source.Mtime, 'Utc').ToLocalTime(); $s.Updated = $s.Started }
    if ($s.Cwd) { Add-PathHit $s.Hits $s.Cwd 4 }
    [pscustomobject]$s
}

function Read-Memory($source) {
    $raw = Get-Content $source.Path -Raw
    $title = if ($raw -match '(?m)^name:\s*(.+)$') { $Matches[1].Trim().Trim('"') } else { [IO.Path]::GetFileNameWithoutExtension($source.Path) }
    $hits = [Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($raw, $PathRegex)) { Add-PathHit $hits $m.Value 2 }
    $file = Get-Item $source.Path
    [pscustomobject]@{ Id = $source.Id; Kind = 'memory'; SourcePath = $source.Path; Title = $title; Raw = $raw; Hits = $hits
        UserText = $raw; Cwd = ''; Source = 'Claude memory'; Started = $file.CreationTime; Updated = $file.LastWriteTime; Prompts = 0 }
}

#endregion

#region Sorting

$script:RootCache = @{}
$script:ContainerDirs = 'Documents', 'Desktop', 'Development', 'Projects', 'Code', 'Dev', 'Repos', 'Source', 'src', 'Git', 'GitHub', 'Work', 'OneDrive'
$script:SkipHomeDirs = 'AppData', 'Downloads', 'Pictures', 'Music', 'Videos', 'Contacts', 'Favorites', 'Links', 'Saved Games', 'Searches',
    'Templates', 'Start Menu', 'Recent', 'SendTo', 'NetHood', 'PrintHood', 'Cookies', 'Local Settings', 'Application Data', 'My Documents', 'Context'

function ConvertTo-WindowsPath([string]$path) {
    $p = $path.Trim().TrimEnd('.', ':', '\', '/')
    if ($p -match '^~[\\/]') { $p = Join-Path $HOME $p.Substring(2) }
    elseif ($p -match '^/([a-zA-Z])/(.*)$') { $p = "$($Matches[1].ToUpper()):\$($Matches[2])" }
    $p = $p -replace '[\\/]+', '\'      # transcripts often hold JSON-escaped paths (C:\\Users)
    if ($p -match '^[a-z]:') { $p = $p.Substring(0, 1).ToUpper() + $p.Substring(1) }
    $p
}

# Which project folder does a path belong to? Git repo root first, otherwise the first folder under the
# user's home (or under a container folder like Documents). Cached, because sessions repeat paths a lot.
function Get-ProjectRoot([string]$path, $config) {
    $p = ConvertTo-WindowsPath $path
    if ($RootCache.ContainsKey($p)) { return $RootCache[$p] }
    $root = $null
    $home_ = $HOME.TrimEnd('\')
    $isUnderHome = $p.StartsWith("$home_\", [StringComparison]::OrdinalIgnoreCase)
    $ctx = $config.ContextDir.TrimEnd('\')
    $inContext = $p.StartsWith("$ctx\", [StringComparison]::OrdinalIgnoreCase) -or $p -eq $ctx
    $systemDir = $p -match '(?i)\\(AppData|\.claude|\.codex|Temp|Windows|Program Files( \(x86\))?|ProgramData)(\\|$)'
    $skip = $inContext -or $systemDir -or $p -notmatch '^[A-Za-z]:\\'
    if (-not $skip) {
        # nearest .git above the path
        $dir = $p
        for ($i = 0; $i -lt 12 -and $dir; $i++) {
            if ($dir.TrimEnd('\') -ieq $home_) { break }
            if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $root = $dir; break }
            $parent = Split-Path $dir -Parent
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
        if (-not $root -and $isUnderHome) {
            $parts = $p.Substring($home_.Length + 1) -split '\\'
            $candidate = $null
            if ($parts.Count -ge 4 -and $parts[0] -eq 'source' -and $parts[1] -eq 'repos') { $candidate = Join-Path $home_ "source\repos\$($parts[2])" }
            elseif ($parts.Count -ge 3 -and $parts[0] -in $ContainerDirs) { $candidate = Join-Path $home_ "$($parts[0])\$($parts[1])" }
            elseif ($parts.Count -ge 2 -and $parts[0] -notin $SkipHomeDirs -and $parts[0] -notin $ContainerDirs -and -not $parts[0].StartsWith('.')) {
                $candidate = Join-Path $home_ $parts[0]
            }
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { $root = $candidate }
        }
        if ($root -and ($config.GenericDirs | Where-Object { $_ -and $_.TrimEnd('\') -ieq $root.TrimEnd('\') })) { $root = $null }
    }
    $RootCache[$p] = $root
    $root
}

function Find-ProjectByPath($projects, [string]$root) {
    foreach ($name in $projects.Keys) {
        foreach ($pp in @($projects[$name].paths)) { if ($pp -and $pp.TrimEnd('\') -ieq $root.TrimEnd('\')) { return $name } }
    }
    $null
}

function Get-TermRegex([string]$term) { '(?i)(?<![\w-])' + [regex]::Escape($term) + '(?![\w-])' }

# Scores every project for an item and returns the winner (or Unsorted). New project roots found in the
# item's paths are added to $projects as discovered projects.
function Get-AutoProject($item, $projects, $config) {
    $scores = @{}
    $seen = @{}
    foreach ($hit in $item.Hits) {
        $root = Get-ProjectRoot $hit.Path $config
        if (-not $root) { continue }
        $name = Find-ProjectByPath $projects $root
        if (-not $name) {
            $name = Get-SafeName (Split-Path $root -Leaf)
            if ($projects.Contains($name)) { $name = "$name ($(Split-Path (Split-Path $root -Parent) -Leaf))" }
            $projects[$name] = [ordered]@{ paths = @($root); keywords = @(); discovered = $true }
        }
        # the same file read 40 times shouldn't outweigh everything else
        $key = "$name|$($hit.Path)"
        $seen[$key] = ($seen[$key] ?? 0) + 1
        if ($seen[$key] -le 3) { $scores[$name] = ($scores[$name] ?? 0) + $hit.Weight }
    }
    $text = "$($item.Title)`n$($item.UserText)"
    foreach ($name in @($projects.Keys)) {
        $terms = @($name) + @($projects[$name].keywords) | Where-Object { $_ -and $_.Length -ge 3 }
        $n = 0
        foreach ($t in $terms) { $n += [regex]::Matches($text, (Get-TermRegex $t)).Count }
        if ($n) { $scores[$name] = ($scores[$name] ?? 0) + [Math]::Min($n * 2, 12) }
        if ($item.Title -and ($terms | Where-Object { $item.Title -match (Get-TermRegex $_) })) { $scores[$name] = ($scores[$name] ?? 0) + 3 }
    }
    $best = $scores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if ($best -and $best.Value -ge $config.MinScore) { $best.Key } else { $Unsorted }
}

#endregion

#region Rendering

function Format-Frontmatter($fields) {
    $lines = @('---')
    foreach ($k in $fields.Keys) {
        $v = $fields[$k]
        if ($null -eq $v -or $v -eq '') { continue }
        if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }
        $lines += "${k}: $(($v -replace '[\r\n]+', ' '))"
    }
    $lines += '---', ''
    $lines -join "`n"
}

function Format-Session($s, $project, $config) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append((Format-Frontmatter ([ordered]@{ title = $s.Title; session = $s.Id; project = $project; source = $s.Source
        cwd = $s.Cwd; branch = $s.Branch; started = $s.Started; updated = $s.Updated; prompts = $s.Prompts })))
    [void]$sb.AppendLine("# $($s.Title)").AppendLine()
    $resume = if ($s.PSObject.Properties['ResumeHint']) { if ($s.ResumeHint) { " · resume: ``$($s.ResumeHint)``" } else { '' } }
        elseif ($s.Source -eq 'claude.ai') { '' } else { " · resume: ``claude --resume $($s.Id)``" }
    $assistant = if ($s.PSObject.Properties['AssistantName'] -and $s.AssistantName) { $s.AssistantName } else { 'Claude' }
    [void]$sb.AppendLine("> $($s.Source) · $($s.Started.ToString('yyyy-MM-dd HH:mm')) → $($s.Updated.ToString('yyyy-MM-dd HH:mm'))$resume").AppendLine()
    foreach ($t in $s.Turns) {
        $who = if ($t.Role -eq 'user') { 'You' } else { $assistant }
        $when = if ($t.Time) { " · $($t.Time.ToString('MM-dd HH:mm'))" } else { '' }
        [void]$sb.AppendLine("## $who$when").AppendLine()
        if ($t.Text.Count) { [void]$sb.AppendLine(($t.Text -join "`n`n")).AppendLine() }
        if ($t.Tools.Count) { [void]$sb.AppendLine(($t.Tools -join "`n")).AppendLine() }
    }
    $out = $sb.ToString()
    if ($config.Redact) { $out = Protect-Secrets $out }
    $out
}

function Get-ItemFileName($item) {
    $folder = if ($item.PSObject.Properties['Folder'] -and $item.Folder) { "$($item.Folder)\" } else { '' }
    $short = if ($item.PSObject.Properties['ShortId'] -and $item.ShortId) { $item.ShortId } else { $item.Id -replace '^[a-z]+:', '' }
    if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
    switch ($item.Kind) {
        'memory' { "${folder}memory\$(Split-Path $item.SourcePath -Leaf)" }
        default { "${folder}sessions\$($item.Started.ToString('yyyy-MM-dd'))_$(Get-Slug $item.Title)_$short.md" }
    }
}

function Write-ContextItem($item, $project, $config) {
    $rel = Join-Path (Get-SafeName $project) (Get-ItemFileName $item)
    $full = Join-Path $config.ContextDir $rel
    New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
    $content = if ($item.Kind -eq 'memory') { if ($config.Redact) { Protect-Secrets $item.Raw } else { $item.Raw } } else { Format-Session $item $project $config }
    Set-Content -LiteralPath $full -Value $content -Encoding utf8NoBOM -NoNewline
    $rel
}

# Copies each project's CLAUDE.md (and the global ~/.claude/CLAUDE.md) into the Context folder
function Copy-ClaudeMds($projects, $config) {
    $globalFile = Join-Path $ClaudeDir 'CLAUDE.md'
    if (Test-Path $globalFile) {
        New-Item -ItemType Directory -Force (Join-Path $config.ContextDir $Global) | Out-Null
        Copy-Item $globalFile (Join-Path $config.ContextDir "$Global\CLAUDE.md") -Force
    }
    foreach ($name in $projects.Keys) {
        foreach ($root in @($projects[$name].paths)) {
            if (-not $root) { continue }
            $src = (Join-Path $root 'CLAUDE.md'), (Join-Path $root '.claude\CLAUDE.md'), (Join-Path $root 'claude-context.md') |
                Where-Object { Test-Path -LiteralPath $_ }
            foreach ($f in $src) {
                $dest = Join-Path $config.ContextDir (Get-SafeName $name)
                New-Item -ItemType Directory -Force $dest | Out-Null
                $text = Get-Content -LiteralPath $f -Raw
                if ($config.Redact) { $text = Protect-Secrets $text }
                Set-Content -LiteralPath (Join-Path $dest (Split-Path $f -Leaf)) -Value $text -Encoding utf8NoBOM -NoNewline
            }
        }
    }
}

function Get-ProjectNames($config) {
    if (-not (Test-Path $config.ContextDir)) { return @() }
    @(Get-ChildItem $config.ContextDir -Directory | Where-Object { -not $_.Name.StartsWith('.') } | Select-Object -ExpandProperty Name)
}

# Files in a project folder that aren't indexed items: CLAUDE.md, codex\AGENTS.md, claude-ai-project\*...
function Get-ProjectDocs([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($dir.TrimEnd('\').Length + 1)
        if ($rel -ne 'PROJECT.md' -and $rel -notmatch '(^|\\)(sessions|memory)\\') {
            $_ | Add-Member -NotePropertyName RelPath -NotePropertyValue $rel -PassThru -Force
        }
    } | Sort-Object { $_.RelPath.Contains('\') }, RelPath
}

function Write-ProjectIndex($project, $index, $projects, $config) {
    $dir = Join-Path $config.ContextDir (Get-SafeName $project)
    if (-not (Test-Path $dir)) { return }
    $items = @($index.Values | Where-Object { $_.project -eq $project })
    $sessions = @($items | Where-Object kind -ne 'memory' | Sort-Object { $_.updated } -Descending)
    $memory = @($items | Where-Object kind -eq 'memory' | Sort-Object { $_.title })
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $project").AppendLine()
    $rule = $projects[$project]
    if ($rule -and @($rule.paths).Count) { [void]$sb.AppendLine("**Folders:** $((@($rule.paths) | ForEach-Object { '`' + $_ + '`' }) -join ', ')  ") }
    if ($rule -and @($rule.keywords).Count) { [void]$sb.AppendLine("**Keywords:** $(@($rule.keywords) -join ', ')  ") }
    $last = if ($sessions) { $sessions[0].updated } else { '-' }
    [void]$sb.AppendLine("**Sessions:** $($sessions.Count) · **Memory files:** $($memory.Count) · **Last activity:** $last").AppendLine()
    $docs = @(Get-ProjectDocs $dir)
    if ($docs) {
        [void]$sb.AppendLine('## Project docs').AppendLine()
        foreach ($d in $docs) { $link = $d.RelPath -replace '\\', '/'; [void]$sb.AppendLine("- [$link]($link)") }
        [void]$sb.AppendLine()
    }
    if ($memory) {
        [void]$sb.AppendLine('## Memory').AppendLine()
        foreach ($m in $memory) { [void]$sb.AppendLine("- [$($m.title)]($(($m.file.Substring($m.file.IndexOf('\') + 1)) -replace '\\', '/'))") }
        [void]$sb.AppendLine()
    }
    # one table per agent, Claude first: plugin context stays separate
    foreach ($group in $sessions | Group-Object { Get-AgentLabel $_ } | Sort-Object { $_.Name -ne 'Claude' }, Name) {
        $heading = if ($group.Name -eq 'Claude') { 'Sessions' } else { "$($group.Name) sessions" }
        [void]$sb.AppendLine("## $heading").AppendLine()
        [void]$sb.AppendLine('| Updated | Title | Source | Prompts |').AppendLine('|---|---|---|---|')
        foreach ($x in $group.Group) {
            # links are relative to PROJECT.md, which sits in the project folder
            $link = ($x.file.Substring($x.file.IndexOf('\') + 1)) -replace '\\', '/'
            [void]$sb.AppendLine("| $($x.updated) | [$($x.title -replace '\|', '/')]($link) | $($x.source) | $($x.prompts) |")
        }
        [void]$sb.AppendLine()
    }
    Set-Content (Join-Path $dir 'PROJECT.md') $sb.ToString() -Encoding utf8NoBOM -NoNewline
}

function Write-ContextReadme($index, $config) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Context').AppendLine()
    [void]$sb.AppendLine('Claude Code / Claude Desktop (and plugin agent) context, sorted by project by [ClaudeContextManager](https://github.com/ItsOverk1ll/ClaudeContextManager).').AppendLine()
    [void]$sb.AppendLine('| Project | Sessions | Memory | Last activity |').AppendLine('|---|---|---|---|')
    $groups = $index.Values | Group-Object project | Sort-Object { @($_.Group.updated | Sort-Object)[-1] } -Descending
    foreach ($g in $groups) {
        $s = @($g.Group | Where-Object kind -ne 'memory')
        $m = @($g.Group | Where-Object kind -eq 'memory')
        $last = @($g.Group.updated | Sort-Object)[-1]
        [void]$sb.AppendLine("| [$($g.Name)]($([uri]::EscapeDataString((Get-SafeName $g.Name)))/PROJECT.md) | $($s.Count) | $($m.Count) | $last |")
    }
    [void]$sb.AppendLine().AppendLine("_Last sync: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))_")
    Set-Content (Join-Path $config.ContextDir 'README.md') $sb.ToString() -Encoding utf8NoBOM -NoNewline
}

#endregion

#region Sync

function New-IndexEntry($item, $project, $rel, $source, [bool]$auto, [string]$agent = 'claude') {
    [ordered]@{ kind = $item.Kind; agent = $agent; project = $project; auto = $auto; file = $rel; title = $item.Title; source = $item.Source
        cwd = $item.Cwd; started = $item.Started.ToString('yyyy-MM-dd HH:mm'); updated = $item.Updated.ToString('yyyy-MM-dd HH:mm')
        prompts = $item.Prompts; sourcePath = $item.SourcePath; mtime = $source.Mtime; size = $source.Size }
}

function Invoke-WithLock($config, [scriptblock]$action) {
    $dir = Get-StateDir $config
    New-Item -ItemType Directory -Force $dir | Out-Null
    try { $lock = [IO.File]::Open((Join-Path $dir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { return $null }   # another sync is running
    try { & $action } finally { $lock.Dispose() }
}

# Places one parsed item: keeps manual sorting, re-sorts auto-sorted items, writes the file, updates the index.
function Save-ContextItem($item, $source, $index, $overrides, $projects, $config, [switch]$Resort, [string]$Agent = 'claude') {
    $old = $index[$item.Id]
    $auto = $true
    if ($overrides.Contains($item.Id)) { $project = $overrides[$item.Id]; $auto = $false }
    elseif ($old -and -not $old.auto) { $project = $old.project; $auto = $false }
    elseif ($old -and -not $config.AutoSort -and -not $Resort) { $project = $old.project; $auto = [bool]$old.auto }
    elseif ($config.AutoSort -or $Resort) { $project = Get-AutoProject $item $projects $config }
    else { $project = $Unsorted }
    $rel = Write-ContextItem $item $project $config
    if ($old -and $old.file -and $old.file -ne $rel) {
        Remove-Item -LiteralPath (Join-Path $config.ContextDir $old.file) -ErrorAction SilentlyContinue
    }
    $index[$item.Id] = New-IndexEntry $item $project $rel $source $auto $Agent
    @($project, $old.project) | Where-Object { $_ }
}

function Invoke-Sync($config, [switch]$Quiet, [switch]$Resort, [switch]$Push) {
    $result = Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $overrides = Read-State $config 'overrides'
        $projects = Read-State $config 'projects'
        $ignored = Read-State $config 'ignored'
        $touched = [Collections.Generic.HashSet[string]]::new()
        $count = 0
        foreach ($cs in $ContextSources.Values) {
            try { $sources = @(& $cs.GetSources) } catch { if (-not $Quiet) { Write-Warn "$($cs.Label): couldn't list sources: $_" }; continue }
            $cache = @{}
            $i = 0
            foreach ($src in $sources) {
                $i++
                if ($ignored.Contains($src.Id)) { continue }
                $old = $index[$src.Id]
                if (-not $Resort -and $old -and $old.mtime -eq $src.Mtime -and $old.size -eq $src.Size -and
                    (Test-Path -LiteralPath (Join-Path $config.ContextDir $old.file))) { continue }
                if (-not $Quiet) { Write-Progress -Activity "Syncing $($cs.Label) context" -Status (Split-Path $src.Path -Leaf) -PercentComplete (100 * $i / $sources.Count) }
                try {
                    $item = & $cs.Read $src $cache
                    if (-not $item -or ($item.Kind -ne 'memory' -and $item.Turns.Count -eq 0)) { continue }
                    if ($cs.Folder -and -not $item.PSObject.Properties['Folder']) { $item | Add-Member -NotePropertyName Folder -NotePropertyValue $cs.Folder }
                    foreach ($p in (Save-ContextItem $item $src $index $overrides $projects $config -Resort:$Resort -Agent $cs.Name)) { [void]$touched.Add($p) }
                    $count++
                } catch {
                    if (-not $Quiet) { Write-Warn "Skipped $($src.Path): $_" }
                }
            }
        }
        if ($Resort) {
            # claude.ai conversations aren't re-read from a source file; re-sort them from their saved Markdown
            foreach ($id in @($index.Keys | Where-Object { $_ -like 'web:*' })) {
                $e = $index[$id]
                if (-not $e.auto -or $overrides.Contains($id)) { continue }
                $full = Join-Path $config.ContextDir $e.file
                if (-not (Test-Path -LiteralPath $full)) { continue }
                $raw = Get-Content -LiteralPath $full -Raw
                $hits = [Collections.Generic.List[object]]::new()
                foreach ($m in [regex]::Matches($raw, $PathRegex)) { Add-PathHit $hits $m.Value 1 }
                $p = Get-AutoProject ([pscustomobject]@{ Title = $e.title; UserText = $raw; Hits = $hits }) $projects $config
                if ($p -ne $e.project) { [void]$touched.Add($e.project); [void]$touched.Add($p); Move-IndexedFile $index $id $p $config }
            }
        }
        if (-not $Quiet) { Write-Progress -Activity 'Syncing context' -Completed }
        foreach ($cs in $ContextSources.Values) {
            if (-not $cs.CopyDocs) { continue }
            try { & $cs.CopyDocs $projects $config } catch { if (-not $Quiet) { Write-Warn "$($cs.Label) docs: $_" } }
        }
        Write-State $config 'index' $index
        Write-State $config 'projects' $projects
        foreach ($p in $touched) { Write-ProjectIndex $p $index $projects $config }
        Remove-EmptyProjects $config
        Write-ContextReadme $index $config
        $count
    }
    if ($null -eq $result) { if (-not $Quiet) { Write-Warn 'Another sync is already running.' }; return 0 }
    if (-not $Quiet) { Write-Ok "Synced: $result new or updated item(s)." }
    if (($Push -or $config.AutoPush) -and $config.Repo) { Push-Context $config -Quiet:$Quiet }
    $result
}

function Remove-EmptyProjects($config) {
    foreach ($name in Get-ProjectNames $config) {
        $dir = Join-Path $config.ContextDir $name
        Get-ChildItem -LiteralPath $dir -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item
        $left = Get-ChildItem $dir -Force | Where-Object Name -ne 'PROJECT.md'
        if (-not $left) { Remove-Item $dir -Recurse -Force }
    }
}

#endregion

#region Manual sorting

# Moves an item's Markdown file to another project folder and fixes its frontmatter
function Move-IndexedFile($index, $id, $project, $config) {
    $e = $index[$id]
    $from = Join-Path $config.ContextDir $e.file
    $rel = Join-Path (Get-SafeName $project) ($e.file.Substring($e.file.IndexOf('\') + 1))
    $to = Join-Path $config.ContextDir $rel
    if ($from -ne $to -and (Test-Path -LiteralPath $from)) {
        New-Item -ItemType Directory -Force (Split-Path $to -Parent) | Out-Null
        $text = Get-Content -LiteralPath $from -Raw
        if ($e.kind -ne 'memory') { $text = $text -replace '(?m)^project: .*$', "project: $project" }
        Set-Content -LiteralPath $to -Value $text -Encoding utf8NoBOM -NoNewline
        Remove-Item -LiteralPath $from
    }
    $e.project = $project
    $e.file = $rel
}

function Move-ContextItem($config, $id, $project) {
    Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $overrides = Read-State $config 'overrides'
        $projects = Read-State $config 'projects'
        $old = $index[$id].project
        Move-IndexedFile $index $id $project $config
        $index[$id].auto = $false
        $overrides[$id] = $project
        if (-not $projects.Contains($project) -and $project -ne $Unsorted) { $projects[$project] = [ordered]@{ paths = @(); keywords = @() } }
        Write-State $config 'index' $index
        Write-State $config 'overrides' $overrides
        Write-State $config 'projects' $projects
        Write-ProjectIndex $old $index $projects $config
        Write-ProjectIndex $project $index $projects $config
        Remove-EmptyProjects $config
        Write-ContextReadme $index $config
    } | Out-Null
}

function Remove-ContextItem($config, $id) {
    Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $ignored = Read-State $config 'ignored'
        $projects = Read-State $config 'projects'
        $e = $index[$id]
        Remove-Item -LiteralPath (Join-Path $config.ContextDir $e.file) -ErrorAction SilentlyContinue
        $index.Remove($id)
        $ignored[$id] = $e.title
        Write-State $config 'index' $index
        Write-State $config 'ignored' $ignored
        Write-ProjectIndex $e.project $index $projects $config
        Remove-EmptyProjects $config
        Write-ContextReadme $index $config
    } | Out-Null
}

function New-ContextProject($config, $name, [string[]]$paths = @(), [string[]]$keywords = @()) {
    $projects = Read-State $config 'projects'
    $projects[$name] = [ordered]@{ paths = @($paths | Where-Object { $_ }); keywords = @($keywords | Where-Object { $_ }) }
    Write-State $config 'projects' $projects
    New-Item -ItemType Directory -Force (Join-Path $config.ContextDir (Get-SafeName $name)) | Out-Null
}

function Rename-ContextProject($config, $old, $new) {
    Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $overrides = Read-State $config 'overrides'
        $projects = Read-State $config 'projects'
        $from = Join-Path $config.ContextDir (Get-SafeName $old)
        $to = Join-Path $config.ContextDir (Get-SafeName $new)
        if (Test-Path $to) {
            # merge into the existing project
            foreach ($id in @($index.Keys | Where-Object { $index[$_].project -eq $old })) { Move-IndexedFile $index $id $new $config }
            foreach ($d in @(Get-ProjectDocs $from)) {
                $dest = Join-Path $to $d.RelPath
                New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
                Move-Item -LiteralPath $d.FullName $dest -Force
            }
            Remove-Item $from -Recurse -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path $from) { Rename-Item -LiteralPath $from (Split-Path $to -Leaf) }
        foreach ($id in @($index.Keys)) {
            $e = $index[$id]
            if ($e.project -ne $old) { continue }
            $e.project = $new
            $e.file = Join-Path (Get-SafeName $new) ($e.file.Substring($e.file.IndexOf('\') + 1))
            $f = Join-Path $config.ContextDir $e.file
            if ($e.kind -ne 'memory' -and (Test-Path -LiteralPath $f)) {
                $t = (Get-Content -LiteralPath $f -Raw) -replace '(?m)^project: .*$', "project: $new"
                Set-Content -LiteralPath $f -Value $t -Encoding utf8NoBOM -NoNewline
            }
        }
        foreach ($id in @($overrides.Keys)) { if ($overrides[$id] -eq $old) { $overrides[$id] = $new } }
        if ($projects.Contains($old)) {
            $rule = $projects[$old]; $projects.Remove($old)
            if ($projects.Contains($new)) {
                $projects[$new].paths = @(@($projects[$new].paths) + @($rule.paths) | Where-Object { $_ } | Select-Object -Unique)
                $projects[$new].keywords = @(@($projects[$new].keywords) + @($rule.keywords) | Where-Object { $_ } | Select-Object -Unique)
            } else { $rule.discovered = $false; $projects[$new] = $rule }
            # keep the old name as a keyword so sessions that mention it still land here
            if ($old -ne $Unsorted) { $projects[$new].keywords = @(@($projects[$new].keywords) + $old | Select-Object -Unique) }
        }
        Write-State $config 'index' $index
        Write-State $config 'overrides' $overrides
        Write-State $config 'projects' $projects
        Write-ProjectIndex $new $index $projects $config
        Write-ContextReadme $index $config
    } | Out-Null
}

#endregion

#region claude.ai / Claude Desktop chat export

function Get-ExportText($msg) {
    $parts = foreach ($c in @($msg.content)) { if ($c -is [System.Collections.IDictionary] -and $c.type -eq 'text' -and $c.text) { $c.text } }
    $text = ($parts -join "`n`n")
    if (-not $text) { $text = $msg.text }
    "$text".Trim()
}

# Imports a claude.ai data export (Settings > Privacy > Export data): the .zip or its extracted folder.
# Claude Desktop chats live on claude.ai, so this is how they get into the Context folder.
function Import-ClaudeExport($config, [string]$path) {
    $path = $path.Trim('"', ' ')
    $temp = $null
    if ($path -like '*.zip') {
        $temp = Join-Path ([IO.Path]::GetTempPath()) "ccm-export-$([guid]::NewGuid().ToString('N'))"
        Expand-Archive -LiteralPath $path -DestinationPath $temp
        $path = $temp
    }
    try {
        $convFile = Get-ChildItem $path -Recurse -Filter conversations.json | Select-Object -First 1
        if (-not $convFile) { throw "No conversations.json in $path" }
        $conversations = Get-Content $convFile.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $count = Invoke-WithLock $config {
            $index = Read-State $config 'index'
            $overrides = Read-State $config 'overrides'
            $projects = Read-State $config 'projects'
            $ignored = Read-State $config 'ignored'
            $touched = [Collections.Generic.HashSet[string]]::new()
            $n = 0
            foreach ($c in $conversations) {
                $id = "web:$($c.uuid)"
                if ($ignored.Contains($id)) { continue }
                $updated = ConvertTo-DateTime $c.updated_at
                $src = [pscustomobject]@{ Mtime = $updated.Ticks; Size = @($c.chat_messages).Count }
                $old = $index[$id]
                if ($old -and $old.mtime -eq $src.Mtime -and $old.size -eq $src.Size) { continue }
                $turns = [Collections.Generic.List[object]]::new()
                $userText = [Text.StringBuilder]::new()
                $hits = [Collections.Generic.List[object]]::new()
                foreach ($m in @($c.chat_messages)) {
                    $text = Get-ExportText $m
                    if (-not $text) { continue }
                    $role = if ($m.sender -eq 'human') { 'user' } else { 'assistant' }
                    if ($role -eq 'user') { [void]$userText.AppendLine($text) }
                    foreach ($x in [regex]::Matches($text, $PathRegex)) { Add-PathHit $hits $x.Value 1 }
                    $t = @{ Role = $role; Time = (ConvertTo-DateTime $m.created_at); Text = [Collections.Generic.List[string]]::new(); Tools = [Collections.Generic.List[string]]::new() }
                    $t.Text.Add($text)
                    $turns.Add($t)
                }
                if ($turns.Count -eq 0) { continue }
                $title = if ($c.name) { $c.name } else { Get-OneLine $turns[0].Text[0] 60 }
                $item = [pscustomobject]@{ Id = $id; Kind = 'chat'; SourcePath = ''; Title = $title; Cwd = ''; Branch = ''; Source = 'claude.ai'
                    Started = (ConvertTo-DateTime $c.created_at); Updated = $updated; Turns = $turns; Hits = $hits
                    UserText = $userText.ToString(); Prompts = @($turns | Where-Object Role -eq 'user').Count }
                foreach ($p in (Save-ContextItem $item $src $index $overrides $projects $config)) { [void]$touched.Add($p) }
                $n++
            }
            # claude.ai Projects: their instructions and knowledge files become project docs
            $projFile = Get-ChildItem $path -Recurse -Filter projects.json | Select-Object -First 1
            if ($projFile) {
                foreach ($p in (Get-Content $projFile.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100)) {
                    if (-not $p.name -or $p.is_starter_project) { continue }
                    $name = Get-SafeName $p.name
                    $dir = Join-Path $config.ContextDir "$name\claude-ai-project"
                    New-Item -ItemType Directory -Force $dir | Out-Null
                    $about = "# $($p.name)`n`n$($p.description)`n`n## Instructions`n`n$($p.prompt_template)`n"
                    Set-Content (Join-Path $dir 'README.md') $about -Encoding utf8NoBOM
                    foreach ($doc in @($p.docs)) {
                        if ($doc.filename -and $doc.content) {
                            $text = if ($config.Redact) { Protect-Secrets $doc.content } else { $doc.content }
                            Set-Content (Join-Path $dir (Get-SafeName $doc.filename)) $text -Encoding utf8NoBOM
                        }
                    }
                    if (-not $projects.Contains($name)) { $projects[$name] = [ordered]@{ paths = @(); keywords = @() } }
                    [void]$touched.Add($name)
                }
            }
            Write-State $config 'index' $index
            Write-State $config 'projects' $projects
            foreach ($p in $touched) { Write-ProjectIndex $p $index $projects $config }
            Write-ContextReadme $index $config
            $n
        }
        $count
    } finally {
        if ($temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region GitHub backup

function Invoke-Git($config, [string[]]$gitArgs) {
    $out = & git -C $config.ContextDir @gitArgs 2>&1
    @{ Ok = ($LASTEXITCODE -eq 0); Output = ($out | Out-String).Trim() }
}

function Test-GitHubCli {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return 'GitHub CLI (gh) is not installed. Install it with: winget install GitHub.cli' }
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { return 'GitHub CLI is not signed in. Run: gh auth login' }
    $null
}

# Creates (or reuses) a private GitHub repo and makes the Context folder a clone of it
function Initialize-ContextRepo($config, [string]$name) {
    $problem = Test-GitHubCli
    if ($problem) { throw $problem }
    $login = (& gh api user --jq .login).Trim()
    $full = "$login/$name"
    New-Item -ItemType Directory -Force $config.ContextDir | Out-Null
    & gh repo view $full *> $null
    $exists = $LASTEXITCODE -eq 0
    if (-not $exists) {
        & gh repo create $full --private --description 'My Claude context, sorted by project (ClaudeContextManager)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't create $full" }
    }
    $isPrivate = (& gh repo view $full --json isPrivate --jq .isPrivate).Trim()
    if ($isPrivate -ne 'true') { throw "$full exists and is public. Pick another name (context can contain private data)." }
    & gh auth setup-git *> $null
    if (-not (Test-Path (Join-Path $config.ContextDir '.git'))) {
        [void](Invoke-Git $config @('init', '-b', 'main'))
    }
    if (-not (Invoke-Git $config @('config', 'user.email')).Output) {
        # no git identity on this PC: commit as the GitHub account's private noreply address
        $id = (& gh api user --jq .id).Trim()
        [void](Invoke-Git $config @('config', 'user.email', "$id+$login@users.noreply.github.com"))
        [void](Invoke-Git $config @('config', 'user.name', $login))
    }
    [void](Invoke-Git $config @('config', 'core.autocrlf', 'false'))
    [void](Invoke-Git $config @('config', 'core.quotepath', 'false'))
    $url = "https://github.com/$full.git"
    if ((Invoke-Git $config @('remote', 'get-url', 'origin')).Ok) { [void](Invoke-Git $config @('remote', 'set-url', 'origin', $url)) }
    else { [void](Invoke-Git $config @('remote', 'add', 'origin', $url)) }
    $gitignore = Join-Path $config.ContextDir '.gitignore'
    if (-not (Test-Path $gitignore)) { Set-Content $gitignore ".ccm/sync.lock`n" -Encoding utf8NoBOM }
    if ($exists) {
        # existing repo (another PC, or setup run again): merge what's there first
        $fetch = Invoke-Git $config @('fetch', 'origin')
        if ($fetch.Ok -and (Invoke-Git $config @('rev-parse', '--verify', 'origin/main')).Ok) {
            [void](Invoke-Git $config @('add', '-A'))
            [void](Invoke-Git $config @('commit', '-m', 'Local context before joining repo'))
            $merge = Invoke-Git $config @('pull', 'origin', 'main', '--allow-unrelated-histories', '--no-edit', '-X', 'ours')
            if (-not $merge.Ok) { throw "Couldn't merge $full into the Context folder:`n$($merge.Output)" }
        }
    }
    $config.Repo = $full
    Save-Config $config
    Push-Context $config
}

function Push-Context($config, [switch]$Quiet) {
    if (-not $config.Repo) { if (-not $Quiet) { Write-Warn 'No GitHub repo set up (Settings > GitHub repo).' }; return }
    [void](Invoke-Git $config @('add', '-A'))
    $status = Invoke-Git $config @('status', '--porcelain')
    if ($status.Output) {
        $n = @($status.Output -split "`n").Count
        $commit = Invoke-Git $config @('commit', '-m', "Sync $((Get-Date).ToString('yyyy-MM-dd HH:mm')) ($n file(s))")
        if (-not $commit.Ok) { if (-not $Quiet) { Write-Warn "Commit failed:`n$($commit.Output)" }; return }
    }
    $branch = (Invoke-Git $config @('rev-parse', '--abbrev-ref', 'HEAD')).Output
    $pull = Invoke-Git $config @('pull', '--rebase', '--autostash', 'origin', $branch)
    if (-not $pull.Ok -and $pull.Output -notmatch "couldn't find remote ref") {
        [void](Invoke-Git $config @('rebase', '--abort'))
    }
    $push = Invoke-Git $config @('push', '-u', 'origin', $branch)
    if ($Quiet) { return }
    if ($push.Ok) { Write-Ok "Pushed to github.com/$($config.Repo)" } else { Write-Warn "Push failed:`n$($push.Output)" }
}

#endregion

#region Integrations (Claude Code hook, scheduled sync)

$script:HookMarker = 'ClaudeContextManager'
$script:TaskName = 'ClaudeContextManager Sync'

function Get-CcmScript { Join-Path $PSScriptRoot 'ccm.ps1' }

function Get-ClaudeSettings {
    $file = Join-Path $ClaudeDir 'settings.json'
    $settings = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { [ordered]@{} }
    @{ File = $file; Settings = $settings }
}

function Test-SyncHook {
    $s = (Get-ClaudeSettings).Settings
    [bool]($s.hooks.SessionEnd | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "*$HookMarker*" })
}

# Adds a SessionEnd hook to ~/.claude/settings.json so every Claude Code session (CLI or the Desktop
# Code tab) is synced right after it ends. The hook starts a background sync and returns at once.
function Install-SyncHook {
    $cs = Get-ClaudeSettings
    if (Test-Path $cs.File) { Copy-Item $cs.File "$($cs.File).ccm-backup" -Force }
    Uninstall-SyncHook -NoSave $cs
    $script = (Get-CcmScript) -replace '\\', '/'
    $hook = [ordered]@{ type = 'command'; command = "pwsh -NoProfile -WindowStyle Hidden -File `"$script`" sync --background"; timeout = 30 }
    $s = $cs.Settings
    if (-not $s.Contains('hooks')) { $s['hooks'] = [ordered]@{} }
    if (-not $s.hooks.Contains('SessionEnd')) { $s.hooks['SessionEnd'] = @() }
    $s.hooks['SessionEnd'] = @($s.hooks.SessionEnd) + @([ordered]@{ hooks = @($hook) })
    $s | ConvertTo-Json -Depth 100 | Set-Content $cs.File -Encoding utf8NoBOM
}

function Uninstall-SyncHook($NoSave) {
    $cs = if ($NoSave) { $NoSave } else { Get-ClaudeSettings }
    $s = $cs.Settings
    if (-not $s.hooks -or -not $s.hooks.SessionEnd) { return }
    $kept = @(foreach ($group in @($s.hooks.SessionEnd)) {
        $group.hooks = @($group.hooks | Where-Object { $_.command -notlike "*$HookMarker*" })
        if ($group.hooks.Count) { $group }
    })
    if ($kept.Count) { $s.hooks.SessionEnd = $kept } else { $s.hooks.Remove('SessionEnd') }
    if ($s.hooks.Count -eq 0) { $s.Remove('hooks') }
    if (-not $NoSave) { $s | ConvertTo-Json -Depth 100 | Set-Content $cs.File -Encoding utf8NoBOM }
}

function Test-SyncTask { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }

# Background sync every 30 minutes (Claude Desktop sessions don't always end, so the hook alone can miss them).
# conhost --headless keeps the pwsh window from flashing.
function Install-SyncTask {
    $pwsh = (Get-Command pwsh).Source
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$pwsh`" -NoProfile -File `"$(Get-CcmScript)`" sync --quiet"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 30)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Syncs Claude context into the Context folder' -Force | Out-Null
}

function Uninstall-SyncTask { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

#endregion

#region Plugins

# The built-in source: Claude Code (CLI + Desktop Code tab) sessions, Claude memory and CLAUDE.md files
Register-ContextSource @{
    Name       = 'claude'
    Label      = 'Claude'
    GetSources = { @(Get-SessionSources) + @(Get-MemorySources) }
    Read       = {
        param($src, $cache)
        if ($src.Kind -eq 'memory') { return (Read-Memory $src) }
        if (-not $cache.Contains('Desktop')) { $cache.Desktop = Get-DesktopSessionInfo }
        Read-Session $src $cache.Desktop
    }
    CopyDocs   = { param($projects, $config) Copy-ClaudeMds $projects $config }
    Resume     = { param($id, $entry) & claude --resume $id }
}

function Read-PluginManifest([string]$dir) {
    $file = Join-Path $dir 'plugin.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $m = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    [pscustomobject]@{ Name = $m.name; Version = $m.version; Description = $m.description; Author = $m.author
        MinCcmVersion = $m.minCcmVersion ?? '1.1.0'; Path = $dir; Readme = (Join-Path $dir 'README.md') }
}

function Get-InstalledPlugins {
    if (-not (Test-Path $PluginDir)) { return @() }
    @(Get-ChildItem $PluginDir -Directory | ForEach-Object { Read-PluginManifest $_.FullName } | Where-Object { $_ })
}

# Shallow clone of the repo's Plugins branch, refreshed on every call; returns the folder
function Update-PluginCatalog($config) {
    $cache = Join-Path (Split-Path $ConfigFile -Parent) 'plugin-catalog'
    $url = "https://github.com/$($config.PluginRepo).git"
    if (Test-Path (Join-Path $cache '.git')) {
        $out = & git -C $cache fetch --depth 1 origin $config.PluginBranch 2>&1
        if ($LASTEXITCODE -eq 0) { & git -C $cache reset --hard FETCH_HEAD *> $null; return $cache }
        Remove-Item $cache -Recurse -Force
    }
    $out = & git clone --quiet --depth 1 --single-branch --branch $config.PluginBranch $url $cache 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Couldn't download the plugin list from $url ($($config.PluginBranch) branch). If the repo is private, sign in first: gh auth login, then gh auth setup-git.`n$($out | Out-String)"
    }
    $cache
}

function Get-AvailablePlugins($catalog) {
    $dir = Join-Path $catalog 'plugins'
    if (-not (Test-Path $dir)) { return @() }
    @(Get-ChildItem $dir -Directory | ForEach-Object { Read-PluginManifest $_.FullName } | Where-Object { $_ } | Sort-Object Name)
}

# Installs (or updates) a plugin by name from the Plugins branch, or from a local folder for plugin development
function Install-CcmPlugin($config, [string]$nameOrPath) {
    $src = if (Test-Path -LiteralPath (Join-Path $nameOrPath 'plugin.json')) { Read-PluginManifest (Resolve-Path -LiteralPath $nameOrPath).Path }
        else {
            $catalog = Update-PluginCatalog $config
            $found = Get-AvailablePlugins $catalog | Where-Object Name -eq $nameOrPath
            if (-not $found) { throw "No plugin named '$nameOrPath'. Available: $((Get-AvailablePlugins $catalog).Name -join ', ')" }
            $found
        }
    if ([version]$src.MinCcmVersion -gt [version]$CcmVersion) {
        throw "$($src.Name) needs ClaudeContextManager $($src.MinCcmVersion) or newer (you have $CcmVersion). Update: git pull in your clone, then pwsh -File install.ps1"
    }
    if ($src.Name -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "Invalid plugin name '$($src.Name)'" }
    $dest = Join-Path $PluginDir $src.Name
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem -LiteralPath $src.Path -Force | Where-Object Name -ne '.git' | Copy-Item -Destination $dest -Recurse -Force
    Read-PluginManifest $dest
}

# Removes a plugin; with -RemoveContext also deletes the context it added to the Context folder
function Uninstall-CcmPlugin($config, [string]$name, [switch]$RemoveContext) {
    $dir = Join-Path $PluginDir $name
    if (-not (Test-Path $dir)) { throw "Plugin '$name' isn't installed." }
    Remove-Item $dir -Recurse -Force
    if (-not $RemoveContext) { return }
    Invoke-WithLock $config {
        $index = Read-State $config 'index'
        $projects = Read-State $config 'projects'
        $touched = @{}
        foreach ($id in @($index.Keys | Where-Object { $index[$_].agent -eq $name })) {
            $e = $index[$id]
            Remove-Item -LiteralPath (Join-Path $config.ContextDir $e.file) -ErrorAction SilentlyContinue
            $touched[$e.project] = $true
            $index.Remove($id)
        }
        # the plugin's doc folders (e.g. <Project>\codex) go too
        foreach ($p in Get-ProjectNames $config) {
            $sub = Join-Path $config.ContextDir "$p\$name"
            if (Test-Path -LiteralPath $sub) { Remove-Item -LiteralPath $sub -Recurse -Force; $touched[$p] = $true }
        }
        Write-State $config 'index' $index
        foreach ($p in $touched.Keys) { Write-ProjectIndex $p $index $projects $config }
        Remove-EmptyProjects $config
        Write-ContextReadme $index $config
    } | Out-Null
}

# Load installed plugins (dot-sourced here so their functions and Register-ContextSource calls take effect)
foreach ($pluginScript in @(Get-ChildItem $PluginDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'plugin.ps1' } | Where-Object { Test-Path $_ })) {
    try { . $pluginScript } catch { Write-Host "  Plugin $(Split-Path (Split-Path $pluginScript -Parent) -Leaf) failed to load: $_" }
}
Remove-Variable pluginScript -ErrorAction SilentlyContinue

#endregion
