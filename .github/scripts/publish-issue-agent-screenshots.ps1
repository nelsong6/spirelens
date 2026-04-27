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

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PreviewMarkdownPath) | Out-Null
Remove-Item -LiteralPath $PreviewMarkdownPath -Force -ErrorAction SilentlyContinue

$published = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($ScreenshotDir) -or -not (Test-Path -LiteralPath $ScreenshotDir)) {
    Write-Warning "Screenshot directory not found: $ScreenshotDir"
    Set-Content -LiteralPath $PreviewMarkdownPath -Value '' -Encoding UTF8
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
        az storage blob upload `
            --auth-mode login `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $blobName `
            --file $file.FullName `
            --overwrite true `
            --content-type image/png `
            --only-show-errors | Out-Null

        $response = Invoke-WebRequest -Uri $blobUrl -Method Head -UseBasicParsing -TimeoutSec 20
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            throw "Blob preview verification returned HTTP $($response.StatusCode)."
        }

        $published.Add("![$relative]($blobUrl)") | Out-Null
        Write-Host "Published screenshot preview: $blobUrl"
    } catch {
        Write-Warning "Unable to publish screenshot '$($file.FullName)': $($_.Exception.Message)"
    }
}

$published | Set-Content -LiteralPath $PreviewMarkdownPath -Encoding UTF8
