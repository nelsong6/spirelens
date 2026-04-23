[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\repos\card-utility-stats",
    [string]$RepoSlug = "nelsong6/card-utility-stats",
    [string]$WorkerName = "",
    [string]$QueueLabel = "codex-queue",
    [string]$ActiveLabel = "codex-active",
    [string]$BlockedLabel = "codex-blocked",
    [string]$CompleteLabel = "codex-complete",
    [string]$DashboardEventUrl = "",
    [string]$DashboardEventSecretName = "codex-queue-jwt-secret",
    [string]$DashboardEventSecretEnvironmentVariable = "CODEX_QUEUE_JWT_SECRET",
    [string]$DashboardEventAudience = "diagrams-codex-queue",
    [string]$DashboardEventIssuer = "codex-queue-worker",
    [int]$DashboardEventTimeoutSeconds = 10,
    [string]$StateRoot = "",
    [int]$MaxIssuesPerRun = 100,
    [int]$MaxAttemptsPerIssue = 3
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line

    if ($script:WorkerLogPath) {
        Add-Content -LiteralPath $script:WorkerLogPath -Value $line
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return $Path
}

function Resolve-StateRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoSlugValue,

        [string]$ExplicitStateRoot = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitStateRoot)) {
        return Ensure-Directory -Path $ExplicitStateRoot
    }

    $safeRepoSlug = $RepoSlugValue.Replace("/", "-")
    $configuredBase = [Environment]::GetEnvironmentVariable("CODEX_ISSUE_QUEUE_STATE_ROOT", "Process")
    if ([string]::IsNullOrWhiteSpace($configuredBase)) {
        $configuredBase = [Environment]::GetEnvironmentVariable("CODEX_ISSUE_QUEUE_STATE_ROOT", "User")
    }
    if ([string]::IsNullOrWhiteSpace($configuredBase)) {
        $configuredBase = [Environment]::GetEnvironmentVariable("CODEX_ISSUE_QUEUE_STATE_ROOT", "Machine")
    }

    if (-not [string]::IsNullOrWhiteSpace($configuredBase)) {
        return Ensure-Directory -Path (Join-Path $configuredBase $safeRepoSlug)
    }

    return Ensure-Directory -Path (Join-Path $env:LOCALAPPDATA "CodexIssueQueue\$safeRepoSlug")
}

function Add-ToolPath {
    $paths = @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files\GitHub CLI",
        "C:\Program Files\PowerShell\7"
    )

    foreach ($path in $paths) {
        if ((Test-Path -LiteralPath $path) -and -not (($env:PATH -split ";") -contains $path)) {
            $env:PATH = "$path;$env:PATH"
        }
    }
}

function Get-DefaultWorkerName {
    $candidates = @(
        [Environment]::GetEnvironmentVariable("CARD_UTILITY_STATS_WORKER_NAME", "Process"),
        [Environment]::GetEnvironmentVariable("CARD_UTILITY_STATS_WORKER_NAME", "User"),
        [Environment]::GetEnvironmentVariable("CARD_UTILITY_STATS_WORKER_NAME", "Machine"),
        $env:RUNNER_NAME,
        $env:COMPUTERNAME
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    return "codex-queue-worker"
}

function Ensure-LocalCodexBinary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot
    )

    $candidatePaths = New-Object System.Collections.Generic.List[string]

    foreach ($scope in @("Process", "User", "Machine")) {
        $explicitPath = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", $scope)
        if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
            $candidatePaths.Add($explicitPath)
        }
    }

    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codexCommand) {
        if (-not [string]::IsNullOrWhiteSpace($codexCommand.Source)) {
            $candidatePaths.Add($codexCommand.Source)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($codexCommand.Path)) {
            $candidatePaths.Add($codexCommand.Path)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidatePaths.Add((Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe"))
    }

    $userRoot = "C:\Users"
    if (Test-Path -LiteralPath $userRoot) {
        Get-ChildItem -LiteralPath $userRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidatePaths.Add((Join-Path $_.FullName "AppData\Local\OpenAI\Codex\bin\codex.exe"))
            }
    }

    $windowsAppsRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $windowsAppsRoots += (Join-Path $env:ProgramFiles "WindowsApps")
    }
    $windowsAppsRoots += "C:\Program Files\WindowsApps"

    foreach ($root in ($windowsAppsRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            ForEach-Object {
                $candidatePaths.Add((Join-Path $_.FullName "app\resources\codex.exe"))
            }
    }

    $candidatePaths.Add("C:\Program Files\WindowsApps\OpenAI.Codex_26.421.620.0_x64__2p2nqsd0c76g0\app\resources\codex.exe")

    $sourcePath = $null
    foreach ($candidate in ($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            $sourcePath = $candidate
            break
        }
    }

    if (-not $sourcePath) {
        throw "Unable to locate the installed Codex CLI binary."
    }

    $binDir = Ensure-Directory -Path (Join-Path $StateRoot "bin")
    $targetPath = Join-Path $binDir "codex.exe"

    $shouldCopy = $true
    if (Test-Path -LiteralPath $targetPath) {
        $sourceInfo = Get-Item -LiteralPath $sourcePath
        $targetInfo = Get-Item -LiteralPath $targetPath
        $shouldCopy = $sourceInfo.Length -ne $targetInfo.Length -or $sourceInfo.LastWriteTimeUtc -gt $targetInfo.LastWriteTimeUtc
    }

    if ($shouldCopy) {
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }

    return $targetPath
}

function ConvertTo-Base64Url {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return ([Convert]::ToBase64String($Bytes)).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-Hs256Jwt {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Claims,

        [Parameter(Mandatory = $true)]
        [string]$Secret
    )

    $headerJson = @{ alg = "HS256"; typ = "JWT" } | ConvertTo-Json -Compress
    $payloadJson = $Claims | ConvertTo-Json -Compress -Depth 10

    $encodedHeader = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($headerJson))
    $encodedPayload = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
    $unsignedToken = "$encodedHeader.$encodedPayload"

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $signatureBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($unsignedToken))
    }
    finally {
        $hmac.Dispose()
    }

    $encodedSignature = ConvertTo-Base64Url -Bytes $signatureBytes
    return "$unsignedToken.$encodedSignature"
}

function Get-DashboardEventSecret {
    if ($script:DashboardEventSecret) {
        return $script:DashboardEventSecret
    }

    $secret = [Environment]::GetEnvironmentVariable($DashboardEventSecretEnvironmentVariable, "Process")
    if ([string]::IsNullOrWhiteSpace($secret)) {
        $secret = [Environment]::GetEnvironmentVariable($DashboardEventSecretEnvironmentVariable, "User")
    }
    if ([string]::IsNullOrWhiteSpace($secret)) {
        $secret = [Environment]::GetEnvironmentVariable($DashboardEventSecretEnvironmentVariable, "Machine")
    }

    if ([string]::IsNullOrWhiteSpace($secret) -and (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        try {
            $secret = Get-Secret -Name $DashboardEventSecretName -AsPlainText -ErrorAction Stop
        }
        catch {
            $secret = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($secret)) {
        if (-not $script:DashboardSecretWarningIssued) {
            Write-Log "Dashboard push is enabled but no JWT secret was found in environment variable '$DashboardEventSecretEnvironmentVariable' or Get-Secret '$DashboardEventSecretName'."
            $script:DashboardSecretWarningIssued = $true
        }
        return $null
    }

    $script:DashboardEventSecret = $secret
    return $script:DashboardEventSecret
}

function Send-DashboardEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [hashtable]$Data = @{}
    )

    if ([string]::IsNullOrWhiteSpace($DashboardEventUrl)) {
        return
    }

    $secret = Get-DashboardEventSecret
    if ([string]::IsNullOrWhiteSpace($secret)) {
        return
    }

    $now = [DateTimeOffset]::UtcNow
    $claims = @{
        iss = $DashboardEventIssuer
        sub = $WorkerName
        aud = $DashboardEventAudience
        iat = [int]$now.ToUnixTimeSeconds()
        exp = [int]$now.AddMinutes(5).ToUnixTimeSeconds()
        jti = [guid]::NewGuid().ToString()
        repo = $RepoSlug
    }

    $payload = @{
        type = $Type
        repo = $RepoSlug
        worker = $WorkerName
        host = $env:COMPUTERNAME
        occurred_at = $now.ToString("o")
        run_id = $script:QueueRunId
    }

    foreach ($key in $Data.Keys) {
        if ($null -ne $Data[$key]) {
            $payload[$key] = $Data[$key]
        }
    }

    try {
        $token = New-Hs256Jwt -Claims $claims -Secret $secret
        Invoke-RestMethod `
            -Method Post `
            -Uri $DashboardEventUrl `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType "application/json" `
            -Body ($payload | ConvertTo-Json -Compress -Depth 10) `
            -TimeoutSec $DashboardEventTimeoutSeconds | Out-Null
    }
    catch {
        Write-Log "Dashboard push event '$Type' failed: $($_.Exception.Message)"
    }
}

function Invoke-GhJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $json = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh command failed: gh $($Arguments -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Ensure-Label {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Color,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $existing = Invoke-GhJson -Arguments @("label", "list", "--repo", $Repo, "--limit", "200", "--json", "name")
    if ($existing.name -contains $Name) {
        return
    }

    & gh label create $Name --repo $Repo --color $Color --description $Description | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create label '$Name'."
    }
}

function Ensure-QueueLabels {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    Ensure-Label -Repo $Repo -Name $QueueLabel -Color "0e8a16" -Description "Queued for autonomous Codex processing"
    Ensure-Label -Repo $Repo -Name $ActiveLabel -Color "fbca04" -Description "Currently being processed by the Codex queue worker"
    Ensure-Label -Repo $Repo -Name $BlockedLabel -Color "d93f0b" -Description "Blocked pending human action or missing prerequisites"
    Ensure-Label -Repo $Repo -Name $CompleteLabel -Color "1d76db" -Description "Processed by the Codex queue worker"
}

function Get-AttemptFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    $attemptsDir = Ensure-Directory -Path (Join-Path $StateRoot "attempts")
    return Join-Path $attemptsDir "$IssueNumber.json"
}

function Get-IssueAttemptCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    $path = Get-AttemptFilePath -StateRoot $StateRoot -IssueNumber $IssueNumber
    if (-not (Test-Path -LiteralPath $path)) {
        return 0
    }

    return ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).attempts)
}

function Set-IssueAttemptCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [int]$Attempts
    )

    $payload = @{
        issue_number = $IssueNumber
        attempts = $Attempts
        updated_at = (Get-Date).ToString("o")
    }

    $payload | ConvertTo-Json | Set-Content -LiteralPath (Get-AttemptFilePath -StateRoot $StateRoot -IssueNumber $IssueNumber)
}

function Clear-IssueAttemptCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    $path = Get-AttemptFilePath -StateRoot $StateRoot -IssueNumber $IssueNumber
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-TextFileTail {
    param(
        [string]$Path,

        [int]$MaxLines = 40,

        [int]$MaxCharacters = 4000
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        $text = (Get-Content -LiteralPath $Path -Tail $MaxLines -ErrorAction Stop) -join [Environment]::NewLine
        $text = $text.Trim()
        if ($text.Length -gt $MaxCharacters) {
            $text = $text.Substring($text.Length - $MaxCharacters)
        }

        $markdownFence = ([string][char]96) * 3
        return $text.Replace($markdownFence, "'''")
    }
    catch {
        return ""
    }
}

function Get-NextQueuedIssue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [int[]]$ExcludeIssueNumbers = @()
    )

    $issues = Invoke-GhJson -Arguments @(
        "issue", "list",
        "--repo", $Repo,
        "--state", "open",
        "--label", $QueueLabel,
        "--limit", "100",
        "--json", "number,title,createdAt,labels,url"
    )

    if (-not $issues) {
        return $null
    }

    $eligible = $issues | Where-Object {
        $labelNames = @($_.labels | ForEach-Object { $_.name })
        -not ($labelNames -contains $ActiveLabel) -and -not ($ExcludeIssueNumbers -contains [int]$_.number)
    }

    if (-not $eligible) {
        return $null
    }

    return $eligible | Sort-Object createdAt | Select-Object -First 1
}

function Get-IssuePacket {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    return Invoke-GhJson -Arguments @(
        "issue", "view", $IssueNumber.ToString(),
        "--repo", $Repo,
        "--json", "number,title,body,labels,comments,author,url,assignees,projectItems"
    )
}

function Edit-IssueLabels {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [string[]]$AddLabels = @(),

        [string[]]$RemoveLabels = @()
    )

    $args = @("issue", "edit", $IssueNumber.ToString(), "--repo", $Repo)

    foreach ($label in $AddLabels) {
        if (-not [string]::IsNullOrWhiteSpace($label)) {
            $args += @("--add-label", $label)
        }
    }

    foreach ($label in $RemoveLabels) {
        if (-not [string]::IsNullOrWhiteSpace($label)) {
            $args += @("--remove-label", $label)
        }
    }

    & gh @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to edit labels for issue #$IssueNumber."
    }
}

function Comment-OnIssue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    & gh issue comment $IssueNumber --repo $Repo --body $Body | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to comment on issue #$IssueNumber."
    }
}

function Invoke-CodexIssueRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexPath,

        [Parameter(Mandatory = $true)]
        [string]$RepoRootValue,

        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Worker,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$IssuePacket
    )

    $issueRunRoot = Ensure-Directory -Path (Join-Path $StateRoot "runs\$IssueNumber")
    $attempt = (Get-IssueAttemptCount -StateRoot $StateRoot -IssueNumber $IssueNumber) + 1
    Set-IssueAttemptCount -StateRoot $StateRoot -IssueNumber $IssueNumber -Attempts $attempt

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runDir = Ensure-Directory -Path (Join-Path $issueRunRoot "$timestamp-attempt-$attempt")
    $packetPath = Join-Path $runDir "issue-packet.json"
    $promptPath = Join-Path $runDir "prompt.md"
    $stdoutPath = Join-Path $runDir "codex-stdout.log"
    $stderrPath = Join-Path $runDir "codex-stderr.log"
    $resultPath = Join-Path $runDir "codex-result.json"
    $schemaPath = Join-Path $RepoRootValue "ops\codex-queue\issue-output-schema.json"
    $instructionsPath = Join-Path $RepoRootValue "ops\codex-queue\worker-instructions.md"

    $IssuePacket | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $packetPath

    $instructions = Get-Content -LiteralPath $instructionsPath -Raw
    $prompt = @"
$instructions

Repository:
- slug: $Repo
- local_path: $RepoRootValue
- worker_name: $Worker

Target issue:
- number: $IssueNumber
- packet_path: $packetPath

Execution requirements:
- Read the issue packet before acting.
- Handle exactly this one issue.
- Use GitHub CLI if you need to inspect PRs or issues.
- Use git locally for branch/commit work.
- Do not wait for a human if the issue can be advanced.
- Return JSON that matches the schema file at: $schemaPath
"@

    $prompt | Set-Content -LiteralPath $promptPath

    $args = @(
        "exec",
        "--cd", $RepoRootValue,
        "--add-dir", $runDir,
        "--dangerously-bypass-approvals-and-sandbox",
        "--output-schema", $schemaPath,
        "--output-last-message", $resultPath,
        "-"
    )

    $process = Start-Process `
        -FilePath $CodexPath `
        -ArgumentList $args `
        -RedirectStandardInput $promptPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -Wait `
        -PassThru
    $exitCode = $process.ExitCode

    $resultObject = $null
    if (Test-Path -LiteralPath $resultPath) {
        try {
            $resultObject = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        }
        catch {
            $resultObject = $null
        }
    }

    return @{
        Attempt = $attempt
        ExitCode = $exitCode
        RunDirectory = $runDir
        Result = $resultObject
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        ResultPath = $resultPath
    }
}

function Format-WorkerComment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Worker,

        [Parameter(Mandatory = $true)]
        [int]$Attempt,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $validationLines = @()
    foreach ($line in $Result.validation) {
        $validationLines += "- $line"
    }

    if (-not $validationLines) {
        $validationLines = @("- No validation details were reported.")
    }

    $prLine = if ($Result.pr_url) { "- PR: $($Result.pr_url)" } else { "- PR: none" }
    $branchLine = if ($Result.branch) { "- Branch: $($Result.branch)" } else { "- Branch: none" }
    $commitLine = if ($Result.commit) { "- Commit: $($Result.commit)" } else { "- Commit: none" }

    return @"
Autonomous worker update from ``$Worker``:

- Attempt: $Attempt
- Status: $($Result.status)
$branchLine
$commitLine
$prLine

Summary:
$($Result.summary)

Validation:
$($validationLines -join [Environment]::NewLine)

Worker note:
$($Result.issue_comment)
"@
}

function Apply-ResultToIssue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$Worker,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [hashtable]$InvocationResult
    )

    $attempt = $InvocationResult.Attempt
    $result = $InvocationResult.Result
    $exitCode = $InvocationResult.ExitCode
    $stdoutTail = Get-TextFileTail -Path $InvocationResult.StdoutPath
    $stderrTail = Get-TextFileTail -Path $InvocationResult.StderrPath

    $diagnostics = ""
    $markdownFence = ([string][char]96) * 3
    if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
        $diagnostics += [Environment]::NewLine + "Stderr tail:" + [Environment]::NewLine + $markdownFence + "text" + [Environment]::NewLine + $stderrTail + [Environment]::NewLine + $markdownFence + [Environment]::NewLine
    }
    if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
        $diagnostics += [Environment]::NewLine + "Stdout tail:" + [Environment]::NewLine + $markdownFence + "text" + [Environment]::NewLine + $stdoutTail + [Environment]::NewLine + $markdownFence + [Environment]::NewLine
    }

    if ($exitCode -ne 0 -or -not $result) {
        if ($attempt -ge $MaxAttemptsPerIssue) {
            Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -AddLabels @($BlockedLabel) -RemoveLabels @($ActiveLabel, $QueueLabel)
            Comment-OnIssue -Repo $Repo -IssueNumber $IssueNumber -Body @"
Autonomous worker ``$Worker`` could not complete issue #$IssueNumber after $attempt attempts.

- Codex exit code: $exitCode
- Last run directory: $($InvocationResult.RunDirectory)
$diagnostics

The issue has been moved out of the queue and marked blocked for human review.
"@
            return "blocked"
        }

        Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -RemoveLabels @($ActiveLabel)
        Comment-OnIssue -Repo $Repo -IssueNumber $IssueNumber -Body @"
Autonomous worker ``$Worker`` failed attempt $attempt on issue #$IssueNumber.

- Codex exit code: $exitCode
- Last run directory: $($InvocationResult.RunDirectory)
$diagnostics

The issue remains queued and will be retried automatically.
"@
        return "retry"
    }

    $comment = Format-WorkerComment -Worker $Worker -Attempt $attempt -Result $result
    Comment-OnIssue -Repo $Repo -IssueNumber $IssueNumber -Body $comment

    switch ($result.status) {
        "completed" {
            Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -AddLabels @($CompleteLabel) -RemoveLabels @($QueueLabel, $ActiveLabel, $BlockedLabel)
            Clear-IssueAttemptCount -StateRoot $StateRoot -IssueNumber $IssueNumber
            return "completed"
        }
        "blocked" {
            Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -AddLabels @($BlockedLabel) -RemoveLabels @($QueueLabel, $ActiveLabel)
            return "blocked"
        }
        "needs_human" {
            Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -AddLabels @($BlockedLabel) -RemoveLabels @($QueueLabel, $ActiveLabel)
            return "needs_human"
        }
        default {
            if ($attempt -ge $MaxAttemptsPerIssue) {
                Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -AddLabels @($BlockedLabel) -RemoveLabels @($QueueLabel, $ActiveLabel)
                return "blocked"
            }

            Edit-IssueLabels -Repo $Repo -IssueNumber $IssueNumber -RemoveLabels @($ActiveLabel)
            return "retry"
        }
    }
}

function Acquire-Lock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot
    )

    $lockPath = Join-Path $StateRoot "worker.lock"

    if (Test-Path -LiteralPath $lockPath) {
        $existing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $pidValue = [int]$existing.pid
        if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
            Write-Log "Another queue worker process is already active (PID $pidValue). Exiting."
            return $null
        }
    }

    $payload = @{
        pid = $PID
        created_at = (Get-Date).ToString("o")
        repo = $RepoSlug
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $lockPath
    return $lockPath
}

function Release-Lock {
    param(
        [string]$LockPath
    )

    if ($LockPath -and (Test-Path -LiteralPath $LockPath)) {
        Remove-Item -LiteralPath $LockPath -Force
    }
}

Add-ToolPath

if ([string]::IsNullOrWhiteSpace($WorkerName)) {
    $WorkerName = Get-DefaultWorkerName
}

$stateRoot = Resolve-StateRoot -RepoSlugValue $RepoSlug -ExplicitStateRoot $StateRoot
$script:QueueRunId = [guid]::NewGuid().ToString()
$script:WorkerLogPath = Join-Path $stateRoot "worker.log"
$lockPath = Acquire-Lock -StateRoot $stateRoot
if (-not $lockPath) {
    exit 0
}

$processedCount = 0
$processedIssueNumbersThisRun = New-Object 'System.Collections.Generic.HashSet[int]'
try {
    try {
        Ensure-QueueLabels -Repo $RepoSlug
        $codexPath = Ensure-LocalCodexBinary -StateRoot $stateRoot
        Write-Log "Using local Codex binary at $codexPath"
        Send-DashboardEvent -Type "worker_run_started" -Data @{
            state_root = $stateRoot
            message = "Worker run started."
            processed_count = $processedCount
        }

        while ($processedCount -lt $MaxIssuesPerRun) {
            $nextIssue = Get-NextQueuedIssue -Repo $RepoSlug -ExcludeIssueNumbers ([int[]]@($processedIssueNumbersThisRun))
            if (-not $nextIssue) {
                Write-Log "Queue is empty."
                Send-DashboardEvent -Type "queue_empty" -Data @{
                    message = "Queue is empty."
                    processed_count = $processedCount
                }
                break
            }

            $issueNumber = [int]$nextIssue.number
            Write-Log "Claiming issue #$issueNumber - $($nextIssue.title)"

            Edit-IssueLabels -Repo $RepoSlug -IssueNumber $issueNumber -AddLabels @($ActiveLabel) -RemoveLabels @($BlockedLabel, $CompleteLabel)
            Comment-OnIssue -Repo $RepoSlug -IssueNumber $issueNumber -Body "Autonomous worker ``$WorkerName`` claimed this issue and is starting work now."
            Send-DashboardEvent -Type "issue_claimed" -Data @{
                issue_number = $issueNumber
                issue_title = $nextIssue.title
                issue_url = $nextIssue.url
                processed_count = $processedCount
                message = "Claimed issue #$issueNumber."
            }

            $packet = Get-IssuePacket -Repo $RepoSlug -IssueNumber $issueNumber
            try {
                $invocation = Invoke-CodexIssueRun -CodexPath $codexPath -RepoRootValue $RepoRoot -StateRoot $stateRoot -Repo $RepoSlug -Worker $WorkerName -IssueNumber $issueNumber -IssuePacket $packet
            }
            catch {
                Write-Log "Codex invocation for issue #$issueNumber failed before producing a result: $($_.Exception.Message)"
                $invocation = @{
                    Attempt = Get-IssueAttemptCount -StateRoot $stateRoot -IssueNumber $issueNumber
                    ExitCode = 1
                    RunDirectory = $stateRoot
                    Result = $null
                    StdoutPath = $null
                    StderrPath = $null
                    ResultPath = $null
                }
            }
            $outcome = Apply-ResultToIssue -Repo $RepoSlug -StateRoot $stateRoot -Worker $WorkerName -IssueNumber $issueNumber -InvocationResult $invocation

            Write-Log "Issue #$issueNumber finished with queue outcome '$outcome'."
            $processedCount += 1
            $processedIssueNumbersThisRun.Add($issueNumber) | Out-Null
            Send-DashboardEvent -Type "issue_finished" -Data @{
                issue_number = $issueNumber
                issue_title = $nextIssue.title
                issue_url = $nextIssue.url
                outcome = $outcome
                processed_count = $processedCount
                message = "Issue #$issueNumber finished with outcome '$outcome'."
            }
        }

        Write-Log "Processed $processedCount issue(s) this run."
        Send-DashboardEvent -Type "worker_run_finished" -Data @{
            outcome = "idle"
            processed_count = $processedCount
            message = "Worker run finished."
        }
    }
    catch {
        Send-DashboardEvent -Type "worker_run_failed" -Data @{
            processed_count = $processedCount
            message = $_.Exception.Message
        }
        throw
    }
}
finally {
    Release-Lock -LockPath $lockPath
}
