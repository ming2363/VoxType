param([string]$OutputDirectory = (Join-Path $PSScriptRoot "artifacts/publish"))
$ErrorActionPreference = "Stop"
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "Building requires the .NET 10 SDK. End users of the portable package do not need a runtime installation."
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = "false"
Push-Location $PSScriptRoot
try {
    if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot $OutputDirectory }
    & dotnet run --project VoxType.Core.Checks/VoxType.Core.Checks.csproj -c Release -p:UseSharedCompilation=false
    if ($LASTEXITCODE -ne 0) { throw "Core checks failed." }
    & dotnet publish VoxType.Windows/VoxType.Windows.csproj -c Release -r win-x64 --self-contained true --disable-build-servers -p:UseSharedCompilation=false -o $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw "Windows publish failed." }
    Copy-Item (Join-Path $PSScriptRoot "README.md") (Join-Path $OutputDirectory "README.md") -Force
    Copy-Item (Join-Path $PSScriptRoot "VERIFICATION.md") (Join-Path $OutputDirectory "VERIFICATION.md") -Force
    Copy-Item (Join-Path $PSScriptRoot "../LICENSE") (Join-Path $OutputDirectory "LICENSE") -Force
    Copy-Item (Join-Path $PSScriptRoot "../NOTICE") (Join-Path $OutputDirectory "NOTICE") -Force
    $packageRoot = (& dotnet msbuild VoxType.Windows/VoxType.Windows.csproj -nologo -getProperty:NuGetPackageRoot).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $packageRoot)) { throw "Cannot locate runtime license files." }
    foreach ($name in @("microsoft.netcore.app.runtime.win-x64", "microsoft.windowsdesktop.app.runtime.win-x64")) {
        $packages = Join-Path $packageRoot $name
        if (-not (Test-Path $packages)) { throw "Missing runtime package notices: $name" }
        foreach ($version in Get-ChildItem $packages -Directory) {
            $destination = Join-Path $OutputDirectory "third-party/$name/$($version.Name)"
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Get-ChildItem $version.FullName -File | Where-Object { $_.Name -match 'LICENSE|NOTICE' } |
                Copy-Item -Destination $destination -Force
        }
    }
    Get-ChildItem $OutputDirectory -Recurse -File | Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
        Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($OutputDirectory.TrimEnd('\').Length + 1).Replace('\', '/')
            "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
        } | Set-Content (Join-Path $OutputDirectory "SHA256SUMS.txt") -Encoding utf8
    $zip = Join-Path (Split-Path $OutputDirectory) "VoxType-windows-x64-preview.zip"
    Compress-Archive -Path (Join-Path $OutputDirectory "*") -DestinationPath $zip -Force
    Write-Output "Portable preview: $zip"
} finally { Pop-Location }
