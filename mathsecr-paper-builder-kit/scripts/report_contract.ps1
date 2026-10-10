# This contract validates the full internal evidence packet. User-facing output is
# the closed 0-4 projection (paper link, success/failure counts, crop report, sources)
# defined in AGENTS.md and SKILL.md.
. (Join-Path $PSScriptRoot "search_attempt_contract.ps1")
. (Join-Path $PSScriptRoot "read_contract_json.ps1")

$script:AllowedStatuses = @( "완료", "부분 완료", "검색 완료/0선택", "차단" )
$script:RequiredHeadings = @(
  "## MathSecr 세션 보고서",
  "### 프린트별 미발견 문제",
  "### 최초 범위 밖에서 선택한 exact 문제",
  "### 대체 또는 유사 문제",
  "### 실패 또는 위험 단계",
  "### 효율적이었던 단계",
  "### 검색 메모",
  "### 도구 메모",
  "### 남은 항목"
)
$script:IssueLabel = "- $([char]96)출제하기$([char]96) 클릭:"
$script:RequiredLabels = @(
  "세션 ID:",
  "문제지 URL:",
  "원본 파일:",
  "목표:",
  "최종 상태:",
  "사용자 지정 최초 DB/출처 범위:",
  "사용자 지정 최초 단원/유형 범위:",
  "사용한 브라우저 표면:",
  "비-Aside REPL live 조작 발생:",
  "비-Aside REPL 조작 발생 시 최종 상태:",
  "- 원본 문제 수:",
  "- 선택한 문제 수:",
  "- 저장 전 초안/로컬 선택 수:",
  "- 저장 후 재로드/새 탭 확인 수:",
  "- 최종 편집 화면 도달:",
  "- 저장/확인 컨트롤 클릭:",
  "- 새로고침 또는 새 탭 검증:",
  "- API/route/help/docs를 live tab에서 열었는지:",
  $script:IssueLabel,
  "미발견 문제 번호:",
  "시도한 검색/근거:",
  "- 저장 전 순서화된 target ID 목록:",
  "- 저장 후 재로드 target ID 목록:",
  "- 저장 전 순서화된 occurrenceKey 목록:",
  "- 저장 후 재로드 occurrenceKey 목록:",
  "- 카드/시각 identity fallback 근거:",
  "- 검색 시도 계약 receipt:",
  "- live tab 이동 사고:",
  "- 체크포인트 데이터:",
  "대체 문제 ID/cell ID:",
  "사용자 승인:"
)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Get-UniqueField {
  param([string]$Text, [string]$Label)

  $escaped = [regex]::Escape($Label)
  $matches = [regex]::Matches($Text, "(?m)^[ \t]*$escaped[ \t]*(?<value>[^\r\n]*)$")
  if ($matches.Count -ne 1) {
    throw "Required report field must appear exactly once: $Label"
  }
  $value = $matches[0].Groups["value"].Value.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Required report field must not be blank: $Label"
  }
  return $value
}

function Test-IsAsideReplOnlySurface {
  param([string]$Value)

  $normalized = (($Value -replace '[`()]+', ' ') -replace '\s+', ' ').Trim().ToLowerInvariant()
  return $normalized -in @(
    "aside repl",
    "aside repl only",
    "aside browser repl",
    "aside browser aside repl",
    "aside browser aside repl only"
  )
}

function Get-Count {
  param([hashtable]$Fields, [string]$Label)

  $value = $Fields[$Label]
  if ($value -notmatch "^\d+$") {
    throw "Count field must be numeric: $Label$value"
  }
  return [int]$value
}

function Assert-Enum {
  param([string]$Label, [string]$Value, [string[]]$Allowed)

  if ($Allowed -notcontains $Value) {
    throw "$Label must be one of: $($Allowed -join ', ')"
  }
}

function Test-IsCanonicalReportToken {
  param($Value)

  # Report IDs and occurrence keys are opaque tokens after comma formatting
  # has been trimmed. The exact `없음` sentinel is valid only for the whole
  # field, never as a list item; commas are delimiters and CR/LF are unsafe
  # embedded content. Internal TAB/NBSP and case remain preserved.
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  if ($Value -ceq "없음" -or $Value -cne $Value.Trim() -or $Value -match '^[ \t\u00A0]|[ \t\u00A0]$') {
    return $false
  }
  return -not [regex]::IsMatch($Value, '[,\r\n]')
}

function Test-HasDuplicateReportTokensOrdinal {
  param($Values)

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($value in @($Values)) {
    if (-not $seen.Add([string]$value)) {
      return $true
    }
  }
  return $false
}

function Get-OrderedIds {
  param([string]$Label, [string]$Value, [switch]$AllowDuplicates)

  if ($Value -eq "없음") {
    return @()
  }
  $ids = @($Value -split "," | ForEach-Object { $_.Trim() })
  if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw "$Label contains a blank ID"
  }
  if (@($ids | Where-Object { -not (Test-IsCanonicalReportToken $_) }).Count -gt 0) {
    throw "$Label contains a noncanonical ID token"
  }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($id in $ids) {
    if (-not $AllowDuplicates -and -not $seen.Add($id)) {
      throw "$Label contains duplicate IDs"
    }
  }
  return $ids
}

function Get-OccurrenceKeys {
  param([string]$Label, [string]$Value)

  if ($Value -eq "없음") {
    return @()
  }
  # Commas are report-text formatting, so trim only each token's edge
  # whitespace while preserving opaque internal whitespace and case.
  $keys = @($Value -split "," | ForEach-Object { $_.Trim() })
  if (@($keys | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw "$Label contains a blank occurrenceKey"
  }
  if (@($keys | Where-Object { -not (Test-IsCanonicalReportToken $_) }).Count -gt 0) {
    throw "$Label contains a noncanonical occurrenceKey"
  }
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($key in $keys) {
    if (-not $seen.Add($key)) {
      throw "$Label contains duplicate occurrenceKey values"
    }
  }
  return $keys
}

function Assert-FailedProblemReportPdf {
  param([string]$Path, [int[]]$FailedProblems)

  Assert-True ($FailedProblems.Count -gt 0) "PDF validation requires at least one failed printed number"
  $expectedNumbers = ($FailedProblems | ForEach-Object { [string]$_ }) -join ","
  # Keep PDF parsing deterministic and fail closed.  The report generator is
  # Python/reportlab-based, and pypdf is the narrow reader used here to verify
  # that the linked artifact is a readable PDF whose page/printed-number
  # sequence matches the public failure references.
  $pythonCode = @'
import re
import sys

try:
    from pypdf import PdfReader
except Exception as exc:
    print('pypdf dependency is required for failed-problem report validation: ' + str(exc), file=sys.stderr)
    raise SystemExit(2)

path = sys.argv[1]
expected = [int(value) for value in sys.argv[2].split(',') if value]
try:
    reader = PdfReader(path, strict=True)
    pages = list(reader.pages)
    if len(pages) != len(expected):
        raise ValueError('page count {} does not match failed printed-number count {}'.format(len(pages), len(expected)))
    for page_index, (page, number) in enumerate(zip(pages, expected), start=1):
        text = page.extract_text() or ''
        marker_pattern = rf'(?<!\d){re.escape(str(number))}번(?!\d)'
        if not re.search(marker_pattern, text):
            raise ValueError('page {} is missing printed marker {}번'.format(page_index, number))
except Exception as exc:
    print('PDF parse/marker validation failed: ' + str(exc), file=sys.stderr)
    raise SystemExit(3)

print('validated pages={} markers={}'.format(len(pages), ','.join(str(number) + '번' for number in expected)))
'@
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    try {
      $output = @(& python -c $pythonCode $Path $expectedNumbers 2>&1)
      $exitCode = $LASTEXITCODE
    } catch {
      throw "Unable to invoke Python for failed-problem report validation: $($_.Exception.Message)"
    }
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  if ($exitCode -ne 0) {
    $detail = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) {
      $detail = "Python PDF validator exited with code $exitCode"
    }
    throw "Failed-problem report PDF validation failed: $detail"
  }
}

function Assert-OrderedIdsEqual {
  param([string[]]$Expected, [string[]]$Actual)

  if ($Expected.Count -ne $Actual.Count) {
    throw "ordered ID bundles have different counts"
  }
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if ($Expected[$index] -cne $Actual[$index]) {
      throw "ordered ID bundles differ at position $index"
    }
  }
}

function Assert-OrderedOccurrenceKeysEqual {
  param([string[]]$Expected, [string[]]$Actual)

  if ($Expected.Count -ne $Actual.Count) {
    throw "occurrenceKey bundles have different counts"
  }
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if ($Expected[$index] -cne $Actual[$index]) {
      throw "occurrenceKey bundles differ at position $index"
    }
  }
}

function Assert-StructuredFallbackReceipt {
  param([string]$Value, [string]$ProjectRoot)

  $pattern = '^artifact=(?<artifact>[^;]+);\s*sha256=(?<sha256>[A-Fa-f0-9]{64});\s*identity=(?<identity>.+)$'
  $match = [regex]::Match($Value.Trim(), $pattern)
  if (-not $match.Success) {
    throw "card/visual identity fallback must use: artifact=<path>; sha256=<64 hex>; identity=<substantive description>"
  }

  $artifact = $match.Groups['artifact'].Value.Trim()
  $identity = $match.Groups['identity'].Value.Trim()
  Assert-True (-not [string]::IsNullOrWhiteSpace($artifact)) "fallback artifact path must not be blank"
  Assert-True ($artifact -notmatch '(^|[\\/])\.\.([\\/]|$)') "fallback artifact path must not escape through parent traversal"
  Assert-True (-not [IO.Path]::IsPathRooted($artifact)) "fallback artifact path must be relative to the trusted project root"
  Assert-True (-not [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($artifact))) "fallback artifact must name a file"
  Assert-True (-not [string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($artifact))) "fallback artifact must have a file extension"

  $genericIdentity = (($identity -replace '\s+', ' ').Trim()).ToLowerInvariant()
  Assert-True ($identity.Length -ge 20) "fallback identity description must be substantive"
  Assert-True ($genericIdentity -notin @( '있음', 'present', 'verified', '확인함', '증거 있음' )) "fallback identity description must be substantive"

  Assert-True (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) "fallback evidence verification requires a trusted project root"
  $rootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
  Assert-True (Test-Path -LiteralPath $rootFull -PathType Container) "fallback trusted project root does not exist"
  $artifactFull = [IO.Path]::GetFullPath((Join-Path $rootFull ($artifact -replace '/', '\')))
  $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  Assert-True ($artifactFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "fallback artifact resolves outside the trusted project root"
  Assert-True (Test-Path -LiteralPath $artifactFull -PathType Leaf) "fallback artifact file does not exist"
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactFull).Hash
  $expectedHash = $match.Groups['sha256'].Value.ToUpperInvariant()
  Assert-True ($actualHash -ceq $expectedHash) "fallback artifact SHA-256 does not match the receipt"
}

function Get-CanonicalMissedProblemNumbers {
  param([string]$Value, [string]$ReportStatus)

  if ($Value -ceq "없음") {
    return @()
  }
  if ($Value -ceq "전체 세션 — 차단") {
    Assert-True ($ReportStatus -ceq "차단") "미발견 문제 번호: 전체 세션 — 차단 requires 최종 상태: 차단"
    return @()
  }
  $tokens = @($Value -split ',' | ForEach-Object { $_.Trim() })
  Assert-True ($tokens.Count -gt 0) "미발견 문제 번호 must contain at least one number or 없음"
  $numbers = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($token in $tokens) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($token)) "미발견 문제 번호 contains a blank number"
    # Keep printed digits as strings so targetBinding comparisons never coerce
    # opaque identifiers. Reports may use `2` or `2번`.
    $match = [regex]::Match($token, '^(?<number>[0-9]+)(?:번)?$')
    Assert-True $match.Success "미발견 문제 번호 must be comma-separated printed numbers"
    $number = $match.Groups['number'].Value
    Assert-True ($number -match '^(?!0+$)[0-9]+$') "미발견 문제 번호 must be positive"
    Assert-True ($seen.Add($number)) "미발견 문제 번호 contains duplicate source problem numbers"
    $numbers.Add($number)
  }
  return @($numbers.ToArray())
}

function Test-IsCanonicalSearchTargetBindingValue {
  param($Value, [switch]$AllowReservedNone)

  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  if ($Value -cne $Value.Trim() -or $Value -match '[,\r\n]') {
    return $false
  }
  if (-not $AllowReservedNone -and $Value -ceq "없음") {
    return $false
  }
  return $true
}

function Assert-SearchAttemptContractEntry {
  param(
    [string]$Value,
    [string]$ProjectRoot,
    [string]$ReportStatus
  )

  $pattern = '^artifact=(?<artifact>[^;\r\n]+); sha256=(?<sha256>[A-Fa-f0-9]{64}); case=(?<case>[A-Za-z0-9][A-Za-z0-9._-]*); expected=(?<expected>candidate-recovery-pending|miss-closure-ready)$'
  $match = [regex]::Match($Value.Trim(), $pattern)
  if (-not $match.Success) {
    throw "search-attempt contract receipt must use: artifact=<ProjectRoot-relative-json>; sha256=<64 hex>; case=<case>; expected=<candidate-recovery-pending|miss-closure-ready>"
  }

  $artifact = $match.Groups['artifact'].Value.Trim()
  $expectedHash = $match.Groups['sha256'].Value.ToUpperInvariant()
  $caseName = $match.Groups['case'].Value
  $expectedStatus = $match.Groups['expected'].Value
  Assert-True (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) "search-attempt receipt verification requires a trusted project root"
  Assert-True ([IO.Path]::GetExtension($artifact).ToLowerInvariant() -eq '.json') "search-attempt receipt artifact must be a .json file"
  Assert-True (-not [IO.Path]::IsPathRooted($artifact)) "search-attempt receipt artifact must be relative to the trusted project root"
  Assert-True ($artifact -notmatch '(^|[\\/])\.\.([\\/]|$)') "search-attempt receipt artifact must not escape through parent traversal"
  Assert-True ($artifact -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') "search-attempt receipt artifact must not be a URL"

  $rootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
  Assert-True (Test-Path -LiteralPath $rootFull -PathType Container) "search-attempt receipt trusted project root does not exist"
  $artifactFull = [IO.Path]::GetFullPath((Join-Path $rootFull ($artifact -replace '/', '\')))
  $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  Assert-True ($artifactFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "search-attempt receipt artifact resolves outside the trusted project root"
  Assert-True (Test-Path -LiteralPath $artifactFull -PathType Leaf) "search-attempt receipt artifact file does not exist"
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactFull).Hash.ToUpperInvariant()
  Assert-True ($actualHash -ceq $expectedHash) "search-attempt receipt artifact SHA-256 does not match the receipt"

  try {
    $fixture = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $artifactFull -Raw -Encoding UTF8)
  } catch {
    throw "search-attempt receipt artifact is not valid JSON: $($_.Exception.Message)"
  }
  Assert-True ($null -ne $fixture.PSObject.Properties['cases'] -and $fixture.cases -is [System.Array]) "search-attempt receipt JSON must contain a cases array"
  $matchingCases = @($fixture.cases | Where-Object {
      $null -ne $_.PSObject.Properties['name'] -and
      $_.name -is [string] -and
      $_.name -ceq $caseName
    })
  Assert-True ($matchingCases.Count -eq 1) "search-attempt receipt case must appear exactly once: $caseName"
  $fixtureCase = $matchingCases[0]
  Assert-True ($null -ne $fixtureCase.PSObject.Properties['packet']) "search-attempt receipt case is missing packet: $caseName"

  $contract = Test-MathSecrSearchAttemptContract $fixtureCase.packet
  Assert-True ([bool]$contract.SchemaValid) "search-attempt receipt case has an invalid packet schema: $caseName"
  Assert-True ($expectedStatus -ceq [string]$contract.Status) "search-attempt receipt expected status does not match derived status: expected=$expectedStatus derived=$($contract.Status)"
  $derivedCanClose = [bool]$contract.CanCloseMiss
  Assert-True (($expectedStatus -ceq "miss-closure-ready") -eq $derivedCanClose) "search-attempt receipt expected closure does not match derived CanCloseMiss"
  if ($ReportStatus -ceq "검색 완료/0선택") {
    Assert-True ($expectedStatus -ceq "miss-closure-ready" -and $derivedCanClose) "검색 완료/0선택 requires a miss-closure-ready search-attempt receipt"
  }

  $targetBinding = $fixtureCase.packet.PSObject.Properties['targetBinding']
  Assert-True ($null -ne $targetBinding) "search-attempt receipt case is missing targetBinding: $caseName"
  $sourceNumberProperty = $targetBinding.Value.PSObject.Properties['sourceProblemNumber']
  Assert-True ($null -ne $sourceNumberProperty -and (Test-IsCanonicalSearchTargetBindingValue $sourceNumberProperty.Value)) "search-attempt receipt targetBinding.sourceProblemNumber must be a canonical nonblank string: $caseName"
  $occurrenceProperty = $targetBinding.Value.PSObject.Properties['occurrenceKey']
  Assert-True ($null -ne $occurrenceProperty -and (Test-IsCanonicalSearchTargetBindingValue $occurrenceProperty.Value)) "search-attempt receipt targetBinding.occurrenceKey must be a canonical opaque string: $caseName"

  return [pscustomobject]@{
    Receipt = $Value.Trim()
    Contract = $contract
    Artifact = $artifact
    ArtifactFull = $artifactFull
    Case = $caseName
    Expected = $expectedStatus
    SourceProblemNumber = [string]$sourceNumberProperty.Value
    OccurrenceKey = [string]$occurrenceProperty.Value
  }
}

function Assert-SearchAttemptContractReceipt {
  param(
    [string]$Value,
    [string]$ProjectRoot,
    [string]$ReportStatus,
    [string[]]$MissedProblemNumbers = @()
  )

  $missed = @($MissedProblemNumbers)
  if ($missed.Count -eq 0) {
    Assert-True ($Value -ceq "없음") "Reports without missed source problem numbers must use 검색 시도 계약 receipt: 없음"
    return [pscustomobject]@{
      Provided = $false
      Receipt = "없음"
      Entries = @()
      Contracts = @()
      MissingProblemNumbers = @()
      AllClosureReady = $true
      AggregateStatus = $null
      CommonChips = @()
      AttemptSummaries = @()
    }
  }
  Assert-True ($Value -cne "없음" -and -not [string]::IsNullOrWhiteSpace($Value)) "$ReportStatus with missed source problem numbers requires search-attempt contract receipts"

  # One required label remains in the report template. Multiple ordered
  # receipts use a delimiter that cannot occur in a Windows path or case name.
  $entries = @($Value -split '\s*\|\|\s*' | ForEach-Object { $_.Trim() })
  Assert-True ($entries.Count -eq $missed.Count) "search-attempt receipt count must equal missed source problem number count"
  Assert-True (@($entries | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "search-attempt receipt entries must not be blank"

  $receipts = [System.Collections.Generic.List[object]]::new()
  $caseKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $targetNumbers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $occurrenceKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  for ($index = 0; $index -lt $entries.Count; $index++) {
    $entry = Assert-SearchAttemptContractEntry $entries[$index] $ProjectRoot $ReportStatus
    Assert-True ($targetNumbers.Add($entry.SourceProblemNumber)) "search-attempt receipts reuse a target source problem number: $($entry.SourceProblemNumber)"
    Assert-True ($entry.SourceProblemNumber -ceq $missed[$index]) "search-attempt receipt targetBinding.sourceProblemNumber does not match missed problem number at position $($index + 1): expected=$($missed[$index]) actual=$($entry.SourceProblemNumber)"
    $caseKey = $entry.ArtifactFull + "|" + $entry.Case
    Assert-True ($caseKeys.Add($caseKey)) "search-attempt receipts reuse the same fixture case: $($entry.Case)"
    Assert-True ($occurrenceKeys.Add($entry.OccurrenceKey)) "search-attempt receipts reuse targetBinding.occurrenceKey: $($entry.OccurrenceKey)"
    $receipts.Add($entry)
  }

  $allClosureReady = (@($receipts | Where-Object { -not [bool]$_.Contract.CanCloseMiss }).Count -eq 0)
  if ($ReportStatus -ceq "검색 완료/0선택") {
    Assert-True $allClosureReady "검색 완료/0선택 requires every missed source problem receipt to be miss-closure-ready"
  }
  $aggregateStatus = if ($allClosureReady) { "miss-closure-ready" } else { "candidate-recovery-pending" }

  $commonChips = @($receipts[0].Contract.CommonChips)
  for ($receiptIndex = 1; $receiptIndex -lt $receipts.Count; $receiptIndex++) {
    $otherChips = @($receipts[$receiptIndex].Contract.CommonChips)
    $commonChips = @($commonChips | Where-Object {
        $chip = $_
        @($otherChips | Where-Object { $_ -ceq $chip }).Count -gt 0
      })
  }
  $attemptSummaries = @($receipts | ForEach-Object { $_.Contract.AttemptSummaries })
  return [pscustomobject]@{
    Provided = $true
    Receipt = ($receipts | ForEach-Object { $_.Receipt }) -join " || "
    Entries = @($receipts)
    Contracts = @($receipts | ForEach-Object { $_.Contract })
    MissingProblemNumbers = @($missed)
    AllClosureReady = $allClosureReady
    AggregateStatus = $aggregateStatus
    CommonChips = @($commonChips)
    AttemptSummaries = @($attemptSummaries)
  }
}

function Invoke-MathSecrReportLint {
  param([string]$Text, [string]$ProjectRoot)

  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
  }
  $Text = $Text -replace "`r`n", "`n" -replace "`r", "`n"
  Assert-True ($Text -notlike "*미완성(0선택)*") "Forbidden stale zero-selection label: 미완성(0선택)"
  foreach ($heading in $script:RequiredHeadings) {
    Assert-True (([regex]::Matches($Text, [regex]::Escape($heading))).Count -eq 1) "Required report heading must appear exactly once: $heading"
  }

  $fields = @{}
  foreach ($label in $script:RequiredLabels) {
    $fields[$label] = Get-UniqueField $Text $label
  }

  $status = $fields["최종 상태:"]
  Assert-Enum "최종 상태" $status $script:AllowedStatuses
  $nonAsideRepl = $fields["비-Aside REPL live 조작 발생:"]
  Assert-Enum "비-Aside REPL live 조작 발생" $nonAsideRepl @( "예", "아니오" )
  $nonAsideReplOutcome = $fields["비-Aside REPL 조작 발생 시 최종 상태:"]
  $browserSurface = $fields["사용한 브라우저 표면:"]
  $asideReplOnlySurface = Test-IsAsideReplOnlySurface $browserSurface
  $noBrowserSurface = $browserSurface -eq "없음"
  if ($nonAsideRepl -eq "예") {
    Assert-True ($status -eq "차단" -and $nonAsideReplOutcome -eq "차단") "Any non-Aside-REPL live manipulation must report final status 차단"
    Assert-True (-not $asideReplOnlySurface -and -not $noBrowserSurface) "비-Aside REPL=yes requires a non-Aside-REPL browser surface"
  } else {
    Assert-True ($nonAsideReplOutcome -eq "없음") "비-Aside REPL 조작 발생 시 최종 상태 must be 없음 when no non-Aside-REPL manipulation occurred"
    Assert-True ($asideReplOnlySurface -or $noBrowserSurface) "A non-Aside-REPL or unrecognized browser surface contradicts 비-Aside REPL=no"
  }
  if ($status -in @( "완료", "부분 완료", "검색 완료/0선택" )) {
    Assert-True $asideReplOnlySurface "$status requires an Aside-REPL-only browser surface"
  }
  if ($noBrowserSurface) {
    Assert-True ($status -eq "차단") "사용한 브라우저 표면: 없음 is allowed only for 차단"
  }

  $editReached = $fields["- 최종 편집 화면 도달:"]
  $saveControl = $fields["- 저장/확인 컨트롤 클릭:"]
  $reload = $fields["- 새로고침 또는 새 탭 검증:"]
  $routeAccident = $fields["- API/route/help/docs를 live tab에서 열었는지:"]
  $issue = $fields[$script:IssueLabel]
  Assert-Enum "최종 편집 화면 도달" $editReached @( "예", "아니오" )
  Assert-Enum "저장/확인 컨트롤 클릭" $saveControl @( "예", "아니오", "없음" )
  Assert-Enum "새로고침 또는 새 탭 검증" $reload @( "예", "아니오" )
  Assert-Enum "API/route/help/docs 사고" $routeAccident @( "예", "아니오" )
  Assert-Enum "출제하기 클릭" $issue @( "예", "아니오" )
  Assert-True ($issue -eq "아니오") "출제하기 click cannot be 예 in a valid report"

  $original = Get-Count $fields "- 원본 문제 수:"
  $selected = Get-Count $fields "- 선택한 문제 수:"
  $draft = Get-Count $fields "- 저장 전 초안/로컬 선택 수:"
  $persisted = Get-Count $fields "- 저장 후 재로드/새 탭 확인 수:"
  Assert-True ($selected -le $original) "Selected count cannot exceed original count"

  $missed = $fields["미발견 문제 번호:"]
  $triedClues = $fields["시도한 검색/근거:"]
  $missedProblemNumbers = @(Get-CanonicalMissedProblemNumbers $missed $status)
  $searchAttemptReceipt = Assert-SearchAttemptContractReceipt `
    $fields["- 검색 시도 계약 receipt:"] `
    $ProjectRoot `
    $status `
    $missedProblemNumbers
  $beforeIds = @(Get-OrderedIds "- 저장 전 순서화된 target ID 목록:" $fields["- 저장 전 순서화된 target ID 목록:"] -AllowDuplicates)
  $afterIds = @(Get-OrderedIds "- 저장 후 재로드 target ID 목록:" $fields["- 저장 후 재로드 target ID 목록:"] -AllowDuplicates)
  $beforeOccurrenceKeys = @(Get-OccurrenceKeys "- 저장 전 순서화된 occurrenceKey 목록:" $fields["- 저장 전 순서화된 occurrenceKey 목록:"])
  $afterOccurrenceKeys = @(Get-OccurrenceKeys "- 저장 후 재로드 occurrenceKey 목록:" $fields["- 저장 후 재로드 occurrenceKey 목록:"])
  $hasDuplicateIds = (Test-HasDuplicateReportTokensOrdinal $beforeIds) -or
    (Test-HasDuplicateReportTokensOrdinal $afterIds)
  $hasOccurrenceKeys = ($beforeOccurrenceKeys.Count -gt 0 -or $afterOccurrenceKeys.Count -gt 0)
  if ($hasOccurrenceKeys) {
    Assert-True ($beforeOccurrenceKeys.Count -gt 0 -and $afterOccurrenceKeys.Count -gt 0) "occurrenceKey bundles must both be present or both be 없음"
    Assert-True ($beforeOccurrenceKeys.Count -eq $afterOccurrenceKeys.Count) "occurrenceKey bundles have different counts"
    Assert-OrderedOccurrenceKeysEqual $beforeOccurrenceKeys $afterOccurrenceKeys
  }
  if ($hasDuplicateIds) {
    Assert-True $hasOccurrenceKeys "duplicate ID bundles require selected/edit/persisted occurrenceKey evidence"
    Assert-True ($beforeIds.Count -eq $selected -and $afterIds.Count -eq $selected) "duplicate ID bundles require ordered ID counts to equal selected count"
    Assert-True ($beforeOccurrenceKeys.Count -eq $selected -and $afterOccurrenceKeys.Count -eq $selected) "duplicate ID bundles require occurrenceKey counts to equal selected count"
  }
  if ($hasOccurrenceKeys -and $beforeIds.Count -eq 0 -and $afterIds.Count -eq 0) {
    throw "occurrenceKey bundles cannot accompany empty target ID bundles"
  }
  $fallback = $fields["- 카드/시각 identity fallback 근거:"]
  $replacementId = $fields["대체 문제 ID/cell ID:"]
  $replacementApproval = $fields["사용자 승인:"]
  Assert-Enum "사용자 승인" $replacementApproval @( "명시", "명시 세션 정책", "승인 없음" )
  if ($replacementId -eq "없음") {
    Assert-True ($replacementApproval -eq "승인 없음") "No replacement ID requires 사용자 승인: 승인 없음"
  } else {
    Assert-True ($replacementApproval -in @( "명시", "명시 세션 정책" )) "A replacement ID requires explicit user approval or explicit session policy"
  }

  if ($status -in @( "완료", "부분 완료" )) {
    Assert-True ($selected -gt 0) "$status requires selected count above zero"
    Assert-True ($draft -eq $selected -and $persisted -eq $selected) "$status requires draft and persisted counts to equal selected count"
    Assert-True ($editReached -eq "예" -and $reload -eq "예") "$status requires edit screen and reload verification"
    Assert-True ($saveControl -in @( "예", "없음" )) "$status requires a clicked or absent save control"
    if ($beforeIds.Count -eq 0 -and $afterIds.Count -eq 0) {
      Assert-StructuredFallbackReceipt $fallback $ProjectRoot
    } else {
      Assert-True ($beforeIds.Count -eq $selected -and $afterIds.Count -eq $selected) "$status requires ordered ID counts to equal selected count"
      Assert-OrderedIdsEqual $beforeIds $afterIds
      if ($hasOccurrenceKeys) {
        Assert-True ($beforeOccurrenceKeys.Count -eq $selected -and $afterOccurrenceKeys.Count -eq $selected) "$status requires occurrenceKey counts to equal selected count"
      }
    }
  }

  if ($status -eq "완료") {
    Assert-True ($selected -eq $original -and $selected -gt 0) "완료 requires selected count to equal original count and be positive"
    Assert-True ($missed -eq "없음" -and $triedClues -eq "없음") "완료 cannot include missed search evidence"
  }
  if ($status -eq "부분 완료") {
    Assert-True ($selected -lt $original) "부분 완료 requires selected count below original count"
    Assert-True ($missed -ne "없음" -and $triedClues -ne "없음") "부분 완료 requires missed numbers and tried clues"
  }
  if ($status -eq "검색 완료/0선택") {
    Assert-True ($original -gt 0) "zero-selection requires original count above zero"
    Assert-True ($selected -eq 0 -and $draft -eq 0 -and $persisted -eq 0) "zero-selection requires selected, draft, and persisted counts of zero"
    Assert-True ($editReached -eq "아니오" -and $saveControl -eq "없음" -and $reload -eq "아니오") "zero-selection cannot enter edit or persistence verification"
    Assert-True ($beforeIds.Count -eq 0 -and $afterIds.Count -eq 0 -and $beforeOccurrenceKeys.Count -eq 0 -and $afterOccurrenceKeys.Count -eq 0 -and $fallback -eq "없음") "zero-selection cannot claim selected bundle evidence"
    Assert-True ($missed -ne "없음" -and $triedClues -ne "없음") "zero-selection requires missed numbers and tried clues"
  }

  return [pscustomobject]@{
    Status = $status
    Original = $original
    Selected = $selected
    Draft = $draft
    Persisted = $persisted
    ReloadVerified = $reload
    OrderedBundleEvidence = ($beforeIds.Count -gt 0 -or $beforeOccurrenceKeys.Count -gt 0 -or $fallback -ne "없음")
    SearchAttemptReceipt = $searchAttemptReceipt.Receipt
    SearchAttemptStatus = if ($searchAttemptReceipt.Provided) { [string]$searchAttemptReceipt.AggregateStatus } else { $null }
    SearchAttemptCanCloseMiss = if ($searchAttemptReceipt.Provided) { [bool]$searchAttemptReceipt.AllClosureReady } else { $false }
    SearchAttemptCommonChips = @($searchAttemptReceipt.CommonChips)
    SearchAttemptAttempts = @($searchAttemptReceipt.AttemptSummaries)
    SearchAttemptReceipts = @($searchAttemptReceipt.Entries)
    MissedProblemNumbers = @($missedProblemNumbers)
  }
}

function Invoke-MathSecrUserSummaryLint {
  param([string]$Text, [pscustomobject]$ExpectedProjection)

  Assert-True (-not [string]::IsNullOrWhiteSpace($Text)) "User summary must not be blank"
  $normalized = (($Text -replace "`r`n", "`n") -replace "`r", "`n").Trim()
  # The public projection is a closed schema (blank lines and indentation are
  # presentation-only):
  #   0. 제작한 문제지 링크
  #      - [paper](https://www.mathsecr.com/mypaper/<digits>)
  #   1. 성공한 문제 S문제/T문제
  #   2. 실패한 문제 F문제/T문제
  #      1. 6번, 8번, 9번 | 없음 | 전체 세션 — 차단
  #   3. 실패한 문제 이미지 크롭 보고서 PDF
  #      - [report](<absolute-local-pdf>) | 없음
  #   4. 출처
  #      1. <source> — N문제 (up to three rows, descending by count)
  $lines = @($normalized -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
  Assert-True ($lines.Count -ge 9 -and $lines.Count -le 11) "User summary must contain 9-11 non-empty lines"
  Assert-True (-not ($normalized.Contains('#') -or $normalized.Contains('@'))) "User summary must not contain # or @ symbols"
  Assert-True ($lines[0] -eq "0. 제작한 문제지 링크") "User summary must start with: 0. 제작한 문제지 링크"
  Assert-True ($lines[2] -match '^1\. 성공한 문제 (0|[1-9][0-9]*)문제/[1-9][0-9]*문제$') "User summary success count line is invalid"
  Assert-True ($lines[3] -match '^2\. 실패한 문제 (0|[1-9][0-9]*)문제/[1-9][0-9]*문제$') "User summary failure count line is invalid"
  Assert-True ($lines[5] -eq "3. 실패한 문제 이미지 크롭 보고서 PDF") "User summary must contain the failed-problem PDF line"
  Assert-True ($lines[7] -eq "4. 출처") "User summary must contain the 출처 section"

  $paperMatch = [regex]::Match($lines[1], '^- \[(?<label>[^\]]+)\]\((?<url>https://www\.mathsecr\.com/mypaper/[0-9]+)\)$')
  Assert-True $paperMatch.Success "Paper link must be a MathSecr mypaper Markdown link"
  $paperLabel = $paperMatch.Groups['label'].Value
  $paperUrl = $paperMatch.Groups['url'].Value
  Assert-True (-not [string]::IsNullOrWhiteSpace($paperLabel)) "Paper link label must not be blank"

  $successMatch = [regex]::Match($lines[2], '^1\. 성공한 문제 (?<success>0|[1-9][0-9]*)문제/(?<total>[1-9][0-9]*)문제$')
  $failureMatch = [regex]::Match($lines[3], '^2\. 실패한 문제 (?<failure>0|[1-9][0-9]*)문제/(?<total>[1-9][0-9]*)문제$')
  $successCount = [int]$successMatch.Groups['success'].Value
  $failureCount = [int]$failureMatch.Groups['failure'].Value
  $successTotal = [int]$successMatch.Groups['total'].Value
  $failureTotal = [int]$failureMatch.Groups['total'].Value
  Assert-True ($successTotal -gt 0) "User summary total must be positive"
  Assert-True ($successTotal -eq $failureTotal) "Success and failure totals must match"
  Assert-True (($successCount + $failureCount) -eq $successTotal) "Success and failure counts must add up to total"

  $failureDetail = $lines[4]
  $failedProblems = @()
  $isBlocked = $false
  if ($failureDetail -eq '1. 없음') {
    Assert-True ($failureCount -eq 0) "실패한 문제 없음 requires 0문제/총문제"
  } elseif ($failureDetail -eq '1. 전체 세션 — 차단') {
    $isBlocked = $true
    Assert-True ($successCount -eq 0 -and $failureCount -eq $successTotal) "Whole-session blocker requires 0 success and all problems failed"
  } else {
    Assert-True ($failureDetail -match '^1\. [1-9][0-9]*번(?:, [1-9][0-9]*번)*$') "Failed-problem detail must be comma-separated N번 values"
    $failedProblems = @($failureDetail.Substring(3) -split ', ' | ForEach-Object { [int]($_ -replace '번$','') })
    Assert-True ($failedProblems.Count -eq $failureCount) "Failed-problem reference count must equal failure count"
    Assert-True (@($failedProblems | Sort-Object -Unique).Count -eq $failedProblems.Count) "Failed-problem references must not contain duplicates"
    Assert-True (@($failedProblems | Where-Object { $_ -lt 1 }).Count -eq 0) "Failed-problem references must be positive"
  }

  $pdfLabel = $null
  $pdfPath = $null
  if ($lines[6] -eq '- 없음') {
    Assert-True ($failureCount -eq 0 -or $isBlocked) "A failed-problem report PDF is required for per-problem failures"
  } else {
    $pdfMatch = [regex]::Match($lines[6], '^- \[(?<label>[^\]]+)\]\((?<target><[^>]+>|[^)]+)\)$')
    Assert-True $pdfMatch.Success "Failed-problem report must be a local PDF Markdown link or - 없음"
    $pdfLabel = $pdfMatch.Groups['label'].Value
    $pdfPath = $pdfMatch.Groups['target'].Value.Trim()
    if ($pdfPath.StartsWith('<') -and $pdfPath.EndsWith('>')) {
      $pdfPath = $pdfPath.Substring(1, $pdfPath.Length - 2)
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($pdfLabel)) "Failed-problem report PDF label must not be blank"
    Assert-True (-not [string]::IsNullOrWhiteSpace($pdfPath)) "Failed-problem report PDF path must not be blank"
    Assert-True ([IO.Path]::IsPathRooted($pdfPath)) "Failed-problem report PDF path must be an absolute local path"
    Assert-True ($pdfPath -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') "Failed-problem report PDF link must not be a URL"
    Assert-True ([IO.Path]::GetExtension($pdfPath).ToLowerInvariant() -eq '.pdf') "Failed-problem report path must end in .pdf"
    Assert-True (Test-Path -LiteralPath $pdfPath -PathType Leaf) "Failed-problem report PDF does not exist: $pdfPath"
    Assert-True ($failureCount -gt 0 -and -not $isBlocked) "A PDF link is only valid for per-problem failures"
    Assert-FailedProblemReportPdf $pdfPath ([int[]]$failedProblems)
  }

  $forbiddenInternalTokens = @($script:RequiredHeadings) + @($script:RequiredLabels) + @("### 개수", "## 성공한 문제", "## 실패한 문제")
  foreach ($forbidden in $forbiddenInternalTokens) {
    Assert-True (-not $normalized.Contains($forbidden)) "User summary leaked internal field: $forbidden"
  }

  $sourceLines = @($lines[8..($lines.Count - 1)])
  $sources = @()
  if ($successCount -eq 0) {
    Assert-True ($sourceLines.Count -eq 1 -and $sourceLines[0] -eq '1. 없음') "Zero-success summaries must contain only 1. 없음 under 출처"
  } else {
    Assert-True ($sourceLines.Count -ge 1 -and $sourceLines.Count -le 3) "출처 must contain one to three source rows when success is positive"
    $sourceRecords = @()
    $seenSources = @{}
    $previousCount = $null
    $sourceTotal = 0
    for ($index = 0; $index -lt $sourceLines.Count; $index++) {
      $sourceMatch = [regex]::Match($sourceLines[$index], '^(?<rank>[1-3])\. (?<name>.+) — (?<count>[1-9][0-9]*)문제$')
      Assert-True $sourceMatch.Success "출처 row must use: N. <출처> — N문제"
      $rank = [int]$sourceMatch.Groups['rank'].Value
      $name = $sourceMatch.Groups['name'].Value.Trim()
      $count = [int]$sourceMatch.Groups['count'].Value
      Assert-True ($rank -eq ($index + 1)) "출처 ranks must start at 1 and be consecutive"
      Assert-True (-not [string]::IsNullOrWhiteSpace($name)) "출처 name must not be blank"
      Assert-True ($name -notmatch '(?i)(?:https?://|ftp://|www\.|(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/|$))') "출처 name must not contain a URL"
      Assert-True ($name -notmatch '(?i)(?:문제\s*(?:id|아이디|번호)|(?:cell|problem)\s*[-_ ]?id|[?&]id=|\b(?:id|cellid|problemid)\b\s*[:=#-]?\s*[0-9]+)') "출처 name must not contain a problem ID"
      foreach ($forbidden in $forbiddenInternalTokens) {
        Assert-True (-not $name.Contains($forbidden)) "출처 name leaked internal field: $forbidden"
      }
      $forbiddenSourceLabels = @("문제지 URL", "원본 파일", "최종 상태", "사용한 브라우저", "원본 문제 수", "선택한 문제 수", "미발견 문제 번호", "시도한 검색", "저장 전", "저장 후", "대체 문제 ID", "사용자 승인", "체크포인트 데이터")
      foreach ($forbiddenLabel in $forbiddenSourceLabels) {
        Assert-True (-not $name.Contains($forbiddenLabel)) "출처 name leaked internal field: $forbiddenLabel"
      }
      foreach ($internalLabel in $script:RequiredLabels) {
        $bareInternalLabel = $internalLabel.Trim().TrimStart('-').Trim().TrimEnd(':').Trim()
        if ($bareInternalLabel.Length -ge 3) {
          Assert-True (-not $name.Contains($bareInternalLabel)) "출처 name leaked internal field: $bareInternalLabel"
        }
      }
      Assert-True ($count -le $successCount) "출처 count cannot exceed 성공한 문제 count"
      $sourceTotal += $count
      $sourceKey = (($name -replace '\s+', ' ').Trim()).ToLowerInvariant()
      Assert-True (-not $seenSources.ContainsKey($sourceKey)) "출처 names must not repeat"
      $seenSources[$sourceKey] = $true
      if ($null -ne $previousCount) {
        Assert-True ($count -le $previousCount) "출처 rows must be sorted by descending frequency"
      }
      $previousCount = $count
      $sourceRecords += [pscustomobject]@{ name = $name; count = $count; rank = $rank }
    }
    Assert-True ($sourceTotal -le $successCount) "출처 counts sum cannot exceed 성공한 문제 count"
    $sources = @($sourceRecords)
  }

  # Text-only callers retain the historical format lint. The production path
  # supplies a projection freshly derived from the validated session and checks
  # every public claim against it, including source identity and tie order.
  if ($null -ne $ExpectedProjection) {
    Assert-True (Test-MathSecrSearchRequiredProperties $ExpectedProjection @('OriginalCount','SuccessCount','FailureCount','FailedNumbers','PaperUrl','PaperName','FailureReportPdf','Sources')) "Typed summary projection is incomplete"
    Assert-True ($successTotal -eq $ExpectedProjection.OriginalCount -and $successCount -eq $ExpectedProjection.SuccessCount -and $failureCount -eq $ExpectedProjection.FailureCount) "User summary counts differ from the typed session"
    Assert-True (-not $isBlocked) "A validated production projection cannot become a whole-session blocker"
    Assert-True ($paperUrl -ceq $ExpectedProjection.PaperUrl -and $paperLabel -ceq $ExpectedProjection.PaperName) "User summary paper differs from the typed session"
    $expectedFailures = @($ExpectedProjection.FailedNumbers | ForEach-Object { [int]$_ })
    Assert-True ($failedProblems.Count -eq $expectedFailures.Count) "User summary failed rows differ from the typed session"
    for ($i=0; $i -lt $expectedFailures.Count; $i++) {
      Assert-True ($failedProblems[$i] -eq $expectedFailures[$i]) "User summary failed row order differs from the typed session"
    }
    $expectedPdf = if ($ExpectedProjection.FailureReportPdf -ceq '없음') { $null } else { $ExpectedProjection.FailureReportPdf }
    Assert-True ($pdfPath -ceq $expectedPdf) "User summary failure PDF differs from the typed session"
    Assert-True ($sources.Count -eq @($ExpectedProjection.Sources).Count) "User summary sources differ from persisted cards"
    for ($i=0; $i -lt $sources.Count; $i++) {
      Assert-True ($sources[$i].name -ceq $ExpectedProjection.Sources[$i].Name -and $sources[$i].count -eq $ExpectedProjection.Sources[$i].Count) "User summary source name/count/order differs from persisted cards"
    }
  }

  return [pscustomobject]@{
    Success = $successCount
    Failure = $failureCount
    Total = $successTotal
    SuccessCount = $successCount
    FailureCount = $failureCount
    TotalCount = $successTotal
    FailedProblems = $failedProblems
    IsBlocked = $isBlocked
    PaperUrl = $paperUrl
    PaperLabel = $paperLabel
    ReportPdf = $pdfPath
    ReportPdfLabel = $pdfLabel
    Sources = $sources
    Lines = $lines
  }
}
