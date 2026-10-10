[CmdletBinding()]
param(
  [AllowEmptyString()]
  [string]$StartYear,
  [AllowEmptyString()]
  [string]$EndYear
)

# Conservative offline adapter policy; this is not evidence of MathSecr's upstream normalization.
function Test-LocalFiniteNumber {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $false
  }

  $numericTypeCodes = @(
    [System.TypeCode]::SByte,
    [System.TypeCode]::Byte,
    [System.TypeCode]::Int16,
    [System.TypeCode]::UInt16,
    [System.TypeCode]::Int32,
    [System.TypeCode]::UInt32,
    [System.TypeCode]::Int64,
    [System.TypeCode]::UInt64,
    [System.TypeCode]::Single,
    [System.TypeCode]::Double,
    [System.TypeCode]::Decimal
  )
  if ([System.Type]::GetTypeCode($Value.GetType()) -notin $numericTypeCodes) {
    return $false
  }

  $number = [double]$Value
  return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function ConvertTo-LocalYearRangePayload {
  param(
    [AllowNull()][object]$StartYear,
    [AllowNull()][object]$EndYear
  )

  $payload = [ordered]@{}
  if (
    (Test-LocalFiniteNumber $StartYear) -and
    (Test-LocalFiniteNumber $EndYear) -and
    ([double]$StartYear -le [double]$EndYear)
  ) {
    $payload.sourceStartYear = $StartYear
    $payload.sourceEndYear = $EndYear
  }

  return [pscustomobject]$payload
}

function ConvertTo-LocalCliYear {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  $parsedYear = 0.0
  $parsed = [double]::TryParse(
    $Value,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$parsedYear
  )
  if (-not $parsed) {
    return $null
  }

  return $parsedYear
}

if ($MyInvocation.InvocationName -ne ".") {
  $cliStartYear = ConvertTo-LocalCliYear -Value $StartYear
  $cliEndYear = ConvertTo-LocalCliYear -Value $EndYear
  ConvertTo-LocalYearRangePayload -StartYear $cliStartYear -EndYear $cliEndYear | ConvertTo-Json -Compress
}
