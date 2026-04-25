param(
    [string]$EventLogPath,
    [string]$SummaryLogPath,
    [string]$DebugLogPath,
    [string]$ScreenshotDir,
    [string]$ValidationArtifactDir,
    [string]$ArtifactName,
    [string]$RepoSlug,
    [string]$RunId,
    [string]$IssueNumber,
    [string]$HeadSha,
    [string]$RefName,
    [string]$AuthMode
)

$ErrorActionPreference = 'Continue'

function Copy-IfExists {
    param(
        [string]$LiteralPath,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }

    Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force -ErrorAction SilentlyContinue
}

function Copy-DirectoryIfExists {
    param(
        [string]$LiteralPath,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }

    $target = Join-Path $Destination (Split-Path -Leaf $LiteralPath)
    Copy-Item -LiteralPath $LiteralPath -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
}

function Count-Files {
    param(
        [string]$LiteralPath,
        [string]$Filter = '*'
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) {
        return 0
    }

    return @(Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue).Count
}

function Get-FileListText {
    param(
        [string]$LiteralPath,
        [string]$Filter = '*'
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) {
        return '_None_'
    }

    $root = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrWhiteSpace($root)) {
        return '_None_'
    }

    $files = @(Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 20)
    if ($files.Count -eq 0) {
        return '_None_'
    }

    $items = foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        '- `' + $relative + '`'
    }

    $total = Count-Files -LiteralPath $LiteralPath -Filter $Filter
    if ($total -gt $files.Count) {
        $items += "- ... $($total - $files.Count) more"
    }

    return ($items -join [Environment]::NewLine)
}

function Get-ExitCodeText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return '_Unknown_'
    }

    $exitLine = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"kind"\s*:\s*"exit"' } |
        Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($exitLine)) {
        return '_Unknown_'
    }

    try {
        $record = $exitLine | ConvertFrom-Json -ErrorAction Stop
        $match = [regex]::Match([string]$record.message, '(-?\d+)\s*$')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
        return [string]$record.message
    } catch {
        return '_Unknown_'
    }
}

function Get-ToolUseStats {
    param([string]$Path)

    $stats = [ordered]@{
        Total = 0
        Mcp = 0
        Github = 0
        RawBridge = 0
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $stats
    }

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        try {
            $record = $line | ConvertFrom-Json -ErrorAction Stop
            if ($record.kind -ne 'tool_use') {
                continue
            }

            $message = [string]$record.message
            $stats.Total++
            if ($message -match 'mcp__|spire-lens-mcp|bridge_get|bridge_ping|get_game_state|start_singleplayer_run|enter_debug_room|reload_spirelens_core') {
                $stats.Mcp++
            }
            if ($message -match '\bgh\b|github|issue|pull request|pr ') {
                $stats.Github++
            }
            if ($message -match 'Invoke-WebRequest|Invoke-RestMethod|localhost:15526|raw TCP|spirelens-live-bridge|request\.json|ready\.json|accepted\.json|result\.json') {
                $stats.RawBridge++
            }
        } catch {
            continue
        }
    }

    return $stats
}

function Invoke-GhJson {
    param([string[]]$Arguments)

    try {
        $output = & gh @Arguments 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output -join [Environment]::NewLine))) {
            return $null
        }
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Add-GhComment {
    param(
        [string]$TargetKind,
        [string]$TargetNumber,
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($RepoSlug) -or [string]::IsNullOrWhiteSpace($TargetNumber) -or [string]::IsNullOrWhiteSpace($Body)) {
        return
    }

    try {
        if ($TargetKind -eq 'pr') {
            & gh pr comment $TargetNumber --repo $RepoSlug --body $Body | Out-Null
        } else {
            & gh issue comment $TargetNumber --repo $RepoSlug --body $Body | Out-Null
        }
    } catch {
        Write-Warning "Unable to post $TargetKind comment on #${TargetNumber}: $($_.Exception.Message)"
    }
}

function Close-CompletedIssueIfAppropriate {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($RepoSlug) -or [string]::IsNullOrWhiteSpace($IssueNumber)) {
        return
    }

    $issue = Invoke-GhJson -Arguments @('issue', 'view', $IssueNumber, '--repo', $RepoSlug, '--json', 'body,labels,state')
    if ($null -eq $issue -or $issue.state -ne 'OPEN') {
        return
    }

    $labels = @($issue.labels | ForEach-Object { $_.name })
    if ($labels -notcontains 'issue-agent-complete') {
        return
    }
    if ($labels -contains 'issue-agent-pr-open') {
        return
    }

    $issueBody = [string]$issue.body
    if ($issueBody -match '(?i)\b(leave|keep)\s+open\b|\bdo\s+not\s+close\b') {
        Write-Host "Issue explicitly asks to remain open; not closing #$IssueNumber."
        return
    }

    try {
        & gh issue close $IssueNumber --repo $RepoSlug --comment "Closing because the issue-agent marked this issue complete and did not open a PR. Run summary:$([Environment]::NewLine)$([Environment]::NewLine)$Body" | Out-Null
    } catch {
        Write-Warning "Unable to close completed issue #${IssueNumber}: $($_.Exception.Message)"
    }
}

$runKey = if ([string]::IsNullOrWhiteSpace($RunId)) { (Get-Date).ToString('yyyyMMdd-HHmmss') } else { $RunId }
$persistentRoot = Join-Path 'C:\ProgramData\SpireLens\issue-agent-runs' $runKey
New-Item -ItemType Directory -Force -Path $persistentRoot | Out-Null

Copy-IfExists -LiteralPath $EventLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $SummaryLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $DebugLogPath -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ScreenshotDir -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ValidationArtifactDir -Destination $persistentRoot

Write-Host "Persistent issue-agent logs copied to: $persistentRoot"

$screenshotCount = Count-Files -LiteralPath $ScreenshotDir -Filter '*.png'
$validationArtifactCount = Count-Files -LiteralPath $ValidationArtifactDir
$exitCodeText = Get-ExitCodeText -Path $EventLogPath
$toolStats = Get-ToolUseStats -Path $EventLogPath
$runUrl = if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($RunId)) { "https://github.com/$RepoSlug/actions/runs/$RunId" } else { '_Unavailable_' }
$artifactUrl = if ($runUrl -ne '_Unavailable_') { "$runUrl/artifacts" } else { '_Unavailable_' }
$issueUrl = if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($IssueNumber)) { "https://github.com/$RepoSlug/issues/$IssueNumber" } else { '_Unavailable_' }
$artifactText = if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) { "[$ArtifactName]($artifactUrl)" } else { '_Unavailable_' }
$authModeText = if (-not [string]::IsNullOrWhiteSpace($AuthMode)) { $AuthMode } else { '_Unknown_' }

$evidenceNotes = New-Object System.Collections.Generic.List[string]
if ($screenshotCount -eq 0) {
    $evidenceNotes.Add('- No screenshot artifacts were produced. Do not treat this run as visual proof of card, tooltip, combat, or run-state behavior.')
}
if ($toolStats.Mcp -eq 0) {
    $evidenceNotes.Add('- No MCP tool use was detected in the event stream. Treat any live-game claim as unproven unless the raw logs show otherwise.')
}
if ($toolStats.RawBridge -gt 0) {
    $evidenceNotes.Add('- Potential raw bridge or filesystem-queue fallback language was detected in tool use. Inspect the logs before trusting this run.')
}
if ($evidenceNotes.Count -eq 0) {
    $evidenceNotes.Add('- MCP activity and screenshot artifact presence were detected. Inspect the linked artifacts for proof quality before relying on visual claims.')
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('## Issue Agent Summary')
$lines.Add('')
$lines.Add('| Field | Value |')
$lines.Add('| --- | --- |')
$lines.Add("| Issue | [$IssueNumber]($issueUrl) |")
$lines.Add("| Run | [$RunId]($runUrl) |")
$lines.Add("| Artifact | $artifactText |")
$lines.Add("| GitHub auth mode | $authModeText |")
$lines.Add("| Claude exit code | $exitCodeText |")
$lines.Add("| Head SHA | $HeadSha |")
$lines.Add("| Ref | $RefName |")
$lines.Add("| Persistent local logs | `$persistentRoot` |")
$lines.Add('')
$lines.Add('### Evidence Counters')
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('| --- | ---: |')
$lines.Add("| Tool-use events | $($toolStats.Total) |")
$lines.Add("| MCP-looking tool-use events | $($toolStats.Mcp) |")
$lines.Add("| Raw bridge / queue-looking events | $($toolStats.RawBridge) |")
$lines.Add("| Screenshot artifacts | $screenshotCount |")
$lines.Add("| Validation artifact files | $validationArtifactCount |")
$lines.Add('')
$lines.Add('### Evidence Notes')
$lines.Add('')
$lines.AddRange([string[]]$evidenceNotes)
$lines.Add('')
$lines.Add('### Screenshot Files')
$lines.Add('')
$lines.Add((Get-FileListText -LiteralPath $ScreenshotDir -Filter '*.png'))
$lines.Add('')
$lines.Add('### Validation Artifact Files')
$lines.Add('')
$lines.Add((Get-FileListText -LiteralPath $ValidationArtifactDir))
$lines.Add('')
$lines.Add('### Log Pointers')
$lines.Add('')
$lines.Add('- Event log: `' + $EventLogPath + '`')
$lines.Add('- Summary log: `' + $SummaryLogPath + '`')
$lines.Add('- Debug log: `' + $DebugLogPath + '`')
$lines.Add('- Persistent local directory: `' + $persistentRoot + '`')

$markdown = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $markdown | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
} else {
    Write-Host $markdown
}

if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN) -and -not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($IssueNumber)) {
    Add-GhComment -TargetKind 'issue' -TargetNumber $IssueNumber -Body $markdown

    $prs = Invoke-GhJson -Arguments @('pr', 'list', '--repo', $RepoSlug, '--state', 'all', '--search', "$IssueNumber in:body", '--json', 'number,url,title', '--limit', '10')
    if ($null -ne $prs) {
        foreach ($pr in @($prs)) {
            if ($null -ne $pr.number) {
                Add-GhComment -TargetKind 'pr' -TargetNumber ([string]$pr.number) -Body $markdown
            }
        }
    }

    Close-CompletedIssueIfAppropriate -Body $markdown
}