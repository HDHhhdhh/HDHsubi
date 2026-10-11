[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RosterPath,
  [Parameter(Mandatory)][string]$OccurrenceKey,
  [Parameter(Mandatory)][string]$ObservationPath,
  [Parameter(Mandatory)][string]$BodyJudgmentPath,
  [Parameter(Mandatory)][string]$CandidateRenderPath,
  [Parameter(Mandatory)][string]$OutPath,
  [string]$ProjectRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
  . (Join-Path $PSScriptRoot 'selection_assembly.ps1')
  $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  $paths=[ordered]@{
    roster=(Resolve-MathSecrAssemblyPath $RosterPath $ProjectRoot '.json')
    observation=(Resolve-MathSecrAssemblyPath $ObservationPath $ProjectRoot '.json')
    judgment=(Resolve-MathSecrAssemblyPath $BodyJudgmentPath $ProjectRoot '.json')
    candidateRender=(Resolve-MathSecrAssemblyPath $CandidateRenderPath $ProjectRoot '.png')
  }
  $output=Resolve-MathSecrAssemblyPath $OutPath $ProjectRoot '.json' -Output
  $hashes=[ordered]@{}
  foreach ($key in $paths.Keys) {$hashes[$key]=Get-MathSecrAssemblyHash $paths[$key]}
  $candidateRelative=$paths.candidateRender.Substring($ProjectRoot.Length+1).Replace('\','/')
  $arguments=@{
    Roster=(ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $paths.roster -Raw -Encoding UTF8))
    Observation=(ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $paths.observation -Raw -Encoding UTF8))
    Judgment=(ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $paths.judgment -Raw -Encoding UTF8))
    OccurrenceKey=$OccurrenceKey;CandidateRelativePath=$candidateRelative;ProjectRoot=$ProjectRoot
    InputHashes=[pscustomobject]$hashes
  }
  $target=New-MathSecrAssembledTarget @arguments
  foreach ($key in $paths.Keys) {
    if ((Get-MathSecrAssemblyHash $paths[$key]) -cne $hashes[$key]) {throw 'assembly-input-changed'}
  }
  if (-not [string]::Equals((Get-MathSecrAssemblyHash (Join-Path $ProjectRoot $target.sourceBodyArtifact.path)),
      $target.sourceBodyArtifact.sha256,[StringComparison]::OrdinalIgnoreCase)) {throw 'roster-hash-mismatch'}
  $output=Resolve-MathSecrAssemblyPath $OutPath $ProjectRoot '.json' -Output
  $json=ConvertTo-Json -InputObject $target -Depth 80
  $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json+[Environment]::NewLine)
    $stream.Write($bytes,0,$bytes.Length)
  } finally {$stream.Dispose()}
  [pscustomobject]@{assembled=$true;path=$output;resolution=$target.resolution} | ConvertTo-Json -Compress
} catch {
  [pscustomobject]@{assembled=$false;reason=$_.Exception.Message} | ConvertTo-Json -Compress
  exit 1
}
