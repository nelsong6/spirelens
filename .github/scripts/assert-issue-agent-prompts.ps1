param(
    [string]$PromptScriptPath = (Join-Path $PSScriptRoot 'run-issue-agent-phases.ps1')
)

$ErrorActionPreference = 'Stop'

$blockedPatterns = @(
    @{ Pattern = 'For Make It So'; Reason = 'Card-specific prompt law belongs in issue body or fixtures, not generic phase prompts.' },
    @{ Pattern = 'MAKE_IT_SO plus'; Reason = 'Card-specific deck recipes must not be embedded in generic prompts.' },
    @{ Pattern = 'Watcher card'; Reason = 'STS1/legacy character assumptions must not be prompt examples.' },
    @{ Pattern = 'run_scenario_command'; Reason = 'Removed scenario-command surfaces must not appear in phase prompts.' },
    @{ Pattern = 'LiveScenarios/'; Reason = 'Legacy side-channel references must not be prompt examples.' }
)

$content = Get-Content -LiteralPath $PromptScriptPath -Raw
$findings = New-Object System.Collections.Generic.List[object]
foreach ($item in $blockedPatterns) {
    if ($content -match [regex]::Escape($item.Pattern)) {
        $findings.Add([ordered]@{ pattern = $item.Pattern; reason = $item.Reason }) | Out-Null
    }
}

if ($findings.Count -gt 0) {
    $findings | ConvertTo-Json -Depth 10 | Write-Host
    throw "Issue-agent prompt audit found hidden-policy/stale prompt patterns."
}

Write-Host "Issue-agent prompt audit passed."