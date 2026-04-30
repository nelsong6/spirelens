param(
    [Parameter(Mandatory = $true)][string]$IssueNumber,
    [Parameter(Mandatory = $true)][string]$RepoSlug,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ClaudeCliPath,
    [Parameter(Mandatory = $true)][string]$McpConfigPath,
    [Parameter(Mandatory = $true)][string]$StreamLogPath,
    [Parameter(Mandatory = $true)][string]$DebugLogPath,
    [Parameter(Mandatory = $true)][string]$SummaryLogPath,
    [Parameter(Mandatory = $true)][string]$ScreenshotDir,
    [Parameter(Mandatory = $true)][string]$ValidationArtifactDir,
    [ValidateSet('all', 'test_plan', 'implementation', 'verification')]
    [string]$PhaseName = 'all'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0  # V2 already catches missing PSCustomObject/hashtable properties; V3 adds out-of-bounds array indexing (verified empirically on PS 7.4)
$DefaultPhaseTimeoutSeconds = 360
$DefaultPhaseBudgetUsd = '15.00'

$CatalogMcpTools = @(
    'mcp__spire-lens-mcp__lookup_card',
    'mcp__spire-lens-mcp__lookup_character',
    'mcp__spire-lens-mcp__list_cards',
    'mcp__spire-lens-mcp__list_characters',
    'mcp__spire-lens-mcp__lookup_relic',
    'mcp__spire-lens-mcp__list_relics',
    'mcp__spire-lens-mcp__lookup_encounter',
    'mcp__spire-lens-mcp__list_encounters',
    'mcp__spire-lens-mcp__get_catalog_summary',
    'mcp__spire-lens-mcp__get_validation_capabilities'
)

$SingleplayerMcpTools = @(
    'mcp__spire-lens-mcp__capture_screenshot',
    'mcp__spire-lens-mcp__get_game_state',
    'mcp__spire-lens-mcp__bridge_health',
    'mcp__spire-lens-mcp__reload_spirelens_core',
    'mcp__spire-lens-mcp__set_spirelens_view_stats_enabled',
    'mcp__spire-lens-mcp__open_card_pile',
    'mcp__spire-lens-mcp__close_card_pile',
    'mcp__spire-lens-mcp__list_visible_cards',
    'mcp__spire-lens-mcp__show_card_tooltip',
    'mcp__spire-lens-mcp__list_visible_relics',
    'mcp__spire-lens-mcp__show_relic_tooltip',
    'mcp__spire-lens-mcp__start_singleplayer_run',
    'mcp__spire-lens-mcp__enter_debug_room',
    'mcp__spire-lens-mcp__configure_live_combat',
    'mcp__spire-lens-mcp__list_save_files',
    'mcp__spire-lens-mcp__inspect_save',
    'mcp__spire-lens-mcp__materialize_scenario_save',
    'mcp__spire-lens-mcp__install_save_as_current',
    'mcp__spire-lens-mcp__validate_current_run_save',
    'mcp__spire-lens-mcp__load_current_run_save',
    'mcp__spire-lens-mcp__combat_play_card',
    'mcp__spire-lens-mcp__combat_end_turn',
    'mcp__spire-lens-mcp__combat_select_card',
    'mcp__spire-lens-mcp__combat_confirm_selection',
    'mcp__spire-lens-mcp__use_potion',
    'mcp__spire-lens-mcp__discard_potion',
    'mcp__spire-lens-mcp__proceed_to_map',
    'mcp__spire-lens-mcp__rewards_claim',
    'mcp__spire-lens-mcp__rewards_pick_card',
    'mcp__spire-lens-mcp__rewards_skip_card',
    'mcp__spire-lens-mcp__map_choose_node',
    'mcp__spire-lens-mcp__rest_choose_option',
    'mcp__spire-lens-mcp__shop_purchase',
    'mcp__spire-lens-mcp__event_choose_option',
    'mcp__spire-lens-mcp__event_advance_dialogue',
    'mcp__spire-lens-mcp__deck_select_card',
    'mcp__spire-lens-mcp__deck_confirm_selection',
    'mcp__spire-lens-mcp__deck_cancel_selection',
    'mcp__spire-lens-mcp__bundle_select',
    'mcp__spire-lens-mcp__bundle_confirm_selection',
    'mcp__spire-lens-mcp__bundle_cancel_selection',
    'mcp__spire-lens-mcp__relic_select',
    'mcp__spire-lens-mcp__relic_skip',
    'mcp__spire-lens-mcp__treasure_claim_relic',
    'mcp__spire-lens-mcp__crystal_sphere_set_tool',
    'mcp__spire-lens-mcp__crystal_sphere_click_cell',
    'mcp__spire-lens-mcp__crystal_sphere_proceed'
)

$MultiplayerMcpTools = @(
    'mcp__spire-lens-mcp__mp_get_game_state',
    'mcp__spire-lens-mcp__mp_combat_play_card',
    'mcp__spire-lens-mcp__mp_combat_end_turn',
    'mcp__spire-lens-mcp__mp_combat_undo_end_turn',
    'mcp__spire-lens-mcp__mp_combat_select_card',
    'mcp__spire-lens-mcp__mp_combat_confirm_selection',
    'mcp__spire-lens-mcp__mp_use_potion',
    'mcp__spire-lens-mcp__mp_discard_potion',
    'mcp__spire-lens-mcp__mp_proceed_to_map',
    'mcp__spire-lens-mcp__mp_rewards_claim',
    'mcp__spire-lens-mcp__mp_rewards_pick_card',
    'mcp__spire-lens-mcp__mp_rewards_skip_card',
    'mcp__spire-lens-mcp__mp_map_vote',
    'mcp__spire-lens-mcp__mp_rest_choose_option',
    'mcp__spire-lens-mcp__mp_shop_purchase',
    'mcp__spire-lens-mcp__mp_event_choose_option',
    'mcp__spire-lens-mcp__mp_event_advance_dialogue',
    'mcp__spire-lens-mcp__mp_deck_select_card',
    'mcp__spire-lens-mcp__mp_deck_confirm_selection',
    'mcp__spire-lens-mcp__mp_deck_cancel_selection',
    'mcp__spire-lens-mcp__mp_bundle_select',
    'mcp__spire-lens-mcp__mp_bundle_confirm_selection',
    'mcp__spire-lens-mcp__mp_bundle_cancel_selection',
    'mcp__spire-lens-mcp__mp_relic_select',
    'mcp__spire-lens-mcp__mp_relic_skip',
    'mcp__spire-lens-mcp__mp_treasure_claim_relic',
    'mcp__spire-lens-mcp__mp_crystal_sphere_set_tool',
    'mcp__spire-lens-mcp__mp_crystal_sphere_click_cell',
    'mcp__spire-lens-mcp__mp_crystal_sphere_proceed'
)

$AllSpireLensMcpTools = $CatalogMcpTools + $SingleplayerMcpTools + $MultiplayerMcpTools


$phaseDefinitions = @(
    [ordered]@{
        Name = 'test_plan'
        Json = 'issue-agent-test-plan.json'
        Markdown = 'issue-agent-test-plan.md'
        TimeoutSeconds = 480
        MaxBudgetUsd = '3.00'
        AllowedAbortReasons = @('card_not_found', 'card_ambiguous', 'character_not_found', 'metadata_unavailable', 'mcp_capability_missing', 'game_state_unreachable', 'validation_plan_impossible', 'phase_timeout')
        AllowedTools = @(
            'Read',
            'Write',
            'Glob',
            'Grep',
            'ToolSearch',
            'Bash(gh issue view *)',
            'Bash(rg *)',
            'Bash(git grep *)'
        ) + $CatalogMcpTools
        DisallowedTools = $SingleplayerMcpTools + $MultiplayerMcpTools + @(
            'Bash(gh issue view *--comments*)',
            'Bash(gh api *)',
            'Edit',
            'NotebookEdit',
            'WebFetch',
            'WebSearch',
            'Agent',
            'Task',
            'TaskOutput',
            'TaskStop'
        )
    },
    [ordered]@{
        Name = 'implementation'
        Json = 'issue-agent-implementation.json'
        Markdown = 'issue-agent-implementation.md'
        TimeoutSeconds = 1800
        MaxBudgetUsd = '12.00'
        AllowedAbortReasons = @('change_too_large', 'requires_new_library', 'requires_architecture_change', 'unsafe_refactor', 'missing_code_context', 'conflicting_requirements', 'cannot_implement_without_guessing', 'phase_timeout')
        AllowedTools = @(
            'Read',
            'Write',
            'Edit',
            'Glob',
            'Grep',
            'ToolSearch',
            'TodoWrite',
            'Bash',
            'PowerShell',
            'Bash(gh issue view *)',
            'PowerShell(gh issue view *)'
        ) + $CatalogMcpTools
        DisallowedTools = $SingleplayerMcpTools + $MultiplayerMcpTools + @(
            'Bash(dotnet test *)',
            'PowerShell(dotnet test *)',
            'Read(C:\Users\*\.claude\*)',
            'Read(C:\Users\*\.claude\**)',
            'Bash(gh issue view *--comments*)',
            'PowerShell(gh issue view *--comments*)',
            'Bash(gh api *)',
            'PowerShell(gh api *)',
            'Bash(gh issue comment *)',
            'PowerShell(gh issue comment *)',
            'Bash(gh issue edit *)',
            'PowerShell(gh issue edit *)',
            'Bash(gh pr *)',
            'PowerShell(gh pr *)',
            'Bash(git add *)',
            'PowerShell(git add *)',
            'Bash(git branch *)',
            'PowerShell(git branch *)',
            'Bash(git checkout *)',
            'PowerShell(git checkout *)',
            'Bash(git commit *)',
            'PowerShell(git commit *)',
            'Bash(git push *)',
            'PowerShell(git push *)',
            'mcp__spire-lens-mcp__list_save_files',
            'mcp__spire-lens-mcp__inspect_save',
            'mcp__spire-lens-mcp__materialize_scenario_save',
            'mcp__spire-lens-mcp__install_save_as_current',
            'mcp__spire-lens-mcp__validate_current_run_save',
            'mcp__spire-lens-mcp__load_current_run_save',
            'mcp__spire-lens-mcp__list_scenario_commands',
            'mcp__spire-lens-mcp__run_scenario_command',
            'Bash(git switch *)',
            'PowerShell(git switch *)',
            'WebFetch',
            'WebSearch',
            'Agent',
            'Task',
            'TaskOutput',
            'TaskStop'
        )
    },
    [ordered]@{
        Name = 'verification'
        Json = 'issue-agent-verification.json'
        Markdown = 'issue-agent-verification.md'
        TimeoutSeconds = 600
        MaxBudgetUsd = '6.00'
        AllowedAbortReasons = @('unit_tests_failed', 'live_validation_failed', 'screenshot_missing', 'screenshot_not_relevant', 'target_evidence_missing', 'mcp_state_mismatch', 'game_state_unreachable', 'claimed_result_not_observed', 'artifact_contract_missing', 'phase_timeout')
        AllowedTools = @(
            'Read',
            'Write',
            'Glob',
            'Grep',
            'ToolSearch',
            'TodoWrite',
            'Bash',
            'PowerShell'
        ) + $CatalogMcpTools + $SingleplayerMcpTools
        DisallowedTools = $MultiplayerMcpTools + @(
            'Edit',
            'NotebookEdit',
            'Bash(gh *)',
            'PowerShell(gh *)',
            'Bash(git add *)',
            'PowerShell(git add *)',
            'Bash(git branch *)',
            'PowerShell(git branch *)',
            'Bash(git checkout *)',
            'PowerShell(git checkout *)',
            'Bash(git commit *)',
            'PowerShell(git commit *)',
            'Bash(git push *)',
            'PowerShell(git push *)',
            'Bash(git switch *)',
            'PowerShell(git switch *)',
            'WebFetch',
            'WebSearch',
            'Agent',
            'Task',
            'TaskOutput',
            'TaskStop'
        )
    }
)

function Get-ToolFailureCategory {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Successful test summaries often contain the word "Failed" as a zero count.
    # Count only actual failures, not lines like "Passed! - Failed: 0".
    if ($Text -match '(?i)\bPassed!\s*-\s*Failed:\s*0\b') { return $null }
    if ($Text -match '(?i)\bFailed:\s*0\b' -and
        $Text -notmatch '(?im)^\s*(error|exception|traceback):' -and
        $Text -notmatch '(?i)\b(exit code [1-9]\d*|unauthorized|forbidden)\b') { return $null }

    if ($Text -match '(?i)permission to use .* has been denied|permission_denied|permission denied|not allowed to use tool|disallowed') { return 'permission_denied' }
    if ($Text -match '(?i)\b(500|internal server error)\b') { return 'server_error' }
    if ($Text -match '(?i)\b(timed out|timeout)\b') { return 'timeout' }
    if ($Text -match '(?im)^\s*(error|exception|traceback):') { return 'tool_error' }
    if ($Text -match '(?i)\bFailed:\s*[1-9]\d*\b|\bfailures?:\s*[1-9]\d*\b') { return 'tool_error' }
    if ($Text -match '(?i)\b(exit code [1-9]\d*|exception|traceback|unauthorized|forbidden|not found)\b') { return 'tool_error' }
    return $null
}
function Write-AgentEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Data = $null
    )

    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        kind = $Kind
        message = $Message
    }
    if ($null -ne $Data) { $record.data = $Data }

    $json = $record | ConvertTo-Json -Compress -Depth 30
    Add-Content -LiteralPath $StreamLogPath -Value $json -Encoding UTF8
    Write-Host "[$Kind] $Message"
}

function Add-JobSummaryMarkdown {
    param(
        [string]$Title,
        [string]$MarkdownPath
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) { return }

    "## $Title" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    '' | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    if (Test-Path -LiteralPath $MarkdownPath) {
        Get-Content -LiteralPath $MarkdownPath -Raw | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    } else {
        '_No phase markdown was written._' | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
    '' | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file was not written: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Required JSON file '$Path' is invalid: $($_.Exception.Message)"
    }
}

function Get-PropertyValue {
    # PS7 note: PSObject.Properties on [ordered]@{}/[hashtable] does not expose entries
    # the way it did in PS5. Branch on IDictionary so this helper works for both shapes.
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

function Set-PropertyValue {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    } else {
        $property.Value = $Value
    }
}

function Write-SyntheticRollup {
    param(
        [string]$AbortLayer,
        [string]$AbortReason,
        [string]$Notes
    )

    $rollupPath = Join-Path $ValidationArtifactDir 'issue-agent-result.json'
    $rollup = [ordered]@{
        issue_number = [int]$IssueNumber
        status = 'blocked'
        abort_layer = $AbortLayer
        abort_reason = $AbortReason
        retryable = $false
        human_action_required = $true
        layers = [ordered]@{
            test_plan = [ordered]@{ status = 'not_run'; abort_reason = $null }
            implementation = [ordered]@{ status = 'not_run'; abort_reason = $null }
            verification = [ordered]@{ status = 'not_run'; abort_reason = $null }
        }
        unit_tests = [ordered]@{ passed = $null; status = 'blocked'; notes = '' }
        live_mcp_validation = [ordered]@{ passed = $null; status = 'blocked'; notes = '' }
        screenshot_validation = [ordered]@{ passed = $null; status = 'blocked'; count = 0; notes = '' }
        card_metadata_discovery = [ordered]@{ passed = $null; status = 'blocked'; notes = '' }
        used_mcp = $null
        used_raw_bridge_or_queue = $null
        opened_pr = $null
        opened_pr_url = $null
        should_close_issue = $false
        evidence_summary = @($Notes)
    }
    if ($rollup.layers.Contains($AbortLayer)) {
        $rollup.layers[$AbortLayer].status = 'abort'
        $rollup.layers[$AbortLayer].abort_reason = $AbortReason
    }
    $rollup | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rollupPath -Encoding UTF8
}

function Write-SyntheticPhaseAbort {
    param([hashtable]$Phase, [string]$AbortReason, [string]$Notes)

    $phaseName = $Phase.Name
    $phaseJsonPath = Join-Path $ValidationArtifactDir $Phase.Json
    $phaseMarkdownPath = Join-Path $ValidationArtifactDir $Phase.Markdown
    [ordered]@{
        layer = $phaseName
        status = 'abort'
        abort_reason = $AbortReason
        retryable = $true
        human_action_required = $true
        notes = $Notes
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $phaseJsonPath -Encoding UTF8

    @"
Status: abort

Abort reason: $AbortReason

$Notes
"@ | Set-Content -LiteralPath $phaseMarkdownPath -Encoding UTF8
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    $result = '"'
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') { $backslashes++ }
        elseif ($char -eq '"') {
            $result += ('\' * (($backslashes * 2) + 1))
            $result += '"'
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { $result += ('\' * $backslashes) }
            $result += $char
            $backslashes = 0
        }
    }
    if ($backslashes -gt 0) { $result += ('\' * ($backslashes * 2)) }
    return $result + '"'
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutSeconds,
        [string]$PhaseName
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stdoutDone = $false
    $stderrDone = $false
    $stdoutTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadLineAsync()

    while (-not ($process.HasExited -and $stdoutDone -and $stderrDone)) {
        $madeProgress = $false

        if (-not $stdoutDone -and $stdoutTask.Wait(25)) {
            $line = $stdoutTask.Result
            if ($null -eq $line) {
                $stdoutDone = $true
            } else {
                Add-Content -LiteralPath $StdoutPath -Value $line -Encoding UTF8
                Write-ClaudeOutputLine -Line $line -PhaseName $PhaseName
                $stdoutTask = $process.StandardOutput.ReadLineAsync()
            }
            $madeProgress = $true
        }

        if (-not $stderrDone -and $stderrTask.Wait(25)) {
            $line = $stderrTask.Result
            if ($null -eq $line) {
                $stderrDone = $true
            } else {
                Add-Content -LiteralPath $StderrPath -Value $line -Encoding UTF8
                Write-ClaudeOutputLine -Line $line -PhaseName $PhaseName
                $stderrTask = $process.StandardError.ReadLineAsync()
            }
            $madeProgress = $true
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            return [ordered]@{ TimedOut = $true; ExitCode = $null }
        }

        if (-not $madeProgress) { Start-Sleep -Milliseconds 50 }
    }

    try { $process.WaitForExit(5000) | Out-Null } catch {}
    return [ordered]@{ TimedOut = $false; ExitCode = $process.ExitCode }
}

function Write-ClaudeOutputLine {
    param([string]$Line, [string]$PhaseName)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try {
        $event = $Line | ConvertFrom-Json -ErrorAction Stop
        if ($event.type -eq 'assistant' -and $event.message.content) {
            foreach ($block in $event.message.content) {
                if ($block.type -eq 'tool_use') {
                    $inputJson = if ($null -ne $block.input) { $block.input | ConvertTo-Json -Compress -Depth 20 } else { '{}' }
                    $message = "$($block.name) $inputJson"
                    Write-AgentEvent 'tool_use' $message @{ phase = $PhaseName }
                    Add-Content -LiteralPath $SummaryLogPath -Value "${PhaseName} tool_use: $message" -Encoding UTF8
                } elseif ($block.type -eq 'text' -and -not [string]::IsNullOrWhiteSpace([string]$block.text)) {
                    $text = [string]$block.text
                    if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) + '... [truncated]' }
                    Write-AgentEvent 'assistant_text' $text @{ phase = $PhaseName }
                    Add-Content -LiteralPath $SummaryLogPath -Value "${PhaseName} assistant_text: $text" -Encoding UTF8
                }
            }
        } elseif ($event.type -eq 'user' -and $event.tool_use_result) {
            $result = [string]$event.tool_use_result
            if ($result.Length -gt 600) { $result = $result.Substring(0, 600) + '... [truncated]' }
            $failureCategory = Get-ToolFailureCategory -Text $result
            $toolResultData = [ordered]@{
                phase = $PhaseName
                failed = -not [string]::IsNullOrWhiteSpace($failureCategory)
                failure_category = $failureCategory
            }
            Write-AgentEvent 'tool_result' $result $toolResultData
            $statusLabel = if ($toolResultData.failed) { " failed[$failureCategory]" } else { '' }
            Add-Content -LiteralPath $SummaryLogPath -Value "${PhaseName} tool_result$($statusLabel): $result" -Encoding UTF8
        } elseif ($event.type -eq 'result') {
            $resultJson = $event | ConvertTo-Json -Compress -Depth 30
            Write-AgentEvent 'result' $resultJson @{ phase = $PhaseName }
            Add-Content -LiteralPath $SummaryLogPath -Value "${PhaseName} result: $resultJson" -Encoding UTF8
        } else {
            Write-AgentEvent 'raw' $Line @{ phase = $PhaseName }
        }
    } catch {
        Write-AgentEvent 'raw' $Line @{ phase = $PhaseName }
    }
}

function Write-ClaudeOutputLines {
    param([string]$Path, [string]$PhaseName)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        Write-ClaudeOutputLine -Line ([string]$_) -PhaseName $PhaseName
    }
}
function ConvertTo-Array {
    # Returns the input as a plain array. An earlier `return ,@(...)` variant
    # preserved array shape on assignment but broke the pipe form:
    #     ConvertTo-Array $x | Where-Object { ... }
    # would deliver the whole inner array as a single $_ instead of iterating
    # each element, silently corrupting Assert-Entries and the verification
    # evidence guards. Empirically verified in pwsh 7.4. The shape-preservation
    # responsibility now sits at .Count call sites: wrap with @(...) at the
    # caller, e.g. `if (@(ConvertTo-Array $x).Count -eq 0) { ... }`.
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Get-TextBlob {
    param([object[]]$Values)

    return (($Values | ForEach-Object { if ($null -ne $_) { [string]$_ } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
}

function Test-TextMentionsUnavailableEvidence {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return $Text -match '(?i)(not achievable|not available|unavailable|not renderable|cannot render|cannot be made visible|without mouse hover|no hover support|unit tests? (directly |exclusively |fully )?verif|verified exclusively through unit tests)'
}

function Test-TextMentionsFailedTests {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)\b(partial|regressions?|failing)\b') { return $true }
    return $Text -match '(?i)\b[1-9][0-9]*\s+(?:\S+\s+){0,4}(?:fail(?:ed|s|ures?)?|regressions?)\b'
}

function Set-VerificationGuardAbort {
    param(
        [object]$Result,
        [string]$JsonPath,
        [string]$MarkdownPath,
        [string]$AbortReason,
        [string]$GuardNote
    )

    Set-PropertyValue -Object $Result -Name 'status' -Value 'abort'
    Set-PropertyValue -Object $Result -Name 'abort_reason' -Value $AbortReason
    Set-PropertyValue -Object $Result -Name 'retryable' -Value $true
    Set-PropertyValue -Object $Result -Name 'human_action_required' -Value $false
    $existingNotes = [string](Get-PropertyValue -Object $Result -Name 'notes')
    Set-PropertyValue -Object $Result -Name 'notes' -Value (($existingNotes, $GuardNote | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')

    $screenshotValidation = Get-PropertyValue -Object $Result -Name 'screenshot_validation'
    if ($null -ne $screenshotValidation -and $AbortReason -in @('screenshot_not_relevant', 'target_evidence_missing', 'artifact_contract_missing')) {
        Set-PropertyValue -Object $screenshotValidation -Name 'passed' -Value $false
        Set-PropertyValue -Object $screenshotValidation -Name 'status' -Value 'abort'
        $existingScreenshotNotes = [string](Get-PropertyValue -Object $screenshotValidation -Name 'notes')
        Set-PropertyValue -Object $screenshotValidation -Name 'notes' -Value (($existingScreenshotNotes, $GuardNote | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')
        if ($AbortReason -ne 'artifact_contract_missing') {
            Set-PropertyValue -Object $screenshotValidation -Name 'target_visible' -Value $false
        }
    }

    $Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
    @"
Status: abort

Abort reason: $AbortReason

$GuardNote
"@ | Set-Content -LiteralPath $MarkdownPath -Encoding UTF8
    return (Read-JsonFile -Path $JsonPath)
}

function Apply-VerificationEvidenceGuard {
    param([object]$Result, [string]$JsonPath, [string]$MarkdownPath)

    $status = [string](Get-PropertyValue -Object $Result -Name 'status')
    if ($status -ne 'pass') { return $Result }

    $testPlanPath = Join-Path $ValidationArtifactDir 'issue-agent-test-plan.json'
    if (-not (Test-Path -LiteralPath $testPlanPath)) {
        return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'artifact_contract_missing' -GuardNote 'Verification cannot pass because the test-plan evidence contract is missing.'
    }

    $testPlan = Read-JsonFile -Path $testPlanPath
    # Wrap pipeline output in @(...) so .Count is safe under StrictMode when
    # Where-Object filters down to zero items (would otherwise return $null).
    $requiredEvidence = @(ConvertTo-Array (Get-PropertyValue -Object $testPlan -Name 'required_evidence') | Where-Object { (Get-PropertyValue -Object $_ -Name 'required') -ne $false })
    if ($requiredEvidence.Count -eq 0) {
        return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'artifact_contract_missing' -GuardNote 'Verification cannot pass because test planning did not declare required_evidence. The verifier needs an explicit evidence contract before it can pass.'
    }

    # Wrap with @(...) at the call site so the assignment preserves array shape
    # through PS's empty-/single-item return unwrap (otherwise .Count throws).
    $evidenceResults = @(ConvertTo-Array (Get-PropertyValue -Object $Result -Name 'evidence_results'))
    if ($evidenceResults.Count -eq 0) {
        return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'artifact_contract_missing' -GuardNote 'Verification cannot pass because it did not write evidence_results for the test-plan evidence contract.'
    }

    $unitTests = Get-PropertyValue -Object $Result -Name 'unit_tests'
    if ($null -ne $unitTests) {
        $unitPassed = Get-PropertyValue -Object $unitTests -Name 'passed'
        $unitStatus = [string](Get-PropertyValue -Object $unitTests -Name 'status')
        $unitNotes = [string](Get-PropertyValue -Object $unitTests -Name 'notes')
        $unitText = Get-TextBlob @($unitStatus, $unitNotes)
        if ($unitPassed -eq $false -or (Test-TextMentionsFailedTests -Text $unitText)) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'unit_tests_failed' -GuardNote 'Verification cannot pass because unit test results mention failed, partial, or regressed tests. Fix the tests or abort with unit_tests_failed.'
        }
    }

    $unitEvidenceText = Get-TextBlob @(
        $evidenceResults |
            Where-Object { [string](Get-PropertyValue -Object $_ -Name 'kind') -eq 'unit_test' } |
            ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'notes') }
    )
    if (Test-TextMentionsFailedTests -Text $unitEvidenceText) {
        return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'unit_tests_failed' -GuardNote 'Verification cannot pass because unit-test evidence notes mention failed or regressed tests.'
    }

    $screenshotValidation = Get-PropertyValue -Object $Result -Name 'screenshot_validation'
    $screenshotNotes = [string](Get-PropertyValue -Object $screenshotValidation -Name 'notes')
    $overallNotes = [string](Get-PropertyValue -Object $Result -Name 'notes')
    $allNotes = Get-TextBlob @($overallNotes, $screenshotNotes)

    foreach ($required in $requiredEvidence) {
        $id = [string](Get-PropertyValue -Object $required -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id)) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'artifact_contract_missing' -GuardNote 'Verification cannot pass because a required_evidence item has no id.'
        }

        $match = @($evidenceResults | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'evidence_id') -eq $id })
        if ($match.Count -eq 0) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'artifact_contract_missing' -GuardNote "Verification cannot pass because evidence_results does not include required evidence '$id'."
        }

        $evidenceResult = $match[0]
        if ((Get-PropertyValue -Object $evidenceResult -Name 'passed') -ne $true) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'claimed_result_not_observed' -GuardNote "Verification cannot pass because required evidence '$id' was not marked passed."
        }

        $kind = [string](Get-PropertyValue -Object $required -Name 'kind')
        if ($kind -eq 'screenshot') {
            $artifactPaths = @(ConvertTo-Array (Get-PropertyValue -Object $evidenceResult -Name 'artifact_paths'))
            $targetVisible = Get-PropertyValue -Object $evidenceResult -Name 'target_visible'
            if ($artifactPaths.Count -eq 0) {
                return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'screenshot_missing' -GuardNote "Verification cannot pass because screenshot evidence '$id' has no artifact_paths."
            }
            if ($targetVisible -ne $true) {
                return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'screenshot_not_relevant' -GuardNote "Verification cannot pass because screenshot evidence '$id' does not explicitly mark target_visible=true."
            }

            $mustShow = [string](Get-PropertyValue -Object $required -Name 'must_show')
            $requiresText = (Get-PropertyValue -Object $required -Name 'text_visible_required') -eq $true -or $mustShow -match '(?i)tooltip|text|label|wording|string'
            if ($requiresText) {
                $textVisible = Get-PropertyValue -Object $evidenceResult -Name 'text_visible'
                if ($textVisible -ne $true) {
                    return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'target_evidence_missing' -GuardNote "Verification cannot pass because screenshot evidence '$id' must show text/tooltip content, but evidence_results did not mark text_visible=true."
                }
                $observedText = [string](Get-PropertyValue -Object $evidenceResult -Name 'observed_text')
                if ([string]::IsNullOrWhiteSpace($observedText)) {
                    return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'target_evidence_missing' -GuardNote "Verification cannot pass because screenshot evidence '$id' must show text/tooltip content, but observed_text is empty."
                }
            }
        }
    }

    $screenshotRequired = @($requiredEvidence | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'kind') -eq 'screenshot' })
    if ($screenshotRequired.Count -gt 0) {
        $targetVisible = Get-PropertyValue -Object $screenshotValidation -Name 'target_visible'
        $screenshotPassed = Get-PropertyValue -Object $screenshotValidation -Name 'passed'
        $screenshotCount = Get-PropertyValue -Object $screenshotValidation -Name 'count'
        if ($screenshotPassed -ne $true -or $targetVisible -ne $true -or [int]$screenshotCount -lt 1) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'screenshot_not_relevant' -GuardNote 'Verification cannot pass because screenshot_validation does not show passed=true, target_visible=true, and count >= 1 for required screenshot evidence.'
        }
        if (Test-TextMentionsUnavailableEvidence -Text $allNotes) {
            return Set-VerificationGuardAbort -Result $Result -JsonPath $JsonPath -MarkdownPath $MarkdownPath -AbortReason 'target_evidence_missing' -GuardNote 'Verification cannot pass because its notes say required visual evidence was unavailable or only covered by unit tests.'
        }
    }

    return $Result
}

function Assert-ScenarioIdValidationEntries {
    param(
        [object]$Setup,
        [object]$Validation
    )

    function Normalize-ScenarioCatalogId {
        param(
            [object]$Value,
            [string]$Prefix
        )

        $text = ([string]$Value).Trim().ToUpperInvariant()
        $marker = "$($Prefix.ToUpperInvariant())."
        if ($text.StartsWith($marker, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $text.Substring($marker.Length)
        }
        return $text
    }

    function Assert-Entries {
        param(
            [object[]]$Expected,
            [string]$Kind,
            [string]$Field,
            [string]$Prefix
        )

        if (@($Expected).Count -eq 0) { return }
        $entries = ConvertTo-Array (Get-PropertyValue -Object $Validation -Name $Kind) |
            Where-Object { [string](Get-PropertyValue -Object $_ -Name 'field') -eq $Field }
        foreach ($value in $Expected) {
            $text = [string]$value
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $matching = $entries | Where-Object {
                [string](Get-PropertyValue -Object $_ -Name 'input') -eq $text -and
                -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $_ -Name 'id')) -and
                -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $_ -Name 'source'))
            } | Select-Object -First 1
            if ($null -eq $matching) {
                throw "scenario_id_validation.$Kind is missing validated entry for scenario_setup.$Field value '$text'."
            }
            $validatedId = [string](Get-PropertyValue -Object $matching -Name 'id')
            if ((Normalize-ScenarioCatalogId -Value $text -Prefix $Prefix) -ne (Normalize-ScenarioCatalogId -Value $validatedId -Prefix $Prefix)) {
                throw "scenario_setup.$Field value '$text' must already be the exact resolved catalog id, but scenario_id_validation.$Kind resolved it to '$validatedId'."
            }
        }
    }

    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'deck')) -Kind 'cards' -Field 'deck' -Prefix 'CARD'
    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'add_cards')) -Kind 'cards' -Field 'add_cards' -Prefix 'CARD'
    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'remove_cards')) -Kind 'cards' -Field 'remove_cards' -Prefix 'CARD'
    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'relics')) -Kind 'relics' -Field 'relics' -Prefix 'RELIC'
    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'add_relics')) -Kind 'relics' -Field 'add_relics' -Prefix 'RELIC'
    Assert-Entries -Expected (ConvertTo-Array (Get-PropertyValue -Object $Setup -Name 'remove_relics')) -Kind 'relics' -Field 'remove_relics' -Prefix 'RELIC'

    $encounter = [string](Get-PropertyValue -Object $Setup -Name 'next_normal_encounter')
    if (-not [string]::IsNullOrWhiteSpace($encounter)) {
        $entries = ConvertTo-Array (Get-PropertyValue -Object $Validation -Name 'encounters')
        $matching = $entries | Where-Object {
            [string](Get-PropertyValue -Object $_ -Name 'field') -eq 'next_normal_encounter' -and
            [string](Get-PropertyValue -Object $_ -Name 'input') -eq $encounter -and
            -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $_ -Name 'id')) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $_ -Name 'source'))
        } | Select-Object -First 1
        if ($null -eq $matching) {
            throw "scenario_id_validation.encounters is missing validated entry for scenario_setup.next_normal_encounter value '$encounter'."
        }
        $validatedEncounterId = [string](Get-PropertyValue -Object $matching -Name 'id')
        if ((Normalize-ScenarioCatalogId -Value $encounter -Prefix 'ENCOUNTER') -ne (Normalize-ScenarioCatalogId -Value $validatedEncounterId -Prefix 'ENCOUNTER')) {
            throw "scenario_setup.next_normal_encounter value '$encounter' must already be the exact resolved catalog id, but scenario_id_validation.encounters resolved it to '$validatedEncounterId'."
        }
    }
}

function Test-ScenarioSetupHasEntries {
    param(
        [object]$Setup,
        [string[]]$Fields
    )

    foreach ($field in $Fields) {
        $value = Get-PropertyValue -Object $Setup -Name $field
        $arrayLike = ($value -is [array]) -or (($value -is [System.Collections.IEnumerable]) -and ($value -isnot [string]))
        if ($arrayLike) {
            if (@(ConvertTo-Array $value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                return $true
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $true
        }
    }

    return $false
}

function Assert-PhaseContract {
    param(
        [hashtable]$Phase,
        [object]$Result
    )

    $status = [string](Get-PropertyValue -Object $Result -Name 'status')
    if ($status -notin @('pass', 'abort')) {
        throw "Phase '$($Phase.Name)' wrote invalid status '$status'. Expected pass or abort."
    }

    $abortReason = Get-PropertyValue -Object $Result -Name 'abort_reason'
    if ($status -eq 'abort') {
        if ([string]::IsNullOrWhiteSpace([string]$abortReason)) {
            throw "Phase '$($Phase.Name)' aborted without abort_reason."
        }
        if ([string]$abortReason -notin $Phase.AllowedAbortReasons) {
            throw "Phase '$($Phase.Name)' used abort_reason '$abortReason', outside allowed enum."
        }
    }

    if ($Phase.Name -eq 'test_plan' -and $status -eq 'pass') {
        $scenarioSetup = Get-PropertyValue -Object $Result -Name 'scenario_setup'
        if ($null -eq $scenarioSetup) {
            throw "Test planning phase pass result must include scenario_setup."
        }

        $scenarioIdValidation = Get-PropertyValue -Object $Result -Name 'scenario_id_validation'
        if ($null -eq $scenarioIdValidation -or (Get-PropertyValue -Object $scenarioIdValidation -Name 'passed') -ne $true) {
            throw "Test planning phase pass result must include scenario_id_validation.passed=true for every scenario card/relic/encounter id."
        }

        Assert-ScenarioIdValidationEntries -Setup $scenarioSetup -Validation $scenarioIdValidation

        if (Test-ScenarioSetupHasEntries -Setup $scenarioSetup -Fields @('deck', 'add_cards', 'remove_cards')) {
            $cardDiscovery = Get-PropertyValue -Object $Result -Name 'card_metadata_discovery'
            if ($null -eq $cardDiscovery -or (Get-PropertyValue -Object $cardDiscovery -Name 'passed') -ne $true) {
                throw "Test planning phase pass result must include card_metadata_discovery.passed=true when scenario_setup contains card ids."
            }
        }

        if (Test-ScenarioSetupHasEntries -Setup $scenarioSetup -Fields @('relics', 'add_relics', 'remove_relics')) {
            $relicDiscovery = Get-PropertyValue -Object $Result -Name 'relic_metadata_discovery'
            if ($null -eq $relicDiscovery -or (Get-PropertyValue -Object $relicDiscovery -Name 'passed') -ne $true) {
                throw "Test planning phase pass result must include relic_metadata_discovery.passed=true when scenario_setup contains relic ids."
            }
        }

        $requiredEvidence = @(ConvertTo-Array (Get-PropertyValue -Object $Result -Name 'required_evidence') | Where-Object { (Get-PropertyValue -Object $_ -Name 'required') -ne $false })
        if ($requiredEvidence.Count -eq 0) {
            throw "Test planning phase pass result must include non-empty required_evidence."
        }
        foreach ($item in $requiredEvidence) {
            $id = [string](Get-PropertyValue -Object $item -Name 'id')
            $kind = [string](Get-PropertyValue -Object $item -Name 'kind')
            $mustShow = [string](Get-PropertyValue -Object $item -Name 'must_show')
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($kind) -or [string]::IsNullOrWhiteSpace($mustShow)) {
                throw "Test planning required_evidence items must include id, kind, and must_show."
            }
        }
    }

    if ($Phase.Name -eq 'implementation' -and $status -eq 'pass') {
        $verificationRequired = Get-PropertyValue -Object $Result -Name 'verification_required'
        if ($null -eq $verificationRequired) {
            throw "Implementation phase pass result must include boolean verification_required."
        }
        if ($verificationRequired -isnot [bool]) {
            throw "Implementation phase wrote invalid verification_required '$verificationRequired'. Expected boolean."
        }
    }

    return $status
}

function Get-PhaseAllowedToolsArgument {
    param([hashtable]$Phase)

    $tools = $Phase.AllowedTools
    if ($null -eq $tools -or $tools.Count -eq 0) { return $null }
    return ($tools | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
}

function Get-PhaseDisallowedToolsArgument {
    param([hashtable]$Phase)

    $tools = $Phase.DisallowedTools
    if ($null -eq $tools -or $tools.Count -eq 0) { return $null }
    return ($tools | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
}

function Invoke-ClaudePhase {
    param(
        [hashtable]$Phase,
        [string]$Prompt
    )

    $phaseName = $Phase.Name
    $phaseTimeoutSeconds = if ($Phase.Contains('TimeoutSeconds')) { [int]$Phase.TimeoutSeconds } else { $DefaultPhaseTimeoutSeconds }
    $phaseBudgetUsd = if ($Phase.Contains('MaxBudgetUsd')) { [string]$Phase.MaxBudgetUsd } else { $DefaultPhaseBudgetUsd }
    $promptPath = Join-Path $env:RUNNER_TEMP "claude-issue-agent-$phaseName-prompt.md"
    $phaseJsonPath = Join-Path $ValidationArtifactDir $Phase.Json
    $phaseMarkdownPath = Join-Path $ValidationArtifactDir $Phase.Markdown

    $Prompt | Set-Content -LiteralPath $promptPath -Encoding UTF8
    $promptText = Get-Content -LiteralPath $promptPath -Raw

    Write-Host "::group::Claude issue-agent phase: $phaseName"
    Write-AgentEvent 'phase_start' "Starting $phaseName phase." @{ phase = $phaseName; timeout_seconds = $phaseTimeoutSeconds; max_budget_usd = $phaseBudgetUsd }

    $stdoutPath = Join-Path $env:RUNNER_TEMP "claude-issue-agent-$phaseName-stdout.jsonl"
    $stderrPath = Join-Path $env:RUNNER_TEMP "claude-issue-agent-$phaseName-stderr.log"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

    $claudeArguments = @(
        '-p', $promptText,
        '--model', 'sonnet',
        '--permission-mode', 'bypassPermissions',
        '--output-format', 'stream-json',
        '--verbose',
        '--debug-file', $DebugLogPath,
        '--strict-mcp-config',
        "--mcp-config=$McpConfigPath",
        '--no-session-persistence',
        '--max-budget-usd', $phaseBudgetUsd,
        '--add-dir', $RepoRoot
    )

    $allowedTools = Get-PhaseAllowedToolsArgument -Phase $Phase
    if (-not [string]::IsNullOrWhiteSpace($allowedTools)) {
        $claudeArguments += @('--allowedTools', $allowedTools)
        Write-AgentEvent 'phase_allowed_tools' "${phaseName} allowed tools: $allowedTools" @{ phase = $phaseName; allowed_tools = $Phase.AllowedTools }
    }

    $disallowedTools = Get-PhaseDisallowedToolsArgument -Phase $Phase
    if (-not [string]::IsNullOrWhiteSpace($disallowedTools)) {
        $claudeArguments += @('--disallowedTools', $disallowedTools)
        Write-AgentEvent 'phase_disallowed_tools' "${phaseName} disallowed tools: $disallowedTools" @{ phase = $phaseName; disallowed_tools = $Phase.DisallowedTools }
    }

    $invokeResult = Invoke-ProcessWithTimeout `
        -FilePath $ClaudeCliPath `
        -Arguments $claudeArguments `
        -WorkingDirectory $RepoRoot `
        -StdoutPath $stdoutPath `
        -StderrPath $stderrPath `
        -TimeoutSeconds $phaseTimeoutSeconds `
        -PhaseName $phaseName

    if ($invokeResult.TimedOut) {
        $notes = "Claude phase '$phaseName' exceeded the $phaseTimeoutSeconds second script timeout before writing a required phase result."
        Write-AgentEvent 'phase_timeout' $notes @{ phase = $phaseName; timeout_seconds = $phaseTimeoutSeconds }
        Write-SyntheticPhaseAbort -Phase $Phase -AbortReason 'phase_timeout' -Notes $notes
    }

    $exitCode = $invokeResult.ExitCode
    Write-AgentEvent 'phase_exit' "${phaseName} Claude exit code: $exitCode" @{ phase = $phaseName; exit_code = $exitCode }
    Write-Host "::endgroup::"
    if ((-not $invokeResult.TimedOut) -and $exitCode -ne 0) { throw "Claude phase '$phaseName' failed with exit code $exitCode." }

    $result = Read-JsonFile -Path $phaseJsonPath
    if ($Phase.Name -eq 'verification') {
        $result = Apply-VerificationEvidenceGuard -Result $result -JsonPath $phaseJsonPath -MarkdownPath $phaseMarkdownPath
    }
    $status = Assert-PhaseContract -Phase $Phase -Result $result
    Add-JobSummaryMarkdown -Title "Issue Agent $phaseName" -MarkdownPath $phaseMarkdownPath

    return [ordered]@{
        Status = $status
        JsonPath = $phaseJsonPath
        MarkdownPath = $phaseMarkdownPath
        Result = $result
    }
}

function Get-CommonPromptPrefix {
    param(
        [string]$PhaseName,
        [bool]$IncludeIssueRead = $false
    )

    $issueReadInstruction = if ($IncludeIssueRead) {
@"
Read the issue title and body only with:

``````
gh issue view $IssueNumber --repo $RepoSlug
``````

Do not read issue comments, issue timeline entries, prior issue-agent summaries, PR discussions, or GitHub API comment endpoints in this phase unless a future prompt explicitly says to do so.
"@
    } else {
@"
Do not read the GitHub issue or issue comments in this phase. Use the JSON/Markdown handoff artifacts written by earlier phases as the source of issue context.
"@
    }

@"
You are Claude Code running the $PhaseName phase for $RepoSlug issue #$IssueNumber.

GitHub Actions triggered this job for exactly issue #$IssueNumber. Do not process any other issue.
Do not delegate to subagents, Explore agents, Task agents, or any other secondary agent. Each phase must do its own bounded work with its allowed tools so the logs, costs, and failure reasons stay auditable.
Do not read Claude memory files or any `.claude` directory. Use only this prompt, the issue body or handoff artifacts allowed for this phase, and files inside the repository root.
Use this exact local checkout path as the repository root:

``````
$RepoRoot
``````

The shell tool is Git Bash on Windows. Do not use PowerShell-only environment syntax such as `$env:ISSUE_AGENT_REPO_ROOT` unless you are explicitly invoking `powershell`. Prefer quoted concrete paths from this prompt.
Do not search above the repository root. Do not recurse through parent workspace folders or stale `issue-agent-src` checkouts from other runs.
$issueReadInstruction

Use only the MCP tools allowed for this phase from the project MCP config at `$McpConfigPath`.
- Use `lookup_card`, `lookup_relic`, `lookup_encounter`, `lookup_character`, `list_cards`, `list_relics`, `list_encounters`, `list_characters`, and `get_catalog_summary` for game metadata discovery. Do not rely on model memory for card ownership, relic identity, encounter identity, character ownership, ids, or ambiguity checks.
- Use live gameplay MCP tools for game state and in-game actions.
- Use `capture_screenshot` for screenshot evidence.
Do not use raw localhost bridge calls, filesystem queues, `LiveScenarios/`, `ops/live-worker/`, `D:\automation\spirelens-live-bridge`, shell/PowerShell desktop capture, `CopyFromScreen`, `PrimaryScreen`, or `System.Drawing` for STS2 surfaces.
Write your JSON and Markdown artifacts to this exact validation artifact directory:

``````
$ValidationArtifactDir
``````

Save screenshots to this exact screenshot directory:

``````
$ScreenshotDir
``````
JSON artifacts must be strict JSON. If you include Windows paths in JSON strings, escape backslashes as `\\` or use forward slashes; never write raw `C:\path` text with single backslashes.
Keep Markdown concise and human-readable; it will be appended to the GitHub job summary.
"@
}

Remove-Item -LiteralPath $StreamLogPath, $DebugLogPath, $SummaryLogPath -ErrorAction SilentlyContinue
if ($PhaseName -eq 'all') {
    Remove-Item -LiteralPath $ScreenshotDir, $ValidationArtifactDir -Recurse -Force -ErrorAction SilentlyContinue
} elseif ($PhaseName -eq 'verification') {
    Remove-Item -LiteralPath $ScreenshotDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $ScreenshotDir, $ValidationArtifactDir | Out-Null

$env:SCREENSHOT_DIR = $ScreenshotDir
$env:VALIDATION_ARTIFACT_DIR = $ValidationArtifactDir
Set-Location -LiteralPath $RepoRoot

"Claude phased issue-agent stream for $RepoSlug#$IssueNumber" | Set-Content -LiteralPath $SummaryLogPath -Encoding UTF8
"Sanitized event stream: $StreamLogPath" | Add-Content -LiteralPath $SummaryLogPath -Encoding UTF8
"Debug log: $DebugLogPath" | Add-Content -LiteralPath $SummaryLogPath -Encoding UTF8
"Screenshot dir: $ScreenshotDir" | Add-Content -LiteralPath $SummaryLogPath -Encoding UTF8
"Validation artifact dir: $ValidationArtifactDir" | Add-Content -LiteralPath $SummaryLogPath -Encoding UTF8

$testPlanPrompt = (Get-CommonPromptPrefix -PhaseName 'test_plan' -IncludeIssueRead $true) + @"

TEST PLANNING RULES:
- Do not edit files, commit, push, open PRs, run dotnet tests, capture screenshots, or perform live gameplay validation.
- Focus only on issue interpretation, target identity, character identity, scenario recipe, and evidence contract. Do not inspect proposed code edits; test planning must be independent of implementation.
- Classify each issue-specified gameplay target before planning: `card`, `relic`, `character`, or `mixed card/relic`. For every issue-specified card, call `lookup_card`; for every issue-specified relic, call `lookup_relic`; for mixed card/relic issues, call the relevant lookup for each target. If the target type is unclear, try both `lookup_card` and `lookup_relic` before aborting. A `not_found` card lookup is not an abort if `lookup_relic` resolves the issue target, and a `not_found` relic lookup is not an abort if `lookup_card` resolves it. Abort only when the relevant target type is `not_found` or `ambiguous`.
- For every issue-specified character, call `lookup_character` before writing the test plan result. If lookup returns `not_found` or `ambiguous`, abort with character_not_found or card_ambiguous as appropriate.
- When you need support cards for a scenario deck, use `list_cards` with exact arguments `owner`, `type`, `query`, and/or `limit`; for example use the resolved character owner and needed card type rather than guessing support card names one by one with repeated `lookup_card` calls. If `list_cards` cannot return enough real cards for the recipe, abort with `validation_plan_impossible` or `metadata_unavailable`.
- When you need support relics for a scenario, use `lookup_relic` or `list_relics` rather than guessing relic ids. Scenario saves may use `relics`, `add_relics`, and `remove_relics` with the resolved relic ids.
- Every id in `scenario_setup` must be validated through MCP catalog tools, even when it is only supporting test setup rather than the issue target. Validate `deck`, `add_cards`, and `remove_cards` entries with `lookup_card` or `list_cards`; validate `relics`, `add_relics`, and `remove_relics` entries with `lookup_relic` or `list_relics`. Do not write ids from memory. `scenario_setup` values must be the exact resolved catalog ids, not display names, shorthand aliases, or fuzzy lookup queries.
- `scenario_id_validation.cards` MUST contain one entry for every id in `scenario_setup.deck`, `scenario_setup.add_cards`, and `scenario_setup.remove_cards` — including support cards that are not the issue target. Each entry has shape `{"field":"deck|add_cards|remove_cards","input":"<exact id>","id":"<exact id>","name":"<display name>","source":"lookup_card|list_cards"}`. The same per-id rule applies to `scenario_id_validation.relics` against `relics`, `add_relics`, and `remove_relics`. The wrapper validator throws and aborts the whole run when a `scenario_setup.<field>` value has no matching `scenario_id_validation.<kind>` entry, so a missed entry burns the entire issue-agent run on a contract violation rather than on a real failure.
- Before writing the test-plan JSON, walk every id in `scenario_setup` and confirm `scenario_id_validation` has the matching entry with the same `input` value. If `list_cards` returned five cards, all five must appear in `scenario_id_validation.cards` with `field` set to whichever scenario_setup field referenced them. The validator rejects partial coverage even if the missing card was already lookup-resolved during reasoning — the evidence has to be in the artifact, not just in your head.
- `scenario_setup.next_normal_encounter` is OPTIONAL. Default to `null` and omit the corresponding `scenario_id_validation.encounters` entry. Only specify an encounter id when the relic/card behavior under test depends on which encounter is fought first (e.g. damage-on-combat-start interactions, encounter-type-conditional triggers). For encounter-agnostic behaviors — start-of-combat triggers like Akabeko's Vigor gain, end-of-combat hooks, persistent passives — leave it null; the base save's existing encounter slot is fine. When you do specify it, validate the id with `list_encounters` (preferred — pick a real id from the returned list) or `lookup_encounter`, never from memory or any "default" advertised in capabilities. The validator rejects ids not present in the live encounter catalog, so a hallucinated or stale id aborts the entire run.
- Do not inspect implementation files unless needed to identify an existing test command or fixture name; scenario/evidence planning must remain independent of code edits.
- Do not use an Explore/subagent/Task. If the issue, MCP catalog metadata, and existing test command hints are not enough to produce a validation plan quickly, abort with `validation_plan_impossible` instead of delegating.
- After the required issue read and MCP lookups are complete, write the JSON and Markdown artifacts immediately. Keep the plan concise; do not spend additional turns narrating or re-checking unless a required field is genuinely missing.
- Before writing screenshot or live-validation evidence, call `get_validation_capabilities` and use its returned `card_surfaces`, `relic_surfaces`, `runtime_options`, `recommended_tooltip_evidence_flow`, `recommended_relic_tooltip_evidence_flow`, and `tools[]` manifest as the source of truth for what verification can open, tooltip, screenshot, and mutate. Each referenced tool plan should respect the manifest fields `safe_for_test_planning`, `mutates_state`, `requires_game_running`, `requires_combat`, `output_contract`, `common_failures`, and `examples`. Do not assume an unavailable view exists, and do not omit an available view such as deck, draw_pile, discard_pile, exhaust_pile, player_relic_bar, relic_select, treasure, or verbose hand stats when it is the right evidence surface.
- If MCP catalog metadata or validation capabilities cannot support the needed validation plan, abort.
- Write `issue-agent-test-plan.json` with:
  `{ "layer":"test_plan", "status":"pass|abort", "abort_reason":null, "retryable":false, "human_action_required":false, "notes":"", "target_kind":"card|relic|mixed|unknown", "card":{}, "relic":{}, "character":{}, "card_metadata_discovery":{"passed":true,"status":"pass","notes":"scenario card ids resolved from MCP catalog tools"}, "relic_metadata_discovery":{"passed":true,"status":"pass","notes":"scenario relic ids resolved from MCP catalog tools"}, "scenario_id_validation":{"passed":true,"cards":[{"field":"deck","input":"TARGET_CARD_ID","id":"TARGET_CARD_ID","name":"Target Card","source":"lookup_card|list_cards"}],"relics":[{"field":"add_relics","input":"REAL_RELIC_ID","id":"REAL_RELIC_ID","name":"Relic Name","source":"lookup_relic|list_relics"}],"encounters":[],"notes":"every id in scenario_setup was resolved from MCP catalog tools"}, "validation_plan":[], "scenario_setup":{"base_save_name":"base_<character>","scenario_name":"issue_<issue>_<short_target>","deck":["TARGET_CARD_ID","REAL_SUPPORT_CARD_ID"],"add_cards":null,"remove_cards":null,"relics":null,"add_relics":null,"remove_relics":null,"gold":null,"current_hp":null,"max_hp":null,"max_energy":null,"next_normal_encounter":null,"notes":"small deterministic setup that satisfies the evidence plan"}, "required_evidence":[{"id":"unit-tests","kind":"unit_test","required":true,"must_show":"specific tests that prove the changed behavior"},{"id":"live-target-visible","kind":"screenshot","required":true,"must_show":"target card/relic/UI/tooltip state visibly proving the issue claim","target_visible_required":true,"text_visible_required":false,"allowed_fallback":null}] }`
- `scenario_setup` is the deterministic pre-verification save recipe. Choose the correct `base_save_name` from the verified character identity, such as `base_regent`, `base_ironclad`, `base_silent`, `base_defect`, or `base_necrobinder`. Use a complete small `deck` of real card ids that lets normal gameplay reach the evidence state quickly. When a card needs support cards, use `list_cards` with the resolved owner/type/query constraints to select real support card ids from MCP metadata, and set enough energy/max_energy for the planned validation actions. Do not tell verification to use dev-console `fight`/`card` commands for card availability; card availability must come from this save recipe.
- Never write `card_metadata_discovery.status="not_run"` merely because the issue target is not a card when `scenario_setup` contains cards. If the scenario has any card id, card metadata discovery for those scenario cards must pass or the phase must abort.
- When validating effects that move, summon, return, discard, exhaust, or draw a named card, the scenario must place the card in a source pile where that effect can actually operate before the evidence step. If a card says it puts "this" into hand, the triggering copy must be outside hand before the trigger. A valid Make It So route is: start with Make It So in hand, play Make It So first so it enters discard, play two Skills, inspect the Make It So tooltip from discard for 2/3 progress, play the third Skill, then inspect Make It So in hand for the trigger count. If the same card also needs an in-hand tooltip before the effect, use a duplicate copy or include a validation action that moves/plays the inspected copy out of hand before the trigger. Do not assume a card already in hand can be put into hand again. A 5-card deck that leaves Make It So in hand for the whole test is invalid for trigger-count evidence.
- `required_evidence` is the acceptance contract for verification. Include every proof required before a PR may open. If the issue asks for multiple visible UI claims, the required screenshot evidence must name all of them; do not collapse a multi-part request into proof for only one row or one state. For tooltip, label, wording, or text/UI issues, include a screenshot evidence item with `text_visible_required:true` and `must_show` naming the exact text or tooltip state. When more than one label/row is requested, put all requested labels/rows in `must_show`. Unit tests may be required too, but they are not a substitute for required visual evidence unless the issue is explicitly non-visual and you set `allowed_fallback` with a concrete reason.
- For card-stat tooltip issues, default visual evidence is the in-hand card tooltip unless the issue explicitly names a non-hand surface or the validation capabilities show that another surface is required to expose the relevant state. If the issue requests multiple tooltip rows or states, require the screenshot evidence to show all requested rows or states together when possible, and otherwise explain the exact surface split in the evidence contract.
- For relic-stat issues, prefer a deterministic scenario save with the target relic in `relics` or `add_relics`, then require evidence from `get_game_state` showing the resolved relic id/name in the player's relic list plus the best visible relic tooltip surface supported by validation capabilities. For relic tooltip/text claims, require `text_visible_required:true` and plan `list_visible_relics(surface)` -> `show_relic_tooltip(surface, relic_id=...)` -> `capture_screenshot` when those tools are available. If the capabilities do not expose forced relic-hover support, require the strongest available relic-visible screenshot and describe the missing hover capability instead of pretending card tooltip tools can prove relic text.
- Allowed abort reasons: card_not_found, card_ambiguous, character_not_found, metadata_unavailable, mcp_capability_missing, game_state_unreachable, validation_plan_impossible.
- Write `issue-agent-test-plan.md` summarizing facts found, scenario recipe, missing facts, and the validation plan.
"@

$implementationPrompt = (Get-CommonPromptPrefix -PhaseName 'implementation' -IncludeIssueRead $true) + @"

IMPLEMENTATION RULES:
- Read the issue title/body directly with `gh issue view $IssueNumber --repo $RepoSlug`. Implement the user-facing claim only; do not read issue comments, prior run summaries, PR discussions, or GitHub API comment endpoints. Do not read or depend on the test-plan artifact because this phase runs in parallel with test planning.
- Own code changes only. Do not claim verification success.
- For every issue-specified card, relic, or character, call MCP catalog lookup tools before editing. Use `lookup_card` for cards, `lookup_relic` for relics, and `lookup_character` for characters; if the target type is unclear, try both card and relic lookup before aborting. Abort rather than guessing ids, ownership, or ambiguity.
- Do not run unit tests, integration tests, live validation, or screenshot validation. Verification owns every `dotnet test`, live MCP action, and screenshot.
- You may inspect code, edit code, and run focused builds for compile sanity only. For this repo, compile sanity means `dotnet build "Core/SpireLens.Core.csproj" -c Debug` and, when tests were edited or referenced, `dotnet build "Tests/SpireLens.Core.Tests/SpireLens.Core.Tests.csproj" -c Debug`. Do not build the root `SpireLens.csproj` as a compile sanity check, and do not use `--no-restore`; the root Godot project can require generated `.godot/mono/temp` assets that are not present yet. The workflow wrapper owns the broader build, branch, commit, push, and PR creation after verification passes.
- Keep repository and dependency discovery scoped to this run. Do not search above `$RepoRoot`, under sibling or parent runner workspaces, or inside stale `issue-agent-src` directories from older runs. On the Windows issue-agent runner, the workflow exposes the resolved STS2 install as `ISSUE_AGENT_STS2_GAME_DIR` and the resolved STS2 data directory as `ISSUE_AGENT_STS2_DATA_DIR`; use those first for game assembly metadata. If those are unavailable, use `Sts2PathDiscovery.props`, the configured `Sts2DataDir`, or a focused build in the current checkout to materialize publicized assemblies under the current `$RepoRoot`. Do not start by probing whole drives, registry Steam locations, or old runner artifacts. If those scoped paths are unavailable, abort with `missing_code_context` instead of scanning outside the run.
- If no code change is needed, write a pass result with `changed_files: []`, `opened_pr: null`, and `verification_required: true`; do not run tests to prove that claim.
- Do not start gameplay, enter rooms, play cards, capture screenshots, or perform live MCP validation; leave all live MCP validation to verification.
- If the viable solve requires dramatic changes, a new library, architecture changes, or unsafe refactors, abort.
- Do not create branches, commit, push, open PRs, comment on issues, edit labels, or perform any other GitHub mutation.
- Write `issue-agent-implementation.json` with:
  `{ \"layer\":\"implementation\", \"status\":\"pass|abort\", \"abort_reason\":null, \"retryable\":false, \"human_action_required\":false, \"notes\":\"\", \"changed_files\":[], \"opened_pr\":null, \"opened_pr_url\":null, \"pr_title\":null, \"pr_body\":null, \"verification_required\":true }`
- Allowed abort reasons: change_too_large, requires_new_library, requires_architecture_change, unsafe_refactor, missing_code_context, conflicting_requirements, cannot_implement_without_guessing.
- Write `issue-agent-implementation.md` summarizing changes, suggested PR title/body if useful, no-change decision, or abort reason. Do not mention a created branch, commit, or PR because this phase must not create them.
"@

$verificationPrompt = (Get-CommonPromptPrefix -PhaseName 'verification') + @"

VERIFICATION RULES:
- Read `issue-agent-test-plan.json`, `issue-agent-implementation.json`, and `issue-agent-scenario-setup.json` first. Treat `issue-agent-test-plan.json.required_evidence` as a hard acceptance contract. Do not pass unless every required evidence item is satisfied in `evidence_results`.
- Own tests, live MCP validation, screenshot capture, and final evidence only. This phase is sealed from GitHub mutation: no issue comments, labels, branches, commits, pushes, or PRs.
- Use this Windows validation sequence unless the test plan says it is not applicable:

``````powershell
`$sts2DataDir = `$env:ISSUE_AGENT_STS2_DATA_DIR
if ([string]::IsNullOrWhiteSpace(`$sts2DataDir)) { throw "ISSUE_AGENT_STS2_DATA_DIR was not set." }
dotnet build "Tests\SpireLens.Core.Tests\SpireLens.Core.Tests.csproj" -c Debug "-p:Sts2DataDir=`$sts2DataDir"
dotnet test "Tests\SpireLens.Core.Tests\SpireLens.Core.Tests.csproj" -c Debug --no-build "-p:Sts2DataDir=`$sts2DataDir"
``````

- The full test command above is a hard gate. If any test fails after the implementation checkout is deployed, verification must abort with unit_tests_failed; do not call failures "pre-existing", "outside the contract", "partial", or "follow-up" when baseline main passed earlier in this workflow.
- Default live validation fixture: the workflow has already materialized, installed, validated, and loaded the scenario save before this LLM phase starts. Read `issue-agent-scenario-setup.json` first, then inspect the live state with `get_game_state`. Do not call save materialization, save installation, current-run validation, current-run loading, save listing, save inspection, or scenario-command discovery tools. Do not use live MCP tools to arrange hand/draw/discard/exhaust piles. If needed after combat loads, `configure_live_combat` may set only sparse live properties such as enemy HP, current energy/stars, player powers, or enemy powers; card availability must come from the scenario save/deck and normal gameplay. If the game is at Neow, menu, the wrong character, transition-only state, or any unexpected state after loading, abort with `mcp_state_mismatch` or `game_state_unreachable`; do not choose Neow options, start ad hoc runs, or enter random debug rooms.
- For SpireLens card-stat tooltip evidence, use `bridge_health`, `set_spirelens_view_stats_enabled(true)`, `list_visible_cards(surface)`, then `show_card_tooltip(surface, card_index, card_id)` on the target visible card, then `capture_screenshot`. Prefer `card_id` over card_index alone when validating a named card. For deck, draw pile, discard pile, or exhaust pile evidence, call `open_card_pile(pile)` first, use the matching surface name with `list_visible_cards`/`show_card_tooltip`, capture the screenshot, then call `close_card_pile()`. If `list_visible_cards` cannot find the target, `show_card_tooltip` returns an error, the bridge health check fails, or the captured screenshot still shows the wrong/stale tooltip after one retry, abort with `target_evidence_missing` or `game_state_unreachable`; do not keep trying arbitrary indices. Prefer this route over ad hoc mouse/hover attempts.
- For SpireLens relic-stat tooltip evidence, use `bridge_health`, `set_spirelens_view_stats_enabled(true)`, `list_visible_relics(surface)`, then `show_relic_tooltip(surface, relic_id=...)` on the target visible relic, then `capture_screenshot`. Prefer `player_relic_bar` for owned relic stats unless the test plan explicitly names `relic_select` or `treasure`. Prefer `relic_id` over relic_index alone. If `list_visible_relics` cannot find the target, `show_relic_tooltip` returns an error, the bridge health check fails, or the captured screenshot still shows the wrong/stale tooltip after one retry, abort with `target_evidence_missing` or `game_state_unreachable`; do not use card tooltip tools or arbitrary mouse hover attempts as substitutes.
- Capture screenshots only through the `capture_screenshot` MCP tool.
- Use the full STS2 game window/client area returned by `capture_screenshot` as canonical screenshot evidence. Crops or tighter views may be additional evidence only, not replacements.
- If `capture_screenshot` is unavailable or does not return a saved PNG path plus dimensions, abort with screenshot_missing.
- If the saved screenshot is not meaningful evidence for the validation claim, abort with screenshot_not_relevant. For a named card, tooltip, or UI issue, screenshots must show the target card, tooltip, or changed UI state. If the relevant evidence lives in draw pile, discard pile, exhaust pile, deck view, card selection, rewards, or another non-hand surface, navigate to that surface through MCP when available and capture the target-visible screenshot there. If MCP cannot make the required card text/tooltip visible, abort with target_evidence_missing and say which view or pile was unreachable; do not pass on hand screenshots, unit tests, repeated tooltip attempts, or adjacent state.
- Keep verification bounded: capture the planned screenshot once, and at most one retry per required screenshot if the tooltip or text is stale. If the evidence is still not legible or not causally valid after that, immediately write an abort result with 	arget_evidence_missing, screenshot_not_relevant, or claimed_result_not_observed; do not improvise a new multi-turn scenario until timeout.
- Write `issue-agent-verification.json` with:
  `{ "layer":"verification", "status":"pass|abort", "abort_reason":null, "retryable":false, "human_action_required":false, "notes":"", "unit_tests":{"passed":null,"status":"not_run","notes":""}, "live_mcp_validation":{"passed":null,"status":"not_run","notes":""}, "screenshot_validation":{"passed":null,"status":"not_run","count":0,"target_visible":false,"notes":""}, "evidence_results":[{"evidence_id":"","kind":"unit_test|screenshot|live_mcp|manual_blocker","passed":false,"artifact_paths":[],"target_visible":false,"text_visible":false,"observed_text":"","notes":""}], "used_mcp":null, "used_raw_bridge_or_queue":false }`
- For each `required_evidence` item from the test plan, write exactly one matching `evidence_results` item. Screenshot evidence must include artifact_paths. If the contract requires tooltip/text evidence, set `text_visible:true` only when the screenshot itself shows the required text and copy the visible words into `observed_text`. If the text/tooltip cannot be made visible, abort with target_evidence_missing; do not pass by saying unit tests cover it.
- For card-stat tooltip issues, prefer `show_card_tooltip(surface="hand", card_id=...)` and require the in-hand screenshot to satisfy the text contract unless the test plan explicitly names a non-hand surface.
- For relic-stat tooltip issues, prefer `show_relic_tooltip(surface="player_relic_bar", relic_id=...)` and require the relic tooltip screenshot to satisfy the text contract unless the test plan explicitly names a non-owned relic surface.
- Allowed abort reasons: unit_tests_failed, live_validation_failed, screenshot_missing, screenshot_not_relevant, target_evidence_missing, mcp_state_mismatch, game_state_unreachable, claimed_result_not_observed, artifact_contract_missing.
- Also write rollup `issue-agent-result.json` with issue_number, status, abort_layer, abort_reason, retryable, human_action_required, layers, unit_tests, live_mcp_validation, screenshot_validation, card_metadata_discovery, used_mcp, used_raw_bridge_or_queue, opened_pr, opened_pr_url, should_close_issue, and evidence_summary.
- Write `issue-agent-verification.md` summarizing pass/fail evidence.
- Write `issue-agent-result.md` as a compact final rollup including any PR URL from implementation.
- Do not remove or add labels, post comments, create branches, commit, push, or open PRs. The workflow wrapper handles GitHub updates after this phase writes evidence.
"@

$phaseResults = @{}
$phasesToRun = if ($PhaseName -eq 'all') {
    $phaseDefinitions
} else {
    @($phaseDefinitions | Where-Object { $_.Name -eq $PhaseName })
}

foreach ($phase in $phasesToRun) {
    $prompt = switch ($phase.Name) {
        'test_plan' { $testPlanPrompt }
        'implementation' { $implementationPrompt }
        'verification' { $verificationPrompt }
    }

    $phaseResult = Invoke-ClaudePhase -Phase $phase -Prompt $prompt
    $phaseResults[$phase.Name] = $phaseResult

    if ($phaseResult.Status -eq 'abort') {
        $abortReason = [string](Get-PropertyValue -Object $phaseResult.Result -Name 'abort_reason')
        $notes = [string](Get-PropertyValue -Object $phaseResult.Result -Name 'notes')
        Write-SyntheticRollup -AbortLayer $phase.Name -AbortReason $abortReason -Notes $notes
        break
    }
}

$resultMarkdown = Join-Path $ValidationArtifactDir 'issue-agent-result.md'
if (Test-Path -LiteralPath $resultMarkdown) {
    Add-JobSummaryMarkdown -Title 'Issue Agent final result' -MarkdownPath $resultMarkdown
}

Write-AgentEvent 'exit' 'Phased issue-agent script completed.'















