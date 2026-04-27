param(
    [Parameter(Mandatory = $true)]
    [string]$ScreenshotDir,

    [Parameter(Mandatory = $true)]
    [string]$PreviewMarkdownPath,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerUrl,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [int]$Limit = 10
)

$ErrorActionPreference = 'Stop'

function Join-UrlPath {
    param([string[]]$Segments)
    return (($Segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/')
}

function Normalize-ContainerUrl {
    param([string]$Value)
    return $Value.TrimEnd('/')
}

function Add-PublishWarning {
    param([string]$Message)
    $script:warnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Write-PreviewMarkdown {
    $previewLines = New-Object System.Collections.Generic.List[string]
    foreach ($imageMarkdown in $published) { $previewLines.Add($imageMarkdown) | Out-Null }
    if ($warnings.Count -gt 0) {
        if ($previewLines.Count -gt 0) { $previewLines.Add('') | Out-Null }
        $previewLines.Add('> Screenshot publish warning: one or more screenshot previews could not be published. Use the uploaded artifacts as fallback evidence.') | Out-Null
        foreach ($warning in $warnings) { $previewLines.Add("> $warning") | Out-Null }
    }

    $previewLines | Set-Content -LiteralPath $PreviewMarkdownPath -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PreviewMarkdownPath) | Out-Null
Remove-Item -LiteralPath $PreviewMarkdownPath -Force -ErrorAction SilentlyContinue

$published = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($ScreenshotDir) -or -not (Test-Path -LiteralPath $ScreenshotDir)) {
    Add-PublishWarning "Screenshot directory not found: $ScreenshotDir"
    Write-PreviewMarkdown
    return
}

$root = (Resolve-Path -LiteralPath $ScreenshotDir).Path
$baseUrl = Normalize-ContainerUrl -Value $ContainerUrl
$files = @(Get-ChildItem -LiteralPath $ScreenshotDir -Recurse -File -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -First $Limit)

foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length) -replace '\\', '/'
    $relative = $relative.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = $file.Name }

    $blobName = "$RunId/$relative"
    $blobUrl = "$baseUrl/$(Join-UrlPath -Segments @($RunId))/$(Join-UrlPath -Segments ($relative -split '/'))"

    try {
        $uploadOutput = & az storage blob upload `
            --auth-mode login `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $blobName `
            --file $file.FullName `
            --overwrite true `
            --content-type image/png `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Azure blob upload failed: $uploadOutput" }

        $response = Invoke-WebRequest -Uri $blobUrl -Method Head -UseBasicParsing -TimeoutSec 20
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            throw "Blob preview verification returned HTTP $($response.StatusCode)."
        }

        $published.Add("![$relative]($blobUrl)") | Out-Null
        Write-Host "Published screenshot preview: $blobUrl"
    } catch {
        Add-PublishWarning "Unable to publish screenshot '$relative': $($_.Exception.Message)"
    }
}

Write-PreviewMarkdown
