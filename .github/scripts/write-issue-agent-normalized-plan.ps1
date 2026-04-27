param(
    [Parameter(Mandatory = $true)][string]$TestPlanPath,
    [Parameter(Mandatory = $true)][string]$ValidationArtifactDir
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $ValidationArtifactDir | Out-Null
$plan = Get-Content -LiteralPath $TestPlanPath -Raw | ConvertFrom-Json
$setup = $plan.scenario_setup
$deck = @($setup.deck)
$screenshotEvidence = @($plan.required_evidence | Where-Object { $_.kind -eq 'screenshot' })
$hazards = New-Object System.Collections.Generic.List[string]
if ($deck.Count -gt 5) { $hazards.Add("Deck has $($deck.Count) cards; target card may not be in opening hand unless justified.") | Out-Null }
$planText = $plan.validation_plan | ConvertTo-Json -Compress -Depth 50
foreach ($term in @('run_scenario_command','game input','dev-console')) { if ($planText -match [regex]::Escape($term)) { $hazards.Add("Plan references potentially stale/forbidden term '$term'.") | Out-Null } }

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Normalized Issue-Agent Test Plan')
$md.Add('')
$md.Add('| Field | Value |')
$md.Add('| --- | --- |')
$md.Add("| Target card | $($plan.card.id) / $($plan.card.name) |")
$md.Add("| Character | $($plan.character.id) / $($plan.character.name) |")
$md.Add("| Base save | $($setup.base_save_name) |")
$md.Add("| Scenario | $($setup.scenario_name) |")
$md.Add("| Deck size | $($deck.Count) |")
$md.Add("| Max energy | $($setup.max_energy) |")
$md.Add("| Encounter | $($setup.next_normal_encounter) |")
$md.Add('')
$md.Add('## Deck')
foreach ($card in $deck) { $md.Add("- `$card`") }
$md.Add('')
$md.Add('## Required Screenshots')
if ($screenshotEvidence.Count -eq 0) { $md.Add('- _None_') } else { foreach ($e in $screenshotEvidence) { $md.Add("- `$($e.id)`: $($e.must_show)") } }
$md.Add('')
$md.Add('## Hazards')
if ($hazards.Count -eq 0) { $md.Add('- _None detected by summary pass_') } else { foreach ($h in $hazards) { $md.Add("- $h") } }
$md.Add('')
$path = Join-Path $ValidationArtifactDir 'issue-agent-normalized-plan.md'
$md -join [Environment]::NewLine | Set-Content -LiteralPath $path -Encoding UTF8
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) { Get-Content -LiteralPath $path -Raw | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append }