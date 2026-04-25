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

$ErrorActionPreference = 'Continue'

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
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not (Test-Path -LiteralPath $LiteralPath)) { return $published }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or [string]::IsNullOrWhiteSpace($RepoSlug) -or [string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($RefName)) { return $published }

    $root = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrWhiteSpace($root)) { return $published }

    $files = @(Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -First 10)
    foreach ($file in $files) {
        try {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            if ([string]::IsNullOrWhiteSpace($relative)) { $relative = $file.Name }
            $repoPath = ".github/issue-agent-screenshots/$RunId/$relative"
            $encodedContent = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))

            $existingSha = $null
            try {
                $existing = & gh api "repos/$RepoSlug/contents/$repoPath`?ref=$RefName" 2>$null | ConvertFrom-Json -ErrorAction Stop
                $existingSha = $existing.sha
            } catch {
                $existingSha = $null
            }

            $body = [ordered]@{
                message = "Publish issue-agent screenshot for run $RunId"
                content = $encodedContent
                branch = $RefName
            }
            if (-not [string]::IsNullOrWhiteSpace($existingSha)) { $body.sha = $existingSha }

            $tmp = New-TemporaryFile
            try {
                $body | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
                & gh api -X PUT "repos/$RepoSlug/contents/$repoPath" --input $tmp 2>$null | Out-Null
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }

            $imageUrl = "https://raw.githubusercontent.com/$RepoSlug/$RefName/$repoPath"
            $published.Add("![$relative]($imageUrl)") | Out-Null
        } catch {
            Write-Warning "Unable to publish screenshot '$($file.FullName)': $($_.Exception.Message)"
        }
    }

    return $published
}
function Get-ExitCodeText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '_Unknown_' }
    $exitLine = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"kind"\s*:\s*"exit"' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($exitLine)) { return '_Unknown_' }
    try {
        $record = $exitLine | ConvertFrom-Json -ErrorAction Stop
        return [string]$record.message
    } catch {
        return '_Unknown_'
    }
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
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
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

Copy-IfExists -LiteralPath $EventLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $SummaryLogPath -Destination $persistentRoot
Copy-IfExists -LiteralPath $DebugLogPath -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ScreenshotDir -Destination $persistentRoot
Copy-DirectoryIfExists -LiteralPath $ValidationArtifactDir -Destination $persistentRoot

$phaseNames = @('investigation', 'implementation', 'verification')
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
$lines.Add("| Head SHA | $HeadSha |")
$lines.Add("| Ref | $RefName |")
$lines.Add("| Persistent local logs | `$persistentRoot` |")
$lines.Add('')
$phaseCostRows = New-Object System.Collections.Generic.List[string]
foreach ($phaseName in $phaseNames) {
    $phaseCostRows.Add("| $phaseName | $0.0000 | 0 | 0 | 0 | 0 | 0 |")
}
if (-not [string]::IsNullOrWhiteSpace($EventLogPath) -and (Test-Path -LiteralPath $EventLogPath)) {
    $phaseBuckets = @{}
    foreach ($phaseName in $phaseNames) {
        $phaseBuckets[$phaseName] = [ordered]@{ Cost = 0.0; Turns = 0; Input = 0; Output = 0; CacheCreate = 0; CacheRead = 0 }
    }
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
    $phaseCostRows.Clear()
    foreach ($phaseName in $phaseNames) {
        $bucket = $phaseBuckets[$phaseName]
        $phaseCostRows.Add("| $phaseName | $(Format-Usd $bucket.Cost) | $($bucket.Turns) | $($bucket.Input) | $($bucket.Output) | $($bucket.CacheCreate) | $($bucket.CacheRead) |")
    }
}

$lines.Add('### Phase Results')
$lines.Add('')
$lines.Add('| Phase | Status | Abort reason | Retryable | Human action | Markdown |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($phaseName in $phaseNames) {
    $phase = $phaseResults[$phaseName]
    $mdName = "issue-agent-$phaseName.md"
    $mdState = if (Test-Path -LiteralPath (Join-Path $ValidationArtifactDir $mdName)) { '`' + $mdName + '`' } else { '_missing_' }
    $lines.Add("| $phaseName | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'status')) | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'abort_reason')) | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'retryable')) | $(Format-Cell (Get-PropertyValue -Object $phase -Name 'human_action_required')) | $mdState |")
}
$lines.Add('')
$lines.Add('### Claude Cost By Phase')
$lines.Add('')
$lines.Add('| Phase | Cost | Turns | Input | Output | Cache create | Cache read |')
$lines.Add('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
foreach ($phaseCostRow in $phaseCostRows) { $lines.Add($phaseCostRow) }
$lines.Add('')
$lines.Add('### Evidence')
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('| --- | ---: |')
$lines.Add("| Screenshot artifacts | $screenshotCount |")
$lines.Add("| Validation artifact files | $validationArtifactCount |")
$lines.Add("| Claude result events | $($costSummary.Results) |")
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
$linesif ($publishedScreenshotImages.Count -gt 0) {
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