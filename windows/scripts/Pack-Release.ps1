<#
.SYNOPSIS
  Builds Lavboard for Windows self-contained and packs it with Velopack: Lavboard-win-Setup.exe,
  the full (and, given the previous release in OutputDir, delta) packages, and releases.win.json.
.EXAMPLE
  windows\scripts\Pack-Release.ps1 -Version 0.1.0
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutputDir = "$PSScriptRoot\..\artifacts\releases",
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64'
)
$ErrorActionPreference = 'Stop'
$windows = Resolve-Path "$PSScriptRoot\.."
$rid = if ($Platform -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$publish = Join-Path $windows "artifacts\publish\$rid"
Remove-Item -Recurse -Force $publish -ErrorAction SilentlyContinue

$msbuild = (Get-Command msbuild -ErrorAction SilentlyContinue).Source
if (-not $msbuild) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
}
& $msbuild "$windows\src\Lavboard\Lavboard.csproj" -restore -t:Publish -nologo -v:minimal `
    -p:Configuration=Release -p:Platform=$Platform -p:RuntimeIdentifier=$rid -p:SelfContained=true `
    -p:PublishDir="$publish\" -p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "build failed" }

if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) { $env:PATH += ";$env:USERPROFILE\.dotnet\tools" }
vpk pack --packId Lavboard --packVersion $Version --packDir $publish --mainExe Lavboard.exe `
    --packTitle Lavboard --packAuthors 'Mads Sauer' --icon "$windows\src\Lavboard\Assets\Lavboard.ico" `
    --channel win --runtime $rid --outputDir $OutputDir
if ($LASTEXITCODE -ne 0) { throw "packing failed" }
Get-ChildItem $OutputDir | Select-Object Name, Length | Format-Table -AutoSize
