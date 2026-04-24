param(
    [string]$RepositorySlug = "nelsong6/spirelens",
    [string]$RepositoryUrl = "",
    [string]$KeyVaultName = "",
    [string]$GitHubPatSecretName = "github-pat",
    [string]$GitHubPat = "",
    [string]$RunnerRoot = "",
    [string]$RunnerLabels = "issue-agent",
    [string]$RunnerGroup = "",
    [string]$RunnerNamePrefix = "issue-agent",
    [bool]$RunAsService = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AzureCliPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath;$env:Path"

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if ($azCommand) {
        return $azCommand.Source
    }

    $fallbacks = @(
        "$env:ProgramFiles(x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "C:\ProgramData\chocolatey\bin\az.cmd"
    )

    foreach ($candidate in $fallbacks) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Azure CLI was not found in PATH or known install locations."
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -eq $MaxAttempts) {
                throw
            }

            Write-Host "Attempt $attempt of $MaxAttempts failed for ${Description}: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Resolve-RunnerRoot {
    param([Parameter(Mandatory = $true)][string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return [Environment]::ExpandEnvironmentVariables($RequestedPath)
    }

    $candidates = @(
        "D:\actions-runner-spirelens",
        "C:\actions-runner-spirelens",
        "D:\actions-runner",
        "C:\actions-runner",
        (Join-Path $env:USERPROFILE "actions-runner-spirelens"),
        (Join-Path $env:USERPROFILE "actions-runner")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $candidates[0]
}

function Get-RunnerService {
    param([Parameter(Mandatory = $true)][string]$ServiceNamePrefix)

    return Get-Service | Where-Object { $_.Name -like "$ServiceNamePrefix*" } | Select-Object -First 1
}

function Ensure-RunnerServiceRunning {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    Set-Service -Name $ServiceName -StartupType Automatic

    $service = Get-Service -Name $ServiceName
    if ($service.Status -ne "Running") {
        Start-Service -Name $ServiceName
        $service.WaitForStatus("Running", [TimeSpan]::FromMinutes(2))
    }
}

function Grant-NetworkServiceModifyAccess {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Write-Step "Granting NETWORK SERVICE modify access to $Path"
    & icacls $Path /grant "*S-1-5-20:(OI)(CI)M" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for '$Path' with exit code $LASTEXITCODE."
    }
}

function Get-GitHubPatValue {
    param(
        [string]$DirectPat = "",
        [string]$VaultName = "",
        [Parameter(Mandatory = $true)][string]$SecretName
    )

    if (-not [string]::IsNullOrWhiteSpace($DirectPat)) {
        return $DirectPat
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) {
        return $env:GITHUB_PAT
    }

    if ([string]::IsNullOrWhiteSpace($VaultName)) {
        throw "Provide -GitHubPat, set GITHUB_PAT, or pass -KeyVaultName so the script can read '$SecretName'."
    }

    $azCliPath = Get-AzureCliPath
    Write-Step "Reading GitHub PAT secret '$SecretName' from Key Vault '$VaultName'"
    return Invoke-WithRetry -Description "Key Vault secret read" -ScriptBlock {
        $secretValue = & $azCliPath keyvault secret show --vault-name $VaultName --name $SecretName --query value --output tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretValue)) {
            throw "Unable to read '$SecretName' from '$VaultName'."
        }

        return [string]$secretValue
    }
}

function Invoke-GitHubPost {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pat
    )

    $headers = @{
        Accept                 = "application/vnd.github+json"
        Authorization          = "Bearer $Pat"
        "User-Agent"           = "spirelens-local-runner-bootstrap"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    return Invoke-RestMethod -Method Post -Uri "https://api.github.com$Path" -Headers $headers
}

function Get-GitHubRunnerToken {
    param(
        [Parameter(Mandatory = $true)][string]$Pat,
        [Parameter(Mandatory = $true)][string]$RepoSlug,
        [Parameter(Mandatory = $true)][ValidateSet("registration", "remove")][string]$TokenType
    )

    $response = Invoke-WithRetry -Description "GitHub $TokenType token" -ScriptBlock {
        Invoke-GitHubPost -Path "/repos/$RepoSlug/actions/runners/$TokenType-token" -Pat $Pat
    }

    if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.token)) {
        throw "GitHub did not return a $TokenType token for $RepoSlug."
    }

    return [string]$response.token
}

$RepositorySlug = $RepositorySlug.Trim()
if ([string]::IsNullOrWhiteSpace($RepositorySlug)) {
    throw "RepositorySlug must not be empty."
}

if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
    $RepositoryUrl = "https://github.com/$RepositorySlug"
} else {
    $RepositoryUrl = $RepositoryUrl.Trim().TrimEnd("/")
}

$RunnerRoot = Resolve-RunnerRoot -RequestedPath $RunnerRoot
$RunnerLabelsList = @(
    $RunnerLabels -split "," |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($RunnerLabelsList.Count -eq 0) {
    throw "RunnerLabels must include at least one label."
}

$RunnerLabels = [string]::Join(",", $RunnerLabelsList)
$RunnerName = (($RunnerNamePrefix.Trim("-"), $env:COMPUTERNAME) -join "-") -replace "[^A-Za-z0-9._-]", "-"
$serviceNamePrefix = "actions.runner.$($RepositorySlug -replace '/', '-')."
$configCmdPath = Join-Path $RunnerRoot "config.cmd"
$runnerConfigPath = Join-Path $RunnerRoot ".runner"
$isAdministrator = Test-IsAdministrator
$existingService = Get-RunnerService -ServiceNamePrefix $serviceNamePrefix

if (-not (Test-Path -LiteralPath $configCmdPath)) {
    throw "GitHub Actions runner config was not found at '$configCmdPath'. Install the runner files first."
}

if ((Test-Path -LiteralPath $runnerConfigPath) -and $null -ne $existingService) {
    if ($RunAsService) {
        if ($existingService.Status -eq "Running") {
            Write-Step "Runner is already configured and service '$($existingService.Name)' is already running."
        } elseif (-not $isAdministrator) {
            throw "Runner service '$($existingService.Name)' exists but is not running. Re-run this script from an elevated PowerShell session to manage the Windows service."
        } else {
            Write-Step "Runner is already configured. Ensuring service '$($existingService.Name)' is running."
            Ensure-RunnerServiceRunning -ServiceName $existingService.Name
        }
    } else {
        Write-Step "Runner is already configured."
    }

    exit 0
}

if ($RunAsService -and -not $isAdministrator) {
    throw "Run this script from an elevated PowerShell session when configuring or repairing a Windows service-backed runner."
}

$GitHubPat = Get-GitHubPatValue -DirectPat $GitHubPat -VaultName $KeyVaultName.Trim() -SecretName $GitHubPatSecretName

if ($RunAsService) {
    Grant-NetworkServiceModifyAccess -Path $RunnerRoot
}

if ((-not (Test-Path -LiteralPath $runnerConfigPath)) -and $null -ne $existingService) {
    Write-Step "Removing stale runner service '$($existingService.Name)' before re-registering."
    if ($existingService.Status -ne "Stopped") {
        Stop-Service -Name $existingService.Name -Force -ErrorAction SilentlyContinue
    }

    & sc.exe delete $existingService.Name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete stale runner service '$($existingService.Name)'."
    }

    Start-Sleep -Seconds 5
}

if (Test-Path -LiteralPath $runnerConfigPath) {
    Write-Step "Removing stale GitHub runner configuration before re-registering."
    $removeToken = Get-GitHubRunnerToken -Pat $GitHubPat -RepoSlug $RepositorySlug -TokenType remove

    Push-Location $RunnerRoot
    try {
        & $configCmdPath remove --unattended --token $removeToken | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "config.cmd remove failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

$registrationToken = Get-GitHubRunnerToken -Pat $GitHubPat -RepoSlug $RepositorySlug -TokenType registration
$configureArgs = @(
    "--unattended",
    "--url", $RepositoryUrl,
    "--token", $registrationToken,
    "--name", $RunnerName,
    "--work", "_work",
    "--labels", $RunnerLabels,
    "--replace"
)

if (-not [string]::IsNullOrWhiteSpace($RunnerGroup.Trim())) {
    $configureArgs += @("--runnergroup", $RunnerGroup.Trim())
}

if ($RunAsService) {
    $configureArgs += "--runasservice"
}

Write-Step "Registering runner '$RunnerName' for '$RepositorySlug'"
Push-Location $RunnerRoot
try {
    & $configCmdPath @configureArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "config.cmd failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

if ($RunAsService) {
    $runnerService = Invoke-WithRetry -Description "runner service discovery" -MaxAttempts 10 -DelaySeconds 6 -ScriptBlock {
        $service = Get-RunnerService -ServiceNamePrefix $serviceNamePrefix
        if ($null -eq $service) {
            throw "Runner service has not appeared yet."
        }

        return $service
    }

    Ensure-RunnerServiceRunning -ServiceName $runnerService.Name
}

Write-Step "Local issue-agent runner bootstrap completed successfully."
