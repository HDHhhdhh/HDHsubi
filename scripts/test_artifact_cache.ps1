[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/scripts/read_contract_json.ps1')

function Assert-ArtifactCacheTest {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

# Model a case-sensitive volume without changing Windows directory settings.
# Replace only byte I/O; keep the production reader's SHA check and errors.
$originalReader = (Get-Command Read-MathSecrArtifactBytes).ScriptBlock
$script:caseBytes = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
$script:caseReads = 0
$reader = $originalReader.ToString().Replace(
  '[IO.File]::ReadAllBytes($full)',
  '$( $script:caseReads++; $script:caseBytes[$full] )')
Set-Item Function:Read-MathSecrArtifactBytes ([scriptblock]::Create($reader))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'artifact-cache-case'))
$upper = Join-Path $root 'Candidate.png'
$lower = Join-Path $root 'candidate.png'
$script:caseBytes[$upper] = [Text.Encoding]::UTF8.GetBytes('first artifact')
$script:caseBytes[$lower] = [Text.Encoding]::UTF8.GetBytes('second artifact')
$sha = [Security.Cryptography.SHA256]::Create()
try {
  $upperHash = [BitConverter]::ToString($sha.ComputeHash($script:caseBytes[$upper])).Replace('-', '')
  $lowerHash = [BitConverter]::ToString($sha.ComputeHash($script:caseBytes[$lower])).Replace('-', '')
} finally { $sha.Dispose() }

$context = Enter-MathSecrValidationContext -ProjectRoot $root
try {
  $first = Get-MathSecrValidationArtifact -Path $upper -ExpectedSha256 $upperHash -Context $context
  $repeat = Get-MathSecrValidationArtifact -Path $upper -ExpectedSha256 $upperHash.ToLowerInvariant() -Context $context
  Assert-ArtifactCacheTest ([object]::ReferenceEquals($first, $repeat) -and $script:caseReads -eq 1) 'Identical path/hash did not hit the cache.'
  $rejected = $false
  try {
    $null = Get-MathSecrValidationArtifact -Path $lower -ExpectedSha256 $upperHash -Context $context
  } catch { $rejected = $_.Exception.Data['MathSecrArtifactError'] -ceq 'hash' }
  Assert-ArtifactCacheTest $rejected 'Case-distinct artifact reused the first file hash.'
  $second = Get-MathSecrValidationArtifact -Path $lower -ExpectedSha256 $lowerHash -Context $context
  Assert-ArtifactCacheTest ($second.Path -ceq $lower -and $second.Sha256 -ceq $lowerHash -and $script:caseReads -eq 3) 'Correct case-distinct hash was not read independently.'
  $otherRoot = Join-Path ([IO.Path]::GetDirectoryName($root)) 'Artifact-cache-case'
  $rejected = $false
  try {
    $null = Enter-MathSecrValidationContext -Context $context -ProjectRoot $otherRoot
  } catch { $rejected = $_.Exception.Message -ceq 'Validation context cannot cross project roots during a validation.' }
  Assert-ArtifactCacheTest $rejected 'Case-distinct project root reused the active context.'
} finally { Exit-MathSecrValidationContext -Context $context }

$context = Enter-MathSecrValidationContext -Context $context -ProjectRoot $root
try {
  $null = Get-MathSecrValidationArtifact -Path $upper -ExpectedSha256 $upperHash -Context $context
  Assert-ArtifactCacheTest ($script:caseReads -eq 4) 'A new top-level validation did not reread the artifact.'
} finally {
  Exit-MathSecrValidationContext -Context $context
  Set-Item Function:Read-MathSecrArtifactBytes $originalReader
}
Write-Host 'PASS artifact cache: case-distinct hash rejection, exact cache hit, root isolation, fresh top-level read.'
