[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CodeRoot,
  [Parameter(Mandatory)][string]$FixtureRoot,
  [Parameter(Mandatory)][string]$SessionPath,
  [Parameter(Mandatory)][string]$OutPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $CodeRoot 'mathsecr-paper-builder-kit/scripts/production_validation.ps1')

function Add-MathSecrIdentityScalarTypes {
  param($Value, [string]$Path, [Collections.Generic.List[object]]$Rows)
  if ($null -eq $Value) {
    $Rows.Add([pscustomobject]@{path=$Path;type='<null>'})
  } elseif ($Value -is [array]) {
    for ($index=0; $index -lt $Value.Count; $index++) {
      Add-MathSecrIdentityScalarTypes $Value[$index] ($Path + '[' + $index + ']') $Rows
    }
  } elseif ($Value -is [pscustomobject]) {
    foreach ($property in $Value.PSObject.Properties) {
      Add-MathSecrIdentityScalarTypes $property.Value ($Path + "['" + $property.Name.Replace("'","''") + "']") $Rows
    }
  } elseif ($Value -is [Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      Add-MathSecrIdentityScalarTypes $Value[$key] ($Path + "['" + ([string]$key).Replace("'","''") + "']") $Rows
    }
  } else {
    $Rows.Add([pscustomobject]@{path=$Path;type=$Value.GetType().FullName})
  }
}

$session = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8)
try {
  $result = Invoke-MathSecrProductionStep -Step AfterReload -InputObject $session -ProjectRoot $FixtureRoot
} catch {
  $envelope = [pscustomobject]@{accepted=$false;error=$_.Exception.Message;resultJson=$null;scalarTypes=@()}
  [IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $envelope -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
  exit 0
}
$types = [Collections.Generic.List[object]]::new()
Add-MathSecrIdentityScalarTypes $result '$' $types
# The generator fixes all timestamps. Keep them, including their CLR types:
# comparing every field is stronger than removing the permitted time fields.
$envelope = [pscustomobject]@{
  accepted=$true;error=$null
  resultJson=(ConvertTo-Json -InputObject $result -Depth 100 -Compress)
  scalarTypes=$types.ToArray()
}
[IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $envelope -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
