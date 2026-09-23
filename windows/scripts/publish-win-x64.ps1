# Publish CryptoMako CLI + Desktop for win-x64 (dev/soft ship).
# Usage: pwsh ./scripts/publish-win-x64.ps1 [-SelfContained]
param(
    [switch]$SelfContained,
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$rid = "win-x64"
$sc = [bool]$SelfContained
$cliOut = Join-Path $Root "artifacts/cli-$rid$(if ($sc) { '-sc' } else { '' })"
$deskOut = Join-Path $Root "artifacts/desktop-$rid$(if ($sc) { '-sc' } else { '' })"

Write-Host "Publishing CLI -> $cliOut"
dotnet publish src/CryptoMako.Cli -c $Configuration -r $rid --self-contained:$sc -o $cliOut
Write-Host "Publishing Desktop (WinUI 3 unpackaged) -> $deskOut"
dotnet publish src/CryptoMako.Desktop -c $Configuration -p:Platform=x64 -r $rid --self-contained:$sc -p:PublishSingleFile=false -o $deskOut

Write-Host "Done. Product display name: CryptoMako. Exe/package: cryptomako (CLI AssemblyName)."
Write-Host "Desktop is WinUI 3 / Windows App SDK (WindowsPackageType=None, self-contained WASDK)."
Write-Host "Never bake CRYPTOMAKO_* secrets into publish output."
