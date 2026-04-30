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
    [string]$RefName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0  # uninitialized vars + method-syntax misuse; kept off v3 because optional JSON access patterns (e.g. $result.usage.input_tokens) would throw

function Copy-IfExists {
    param([string]$LiteralPath, [string]$Destination)
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) { return }
    Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force -ErrorAction SilentlyContinue
}

function Copy-DirectoryIfExists {
    param([string]$LiteralPath, [string]$Destination)
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) { return }
    $target = Join-Path $Destination (Split-Path -Leaf $LiteralPath)
    Copy-Item -LiteralPath $LiteralPath -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
}

function Count-Files {
    param([string]$LiteralPath, [string]$Filter = '*')
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) { return 0 }
    return @(Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue).Count
}

function Get-FileListText {
    param([string]$LiteralPath, [string]$Filter = '*')
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) { return '_None_' }
    $root = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrWhiteSpace($root)) { return '_None_' }
    $files = @(Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 25)
    if ($files.Count -eq 0) { return '_None_' }
    $items = foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        '- `' + $relative + '`'
    }
    $total = Count-Files -LiteralPath $LiteralPath -Filter $Filter
    if ($total -gt $files.Count) { $items += "- ... $($total - $files.Count) more" }
    return ($items -join [Environment]::NewLine)
}

function Publish-ScreenshotImages {
    param([string]$LiteralPath)

    $published = New-Object System.Collections.Generic.List[string]
    $previewPath = $env:ISSUE_AGENT_SCREENSHOT_PREVIEWS_PATH
    if ([string]::IsNullOrWhiteSpace($previewPath) -or -not (Test-Path -LiteralPath $previewPath)) { return $published }

    Get-Content -LiteralPath $previewPath -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $published.Add([string]$_) | Out-Null }

    return $published
}
function Get-ToolFailureCategory {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match '(?i)permission to use .* has been denied|permission_denied|permission denied|not allowed to use tool|disallowed') { return 'permission_denied' }
    if ($Text -match '(?i)\b(500|internal server error)\b') { return 'server_error' }
    if ($Text -match '(?i)\b(timed out|timeout)\b') { return 'timeout' }
    if ($Text -match '(?im)^\s*(error|exception|traceback):') { return 'tool_error' }
    if ($Text -match '(?i)\b(exit code [1-9]\d*|unauthorized|forbidden)\b') { return 'tool_error' }
    if ($Text -match '(?im)^\s*Build FAILED\.?\s*$') { return 'tool_error' }
    if ($Text -match '(?i)\berror\s+[A-Z]+\d{3,}\b') { return 'tool_error' }
    return $null
}

function New-ToolMetricBucket {
    return [ordered]@{
        tool_uses = 0
        tool_results = 0
        failed_tool_results = 0
        permission_denials = 0
        failure_categories = [ordered]@{}
    }
}

function Add-ToolMetricFailure {
    param([object]$Bucket, [string]$Category)
    if ([string]::IsNullOrWhiteSpace($Category)) { return }
    $Bucket.failed_tool_results++
    if ($null -eq $Bucket.failure_categories[$Category]) { $Bucket.failure_categories[$Category] = 0 }
    $Bucket.failure_categories[$Category]++
}

function Get-ClaudeToolCallSummary {
    param([string]$Path, [string[]]$PhaseNames)

    $summary = [ordered]@{
        total = New-ToolMetricBucket
        phases = [ordered]@{}
    }
    foreach ($phaseName in $PhaseNames) { $summary.phases[$phaseName] = New-ToolMetricBucket }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $summary }

    Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $record = $_ | ConvertFrom-Json -ErrorAction Stop
            $phaseName = [string](Get-NestedPropertyValue -Object $record -Path @('data', 'phase'))
            if ([string]::IsNullOrWhiteSpace($phaseName)) { $phaseName = 'unknown' }
            if ($null -eq $summary.phases[$phaseName]) { $summary.phases[$phaseName] = New-ToolMetricBucket }
            $phaseBucket = $summary.phases[$phaseName]
            if ($record.kind -eq 'tool_use') {
                $summary.total.tool_uses++
                $phaseBucket.tool_uses++
                return
            }
            if ($record.kind -eq 'tool_result') {
                $summary.total.tool_results++
                $phaseBucket.tool_results++
                $category = [string](Get-NestedPropertyValue -Object $record -Path @('data', 'failure_category'))
                $failed = Get-NestedPropertyValue -Object $record -Path @('data', 'failed')
                if ([string]::IsNullOrWhiteSpace($category)) { $category = Get-ToolFailureCategory -Text ([string]$record.message) }
                if (($failed -is [bool] -and $failed) -and [string]::IsNullOrWhiteSpace($category)) { $category = 'tool_error' }
                if (($failed -is [bool] -and $failed) -or -not [string]::IsNullOrWhiteSpace($category)) {
                    Add-ToolMetricFailure -Bucket $summary.total -Category $category
                    Add-ToolMetricFailure -Bucket $phaseBucket -Category $category
                }
                return
            }
            if ($record.kind -eq 'result' -and -not [string]::IsNullOrWhiteSpace([string]$record.message)) {
                $resultEvent = $record.message | ConvertFrom-Json -ErrorAction Stop
                $denials = @($resultEvent.permission_denials)
                if ($denials.Count -gt 0) {
                    $summary.total.permission_denials += $denials.Count
                    $phaseBucket.permission_denials += $denials.Count
                    foreach ($denial in $denials) {
                        Add-ToolMetricFailure -Bucket $summary.total -Category 'permission_denied'
                        Add-ToolMetricFailure -Bucket $phaseBucket -Category 'permission_denied'
                    }
                }
            }
        } catch {
        }
    }
    return $summary
}

function Format-FailureCategories {
    # PS7 note: callers pass [ordered]@{} (see New-ToolMetricBucket); iterating
    # via PSObject.Properties yields the dict's reflection properties in PS7,
    # not its entries. Use GetEnumerator for IDictionary, fall back for objects.
    param([object]$Categories)
    if ($null -eq $Categories) { return '' }
    $items = @()
    if ($Categories -is [System.Collections.IDictionary]) {
        foreach ($entry in $Categories.GetEnumerator()) {
            if ($null -ne $entry.Value -and [int]$entry.Value -gt 0) { $items += "$($entry.Key): $($entry.Value)" }
        }
    } else {
        foreach ($property in $Categories.PSObject.Properties) {
            if ($null -ne $property.Value -and [int]$property.Value -gt 0) { $items += "$($property.Name): $($property.Value)" }
        }
    }
    if ($items.Count -eq 0) { return '' }
    return ($items -join ', ')
}
function Get-ClaudeCostSummary {
    param([string]$Path)

    $summary = [ordered]@{
        TotalCostUsd = 0.0
        InputTokens = 0
        OutputTokens = 0
        CacheCreationInputTokens = 0
        CacheReadInputTokens = 0
        Turns = 0
        Results = 0
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $summary }

    Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $record = $_ | ConvertFrom-Json -ErrorAction Stop
            if ($record.kind -ne 'result' -or [string]::IsNullOrWhiteSpace([string]$record.message)) { return }
            $result = $record.message | ConvertFrom-Json -ErrorAction Stop
            $summary.Results++
            if ($null -ne $result.total_cost_usd) { $summary.TotalCostUsd += [double]$result.total_cost_usd }
            if ($null -ne $result.num_turns) { $summary.Turns += [int]$result.num_turns }
            if ($null -ne $result.usage) {
                if ($null -ne $result.usage.input_tokens) { $summary.InputTokens += [int64]$result.usage.input_tokens }
                if ($null -ne $result.usage.output_tokens) { $summary.OutputTokens += [int64]$result.usage.output_tokens }
                if ($null -ne $result.usage.cache_creation_input_tokens) { $summary.CacheCreationInputTokens += [int64]$result.usage.cache_creation_input_tokens }
                if ($null -ne $result.usage.cache_read_input_tokens) { $summary.CacheReadInputTokens += [int64]$result.usage.cache_read_input_tokens }
            }
        } catch {
        }
    }

    return $summary
}

function Format-Usd {
    param([double]$Value)
    return ('$' + $Value.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture))
}
function Read-JsonOrNull {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-PropertyValue {
    # See run-issue-agent-phases.ps1 Get-PropertyValue: PS7 PSObject.Properties
    # on dictionaries does not expose entries. Branch on IDictionary.
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-NestedPropertyValue {
    param([object]$Object, [string[]]$Path)
    $current = $Object
    foreach ($part in $Path) {
        $current = Get-PropertyValue -Object $current -Name $part
        if ($null -eq $current) { return $null }
    }
    return $current
}

function Format-Cell {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
    return ([string]$Value).Replace('|', '\|')
}

function ConvertTo-CompactJson {
    param([object]$Value, [int]$Depth = 30)
    if ($null -eq $Value) { return 'null' }
    try { return ($Value | ConvertTo-Json -Compress -Depth $Depth) }
    catch { return [string]$Value }
}

function Add-TranscriptSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        [string[]]$Body
    )
    $Lines.Add("## $Title")
    $Lines.Add('')
    foreach ($line in $Body) { $Lines.Add($line) }
    $Lines.Add('')
}

function New-ClaudeEventTranscript {
    param([string]$EventLogPath, [string]$OutputPath)

    $transcript = New-Object System.Collections.Generic.List[string]
    $transcript.Add('# Claude Event Transcript')
    $transcript.Add('')
    $transcript.Add("Source: $EventLogPath")
    $transcript.Add('')

    if ([string]::IsNullOrWhiteSpace($EventLogPath) -or -not (Test-Path -LiteralPath $EventLogPath)) {
        Add-TranscriptSection -Lines $transcript -Title 'No Event Log' -Body @('The event log was not found.')
        $transcript -join [Environment]::NewLine | Set-Content -LiteralPath $OutputPath -Encoding UTF8
        return
    }

    $lineNumber = 0
    Get-Content -LiteralPath $EventLogPath -ErrorAction SilentlyContinue | ForEach-Object {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($_)) { return }

        try { $event = $_ | ConvertFrom-Json -ErrorAction Stop }
        catch {
            Add-TranscriptSection -Lines $transcript -Title "Raw Line $lineNumber" -Body @('```text', $_, '```')
            return
        }

        if ($null -ne $event.kind) {
            $phase = [string](Get-NestedPropertyValue -Object $event -Path @('data', 'phase'))
            $phasePrefix = if ([string]::IsNullOrWhiteSpace($phase)) { '' } else { "[$phase] " }
            $message = [string]$event.message
            switch ([string]$event.kind) {
                'tool_use' { Add-TranscriptSection -Lines $transcript -Title ($phasePrefix + 'Tool Use') -Body @($message) }
                'tool_result' { Add-TranscriptSection -Lines $transcript -Title ($phasePrefix + 'Tool Result') -Body @('```text', $message, '```') }
                'assistant_text' { Add-TranscriptSection -Lines $transcript -Title ($phasePrefix + 'Assistant') -Body @($message) }
                'result' {
                    $body = New-Object System.Collections.Generic.List[string]
                    try {
                        $resultEvent = $message | ConvertFrom-Json -ErrorAction Stop
                        $body.Add("- Error: $($resultEvent.is_error)")
                        $body.Add("- Turns: $($resultEvent.num_turns)")
                        $body.Add("- Cost: $($resultEvent.total_cost_usd)")
                        if ($resultEvent.permission_denials) {
                            $body.Add('- Permission denials:')
                            foreach ($denial in $resultEvent.permission_denials) {
                                $body.Add("  - $($denial.tool_name) input: $(ConvertTo-CompactJson $denial.tool_input)")
                            }
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$resultEvent.result)) {
                            $body.Add('')
                            $body.Add([string]$resultEvent.result)
                        }
                    } catch {
                        $body.Add('```json')
                        $body.Add($message)
                        $body.Add('```')
                    }
                    Add-TranscriptSection -Lines $transcript -Title ($phasePrefix + 'Result') -Body $body.ToArray()
                }
                default { Add-TranscriptSection -Lines $transcript -Title ($phasePrefix + [string]$event.kind) -Body @($message) }
            }
            return
        }

        switch ([string]$event.type) {
            'system' {
                $servers = if ($event.mcp_servers) { (($event.mcp_servers | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', ') } else { '_none reported_' }
                Add-TranscriptSection -Lines $transcript -Title 'System' -Body @(
                    "- Session: $($event.session_id)",
                    "- Model: $($event.model)",
                    "- CWD: $($event.cwd)",
                    "- MCP servers: $servers"
                )
            }
            'rate_limit_event' { Add-TranscriptSection -Lines $transcript -Title 'Rate Limit' -Body @('```json', (ConvertTo-CompactJson $event.rate_limit_info), '```') }
            'assistant' {
                foreach ($block in @($event.message.content)) {
                    if ($block.type -eq 'text') {
                        Add-TranscriptSection -Lines $transcript -Title 'Assistant' -Body @([string]$block.text)
                    } elseif ($block.type -eq 'tool_use') {
                        Add-TranscriptSection -Lines $transcript -Title 'Tool Use' -Body @(
                            "- Tool: $($block.name)",
                            "- Input: $(ConvertTo-CompactJson $block.input)"
                        )
                    }
                }
            }
            'user' {
                foreach ($block in @($event.message.content)) {
                    if ($block.type -eq 'tool_result') {
                        $body = if ($block.content -is [string]) { [string]$block.content } else { ConvertTo-CompactJson $block.content }
                        Add-TranscriptSection -Lines $transcript -Title 'Tool Result' -Body @('```text', $body, '```')
                    }
                }
            }
            'result' {
                $body = New-Object System.Collections.Generic.List[string]
                $body.Add("- Error: $($event.is_error)")
                $body.Add("- Turns: $($event.num_turns)")
                $body.Add("- Cost: $($event.total_cost_usd)")
                if ($event.permission_denials) {
                    $body.Add('- Permission denials:')
                    foreach ($denial in $event.permission_denials) {
                        $body.Add("  - $($denial.tool_name) input: $(ConvertTo-CompactJson $denial.tool_input)")
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$event.result)) {
                    $body.Add('')
                    $body.Add([string]$event.result)
                }
                Add-TranscriptSection -Lines $transcript -Title 'Result' -Body $body.ToArray()
            }
            default { Add-TranscriptSection -Lines $transcript -Title ([string]$event.type) -Body @('```json', (ConvertTo-CompactJson $event), '```') }
        }
    }

    $transcript -join [Environment]::NewLine | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
function Add-GhComment {
    param([string]$TargetKind, [string]$TargetNumber, [string]$Body)
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or [string]::IsNullOrWhiteSpace($RepoSlug) -or [string]::IsNullOrWhiteSpace($TargetNumber)) { return }
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

$runKey = if ([string]::IsNullOrWhiteSpace($RunId)) { (Get-Date).ToString('yyyyMMdd-HHmmss') } else { $RunId }
$persistentRoot = Join-Path 'C:\ProgramData\SpireLens\issue-agent-runs' $runKey
New-Item -ItemType Directory -Force -Path $persistentRoot | Out-Null

$transcriptPath = Join-Path $ValidationArtifactDir 'claude-issue-agent-transcript.md'
New-Item -ItemType Directory -Force -Path $ValidationArtifactDir | Out-Null
New-ClaudeEventTranscript -EventLogPath $EventLogPath -OutputPath $transcriptPath

Copy-IfExists -LiteralPath $EventLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $transcriptPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $SummaryLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $DebugLogPath -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ScreenshotDir -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ValidationArtifactDir -Destination $persistentRoot

$phaseNames = @('test_plan', 'implementation', 'verification')
$phaseResults = [ordered]@{}
foreach ($phaseName in $phaseNames) {
    $phaseResults[$phaseName] = Read-JsonOrNull -Path (Join-Path $ValidationArtifactDir "issue-agent-$phaseName.json")
}
$result = Read-JsonOrNull -Path (Join-Path $ValidationArtifactDir 'issue-agent-result.json')

$implementationPrUrl = Get-PropertyValue -Object $phaseResults['implementation'] -Name 'opened_pr_url'
$implementationPrNumber = Get-PropertyValue -Object $phaseResults['implementation'] -Name 'opened_pr'
$resultPrUrl = Get-PropertyValue -Object $result -Name 'opened_pr_url'
$resultPrNumber = Get-PropertyValue -Object $result -Name 'opened_pr'
$prUrl = if (-not [string]::IsNullOrWhiteSpace([string]$resultPrUrl)) { $resultPrUrl } else { $implementationPrUrl }
$prNumber = if ($null -ne $resultPrNumber) { $resultPrNumber } else { $implementationPrNumber }

$screenshotCount = Count-Files -LiteralPath $ScreenshotDir -Filter '*.png'
$publishedScreenshotImages = Publish-ScreenshotImages -LiteralPath $ScreenshotDir
$validationArtifactCount = Count-Files -LiteralPath $ValidationArtifactDir
$exitCodeText = Get-ExitCodeText -Path $EventLogPath
$costSummary = Get-ClaudeCostSummary -Path $EventLogPath
$toolSummary = Get-ClaudeToolCallSummary -Path $EventLogPath -PhaseNames $phaseNames
$toolMetricsPath = Join-Path $ValidationArtifactDir 'issue-agent-tool-metrics.json'
$toolSummary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $toolMetricsPath -Encoding UTF8
Copy-IfExists -LiteralPath $toolMetricsPath -Destination $persistentRoot
$runUrl = if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($RunId)) { "https://github.com/$RepoSlug/actions/runs/$RunId" } else { '_Unavailable_' }
$artifactUrl = if ($runUrl -ne '_Unavailable_') { "$runUrl/artifacts" } else { '_Unavailable_' }
$artifactText = if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) { "[$ArtifactName]($artifactUrl)" } else { '_Unavailable_' }
$issueUrl = if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($IssueNumber)) { "https://github.com/$RepoSlug/issues/$IssueNumber" } else { '_Unavailable_' }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('## Issue Agent Summary')
$lines.Add('')
$lines.Add('| Field | Value |')
$lines.Add('| --- | --- |')
$lines.Add("| Issue | [$IssueNumber]($issueUrl) |")
$lines.Add("| Run | [$RunId]($runUrl) |")
$lines.Add("| Artifact | $artifactText |")
$prCell = if ([string]::IsNullOrWhiteSpace([string]$prUrl)) { '_None reported_' } else { "[$prNumber]($prUrl)" }
$lines.Add("| PR | $prCell |")
$lines.Add("| Result status | $(Format-Cell (Get-PropertyValue -Object $result -Name 'status')) |")
$lines.Add("| Abort layer | $(Format-Cell (Get-PropertyValue -Object $result -Name 'abort_layer')) |")
$lines.Add("| Abort reason | $(Format-Cell (Get-PropertyValue -Object $result -Name 'abort_reason')) |")
$lines.Add("| Claude exit | $exitCodeText |")
$lines.Add("| Claude cost | $(Format-Usd $costSummary.TotalCostUsd) |")
$lines.Add("| Claude turns | $($costSummary.Turns) |")
$lines.Add("| Tool calls | $($toolSummary.total.tool_uses) |")
$lines.Add("| Failed tool calls | $($toolSummary.total.failed_tool_results) |")
$lines.Add("| Head SHA | $HeadSha |")
$lines.Add("| Ref | $RefName |")
$lines.Add('| Persistent local logs | `' + $persistentRoot + '` |')
$lines.Add('')
$phaseBuckets = @{}
foreach ($phaseName in $phaseNames) {
    $phaseBuckets[$phaseName] = [ordered]@{ Cost = 0.0; Turns = 0; Input = 0; Output = 0; CacheCreate = 0; CacheRead = 0 }
}
if (-not [string]::IsNullOrWhiteSpace($EventLogPath) -and (Test-Path -LiteralPath $EventLogPath)) {
    Get-Content -LiteralPath $EventLogPath -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $record = $_ | ConvertFrom-Json -ErrorAction Stop
            if ($record.kind -ne 'result') { return }
            $phaseName = [string](Get-NestedPropertyValue -Object $record -Path @('data', 'phase'))
            if (-not $phaseBuckets.ContainsKey($phaseName)) { return }
            $resultEvent = $record.message | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $resultEvent.total_cost_usd) { $phaseBuckets[$phaseName].Cost += [double]$resultEvent.total_cost_usd }
            if ($null -ne $resultEvent.num_turns) { $phaseBuckets[$phaseName].Turns += [int]$resultEvent.num_turns }
            if ($null -ne $resultEvent.usage) {
                if ($null -ne $resultEvent.usage.input_tokens) { $phaseBuckets[$phaseName].Input += [int64]$resultEvent.usage.input_tokens }
                if ($null -ne $resultEvent.usage.output_tokens) { $phaseBuckets[$phaseName].Output += [int64]$resultEvent.usage.output_tokens }
                if ($null -ne $resultEvent.usage.cache_creation_input_tokens) { $phaseBuckets[$phaseName].CacheCreate += [int64]$resultEvent.usage.cache_creation_input_tokens }
                if ($null -ne $resultEvent.usage.cache_read_input_tokens) { $phaseBuckets[$phaseName].CacheRead += [int64]$resultEvent.usage.cache_read_input_tokens }
            }
        } catch {
        }
    }
}

$lines.Add('### Phases')
$lines.Add('')
foreach ($phaseName in $phaseNames) {
    $phase = $phaseResults[$phaseName]
    $costBucket = $phaseBuckets[$phaseName]
    $toolBucket = $toolSummary.phases[$phaseName]
    if ($null -eq $toolBucket) { $toolBucket = New-ToolMetricBucket }
    $mdName = "issue-agent-$phaseName.md"
    $mdState = if (Test-Path -LiteralPath (Join-Path $ValidationArtifactDir $mdName)) { '`' + $mdName + '`' } else { '_missing_' }

    $lines.Add("#### $phaseName")
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Status | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'status')) |")
    $lines.Add("| Abort reason | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'abort_reason')) |")
    $lines.Add("| Retryable | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'retryable')) |")
    $lines.Add("| Human action | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'human_action_required')) |")
    $lines.Add("| Markdown | $mdState |")
    $lines.Add("| Cost | $(Format-Usd $costBucket.Cost) |")
    $lines.Add("| Turns | $($costBucket.Turns) |")
    $lines.Add("| Tokens | input $($costBucket.Input), output $($costBucket.Output), cache create $($costBucket.CacheCreate), cache read $($costBucket.CacheRead) |")
    $lines.Add("| Tool calls | $($toolBucket.tool_uses) calls, $($toolBucket.tool_results) results |")
    $lines.Add("| Failed tool calls | $($toolBucket.failed_tool_results) |")
    $lines.Add("| Permission denials | $($toolBucket.permission_denials) |")
    $lines.Add("| Failure categories | $(Format-Cell (Format-FailureCategories $toolBucket.failure_categories)) |")
    $lines.Add('')
}

$lines.Add('### Overall Evidence')
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('| --- | ---: |')
$lines.Add("| Screenshot artifacts | $screenshotCount |")
$lines.Add("| Validation artifact files | $validationArtifactCount |")
$lines.Add("| Claude result events | $($costSummary.Results) |")
$lines.Add("| Tool calls | $($toolSummary.total.tool_uses) |")
$lines.Add("| Tool results | $($toolSummary.total.tool_results) |")
$lines.Add("| Failed tool calls | $($toolSummary.total.failed_tool_results) |")
$lines.Add("| Permission denials | $($toolSummary.total.permission_denials) |")
$lines.Add("| Input tokens | $($costSummary.InputTokens) |")
$lines.Add("| Output tokens | $($costSummary.OutputTokens) |")
$lines.Add("| Cache creation tokens | $($costSummary.CacheCreationInputTokens) |")
$lines.Add("| Cache read tokens | $($costSummary.CacheReadInputTokens) |")
$lines.Add("| Unit tests passed | $(Format-Cell (Get-NestedPropertyValue -Object $result -Path @('unit_tests', 'passed'))) |")
$lines.Add("| Live MCP validation passed | $(Format-Cell (Get-NestedPropertyValue -Object $result -Path @('live_mcp_validation', 'passed'))) |")
$lines.Add("| Screenshot validation passed | $(Format-Cell (Get-NestedPropertyValue -Object $result -Path @('screenshot_validation', 'passed'))) |")
$lines.Add("| Card metadata discovery passed | $(Format-Cell (Get-NestedPropertyValue -Object $result -Path @('card_metadata_discovery', 'passed'))) |")
$lines.Add('')
$lines.Add('### Screenshot Files')
$lines.Add('')
$lines.Add((Get-FileListText -LiteralPath $ScreenshotDir -Filter '*.png'))
$lines.Add('')
if ($publishedScreenshotImages.Count -gt 0) {
    $lines.Add('### Screenshot Previews')
    $lines.Add('')
    foreach ($imageMarkdown in $publishedScreenshotImages) { $lines.Add($imageMarkdown) }
    $lines.Add('')
}
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

Add-GhComment -TargetKind 'issue' -TargetNumber $IssueNumber -Body $markdown
if ($null -ne $prNumber -and -not [string]::IsNullOrWhiteSpace([string]$prNumber)) {
    Add-GhComment -TargetKind 'pr' -TargetNumber ([string]$prNumber) -Body $markdown
}
