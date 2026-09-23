$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installedDevEcoHomes = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Huawei') `
  -Directory -Filter 'DevEco Studio*' -ErrorAction SilentlyContinue | ForEach-Object {
    $_.FullName
    Join-Path $_.FullName 'DevEco Studio'
  }
$devecoCandidates = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) + @($installedDevEcoHomes)
$devecoHome = $devecoCandidates |
  Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$sdkCandidates = @(
  $env:DEVECO_SDK_HOME,
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\6.1.0-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\23'),
  (Join-Path $projectRoot '.tools\harmony-sdk-26-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0'),
  (Join-Path $devecoHome 'sdk')
) | Where-Object { $_ -and (Test-Path $_) }
$sdkHome = $sdkCandidates | Select-Object -First 1
$targetApiLevel = $env:TAILSCALE_OHOS_TARGET_API_LEVEL
$readelfCandidates = @(
  $(if ($targetApiLevel) { Join-Path $sdkHome "$targetApiLevel\native\llvm\bin\llvm-readelf.exe" }),
  (Join-Path $sdkHome 'default\openharmony\native\llvm\bin\llvm-readelf.exe')
) | Where-Object { $_ }
$readelf = $readelfCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $readelf) {
  throw "llvm-readelf was not found under $sdkHome"
}
$goLibrary = Join-Path $projectRoot 'native\go_bridge\dist\arm64-v8a\libtailscale_go.so'
$hap = Get-ChildItem -Path (Join-Path $projectRoot 'entry\build') -Recurse -Filter '*.hap' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not (Test-Path $goLibrary)) {
  throw 'The Go shared library is missing.'
}
if (-not $hap) {
  throw 'The HAP artifact is missing.'
}

$header = (& $readelf -h $goLibrary) -join "`n"
if ($header -notmatch 'Machine:\s+AArch64' -or $header -notmatch 'Type:\s+DYN') {
  throw 'The Go library is not an AArch64 ELF shared object.'
}

$dynamic = (& $readelf -d $goLibrary) -join "`n"
if ($dynamic -notmatch 'SONAME.*libtailscale_go\.so') {
  throw 'The Go library does not expose the expected SONAME.'
}

$hapEntries = tar -tf $hap.FullName
$requiredEntries = @(
  'libs/arm64-v8a/libtailscale_go.so',
  'libs/arm64-v8a/libtailscale_ohos.so',
  'ets/modules.abc',
  'module.json'
)
foreach ($entry in $requiredEntries) {
  if ($hapEntries -notcontains $entry) {
    throw "HAP is missing required entry: $entry"
  }
}

$moduleJson = (tar -xOf $hap.FullName 'module.json') | ConvertFrom-Json
if ($moduleJson.app.apiReleaseType -ne 'Release') {
  throw "HAP uses a non-Release HarmonyOS API: $($moduleJson.app.apiReleaseType)"
}
if ($moduleJson.app.compileSdkVersion -match 'Beta|Canary') {
  throw "HAP compileSdkVersion is not a Release SDK: $($moduleJson.app.compileSdkVersion)"
}

Write-Host "Verified Release API $($moduleJson.app.compileSdkVersion) AArch64 Go/N-API HAP: $($hap.FullName)"
