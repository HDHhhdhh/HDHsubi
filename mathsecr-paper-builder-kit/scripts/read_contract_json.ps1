function ConvertFrom-MathSecrContractJson {
  param([Parameter(Mandatory = $true)][string]$Json)
  # PowerShell 7.5+ otherwise converts ISO timestamps to DateTime and loses
  # their typed wire representation. PS 5.1 already preserves JSON strings.
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    return ConvertFrom-Json -InputObject $Json -DateKind String
  }
  return ConvertFrom-Json -InputObject $Json
}
