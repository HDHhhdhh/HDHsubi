[CmdletBinding()]
param(
  [ValidateRange(1,100)][int]$Repeat = 3,
  [string]$OutPath = (Join-Path $PSScriptRoot '../../docs/evidence/perf-baseline.json')
)
$ErrorActionPreference = 'Stop'
$out = [IO.Path]::GetFullPath($OutPath)
if (Test-Path -LiteralPath $out) { throw 'A baseline already exists. Use a different OutPath to preserve previous measurements.' }
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($project))
$physicalDisks = @()
try { $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, BusType) } catch {}
$cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty Name)
$measurements = @(foreach ($depth in @(1,2,6)) {
  Write-Host "Measuring N=15 H=$depth Repeat=$Repeat (synthetic, warmed, instrumented)."
  $json = & (Join-Path $PSScriptRoot 'measure_after_reload.ps1') -ProblemCount 15 -HistoryDepth $depth -Repeat $Repeat
  if (-not $?) { throw "Measurement failed for H=$depth" }
  $json | ConvertFrom-Json
})
$hashes = [ordered]@{}
foreach ($name in @('production_validation.ps1','state_machine.ps1','read_contract_json.ps1')) {
  $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $project "mathsecr-paper-builder-kit/scripts/$name")).Hash.ToLowerInvariant()
}
$document = [ordered]@{
  schemaVersion=1;createdAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
  truthScope='offline-contract';liveProductBehavior=$false
  fixtureProvenance='new Phase 0 synthetic inputs from public contracts; private fixture bundle not used'
  environment=[ordered]@{
    os=[Environment]::OSVersion.VersionString;powerShell=$PSVersionTable.PSVersion.ToString();cpu=$cpu
    storage=[ordered]@{fileSystem=$drive.DriveFormat;physicalDisks=@($physicalDisks);
      diskModelObservation=$(if ($physicalDisks.Count) {'observed'} else {'unavailable from current process'})}
  }
  contractSha256=$hashes;measurements=$measurements
  comparisonLimit='Synthetic inputs and proxy overhead differ from the single historical live 113.83 s observation.'
}
$parent = Split-Path -Parent $out
$null = New-Item -ItemType Directory -Path $parent -Force
$json = (ConvertTo-Json -InputObject $document -Depth 15).Replace([Environment]::NewLine, [string][char]10) + [char]10
[IO.File]::WriteAllText($out, $json, [Text.UTF8Encoding]::new($false))
Write-Host 'Phase 0 baseline PASS (N=15, H=1/2/6); measurements written.'
