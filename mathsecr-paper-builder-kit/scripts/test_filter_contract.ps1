[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), [string]$NodePath = 'node')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'search_observation_contract.ps1')
. (Join-Path $PSScriptRoot 'read_contract_json.ps1')
$packetPath = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-filter-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  & $NodePath (Join-Path $PSScriptRoot 'test_filter_collector.cjs') $packetPath
  if ($LASTEXITCODE -ne 0) { throw 'Synthetic filter collector failed.' }
  $json = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
} finally {
  if (Test-Path -LiteralPath $packetPath) { Remove-Item -LiteralPath $packetPath -Force }
}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $cases=ConvertFrom-Json -InputObject $json -DateKind String }
else { $cases=ConvertFrom-Json -InputObject $json }
function Copy-LabPacket {
  param($Packet)
  $json=ConvertTo-Json -InputObject $Packet -Depth 30 -Compress
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $json -DateKind String }
  return ConvertFrom-Json -InputObject $json
}
$script:checks=0
function Assert-Lab {
  param([bool]$Condition,[string]$Name)
  if (-not $Condition) { throw "FAIL Filter Contract: $Name" }
  $script:checks++
}
$normal=Copy-LabPacket $cases.normal
$normal.observations=@($normal.observations | Select-Object -First 2)
$result=Test-MathSecrSearchObservation -Packet $normal
Assert-Lab ($result.FreshResultVerified -and $result.RequiredReadCount -eq 2) 'complete observed criteria accepts ordinary two reads'
Assert-Lab ($result.Projection.FilterChips.Count -eq 11) 'projection retains all encoded observed field groups'
Assert-Lab (-not $result.Projection.BackendCausalityVerified -and -not $result.Projection.BodyExactVerified -and
  -not $result.Projection.CompleteCoverageVerified -and -not $result.Projection.MonotonicClockVerified) 'unchanged claim boundaries'
foreach ($property in $cases.PSObject.Properties) {
  if ($property.Name.StartsWith('filter-change-')) {
    $packet=Copy-LabPacket $property.Value
    $result=Test-MathSecrSearchObservation -Packet $packet
    Assert-Lab ($result.FreshResultVerified -and $result.RequiredReadCount -eq 3 -and
      $result.RiskReasons -contains 'scope-or-filter-change') ($property.Name + ' derives three read risk')
    $packet.observations=@($packet.observations | Select-Object -First 2)
    $result=Test-MathSecrSearchObservation -Packet $packet
    Assert-Lab (-not $result.FreshResultVerified -and ($result.Errors -join ';') -match 'require 3') ($property.Name + ' rejects only two reads')
  } elseif ($property.Name.StartsWith('post-submit-drift-')) {
    $result=Test-MathSecrSearchObservation -Packet $property.Value
    Assert-Lab (-not $result.FreshResultVerified -and ($result.Errors -join ';') -match 'post-submit criteria drift') $property.Name
  }
}
foreach ($name in @('zero-result','partial-cards')) {
  $packet=Copy-LabPacket $cases.$name
  $result=Test-MathSecrSearchObservation -Packet $packet
  Assert-Lab ($result.FreshResultVerified -and $result.RequiredReadCount -eq 3) ($name + ' still requires three')
  $packet.observations=@($packet.observations | Select-Object -First 2)
  Assert-Lab (-not (Test-MathSecrSearchObservation -Packet $packet).FreshResultVerified) ($name + ' rejects two')
}
foreach ($entry in @(
  @{Name='reused-capture';Pattern='replayed'}, @{Name='reused-action';Pattern='action evidence'},
  @{Name='changed-order';Pattern='stable result signature'}, @{Name='loading-tail';Pattern='stable result signature'},
  @{Name='stale-native-submit';Pattern='stale'}
)) {
  $result=Test-MathSecrSearchObservation -Packet $cases.($entry.Name)
  Assert-Lab (-not $result.FreshResultVerified -and ($result.Errors -join ';') -match $entry.Pattern) $entry.Name
}
Write-Output "PASS Filter Contract: $script:checks checks; original strict contract unchanged; synthetic fixture evidence only"
foreach ($timestamp in @('2026-10-12T00:00:00.000Z','2026-10-12T00:00:00.160Z','2026-10-12T00:00:00.590Z')) {
  $wire = '{"capturedAtUtc":"' + $timestamp + '"}'
  $parsed = ConvertFrom-MathSecrContractJson $wire
  $replayed = ConvertFrom-MathSecrContractJson (ConvertTo-Json $parsed -Compress)
  Assert-Lab ($replayed.capturedAtUtc -is [string] -and $replayed.capturedAtUtc -ceq $timestamp) 'ISO string precision preserved by official reader'
}
Write-Output 'PASS Filter JSON Roundtrip: 3 original-reader ISO-string precision cases; validator unchanged'
