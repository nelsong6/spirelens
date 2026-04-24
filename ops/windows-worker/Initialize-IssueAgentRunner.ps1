param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultUri,

    [string]$GitHubPatSecretName = "github-pat",
    [string]$RunnerRoot = "D:\\actions-runner",
    [string]$RunnerLabels = "issue-agent",
    [string]$RunnerGroup = "",
    [string]$RunnerNamePrefix = "issue-agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
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
        "$env:ProgramFiles(x86)\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd",
        "$env:ProgramFiles\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd",
        "C:\\ProgramData\\chocolatey\\bin\\az.cmd"
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

            Write-Host "Attempt $attempt of $MaxAttempts failed for $Description: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-RunnerService {
    param([Parameter(Mandatory = $true)][string]$ServiceNamePrefix)

    return Get-Service | Where-Object { $_.Name -like "$ServiceNamePrefix*" } | Select-Object -First 1
}

function Get-InstanceMetadata {
    $metadataUri = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
    return Invoke-RestMethod -Headers @{ Metadata = "true" } -Method Get -Uri $metadataUri -TimeoutSec 5
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

function Invoke-GitHubPost {
    param([Parameter(Mandatory = $true)][string]$Path)

    $headers = @{
        Accept               = "application/vnd.github+json"
        Authorization        = "Bearer $script:GitHubPat"
        "User-Agent"         = "spirelens-vmss-bootstrap"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    return Invoke-RestMethod -Method Post -Uri "https://api.github.com$Path" -Headers $headers
}

function Get-GitHubRunnerToken {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("registration", "remove")]
        [string]$TokenType
    )

    $response = Invoke-WithRetry -Description "GitHub $TokenType token" -ScriptBlock {
        Invoke-GitHubPost -Path "/repos/$RepositorySlug/actions/runners/$TokenType-token"
    }

    if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.token)) {
        throw "GitHub did not return a $TokenType token for $RepositorySlug."
    }

    return [string]$response.token
}

$RepositorySlug = $RepositorySlug.Trim()
if ([string]::IsNullOrWhiteSpace($RepositorySlug)) {
    throw "RepositorySlug must not be empty."
}

$RepositoryUrl = $RepositoryUrl.Trim().TrimEnd("/")
if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
    $RepositoryUrl = "https://github.com/$RepositorySlug"
}

$RunnerGroup = $RunnerGroup.Trim()
$RunnerNamePrefix = $RunnerNamePrefix.Trim("-")
if ([string]::IsNullOrWhiteSpace($RunnerNamePrefix)) {
    $RunnerNamePrefix = "issue-agent"
}

$RunnerRoot = [Environment]::ExpandEnvironmentVariables($RunnerRoot)
$RunnerLabelsList = @(
    $RunnerLabels -split "," |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($RunnerLabelsList.Count -eq 0) {
    throw "RunnerLabels must include at least one label."
}

$RunnerLabels = [string]::Join(",", $RunnerLabelsList)
$KeyVaultUri = $KeyVaultUri.TrimEnd("/") + "/"
$secretId = "${KeyVaultUri}secrets/$GitHubPatSecretName"

$configCmdPath = Join-Path $RunnerRoot "config.cmd"
$runnerConfigPath = Join-Path $RunnerRoot ".runner"
$serviceNamePrefix = "actions.runner.$($RepositorySlug -replace '/', '-')."
$runnerName = "$RunnerNamePrefix-$env:COMPUTERNAME"

try {
    $instanceMetadata = Invoke-WithRetry -Description "Azure instance metadata" -MaxAttempts 6 -DelaySeconds 5 -ScriptBlock {
        Get-InstanceMetadata
    }

    $metadataName = [string]$instanceMetadata.name
    if (-not [string]::IsNullOrWhiteSpace($metadataName)) {
        $runnerName = (($RunnerNamePrefix, $metadataName) -join "-") -replace "[^A-Za-z0-9._-]", "-"
    }
} catch {
    Write-Host "Azure instance metadata was unavailable. Falling back to COMPUTERNAME for the runner name."
}

if (-not (Test-Path -LiteralPath $configCmdPath)) {
    throw "GitHub Actions runner config was not found at '$configCmdPath'."
}

$azCliPath = Get-AzureCliPath

Write-Step "Logging into Azure with the VM managed identity"
Invoke-WithRetry -Description "Azure managed identity login" -ScriptBlock {
    & $azCliPath login --identity --allow-no-subscriptions --output none | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "az login --identity failed with exit code $LASTEXITCODE."
    }
}

Write-Step "Reading GitHub PAT secret '$GitHubPatSecretName' from Key Vault '$KeyVaultName'"
$script:GitHubPat = Invoke-WithRetry -Description "Key Vault secret read" -MaxAttempts 12 -DelaySeconds 15 -ScriptBlock {
    $secretValue = & $azCliPath keyvault secret show --id $secretId --query value --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretValue)) {
        throw "Unable to read '$GitHubPatSecretName' from '$KeyVaultName'."
    }

    return [string]$secretValue
}

Grant-NetworkServiceModifyAccess -Path $RunnerRoot
Grant-NetworkServiceModifyAccess -Path "D:\\automation"
Grant-NetworkServiceModifyAccess -Path "D:\\repos"
Grant-NetworkServiceModifyAccess -Path "D:\\SteamLibrary"

$existingService = Get-RunnerService -ServiceNamePrefix $serviceNamePrefix
if ((Test-Path -LiteralPath $runnerConfigPath) -and $null -ne $existingService) {
    Write-Step "Runner is already configured. Ensuring service '$($existingService.Name)' is running."
    Ensure-RunnerServiceRunning -ServiceName $existingService.Name
    Write-Step "Issue-agent runner bootstrap is already complete."
    exit 0
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
    $removeToken = Get-GitHubRunnerToken -TokenType remove

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

$registrationToken = Get-GitHubRunnerToken -TokenType registration
$configureArgs = @(
    "--unattended",
    "--url", $RepositoryUrl,
    "--token", $registrationToken,
    "--name", $runnerName,
    "--work", "_work",
    "--labels", $RunnerLabels,
    "--replace",
    "--runasservice"
)

if (-not [string]::IsNullOrWhiteSpace($RunnerGroup)) {
    $configureArgs += @("--runnergroup", $RunnerGroup)
}

Write-Step "Registering runner '$runnerName' for '$RepositorySlug'"
Push-Location $RunnerRoot
try {
    & $configCmdPath @configureArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "config.cmd failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

$runnerService = Invoke-WithRetry -Description "runner service discovery" -MaxAttempts 10 -DelaySeconds 6 -ScriptBlock {
    $service = Get-RunnerService -ServiceNamePrefix $serviceNamePrefix
    if ($null -eq $service) {
        throw "Runner service has not appeared yet."
    }

    return $service
}

Ensure-RunnerServiceRunning -ServiceName $runnerService.Name
Write-Step "Issue-agent runner bootstrap completed successfully."
