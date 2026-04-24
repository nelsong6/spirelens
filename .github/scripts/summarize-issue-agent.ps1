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

function Get-NumberProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return [decimal]0
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return [decimal]0
    }

    try {
        return [decimal]$property.Value
    } catch {
        return [decimal]0
    }
}

function Format-Count {
    param([decimal]$Value)
    return ('{0:N0}' -f $Value)
}

function Format-Dollar {
    param([decimal]$Value)
    return ('$' + ('{0:N4}' -f $Value))
}

function Add-UniqueMatch {
    param(
        [System.Collections.ArrayList]$List,
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    foreach ($match in [regex]::Matches($Text, $Pattern)) {
        $value = $match.Value.TrimEnd('.', ',', ')', ']')
        if (-not $List.Contains($value)) {
            [void]$List.Add($value)
        }
    }
}

function Format-UrlList {
    param(
        [System.Collections.ArrayList]$Urls,
        [string]$Kind
    )

    if ($Urls.Count -eq 0) {
        return '_Not detected_'
    }

    $links = @()
    foreach ($url in $Urls) {
        $label = $url
        if ($Kind -eq 'pull') {
            $match = [regex]::Match($url, '/pull/(\d+)')
            if ($match.Success) {
                $label = '#' + $match.Groups[1].Value
            }
        } elseif ($Kind -eq 'issue') {
            $match = [regex]::Match($url, '/issues/(\d+)(?:#issuecomment-(\d+))?')
            if ($match.Success) {
                $label = '#' + $match.Groups[1].Value
                if ($match.Groups[2].Success) {
                    $label = $label + ' comment'
                }
            }
        }
        $links += "[$label]($url)"
    }

    return ($links -join ', ')
}

$records = @()
if (-not [string]::IsNullOrWhiteSpace($EventLogPath) -and (Test-Path -LiteralPath $EventLogPath)) {
    foreach ($line in Get-Content -LiteralPath $EventLogPath -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $records += ($line | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-Warning "Unable to parse issue-agent event log line: $($_.Exception.Message)"
        }
    }
}

$pullRequestUrls = New-Object System.Collections.ArrayList
$issueUrls = New-Object System.Collections.ArrayList
$pullUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+'
$issueUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/\d+(?:#issuecomment-\d+)?'

$lastResult = $null
foreach ($record in $records) {
    $message = [string]$record.message
    Add-UniqueMatch -List $pullRequestUrls -Text $message -Pattern $pullUrlPattern
    Add-UniqueMatch -List $issueUrls -Text $message -Pattern $issueUrlPattern

    if ([string]$record.kind -eq 'result') {
        try {
            $lastResult = $message | ConvertFrom-Json -ErrorAction Stop
            Add-UniqueMatch -List $pullRequestUrls -Text ([string]$lastResult.result) -Pattern $pullUrlPattern
            Add-UniqueMatch -List $issueUrls -Text ([string]$lastResult.result) -Pattern $issueUrlPattern
        } catch {
            Write-Warning "Unable to parse Claude result payload: $($_.Exception.Message)"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($IssueNumber)) {
    $canonicalIssueUrl = "https://github.com/$RepoSlug/issues/$IssueNumber"
    if (-not $issueUrls.Contains($canonicalIssueUrl)) {
        [void]$issueUrls.Insert(0, $canonicalIssueUrl)
    }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            $issueJson = gh issue view $IssueNumber --repo $RepoSlug --comments --json comments 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($issueJson)) {
                $issue = $issueJson | ConvertFrom-Json -ErrorAction Stop
                foreach ($comment in @($issue.comments)) {
                    Add-UniqueMatch -List $pullRequestUrls -Text ([string]$comment.body) -Pattern $pullUrlPattern
                    Add-UniqueMatch -List $issueUrls -Text ([string]$comment.body) -Pattern $issueUrlPattern
                }
            }
        } catch {
            Write-Warning "Unable to inspect issue comments for PR links: $($_.Exception.Message)"
        }
    }
}

$artifactUrl = $null
if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($RunId) -and -not [string]::IsNullOrWhiteSpace($ArtifactName) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    try {
        $artifactsJson = gh api "repos/$RepoSlug/actions/runs/$RunId/artifacts" 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($artifactsJson)) {
            $artifacts = $artifactsJson | ConvertFrom-Json -ErrorAction Stop
            $artifact = @($artifacts.artifacts | Where-Object { $_.name -eq $ArtifactName } | Select-Object -First 1)
            if ($artifact.Count -gt 0 -and $artifact[0].id) {
                $artifactUrl = "https://github.com/$RepoSlug/actions/runs/$RunId/artifacts/$($artifact[0].id)"
            }
        }
    } catch {
        Write-Warning "Unable to resolve artifact URL: $($_.Exception.Message)"
    }
}

$toolUseCount = @($records | Where-Object { [string]$_.kind -eq 'tool_use' }).Count
$toolResultCount = @($records | Where-Object { [string]$_.kind -eq 'tool_result' }).Count
$assistantTextCount = @($records | Where-Object { [string]$_.kind -eq 'assistant_text' }).Count
$resultCount = @($records | Where-Object { [string]$_.kind -eq 'result' }).Count

$exitCodeText = '_Unknown_'
$exitRecord = @($records | Where-Object { [string]$_.kind -eq 'exit' } | Select-Object -Last 1)
if ($exitRecord.Count -gt 0) {
    $match = [regex]::Match([string]$exitRecord[0].message, '(-?\d+)\s*$')
    if ($match.Success) {
        $exitCodeText = $match.Groups[1].Value
    } else {
        $exitCodeText = [string]$exitRecord[0].message
    }
}

$modelName = '_Unavailable_'
$outcome = '_Unavailable_'
$terminalReason = '_Unavailable_'
$durationMs = [decimal]0
$durationApiMs = [decimal]0
$inputTokens = [decimal]0
$outputTokens = [decimal]0
$cacheCreationTokens = [decimal]0
$cacheReadTokens = [decimal]0
$reportedCostUsd = [decimal]0

if ($null -ne $lastResult) {
    if ($lastResult.subtype) {
        $outcome = [string]$lastResult.subtype
    } elseif ($lastResult.is_error) {
        $outcome = 'error'
    }

    if ($lastResult.terminal_reason) {
        $terminalReason = [string]$lastResult.terminal_reason
    }

    $durationMs = Get-NumberProperty -Object $lastResult -Name 'duration_ms'
    $durationApiMs = Get-NumberProperty -Object $lastResult -Name 'duration_api_ms'
    $reportedCostUsd = Get-NumberProperty -Object $lastResult -Name 'total_cost_usd'

    $usage = $lastResult.usage
    $inputTokens = Get-NumberProperty -Object $usage -Name 'input_tokens'
    $outputTokens = Get-NumberProperty -Object $usage -Name 'output_tokens'
    $cacheCreationTokens = Get-NumberProperty -Object $usage -Name 'cache_creation_input_tokens'
    $cacheReadTokens = Get-NumberProperty -Object $usage -Name 'cache_read_input_tokens'

    if ($cacheCreationTokens -eq 0 -and $usage.cache_creation) {
        $cacheCreationTokens = (Get-NumberProperty -Object $usage.cache_creation -Name 'ephemeral_1h_input_tokens') + (Get-NumberProperty -Object $usage.cache_creation -Name 'ephemeral_5m_input_tokens')
    }

    if ($lastResult.modelUsage) {
        $modelProperties = @($lastResult.modelUsage.PSObject.Properties)
        if ($modelProperties.Count -gt 0) {
            $modelName = $modelProperties[0].Name
            if ($reportedCostUsd -eq 0) {
                $reportedCostUsd = Get-NumberProperty -Object $modelProperties[0].Value -Name 'costUSD'
            }
        }
    }
}

$inputRatePerMillionUsd = [decimal]3.00
$outputRatePerMillionUsd = [decimal]15.00
$cacheCreationRatePerMillionUsd = [decimal]3.75
$cacheReadRatePerMillionUsd = [decimal]0.30
$totalTokens = $inputTokens + $outputTokens + $cacheCreationTokens + $cacheReadTokens
$calculatedCostUsd = (($inputTokens * $inputRatePerMillionUsd) + ($outputTokens * $outputRatePerMillionUsd) + ($cacheCreationTokens * $cacheCreationRatePerMillionUsd) + ($cacheReadTokens * $cacheReadRatePerMillionUsd)) / [decimal]1000000

$screenshotCount = 0
if (-not [string]::IsNullOrWhiteSpace($ScreenshotDir) -and (Test-Path -LiteralPath $ScreenshotDir)) {
    $screenshotCount = @(Get-ChildItem -LiteralPath $ScreenshotDir -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
}

$validationArtifactCount = 0
if (-not [string]::IsNullOrWhiteSpace($ValidationArtifactDir) -and (Test-Path -LiteralPath $ValidationArtifactDir)) {
    $validationArtifactCount = @(Get-ChildItem -LiteralPath $ValidationArtifactDir -Recurse -File -ErrorAction SilentlyContinue).Count
}

$runUrl = '_Unavailable_'
if (-not [string]::IsNullOrWhiteSpace($RepoSlug) -and -not [string]::IsNullOrWhiteSpace($RunId)) {
    $runUrl = "https://github.com/$RepoSlug/actions/runs/$RunId"
}

$artifactText = if ($artifactUrl) { "[$ArtifactName]($artifactUrl)" } elseif (-not [string]::IsNullOrWhiteSpace($ArtifactName)) { $ArtifactName } else { '_Unavailable_' }
$summaryLogText = if (-not [string]::IsNullOrWhiteSpace($SummaryLogPath)) { $SummaryLogPath } else { '_Unavailable_' }
$debugLogText = if (-not [string]::IsNullOrWhiteSpace($DebugLogPath)) { $DebugLogPath } else { '_Unavailable_' }
$durationText = if ($durationMs -gt 0) { ('{0:N1}s' -f ($durationMs / [decimal]1000)) } else { '_Unavailable_' }
$apiDurationText = if ($durationApiMs -gt 0) { ('{0:N1}s' -f ($durationApiMs / [decimal]1000)) } else { '_Unavailable_' }
$calculatedCostText = if ($totalTokens -gt 0) { Format-Dollar $calculatedCostUsd } else { '_Unavailable_' }
$reportedCostText = if ($reportedCostUsd -gt 0) { Format-Dollar $reportedCostUsd } else { '_Unavailable_' }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('## Issue Agent Summary')
$lines.Add('')
$lines.Add('| Field | Value |')
$lines.Add('| --- | --- |')
$lines.Add("| Issue | $(Format-UrlList -Urls $issueUrls -Kind 'issue') |")
$lines.Add("| Created PR | $(Format-UrlList -Urls $pullRequestUrls -Kind 'pull') |")
$lines.Add("| Run | [$RunId]($runUrl) |")
$lines.Add("| Artifact | $artifactText |")
$lines.Add("| Claude outcome | $outcome |")
$lines.Add("| Claude exit code | $exitCodeText |")
$lines.Add("| Terminal reason | $terminalReason |")
$lines.Add("| Head SHA | $HeadSha |")
$lines.Add("| Ref | $RefName |")
$lines.Add('')
$lines.Add('### Cost And Tokens')
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('| --- | ---: |')
$lines.Add("| Model | $modelName |")
$lines.Add("| Input tokens | $(Format-Count $inputTokens) |")
$lines.Add("| Output tokens | $(Format-Count $outputTokens) |")
$lines.Add("| Cache write tokens | $(Format-Count $cacheCreationTokens) |")
$lines.Add("| Cache read tokens | $(Format-Count $cacheReadTokens) |")
$lines.Add("| Total billable token events | $(Format-Count $totalTokens) |")
$lines.Add("| Calculated cost | $calculatedCostText |")
$lines.Add("| Claude-reported cost | $reportedCostText |")
$lines.Add('')
$lines.Add('Cost formula: `(input * $3.00/M) + (output * $15.00/M) + (cache write * $3.75/M) + (cache read * $0.30/M)`.')
$lines.Add('')
$lines.Add('### Validation And Activity')
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('| --- | ---: |')
$lines.Add("| Tool calls | $toolUseCount |")
$lines.Add("| Tool results | $toolResultCount |")
$lines.Add("| Assistant text events | $assistantTextCount |")
$lines.Add("| Result events | $resultCount |")
$lines.Add("| Duration | $durationText |")
$lines.Add("| API duration | $apiDurationText |")
$lines.Add("| Screenshot artifacts | $screenshotCount |")
$lines.Add("| Validation artifact files | $validationArtifactCount |")
$lines.Add('')
$lines.Add('### Log Pointers')
$lines.Add('')
$lines.Add('- Event log: `' + $EventLogPath + '`')
$lines.Add('- Summary log: `' + $summaryLogText + '`')
$lines.Add('- Debug log: `' + $debugLogText + '`')

$markdown = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $markdown | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
} else {
    Write-Host $markdown
}
