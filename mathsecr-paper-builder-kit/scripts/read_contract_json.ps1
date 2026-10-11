function ConvertFrom-MathSecrContractJson {
  param([Parameter(Mandatory = $true)][string]$Json)
  # PowerShell 7.5+ otherwise converts ISO timestamps to DateTime and loses
  # their typed wire representation. PS 5.1 already preserves JSON strings.
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    return ConvertFrom-Json -InputObject $Json -DateKind String
  }
  return ConvertFrom-Json -InputObject $Json
}

function ConvertFrom-MathSecrArtifactBytes {
  param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
  # Get-Content -Raw -Encoding UTF8 consumes a UTF-8 BOM. Keep it in the
  # digest, but remove it before passing the same bytes to the contract reader.
  $offset = 0
  if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $offset = 3 }
  return ConvertFrom-MathSecrContractJson ([Text.Encoding]::UTF8.GetString($Bytes, $offset, $Bytes.Length - $offset))
}

function Read-MathSecrArtifactBytes {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    [switch]$Parse, [ref]$ArtifactBytes)
  $full = [IO.Path]::GetFullPath($Path)
  try { $bytes = [IO.File]::ReadAllBytes($full) } catch {
    $_.Exception.Data['MathSecrArtifactError'] = 'read'
    throw
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
  if (-not [string]::Equals($digest, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
    $artifactError = [IO.InvalidDataException]::new('Artifact hash does not match its bytes.')
    $artifactError.Data['MathSecrArtifactError'] = 'hash'
    throw $artifactError
  }
  if ($null -ne $ArtifactBytes) { $ArtifactBytes.Value = $bytes }
  $value = $null
  if ($Parse) {
    try { $value = ConvertFrom-MathSecrArtifactBytes -Bytes $bytes } catch {
      $_.Exception.Data['MathSecrArtifactError'] = 'parse'
      throw
    }
  }
  return [pscustomobject]@{Path=$full;Sha256=$digest;Value=$value}
}

function New-MathSecrValidationContext {
  param([Parameter(Mandatory=$true)][string]$ProjectRoot)
  return [pscustomobject]@{
    ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    ActiveDepth=0
    ArtifactCache=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    StateCache=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  }
}

function Enter-MathSecrValidationContext {
  param($Context, [Parameter(Mandatory=$true)][string]$ProjectRoot)
  $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  if ($null -eq $Context) { $Context = New-MathSecrValidationContext -ProjectRoot $root }
  if ($Context.ActiveDepth -eq 0) {
    # Even an explicitly reused context begins a fresh top-level validation.
    $Context.ArtifactCache.Clear()
    $Context.StateCache.Clear()
    $Context.ProjectRoot = $root
  } elseif (-not [string]::Equals($Context.ProjectRoot,$root,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Validation context cannot cross project roots during a validation.'
  }
  $Context.ActiveDepth++
  return $Context
}

function Exit-MathSecrValidationContext {
  param([Parameter(Mandatory=$true)]$Context)
  $Context.ActiveDepth--
  if ($Context.ActiveDepth -eq 0) {
    $Context.ArtifactCache.Clear()
    $Context.StateCache.Clear()
  }
}

function Get-MathSecrValidationArtifact {
  param([Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    $Context, [switch]$Parse)
  $full = [IO.Path]::GetFullPath($Path)
  if ($null -eq $Context) { return Read-MathSecrArtifactBytes -Path $full -ExpectedSha256 $ExpectedSha256 -Parse:$Parse }
  $key = $full + '|' + $ExpectedSha256.ToLowerInvariant()
  if (-not $Context.ArtifactCache.ContainsKey($key)) {
    $bytes = $null
    $artifact = Read-MathSecrArtifactBytes -Path $full -ExpectedSha256 $ExpectedSha256 -Parse:$Parse -ArtifactBytes ([ref]$bytes)
    $Context.ArtifactCache[$key] = [pscustomobject]@{Artifact=$artifact;Bytes=$bytes;Parsed=[bool]$Parse}
  }
  $entry = $Context.ArtifactCache[$key]
  if ($Parse -and -not $entry.Parsed) {
    try { $entry.Artifact.Value = ConvertFrom-MathSecrArtifactBytes -Bytes $entry.Bytes } catch {
      $_.Exception.Data['MathSecrArtifactError'] = 'parse'
      throw
    }
    $entry.Parsed = $true
  }
  return $entry.Artifact
}
