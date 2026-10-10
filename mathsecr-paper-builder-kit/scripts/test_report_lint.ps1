param(
  [string]$ProjectRoot = (Get-Location).Path,
  [ValidateSet("All", "ValidComplete", "ValidCompleteLf", "ValidCompleteCrLf", "ValidFormattedIab", "ValidPartial", "ValidZero", "ValidBlockedNonIab", "ValidBlockedNoBrowser", "ValidBlockedMissedSentinel", "InvalidBlockedMissedSentinelNonBlocked", "InvalidBlockedMissedSentinelVariant", "ValidExplicitReplacement", "ValidSessionPolicyReplacement", "ValidStructuredFallback", "ValidDuplicateOccurrencesComplete", "ValidDuplicateOccurrencesPartial", "ValidDuplicateOccurrencesNumericStringKeys", "ValidDuplicateOccurrencesCanonicalWhitespaceCase", "ValidUnicodeOrdinalDistinctIds", "ValidOrdinalMixedCaseDuplicateIds", "ValidReportTokenInternalWhitespaceCase", "ValidUserSummary", "ValidUserSummaryPrintedNumbers", "ValidUserSummaryNone", "ValidUserSummaryBlocked", "InvalidUserSummaryExtraLines", "InvalidUserSummaryInternalLeak", "InvalidUserSummaryPreamble", "InvalidUserSummaryMissingPdf", "InvalidUserSummaryPdfMissing", "InvalidUserSummaryPdfUrl", "InvalidUserSummaryPdfExtension", "InvalidUserSummaryPdfTruncated", "InvalidUserSummaryPdfCorrupt", "InvalidUserSummaryPdfMismatch", "InvalidUserSummaryPdfPageCount", "InvalidUserSummaryPaperUrl", "InvalidUserSummaryCounts", "InvalidUserSummaryRefs", "InvalidUserSummaryNonPositiveRefs", "InvalidUserSummaryUnexpectedPdf", "InvalidUserSummaryBlockerCounts", "InvalidUserSummaryLeadingZero", "InvalidUserSummaryFourSources", "InvalidUserSummaryFrequency", "InvalidUserSummaryDuplicateSource", "InvalidUserSummaryZeroSuccessSource", "InvalidUserSummarySymbol", "InvalidUserSummarySourceUrl", "InvalidUserSummarySourceId", "InvalidUserSummarySourceInternal", "InvalidUserSummarySourceCount", "InvalidUserSummarySourceSum", "InvalidPartialPersistence", "InvalidBundleOrder", "InvalidDuplicateOccurrencesMissingKeys", "InvalidDuplicateOccurrencesBlankKeys", "InvalidDuplicateOccurrencesReorderedKeys", "InvalidDuplicateOccurrencesDuplicateKeys", "InvalidDuplicateOccurrencesWhitespaceCollision", "InvalidDuplicateOccurrencesCommaKey", "InvalidReportTokenSentinel", "InvalidReportTokenCrLf", "InvalidReportTokenComma", "InvalidCompleteZero", "InvalidZeroDraft", "InvalidZeroNoOriginal", "InvalidCompleteNoBrowser", "InvalidPartialNoBrowser", "InvalidZeroNoBrowser", "InvalidNonIabOutcome", "InvalidBlankBrowser", "InvalidChromeSurfaceNonIabNo", "InvalidComputerUseSurfaceNonIabNo", "InvalidIabSurfaceNonIabYes", "InvalidReplacementWithoutApproval", "InvalidReplacementApprovalValue", "InvalidFallbackPlaceholder", "InvalidFallbackMissingHash", "InvalidFallbackTraversal", "InvalidFallbackMissingArtifact", "InvalidFallbackHashMismatch", "InvalidZeroLabel", "InvalidSearchAttemptOneReceiptMultipleMisses", "InvalidSearchAttemptWrongTargetBinding", "InvalidSearchAttemptDuplicateTargetBinding", "InvalidSearchAttemptMissingReceipt", "InvalidSearchAttemptExtraReceipt")]
  [string]$Case = "All",
  [string]$ReportPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "report_contract.ps1")

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Expect-Rejection {
  param([string]$Name, [string]$Text, [string]$ExpectedFragment, [string]$TrustedProjectRoot)
  try {
    $null = Invoke-MathSecrReportLint $Text $TrustedProjectRoot
  } catch {
    Assert-True ($_.Exception.Message -like "*$ExpectedFragment*") "$Name rejected with unexpected message: $($_.Exception.Message)"
    Write-Host "$Name rejected as expected: $($_.Exception.Message)"
    return
  }
  throw "$Name should have failed report lint"
}

function Expect-UserSummaryRejection {
  param([string]$Name, [string]$Text, [string]$ExpectedFragment)
  try {
    $null = Invoke-MathSecrUserSummaryLint $Text
  } catch {
    Assert-True ($_.Exception.Message -like "*$ExpectedFragment*") "$Name rejected with unexpected message: $($_.Exception.Message)"
    Write-Host "$Name rejected as expected: $($_.Exception.Message)"
    return
  }
  throw "$Name should have failed user-summary lint"
}

function Invoke-Python {
  param([string[]]$Arguments)

  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & python @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { [string]$_ })
  }
}

function Get-SummaryFontPair {
  $candidates = @(
    @{ Regular = 'C:\Windows\Fonts\malgun.ttf'; Bold = 'C:\Windows\Fonts\malgunbd.ttf' },
    @{ Regular = 'C:\Windows\Fonts\arial.ttf'; Bold = 'C:\Windows\Fonts\arialbd.ttf' }
  )
  foreach ($candidate in $candidates) {
    if ((Test-Path -LiteralPath $candidate.Regular -PathType Leaf) -and
        (Test-Path -LiteralPath $candidate.Bold -PathType Leaf)) {
      return $candidate
    }
  }
  throw 'No usable Windows TrueType regular/bold font pair was found for the public-summary PDF fixture.'
}

function New-SummaryPdfFixture {
  param(
    [string]$Root,
    [string]$OutputPath,
    [int[]]$ProblemNumbers,
    [hashtable]$FontPair,
    [string]$ImagePath
  )

  Assert-True (Test-Path -LiteralPath $ImagePath -PathType Leaf) "Public-summary PDF fixture image is missing: $ImagePath"
  $manifestPath = Join-Path $Root ("manifest-" + ([IO.Path]::GetFileNameWithoutExtension($OutputPath)) + '.json')
  $items = @($ProblemNumbers | ForEach-Object {
      [ordered]@{ problem_number = $_; image = 'fixture.png'; crop = @(0, 0, 2, 2) }
    })
  $manifest = [ordered]@{
    title = 'Deterministic public summary report'
    source = 'local-fixture-source.pdf'
    items = $items
  }
  [IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 20),
    (New-Object Text.UTF8Encoding($false))
  )
  $generator = Join-Path $PSScriptRoot 'create_failed_problem_report.py'
  $result = Invoke-Python @(
    $generator,
    '--manifest', $manifestPath,
    '--output', $OutputPath,
    '--project-root', $Root,
    '--regular-font', $FontPair.Regular,
    '--bold-font', $FontPair.Bold
  )
  Assert-True ($result.ExitCode -eq 0) "Public-summary PDF fixture generation failed: $($result.Output -join [Environment]::NewLine)"
  Assert-True (Test-Path -LiteralPath $OutputPath -PathType Leaf) "Public-summary PDF fixture was not created: $OutputPath"
}

function New-CompleteReport {
  @"
## MathSecr 세션 보고서

세션 ID: fixture-complete
문제지 URL: local-fixture
원본 파일: fixture.pdf
목표: 8문항 exact 선택
최종 상태: 완료
사용자 지정 최초 DB/출처 범위: 교육청, 평가원
사용자 지정 최초 단원/유형 범위: 없음
사용한 브라우저 표면: Aside REPL
비-Aside REPL live 조작 발생: 아니오
비-Aside REPL 조작 발생 시 최종 상태: 없음

### 개수
- 원본 문제 수: 8
- 선택한 문제 수: 8
- 저장 전 초안/로컬 선택 수: 8
- 저장 후 재로드/새 탭 확인 수: 8
- 최종 편집 화면 도달: 예
- 저장/확인 컨트롤 클릭: 예
- 새로고침 또는 새 탭 검증: 예
- API/route/help/docs를 live tab에서 열었는지: 아니오
- $([char]96)출제하기$([char]96) 클릭: 아니오

### 프린트별 미발견 문제
- 프린트/원본 파일: 없음
  미발견 문제 번호: 없음
  시도한 검색/근거: 없음

### 최초 범위 밖에서 선택한 exact 문제
- 원본 문제 번호: 없음
  선택한 문제 ID/cell ID: 없음
  선택한 DB/출처: 없음
  벗어난 최초 범위: 없음
  exact 근거: 없음

### 대체 또는 유사 문제
- 원본 문제 번호: 없음
  대체 문제 ID/cell ID: 없음
  대체 문제 DB/출처: 없음
  유사하다고 본 근거: 없음
  사용자 승인: 승인 없음

### 실패 또는 위험 단계
- 증상: 없음
  원인: 없음
  복구: 없음
  남은 blocker: 없음

### 효율적이었던 단계
- 전술: ordered ID bundle 비교
  효과: count-only completion 방지
  재사용 조건: persisted reload evidence가 있을 때

### 검색 메모
- 잘 된 것: 없음
- 안 된 것: 없음
- 수식/검색어 정규화: 없음

### 도구 메모
- 브라우저 표면 및 비-Aside REPL 조작 여부: Aside REPL only
- 컨트롤 맵 갱신: 없음
- 결과 inventory/preflight 사용: 있음
- 저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8
- 저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8
- 저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8
- 저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8
- 카드/시각 identity fallback 근거: 없음
- 검색 시도 계약 receipt: 없음
- live tab 이동 사고: 아니오
- 체크포인트 데이터: fresh exact target ordered ID bundle matched after reload

### 남은 항목
- 미발견 문제: 없음
- 범위 밖 exact: 없음
- 대체/유사 후보: 없음
- 사용자 결정 필요: 없음
"@
}

function New-SearchAttemptFixtureReceipt {
  param(
    [string]$CaseName,
    [ValidateSet("candidate-recovery-pending", "miss-closure-ready")]
    [string]$ExpectedStatus,
    [string]$RelativePath = $null
  )

  $relativePath = if ($RelativePath) { $RelativePath } else { $script:SearchReceiptBundleRelativePath }
  Assert-True (-not [string]::IsNullOrWhiteSpace($relativePath)) "Search-attempt report fixture path was not initialized"
  $artifactPath = Join-Path $ProjectRoot ($relativePath -replace '/', '\')
  Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf) "Search-attempt fixture is missing: $artifactPath"
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash
  return "artifact=$relativePath; sha256=$hash; case=$CaseName; expected=$ExpectedStatus"
}

function Set-SearchAttemptReceipt {
  param([string]$Report, [string]$Receipt)

  return $Report -replace '(?m)^- 검색 시도 계약 receipt: [^\r\n]+$', ("- 검색 시도 계약 receipt: " + $Receipt)
}

function New-SearchAttemptReceiptForArtifact {
  param(
    [string]$Root,
    [string]$RelativePath,
    [string]$CaseName,
    [ValidateSet("candidate-recovery-pending", "miss-closure-ready")]
    [string]$ExpectedStatus
  )

  $artifactPath = Join-Path $Root ($RelativePath -replace '/', '\')
  Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf) "Search-attempt test artifact is missing: $artifactPath"
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash
  return "artifact=$RelativePath; sha256=$hash; case=$CaseName; expected=$ExpectedStatus"
}

function New-TargetBoundSearchAttemptFixture {
  param(
    [string]$SourcePath,
    [string]$OutputPath,
    [string[]]$SourceProblemNumbers,
    [string]$BaseCaseName = 'synthetic-absence-control',
    [string]$CasePrefix = 'report-target'
  )

  Assert-True (Test-Path -LiteralPath $SourcePath -PathType Leaf) "Search-attempt source fixture is missing: $SourcePath"
  try {
    $source = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
  } catch {
    throw "Search-attempt source fixture is not valid JSON: $($_.Exception.Message)"
  }
  Assert-True ($null -ne $source.PSObject.Properties['cases'] -and $source.cases -is [System.Array]) "Search-attempt source fixture must contain cases"
  $baseCase = @($source.cases | Where-Object {
      $_.PSObject.Properties['name'] -and $_.name -ceq $BaseCaseName
    } | Select-Object -First 1)[0]
  Assert-True ($null -ne $baseCase) "Search-attempt fixture must expose the requested target-bound case: $BaseCaseName"

  $cases = [System.Collections.Generic.List[object]]::new()
  $index = 0
  foreach ($sourceProblemNumber in @($SourceProblemNumbers)) {
    $clone = ($baseCase | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $index++
    $clone.name = "$CasePrefix-$index"
    $targetBinding = [pscustomobject]@{
      sourceProblemNumber = [string]$sourceProblemNumber
      occurrenceKey = "report-occurrence-$sourceProblemNumber"
    }
    $clone.packet | Add-Member -MemberType NoteProperty -Name targetBinding -Value $targetBinding -Force
    $cases.Add($clone)
  }
  $fixture = [ordered]@{
    schemaVersion = 1
    cases = $cases.ToArray()
  }
  $parent = Split-Path -Parent $OutputPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [IO.File]::WriteAllText($OutputPath, ($fixture | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
  Assert-True (Test-Path -LiteralPath $OutputPath -PathType Leaf) "Target-bound search-attempt fixture was not written: $OutputPath"
}

function Add-PhrasePrepassToSearchAttemptFixture {
  param([string]$Path)

  $fixture = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $phraseValue = "두 직선의 교점"
  foreach ($fixtureCase in @($fixture.cases)) {
    $packet = $fixtureCase.packet
    if (@($packet.literalEvidence.body) -cnotcontains $phraseValue) {
      $packet.literalEvidence.body = @($packet.literalEvidence.body) + @($phraseValue)
    }
    $packet.attempts[0].removedChips = @(
      [pscustomobject]@{ value = $phraseValue; removalReceipt = "$phraseValue 제거" }
    )
    $packet | Add-Member -NotePropertyName phrasePrepass -NotePropertyValue ([pscustomobject][ordered]@{
        attemptId = "$($fixtureCase.name)-phrase-prepass"
        scope = "initial-scope"
        chip = [pscustomobject][ordered]@{
          value = $phraseValue
          provenance = "literal-body"
          evidenceReceipt = "report-fixture:body:continuous-phrase"
        }
        submitted = $true
        freshResultVerified = $true
        resultCount = 1
        exactFound = $false
        resetBefore = $true
        clearReceipt = "report-fixture-phrase-prepass-clear"
        removedChips = @()
        followedByAttemptId = [string]$packet.attempts[0].attemptId
      }) -Force
  }
  [IO.File]::WriteAllText($Path, ($fixture | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
}

function New-PartialReport {
  $report = New-CompleteReport
  $report = $report -replace "최종 상태: 완료", "최종 상태: 부분 완료"
  $report = $report -replace "- 선택한 문제 수: 8", "- 선택한 문제 수: 6"
  $report = $report -replace "- 저장 전 초안/로컬 선택 수: 8", "- 저장 전 초안/로컬 선택 수: 6"
  $report = $report -replace "- 저장 후 재로드/새 탭 확인 수: 8", "- 저장 후 재로드/새 탭 확인 수: 6"
  $report = $report -replace "미발견 문제 번호: 없음", "미발견 문제 번호: 7, 8"
  $report = $report -replace "시도한 검색/근거: 없음", "시도한 검색/근거: whole-DB retry completed"
  $report = $report -replace "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6"
  $report = $report -replace "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6"
  $report = $report -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6"
  $report = $report -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6"
  $receipts = @(1, 2 | ForEach-Object {
      New-SearchAttemptFixtureReceipt "report-target-$_" "miss-closure-ready" $script:SearchReceiptPartialRelativePath
    })
  return $report -replace "검색 시도 계약 receipt: 없음", ("검색 시도 계약 receipt: " + ($receipts -join " || "))
}

function New-ZeroReport {
  $report = New-CompleteReport
  $report = $report -replace "최종 상태: 완료", "최종 상태: 검색 완료/0선택"
  $report = $report -replace "- 선택한 문제 수: 8", "- 선택한 문제 수: 0"
  $report = $report -replace "- 저장 전 초안/로컬 선택 수: 8", "- 저장 전 초안/로컬 선택 수: 0"
  $report = $report -replace "- 저장 후 재로드/새 탭 확인 수: 8", "- 저장 후 재로드/새 탭 확인 수: 0"
  $report = $report -replace "- 최종 편집 화면 도달: 예", "- 최종 편집 화면 도달: 아니오"
  $report = $report -replace "- 저장/확인 컨트롤 클릭: 예", "- 저장/확인 컨트롤 클릭: 없음"
  $report = $report -replace "- 새로고침 또는 새 탭 검증: 예", "- 새로고침 또는 새 탭 검증: 아니오"
  $report = $report -replace "미발견 문제 번호: 없음", "미발견 문제 번호: 1, 2, 3, 4, 5, 6, 7, 8"
  $report = $report -replace "시도한 검색/근거: 없음", "시도한 검색/근거: whole-DB retry completed"
  $report = $report -replace "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 전 순서화된 target ID 목록: 없음"
  $report = $report -replace "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 후 재로드 target ID 목록: 없음"
  $report = $report -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: 없음"
  $report = $report -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: 없음"
  $receipts = @(1, 2, 3, 4, 5, 6, 7, 8 | ForEach-Object {
      New-SearchAttemptFixtureReceipt "report-target-$_" "miss-closure-ready" $script:SearchReceiptZeroRelativePath
    })
  return $report -replace "검색 시도 계약 receipt: 없음", ("검색 시도 계약 receipt: " + ($receipts -join " || "))
}

function New-BlockedNonIabReport {
  $report = New-ZeroReport
  $report = $report -replace "최종 상태: 검색 완료/0선택", "최종 상태: 차단"
  $report = $report -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: Chrome"
  $report = $report -replace "비-Aside REPL live 조작 발생: 아니오", "비-Aside REPL live 조작 발생: 예"
  return $report -replace "비-Aside REPL 조작 발생 시 최종 상태: 없음", "비-Aside REPL 조작 발생 시 최종 상태: 차단"
}

function New-BlockedNoBrowserReport {
  $report = New-ZeroReport
  $report = $report -replace "최종 상태: 검색 완료/0선택", "최종 상태: 차단"
  return $report -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: 없음"
}

if ($ReportPath) {
  Invoke-MathSecrReportLint (Get-Content -LiteralPath $ReportPath -Raw) $ProjectRoot | Format-List
  Write-Host "ReportLint PASS"
  exit 0
}

$complete = New-CompleteReport
$completeLf = ($complete -replace "`r`n", "`n") -replace "`r", "`n"
$completeCrLf = $completeLf -replace "`n", "`r`n"
$formattedIab = $complete -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: Aside Browser ($([char]96)Aside REPL$([char]96))"
$script:SearchReceiptSourcePath = Join-Path $ProjectRoot "mathsecr-paper-builder-kit\test-fixtures\search-attempts\goguk2-mid-q2.json"
$searchReceiptFolderName = "mathsecr-search-receipt-" + [Guid]::NewGuid().ToString("N")
$searchReceiptTestRoot = Join-Path $ProjectRoot (".tmp\" + $searchReceiptFolderName)
$script:SearchReceiptPartialRelativePath = ".tmp/$searchReceiptFolderName/partial-target-bound.json"
$script:SearchReceiptZeroRelativePath = ".tmp/$searchReceiptFolderName/zero-target-bound.json"
$script:SearchReceiptPhraseRelativePath = ".tmp/$searchReceiptFolderName/phrase-target-bound.json"
$script:SearchReceiptBundleRelativePath = $script:SearchReceiptZeroRelativePath
$searchReceiptPartialPath = Join-Path $ProjectRoot ($script:SearchReceiptPartialRelativePath -replace '/', '\')
$searchReceiptZeroPath = Join-Path $ProjectRoot ($script:SearchReceiptZeroRelativePath -replace '/', '\')
$searchReceiptPhrasePath = Join-Path $ProjectRoot ($script:SearchReceiptPhraseRelativePath -replace '/', '\')
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $searchReceiptPartialPath ([string[]]@('7', '8'))
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $searchReceiptZeroPath ([string[]]@('1', '2', '3', '4', '5', '6', '7', '8'))
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $searchReceiptPhrasePath ([string[]]@('7', '8'))
Add-PhrasePrepassToSearchAttemptFixture $searchReceiptPhrasePath
$partial = New-PartialReport
$zero = New-ZeroReport
$blocked = New-BlockedNonIabReport
$blockedNoBrowser = New-BlockedNoBrowserReport
$blockedMissedSentinel = $complete -replace "최종 상태: 완료", "최종 상태: 차단"
$blockedMissedSentinel = $blockedMissedSentinel -replace "미발견 문제 번호: 없음", "미발견 문제 번호: 전체 세션 — 차단"
$explicitReplacement = $complete -replace "대체 문제 ID/cell ID: 없음", "대체 문제 ID/cell ID: replacement-1"
$explicitReplacement = $explicitReplacement -replace "사용자 승인: 승인 없음", "사용자 승인: 명시"
$sessionPolicyReplacement = $complete -replace "대체 문제 ID/cell ID: 없음", "대체 문제 ID/cell ID: replacement-2"
$sessionPolicyReplacement = $sessionPolicyReplacement -replace "사용자 승인: 승인 없음", "사용자 승인: 명시 세션 정책"
$summaryTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("mathsecr-public-summary-" + [Guid]::NewGuid().ToString("N"))
$summaryPdfPath = Join-Path $summaryTestRoot "failed-report.pdf"
$printedSummaryPdfPath = Join-Path $summaryTestRoot "printed-number-report.pdf"
$summaryPageCountPdfPath = Join-Path $summaryTestRoot "one-page-report.pdf"
$summaryTruncatedPdfPath = Join-Path $summaryTestRoot "truncated-report.pdf"
$summaryCorruptPdfPath = Join-Path $summaryTestRoot "corrupt-report.pdf"
New-Item -ItemType Directory -Force -Path $summaryTestRoot | Out-Null
$summaryFontPair = Get-SummaryFontPair
$summaryFixtureImagePath = Join-Path $summaryTestRoot 'fixture.png'
$summaryPngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR42mNUTX7NwMDAxMDAwMDAAAAQyAF3w9z6AQAAAABJRU5ErkJggg==')
[IO.File]::WriteAllBytes($summaryFixtureImagePath, $summaryPngBytes)
New-SummaryPdfFixture $summaryTestRoot $summaryPdfPath ([int[]](2, 4, 5)) $summaryFontPair $summaryFixtureImagePath
New-SummaryPdfFixture $summaryTestRoot $printedSummaryPdfPath ([int[]](21, 28, 35)) $summaryFontPair $summaryFixtureImagePath
New-SummaryPdfFixture $summaryTestRoot $summaryPageCountPdfPath ([int[]](2)) $summaryFontPair $summaryFixtureImagePath
[IO.File]::WriteAllBytes($summaryTruncatedPdfPath, [byte[]](37,80,68,70,45,49,46,55,10))
$summaryCorruptBytes = [IO.File]::ReadAllBytes($summaryPdfPath)
for ($byteIndex = 0; $byteIndex -lt 4; $byteIndex++) {
  $summaryCorruptBytes[$byteIndex] = [byte][char]'X'
}
[IO.File]::WriteAllBytes($summaryCorruptPdfPath, $summaryCorruptBytes)
$validUserSummary = @"
0. 제작한 문제지 링크
- [paper](https://www.mathsecr.com/mypaper/12345)
1. 성공한 문제 12문제/15문제
2. 실패한 문제 3문제/15문제
1. 2번, 4번, 5번
3. 실패한 문제 이미지 크롭 보고서 PDF
- [failed-report.pdf](<$summaryPdfPath>)
4. 출처
1. 교육청 — 9문제
2. EBS 올림포스 고난도 공통수학1 — 2문제
3. 블랙라벨 공통수학1 — 1문제
"@
$validUserSummaryPrintedNumbers = $validUserSummary -replace "1\. 2번, 4번, 5번", "1. 21번, 28번, 35번"
$validUserSummaryPrintedNumbers = $validUserSummaryPrintedNumbers -replace [regex]::Escape($summaryPdfPath), $printedSummaryPdfPath
$validSingleSourceUserSummary = @"
0. 제작한 문제지 링크
- [paper](https://www.mathsecr.com/mypaper/12345)
1. 성공한 문제 1문제/1문제
2. 실패한 문제 0문제/1문제
1. 없음
3. 실패한 문제 이미지 크롭 보고서 PDF
- 없음
4. 출처
1. 교육청 — 1문제
"@
$validUserSummaryNone = @"
0. 제작한 문제지 링크
- [paper](https://www.mathsecr.com/mypaper/12345)
1. 성공한 문제 0문제/3문제
2. 실패한 문제 3문제/3문제
1. 전체 세션 — 차단
3. 실패한 문제 이미지 크롭 보고서 PDF
- 없음
4. 출처
1. 없음
"@
$validBlockedUserSummary = @"
0. 제작한 문제지 링크
- [paper](https://www.mathsecr.com/mypaper/12345)
1. 성공한 문제 0문제/4문제
2. 실패한 문제 4문제/4문제
1. 전체 세션 — 차단
3. 실패한 문제 이미지 크롭 보고서 PDF
- 없음
4. 출처
1. 없음
"@
$invalidSummaryExtraLines = $validUserSummary + "`n추가 내용"
$invalidSummaryInternalLeak = $validUserSummary -replace "0\. 제작한 문제지 링크", "0. 제작한 문제지 링크: 문제지 URL"
$invalidSummaryMissingPdf = $validUserSummary -replace "- \[failed-report\.pdf\]\(<.*>\)", "- 없음"
$invalidSummaryPdfMissing = $validUserSummary -replace [regex]::Escape($summaryPdfPath), (Join-Path $summaryTestRoot "missing.pdf")
$invalidSummaryPdfUrl = $validUserSummary -replace [regex]::Escape("<$summaryPdfPath>"), "https://example.com/failed.pdf"
$invalidSummaryPdfExtension = $validUserSummary -replace [regex]::Escape("<$summaryPdfPath>"), "<${summaryPdfPath}.txt>"
$invalidSummaryPdfTruncated = $validUserSummary -replace [regex]::Escape($summaryPdfPath), $summaryTruncatedPdfPath
$invalidSummaryPdfCorrupt = $validUserSummary -replace [regex]::Escape($summaryPdfPath), $summaryCorruptPdfPath
$invalidSummaryPdfMismatch = $validUserSummary -replace "1\. 2번, 4번, 5번", "1. 2번, 4번, 6번"
$invalidSummaryPdfPageCount = $validUserSummary -replace [regex]::Escape($summaryPdfPath), $summaryPageCountPdfPath
$invalidSummaryPaperUrl = $validUserSummary -replace "https://www\.mathsecr\.com/mypaper/12345", "https://www.mathsecr.com/paper/12345"
$invalidSummaryCounts = $validUserSummary -replace "2\. 실패한 문제 3문제/15문제", "2. 실패한 문제 2문제/15문제"
$invalidSummaryRefs = $validUserSummary -replace "1\. 2번, 4번, 5번", "1. 2번, 2번, 6번"
$invalidSummaryNonPositiveRefs = $validUserSummary -replace "1\. 2번, 4번, 5번", "1. 0번, 4번, 5번"
$invalidSummaryUnexpectedPdf = $validSingleSourceUserSummary -replace "- 없음", "- [failed-report.pdf](<$summaryPdfPath>)"
$invalidSummaryBlockerCounts = $validBlockedUserSummary -replace "0문제/4문제", "1문제/4문제" -replace "4문제/4문제", "3문제/4문제"
$invalidSummaryLeadingZero = $validUserSummary -replace "12문제/15문제", "012문제/15문제"
$invalidSummaryFourSources = $validUserSummary + "`n4. 사설 문제집 — 1문제"
$invalidSummaryFrequency = $validUserSummary -replace "2\. EBS 올림포스 고난도 공통수학1 — 2문제", "2. EBS 올림포스 고난도 공통수학1 — 10문제"
$invalidSummaryDuplicateSource = $validUserSummary -replace "3\. 블랙라벨 공통수학1 — 1문제", "3. 교육청 — 1문제"
$invalidSummaryZeroSuccessSource = $validUserSummaryNone -replace "1\. 없음", "1. 교육청 — 1문제"
$invalidSummarySymbol = $validUserSummary -replace "1\. 성공한 문제 12문제/15문제", "1. 성공한 문제 #12문제/15문제"
$invalidSummarySourceUrl = $validUserSummary -replace "1\. 교육청 — 9문제", "1. https://example.com — 9문제"
$invalidSummarySourceId = $validUserSummary -replace "1\. 교육청 — 9문제", "1. 교육청 문제 ID 123 — 9문제"
$invalidSummarySourceInternal = $validUserSummary -replace "1\. 교육청 — 9문제", "1. 문제지 URL — 9문제"
$invalidSummarySourceCount = $validUserSummary -replace "3\. 블랙라벨 공통수학1 — 1문제", "3. 블랙라벨 공통수학1 — 13문제"
$invalidSummarySourceSum = $validUserSummary -replace "2\. EBS 올림포스 고난도 공통수학1 — 2문제", "2. EBS 올림포스 고난도 공통수학1 — 9문제"
$duplicateComplete = $complete -replace "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 전 순서화된 target ID 목록: a1,a1,a3,a4,a5,a6,a7,a8"
$duplicateComplete = $duplicateComplete -replace "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 후 재로드 target ID 목록: a1,a1,a3,a4,a5,a6,a7,a8"
$duplicatePartial = $partial -replace "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6", "저장 전 순서화된 target ID 목록: a1,a1,a3,a4,a5,a6"
$duplicatePartial = $duplicatePartial -replace "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6", "저장 후 재로드 target ID 목록: a1,a1,a3,a4,a5,a6"
$invalidDuplicateOccurrencesMissingKeys = $duplicateComplete -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: 없음"
$invalidDuplicateOccurrencesMissingKeys = $invalidDuplicateOccurrencesMissingKeys -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: 없음"
$validDuplicateOccurrencesNumericStringKeys = $duplicateComplete -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: 1,2,3,4,5,6,7,8"
$validDuplicateOccurrencesNumericStringKeys = $validDuplicateOccurrencesNumericStringKeys -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: 1,2,3,4,5,6,7,8"
$invalidDuplicateOccurrencesBlankKeys = $duplicateComplete -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: source-page-1,,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$invalidDuplicateOccurrencesReorderedKeys = $duplicateComplete -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: source-page-2,source-page-1,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$invalidDuplicateOccurrencesDuplicateKeys = $duplicateComplete -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-1,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$occurrenceKeySequence = "source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$canonicalWhitespaceCaseSequence = "source page-1,SOURCE page-1,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$validDuplicateOccurrencesCanonicalWhitespaceCase = $duplicateComplete -replace [regex]::Escape($occurrenceKeySequence), $canonicalWhitespaceCaseSequence
$unicodeComposedId = [string][char]0x00E9
$unicodeDecomposedId = "e" + [string][char]0x0301
$unicodeDistinctIdSequence = $unicodeComposedId + "," + $unicodeDecomposedId + ",a3,a4,a5,a6,a7,a8"
$validUnicodeOrdinalDistinctIds = $complete.Replace("a1,a2,a3,a4,a5,a6,a7,a8", $unicodeDistinctIdSequence)
$validUnicodeOrdinalDistinctIds = $validUnicodeOrdinalDistinctIds.Replace($occurrenceKeySequence, "없음")
$validOrdinalMixedCaseDuplicateIds = $complete.Replace("a1,a2,a3,a4,a5,a6,a7,a8", "dup,dup,DUP,a4,a5,a6,a7,a8")
$validOrdinalMixedCaseDuplicateIds = $validOrdinalMixedCaseDuplicateIds.Replace($occurrenceKeySequence, "source-page-1,source-page-2,3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8")
$whitespaceCollisionSequence = "source-page-1, source-page-1,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$invalidDuplicateOccurrencesWhitespaceCollision = $duplicateComplete -replace [regex]::Escape($occurrenceKeySequence), $whitespaceCollisionSequence
$commaKeySequence = "source,page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8"
$invalidDuplicateOccurrencesCommaKey = $duplicateComplete -replace [regex]::Escape($occurrenceKeySequence), $commaKeySequence
$fallbackTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("mathsecr-report-fallback-" + [Guid]::NewGuid().ToString("N"))
$fallbackRelativePath = ".omo/evidence/session-card-bundle.json"
$fallbackArtifactPath = Join-Path $fallbackTestRoot ($fallbackRelativePath -replace '/', '\')
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fallbackArtifactPath) | Out-Null
[IO.File]::WriteAllText($fallbackArtifactPath, '{"ordered_ids":["a1","a2","a3","a4","a5","a6","a7","a8"]}', (New-Object Text.UTF8Encoding($false)))
$fallbackHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fallbackArtifactPath).Hash
$structuredFallback = $complete -replace "저장 전 순서화된 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 전 순서화된 target ID 목록: 없음"
$structuredFallback = $structuredFallback -replace "저장 후 재로드 target ID 목록: a1,a2,a3,a4,a5,a6,a7,a8", "저장 후 재로드 target ID 목록: 없음"
$structuredFallback = $structuredFallback -replace "저장 전 순서화된 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 전 순서화된 occurrenceKey 목록: 없음"
$structuredFallback = $structuredFallback -replace "저장 후 재로드 occurrenceKey 목록: source-page-1,source-page-2,source-page-3,source-page-4,source-page-5,source-page-6,source-page-7,source-page-8", "저장 후 재로드 occurrenceKey 목록: 없음"
$structuredFallback = $structuredFallback -replace "카드/시각 identity fallback 근거: 없음", "카드/시각 identity fallback 근거: artifact=$fallbackRelativePath; sha256=$fallbackHash; identity=ordered cards 1-8 matched source metadata and exact problem bodies"
$searchReceiptFixturePath = Join-Path $searchReceiptTestRoot "fixture.json"
$searchReceiptDuplicatePath = Join-Path $searchReceiptTestRoot "fixture-duplicate.json"
$searchReceiptTamperedPath = Join-Path $searchReceiptTestRoot "fixture-tampered.json"
New-Item -ItemType Directory -Force -Path $searchReceiptTestRoot | Out-Null
$searchReceiptFixtureRaw = Get-Content -LiteralPath $searchReceiptPartialPath -Raw
[IO.File]::WriteAllText($searchReceiptFixturePath, $searchReceiptFixtureRaw, (New-Object Text.UTF8Encoding($false)))
$duplicateFixture = $searchReceiptFixtureRaw | ConvertFrom-Json
$duplicateFixture.cases = @($duplicateFixture.cases) + @($duplicateFixture.cases | Where-Object name -ceq "report-target-1")
[IO.File]::WriteAllText($searchReceiptDuplicatePath, ($duplicateFixture | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding($false)))
$tamperedFixture = $searchReceiptFixtureRaw | ConvertFrom-Json
$tamperedGoodCase = @($tamperedFixture.cases | Where-Object name -ceq "report-target-1")[0]
$tamperedGoodCase.packet.literalOnlyLadderCompleted = $false
[IO.File]::WriteAllText($searchReceiptTamperedPath, ($tamperedFixture | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding($false)))
$searchReceiptFixtureReceipt = New-SearchAttemptReceiptForArtifact $searchReceiptTestRoot "fixture.json" "report-target-1" "miss-closure-ready"
$searchReceiptDuplicateReceipt = New-SearchAttemptReceiptForArtifact $searchReceiptTestRoot "fixture-duplicate.json" "report-target-1" "miss-closure-ready"
$searchReceiptTamperedReceipt = New-SearchAttemptReceiptForArtifact $searchReceiptTestRoot "fixture-tampered.json" "report-target-1" "miss-closure-ready"
$pendingRelativePath = ".tmp/$searchReceiptFolderName/pending-target-bound.json"
$pendingArtifactPath = Join-Path $ProjectRoot ($pendingRelativePath -replace '/', '\')
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $pendingArtifactPath ([string[]]@('7', '8')) 'bad-common-semantic-and' 'pending-target'
$pendingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pendingArtifactPath).Hash
$pendingReceipts = @(1, 2 | ForEach-Object {
    "artifact=$pendingRelativePath; sha256=$pendingHash; case=pending-target-$_; expected=candidate-recovery-pending"
  })
$pendingSearchAttemptReceipt = $pendingReceipts -join " || "
$pendingPartial = Set-SearchAttemptReceipt $partial $pendingSearchAttemptReceipt
$pendingZeroRelativePath = ".tmp/$searchReceiptFolderName/pending-zero-target-bound.json"
$pendingZeroArtifactPath = Join-Path $ProjectRoot ($pendingZeroRelativePath -replace '/', '\')
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $pendingZeroArtifactPath ([string[]]@('1', '2', '3', '4', '5', '6', '7', '8')) 'bad-common-semantic-and' 'pending-zero-target'
$pendingZeroHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pendingZeroArtifactPath).Hash
$pendingZeroReceipts = @(1, 2, 3, 4, 5, 6, 7, 8 | ForEach-Object {
    "artifact=$pendingZeroRelativePath; sha256=$pendingZeroHash; case=pending-zero-target-$_; expected=candidate-recovery-pending"
  })
$pendingZero = Set-SearchAttemptReceipt $zero ($pendingZeroReceipts -join " || ")
$pendingBlockedZero = $pendingZero -replace "최종 상태: 검색 완료/0선택", "최종 상태: 차단"
$singleMissPartial = $partial -replace "미발견 문제 번호: 7, 8", "미발견 문제 번호: 7"
$phraseReceiptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $searchReceiptPhrasePath).Hash
$phraseReceipts = @(1, 2 | ForEach-Object {
    "artifact=$script:SearchReceiptPhraseRelativePath; sha256=$phraseReceiptHash; case=report-target-$_; expected=miss-closure-ready"
  })
$phrasePartial = Set-SearchAttemptReceipt $partial ($phraseReceipts -join " || ")
$q2BadReceipt = New-SearchAttemptFixtureReceipt "bad-common-semantic-and" "candidate-recovery-pending" "mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json"
$duplicateTargetRelativePath = ".tmp/$searchReceiptFolderName/duplicate-target-bound.json"
$duplicateTargetArtifactPath = Join-Path $ProjectRoot ($duplicateTargetRelativePath -replace '/', '\')
New-TargetBoundSearchAttemptFixture $script:SearchReceiptSourcePath $duplicateTargetArtifactPath ([string[]]@('7', '7')) 'synthetic-absence-control' 'duplicate-target'
$duplicateTargetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $duplicateTargetArtifactPath).Hash
$duplicateTargetReceipts = @(1, 2 | ForEach-Object {
    "artifact=$duplicateTargetRelativePath; sha256=$duplicateTargetHash; case=duplicate-target-$_; expected=miss-closure-ready"
  })
$cases = if ($Case -eq "All") {
  @( "ValidComplete", "ValidCompleteLf", "ValidCompleteCrLf", "ValidFormattedIab", "ValidPartial", "ValidZero", "ValidBlockedNonIab", "ValidBlockedNoBrowser", "ValidBlockedMissedSentinel", "ValidExplicitReplacement", "ValidSessionPolicyReplacement", "ValidStructuredFallback", "ValidDuplicateOccurrencesComplete", "ValidDuplicateOccurrencesPartial", "ValidDuplicateOccurrencesNumericStringKeys", "ValidDuplicateOccurrencesCanonicalWhitespaceCase", "ValidUnicodeOrdinalDistinctIds", "ValidOrdinalMixedCaseDuplicateIds", "ValidReportTokenInternalWhitespaceCase", "ValidUserSummary", "ValidUserSummaryPrintedNumbers", "ValidUserSummaryNone", "ValidUserSummaryBlocked", "InvalidUserSummaryExtraLines", "InvalidUserSummaryInternalLeak", "InvalidUserSummaryPreamble", "InvalidUserSummaryMissingPdf", "InvalidUserSummaryPdfMissing", "InvalidUserSummaryPdfUrl", "InvalidUserSummaryPdfExtension", "InvalidUserSummaryPdfTruncated", "InvalidUserSummaryPdfCorrupt", "InvalidUserSummaryPdfMismatch", "InvalidUserSummaryPdfPageCount", "InvalidUserSummaryPaperUrl", "InvalidUserSummaryCounts", "InvalidUserSummaryRefs", "InvalidUserSummaryNonPositiveRefs", "InvalidUserSummaryUnexpectedPdf", "InvalidUserSummaryBlockerCounts", "InvalidUserSummaryLeadingZero", "InvalidUserSummaryFourSources", "InvalidUserSummaryFrequency", "InvalidUserSummaryDuplicateSource", "InvalidUserSummaryZeroSuccessSource", "InvalidUserSummarySymbol", "InvalidUserSummarySourceUrl", "InvalidUserSummarySourceId", "InvalidUserSummarySourceInternal", "InvalidUserSummarySourceCount", "InvalidUserSummarySourceSum", "InvalidPartialPersistence", "InvalidBundleOrder", "InvalidDuplicateOccurrencesMissingKeys", "InvalidDuplicateOccurrencesBlankKeys", "InvalidDuplicateOccurrencesReorderedKeys", "InvalidDuplicateOccurrencesDuplicateKeys", "InvalidDuplicateOccurrencesWhitespaceCollision", "InvalidDuplicateOccurrencesCommaKey", "InvalidReportTokenSentinel", "InvalidReportTokenCrLf", "InvalidReportTokenComma", "InvalidCompleteZero", "InvalidZeroDraft", "InvalidZeroNoOriginal", "InvalidCompleteNoBrowser", "InvalidPartialNoBrowser", "InvalidZeroNoBrowser", "InvalidNonIabOutcome", "InvalidBlankBrowser", "InvalidChromeSurfaceNonIabNo", "InvalidComputerUseSurfaceNonIabNo", "InvalidIabSurfaceNonIabYes", "InvalidReplacementWithoutApproval", "InvalidReplacementApprovalValue", "InvalidFallbackPlaceholder", "InvalidFallbackMissingHash", "InvalidFallbackTraversal", "InvalidFallbackMissingArtifact", "InvalidFallbackHashMismatch", "InvalidZeroLabel", "InvalidBlockedMissedSentinelNonBlocked", "InvalidBlockedMissedSentinelVariant", "InvalidSearchAttemptOneReceiptMultipleMisses", "InvalidSearchAttemptWrongTargetBinding", "InvalidSearchAttemptDuplicateTargetBinding", "InvalidSearchAttemptMissingReceipt", "InvalidSearchAttemptExtraReceipt" )
} else {
  @($Case)
}

try {
  foreach ($item in $cases) {
    switch ($item) {
    "ValidComplete" { $null = Invoke-MathSecrReportLint $complete }
    "ValidCompleteLf" { $null = Invoke-MathSecrReportLint $completeLf }
    "ValidCompleteCrLf" { $null = Invoke-MathSecrReportLint $completeCrLf }
    "ValidFormattedIab" { $null = Invoke-MathSecrReportLint $formattedIab }
    "ValidPartial" { $null = Invoke-MathSecrReportLint $partial }
    "ValidZero" { $null = Invoke-MathSecrReportLint $zero }
    "ValidBlockedNonIab" { $null = Invoke-MathSecrReportLint $blocked }
    "ValidBlockedNoBrowser" { $null = Invoke-MathSecrReportLint $blockedNoBrowser }
    "ValidBlockedMissedSentinel" {
      $projection = Invoke-MathSecrReportLint $blockedMissedSentinel
      Assert-True ($projection.Status -ceq "차단" -and @($projection.MissedProblemNumbers).Count -eq 0 -and $projection.SearchAttemptReceipt -ceq "없음") "차단 sentinel must normalize to no missed numbers and no receipt"
    }
    "InvalidBlockedMissedSentinelNonBlocked" {
      $invalid = $blockedMissedSentinel -replace "최종 상태: 차단", "최종 상태: 부분 완료"
      Expect-Rejection $item $invalid "requires 최종 상태: 차단"
    }
    "InvalidBlockedMissedSentinelVariant" {
      $invalid = $blockedMissedSentinel -replace "전체 세션 — 차단", "전체 세션 - 차단"
      Expect-Rejection $item $invalid "comma-separated printed numbers"
    }
    "ValidExplicitReplacement" { $null = Invoke-MathSecrReportLint $explicitReplacement }
    "ValidSessionPolicyReplacement" { $null = Invoke-MathSecrReportLint $sessionPolicyReplacement }
    "ValidStructuredFallback" { $null = Invoke-MathSecrReportLint $structuredFallback $fallbackTestRoot }
    "ValidDuplicateOccurrencesComplete" { $null = Invoke-MathSecrReportLint $duplicateComplete }
    "ValidDuplicateOccurrencesPartial" { $null = Invoke-MathSecrReportLint $duplicatePartial }
    "ValidDuplicateOccurrencesNumericStringKeys" { $null = Invoke-MathSecrReportLint $validDuplicateOccurrencesNumericStringKeys }
    "ValidDuplicateOccurrencesCanonicalWhitespaceCase" {
      $null = Invoke-MathSecrReportLint $validDuplicateOccurrencesCanonicalWhitespaceCase
      $parsedKeys = @(Get-OccurrenceKeys "canonical occurrenceKey fixture" "source page-1, SOURCE page-1")
      Assert-True ($parsedKeys.Count -eq 2 -and $parsedKeys[0] -ceq "source page-1" -and $parsedKeys[1] -ceq "SOURCE page-1") "Canonical occurrenceKey parser must preserve internal whitespace and case"
    }
    "ValidUnicodeOrdinalDistinctIds" {
      $null = Invoke-MathSecrReportLint $validUnicodeOrdinalDistinctIds
      $parsedIds = @(Get-OrderedIds "Unicode ordinal ID fixture" ($unicodeComposedId + "," + $unicodeDecomposedId))
      Assert-True ($parsedIds.Count -eq 2 -and $parsedIds[0] -ceq $unicodeComposedId -and $parsedIds[1] -ceq $unicodeDecomposedId) "Ordinal ID parser must preserve composed/decomposed codepoint order"
      Assert-True ($parsedIds[0].Length -eq 1 -and [int][char]$parsedIds[0][0] -eq 0x00E9) "Composed Unicode ID codepoint was not preserved"
      Assert-True ($parsedIds[1].Length -eq 2 -and [int][char]$parsedIds[1][0] -eq 0x0065 -and [int][char]$parsedIds[1][1] -eq 0x0301) "Decomposed Unicode ID codepoints were not preserved"
    }
    "ValidOrdinalMixedCaseDuplicateIds" {
      $null = Invoke-MathSecrReportLint $validOrdinalMixedCaseDuplicateIds
      $parsedIds = @(Get-OrderedIds "Ordinal mixed-case duplicate ID fixture" "dup,dup,DUP" -AllowDuplicates)
      Assert-True ($parsedIds.Count -eq 3 -and $parsedIds[0] -ceq "dup" -and $parsedIds[1] -ceq "dup" -and $parsedIds[2] -ceq "DUP") "Ordinal mixed-case duplicate IDs must preserve order and case"
      Assert-True (Test-HasDuplicateReportTokensOrdinal $parsedIds) "Genuine duplicate lower-case IDs must remain detectable"
      Assert-True (-not (Test-HasDuplicateReportTokensOrdinal @("dup", "DUP"))) "Ordinal case-distinct IDs must not collapse"
    }
    "ValidReportTokenInternalWhitespaceCase" {
      $id = "ID`t" + [string][char]0x00A0 + "Case"
      Assert-True (Test-IsCanonicalReportToken $id) "Report token predicate must preserve internal TAB/NBSP and case"
      $parsedIds = @(Get-OrderedIds "internal ID fixture" ("ID`t" + [string][char]0x00A0 + "Case,Other"))
      Assert-True ($parsedIds.Count -eq 2 -and $parsedIds[0] -ceq $id -and $parsedIds[1] -ceq "Other") "Report ID parser must preserve internal TAB/NBSP and case"
    }
    "ValidUserSummary" {
      $null = Invoke-MathSecrUserSummaryLint $validUserSummary
      $null = Invoke-MathSecrUserSummaryLint $validSingleSourceUserSummary
    }
    "ValidUserSummaryPrintedNumbers" {
      $result = Invoke-MathSecrUserSummaryLint $validUserSummaryPrintedNumbers
      Assert-True ($result.Success -eq 12 -and $result.Failure -eq 3 -and $result.Total -eq 15) "ValidUserSummaryPrintedNumbers returned unexpected counts"
      $printedRefs = @($result.FailedProblems)
      Assert-True ($printedRefs.Count -eq 3 -and $printedRefs[0] -eq 21 -and $printedRefs[1] -eq 28 -and $printedRefs[2] -eq 35) "ValidUserSummaryPrintedNumbers returned unexpected printed references"
    }
    "ValidUserSummaryNone" {
      $result = Invoke-MathSecrUserSummaryLint $validUserSummaryNone
      Assert-True ($result.IsBlocked -and $result.Success -eq 0 -and $result.Failure -eq 3 -and $result.Total -eq 3 -and $result.Sources.Count -eq 0) "ValidUserSummaryNone returned unexpected projection"
    }
    "ValidUserSummaryBlocked" {
      $result = Invoke-MathSecrUserSummaryLint $validBlockedUserSummary
      Assert-True ($result.IsBlocked -and $result.Success -eq 0 -and $result.Failure -eq 4 -and $result.FailedProblems.Count -eq 0) "ValidUserSummaryBlocked returned unexpected projection"
    }
    "InvalidUserSummaryExtraLines" {
      Expect-UserSummaryRejection $item $invalidSummaryExtraLines "9-11 non-empty lines"
    }
    "InvalidUserSummaryInternalLeak" {
      Expect-UserSummaryRejection $item $invalidSummaryInternalLeak "start with"
    }
    "InvalidUserSummaryPreamble" {
      Expect-UserSummaryRejection $item ("요약`n" + $validUserSummary) "9-11 non-empty lines"
    }
    "InvalidUserSummaryMissingPdf" {
      Expect-UserSummaryRejection $item $invalidSummaryMissingPdf "required for per-problem failures"
    }
    "InvalidUserSummaryPdfMissing" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfMissing "does not exist"
    }
    "InvalidUserSummaryPdfUrl" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfUrl "absolute local path"
    }
    "InvalidUserSummaryPdfExtension" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfExtension "end in .pdf"
    }
    "InvalidUserSummaryPdfTruncated" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfTruncated "PDF parse/marker validation failed"
    }
    "InvalidUserSummaryPdfCorrupt" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfCorrupt "PDF parse/marker validation failed"
    }
    "InvalidUserSummaryPdfMismatch" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfMismatch "missing printed marker 6번"
    }
    "InvalidUserSummaryPdfPageCount" {
      Expect-UserSummaryRejection $item $invalidSummaryPdfPageCount "page count"
    }
    "InvalidUserSummaryPaperUrl" {
      Expect-UserSummaryRejection $item $invalidSummaryPaperUrl "MathSecr mypaper Markdown link"
    }
    "InvalidUserSummaryCounts" {
      Expect-UserSummaryRejection $item $invalidSummaryCounts "add up to total"
    }
    "InvalidUserSummaryRefs" {
      Expect-UserSummaryRejection $item $invalidSummaryRefs "must not contain duplicates"
    }
    "InvalidUserSummaryNonPositiveRefs" {
      Expect-UserSummaryRejection $item $invalidSummaryNonPositiveRefs "comma-separated N번 values"
    }
    "InvalidUserSummaryUnexpectedPdf" {
      Expect-UserSummaryRejection $item $invalidSummaryUnexpectedPdf "only valid for per-problem failures"
    }
    "InvalidUserSummaryBlockerCounts" {
      Expect-UserSummaryRejection $item $invalidSummaryBlockerCounts "Whole-session blocker requires"
    }
    "InvalidUserSummaryLeadingZero" {
      Expect-UserSummaryRejection $item $invalidSummaryLeadingZero "success count line is invalid"
    }
    "InvalidUserSummaryFourSources" {
      Expect-UserSummaryRejection $item $invalidSummaryFourSources "9-11 non-empty lines"
    }
    "InvalidUserSummaryFrequency" {
      Expect-UserSummaryRejection $item $invalidSummaryFrequency "descending frequency"
    }
    "InvalidUserSummaryDuplicateSource" {
      Expect-UserSummaryRejection $item $invalidSummaryDuplicateSource "must not repeat"
    }
    "InvalidUserSummaryZeroSuccessSource" {
      Expect-UserSummaryRejection $item $invalidSummaryZeroSuccessSource "Zero-success summaries"
    }
    "InvalidUserSummarySymbol" {
      Expect-UserSummaryRejection $item $invalidSummarySymbol "must not contain # or @"
    }
    "InvalidUserSummarySourceUrl" {
      Expect-UserSummaryRejection $item $invalidSummarySourceUrl "must not contain a URL"
    }
    "InvalidUserSummarySourceId" {
      Expect-UserSummaryRejection $item $invalidSummarySourceId "must not contain a problem ID"
    }
    "InvalidUserSummarySourceInternal" {
      Expect-UserSummaryRejection $item $invalidSummarySourceInternal "leaked internal field"
    }
    "InvalidUserSummarySourceCount" {
      Expect-UserSummaryRejection $item $invalidSummarySourceCount "cannot exceed"
    }
    "InvalidUserSummarySourceSum" {
      Expect-UserSummaryRejection $item $invalidSummarySourceSum "counts sum cannot exceed"
    }
    "InvalidPartialPersistence" {
      Expect-Rejection $item ($partial -replace "- 저장 후 재로드/새 탭 확인 수: 6", "- 저장 후 재로드/새 탭 확인 수: 4") "persisted"
    }
    "InvalidBundleOrder" {
      $invalid = $complete -replace "(?m)^(- 저장 후 재로드 target ID 목록: )a1,a2,a3,a4,a5,a6,a7,a8", '$1a2,a1,a3,a4,a5,a6,a7,a8'
      Expect-Rejection $item $invalid "ordered ID bundles"
    }
    "InvalidDuplicateOccurrencesMissingKeys" {
      Assert-True (Test-HasDuplicateReportTokensOrdinal @("same", "same")) "Ordinal duplicate helper must detect genuinely identical IDs"
      Assert-True (-not (Test-HasDuplicateReportTokensOrdinal @($unicodeComposedId, $unicodeDecomposedId))) "Ordinal duplicate helper must keep composed/decomposed IDs distinct"
      Expect-Rejection $item $invalidDuplicateOccurrencesMissingKeys "duplicate ID bundles require"
    }
    "InvalidDuplicateOccurrencesBlankKeys" {
      Expect-Rejection $item $invalidDuplicateOccurrencesBlankKeys "blank occurrenceKey"
    }
    "InvalidDuplicateOccurrencesReorderedKeys" {
      Expect-Rejection $item $invalidDuplicateOccurrencesReorderedKeys "occurrenceKey bundles differ"
    }
    "InvalidDuplicateOccurrencesDuplicateKeys" {
      Expect-Rejection $item $invalidDuplicateOccurrencesDuplicateKeys "duplicate occurrenceKey values"
    }
    "InvalidDuplicateOccurrencesWhitespaceCollision" {
      Expect-Rejection $item $invalidDuplicateOccurrencesWhitespaceCollision "duplicate occurrenceKey values"
    }
    "InvalidDuplicateOccurrencesCommaKey" {
      Assert-True (-not (Test-IsCanonicalReportToken "source,page-1")) "Comma occurrenceKey token must be rejected by report-safe predicate"
      Expect-Rejection $item $invalidDuplicateOccurrencesCommaKey "occurrenceKey counts to equal selected count"
    }
    "InvalidReportTokenSentinel" {
      Assert-True (-not (Test-IsCanonicalReportToken "없음")) "Report token predicate must reject list sentinel"
      try {
        $null = Get-OccurrenceKeys "direct sentinel occurrence helper fixture" "a1,없음"
        throw "Direct sentinel occurrence helper should reject"
      } catch {
        Assert-True ($_.Exception.Message -like "*noncanonical occurrenceKey*") "Direct sentinel occurrence helper rejected with unexpected message: $($_.Exception.Message)"
        Write-Host "Direct sentinel occurrence helper rejected as expected: $($_.Exception.Message)"
      }
      Expect-Rejection $item ($complete -replace "a1,a2,a3,a4,a5,a6,a7,a8", "a1,없음,a3,a4,a5,a6,a7,a8") "noncanonical ID token"
    }
    "InvalidReportTokenCrLf" {
      Assert-True (-not (Test-IsCanonicalReportToken "id`r`nfoo")) "Report token predicate must reject CR/LF"
      try {
        $null = Get-OrderedIds "direct CR/LF ID helper fixture" "a1,id`r`nfoo,a3,a4,a5,a6,a7,a8"
        throw "Direct CR/LF ID helper should reject"
      } catch {
        Assert-True ($_.Exception.Message -like "*noncanonical ID token*") "Direct CR/LF ID helper rejected with unexpected message: $($_.Exception.Message)"
        Write-Host "Direct CR/LF ID helper rejected as expected: $($_.Exception.Message)"
      }
      try {
        $null = Get-OccurrenceKeys "direct CR/LF occurrence helper fixture" "a1,id`r`nfoo"
        throw "Direct CR/LF occurrence helper should reject"
      } catch {
        Assert-True ($_.Exception.Message -like "*noncanonical occurrenceKey*") "Direct CR/LF occurrence helper rejected with unexpected message: $($_.Exception.Message)"
        Write-Host "Direct CR/LF occurrence helper rejected as expected: $($_.Exception.Message)"
      }
      Expect-Rejection $item ($complete -replace "a1,a2,a3,a4,a5,a6,a7,a8", "a1,id`r`nfoo,a3,a4,a5,a6,a7,a8") "ordered ID counts"
    }
    "InvalidReportTokenComma" {
      Assert-True (-not (Test-IsCanonicalReportToken "id,foo")) "Report token predicate must reject commas"
    }
    "InvalidCompleteZero" {
      $invalid = $zero -replace "최종 상태: 검색 완료/0선택", "최종 상태: 완료"
      Expect-Rejection $item $invalid "selected count above zero"
    }
    "InvalidZeroDraft" {
      $invalid = $zero -replace "- 저장 전 초안/로컬 선택 수: 0", "- 저장 전 초안/로컬 선택 수: 1"
      Expect-Rejection $item $invalid "zero-selection"
    }
    "InvalidZeroNoOriginal" {
      $invalid = $zero -replace "- 원본 문제 수: 8", "- 원본 문제 수: 0"
      Expect-Rejection $item $invalid "original count above zero"
    }
    "InvalidCompleteNoBrowser" {
      $invalid = $complete -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: 없음"
      Expect-Rejection $item $invalid "requires an Aside-REPL-only browser surface"
    }
    "InvalidPartialNoBrowser" {
      $invalid = $partial -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: 없음"
      Expect-Rejection $item $invalid "requires an Aside-REPL-only browser surface"
    }
    "InvalidZeroNoBrowser" {
      $invalid = $zero -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: 없음"
      Expect-Rejection $item $invalid "requires an Aside-REPL-only browser surface"
    }
    "InvalidNonIabOutcome" {
      Expect-Rejection $item ($blocked -replace "비-Aside REPL 조작 발생 시 최종 상태: 차단", "비-Aside REPL 조작 발생 시 최종 상태: 없음") "must report final status 차단"
    }
    "InvalidBlankBrowser" {
      Expect-Rejection $item ($complete -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: ") "must not be blank"
    }
    "InvalidChromeSurfaceNonIabNo" {
      Expect-Rejection $item ($complete -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: Chrome") "contradicts 비-Aside REPL=no"
    }
    "InvalidComputerUseSurfaceNonIabNo" {
      Expect-Rejection $item ($complete -replace "사용한 브라우저 표면: Aside REPL", "사용한 브라우저 표면: Computer Use") "contradicts 비-Aside REPL=no"
    }
    "InvalidIabSurfaceNonIabYes" {
      $invalid = $complete -replace "최종 상태: 완료", "최종 상태: 차단"
      $invalid = $invalid -replace "비-Aside REPL live 조작 발생: 아니오", "비-Aside REPL live 조작 발생: 예"
      $invalid = $invalid -replace "비-Aside REPL 조작 발생 시 최종 상태: 없음", "비-Aside REPL 조작 발생 시 최종 상태: 차단"
      Expect-Rejection $item $invalid "requires a non-Aside-REPL browser surface"
    }
    "InvalidReplacementWithoutApproval" {
      $invalid = $complete -replace "대체 문제 ID/cell ID: 없음", "대체 문제 ID/cell ID: replacement-1"
      Expect-Rejection $item $invalid "requires explicit user approval"
    }
    "InvalidReplacementApprovalValue" {
      $invalid = $complete -replace "대체 문제 ID/cell ID: 없음", "대체 문제 ID/cell ID: replacement-1"
      $invalid = $invalid -replace "사용자 승인: 승인 없음", "사용자 승인: 사후 추정"
      Expect-Rejection $item $invalid "must be one of"
    }
    "InvalidFallbackPlaceholder" {
      $invalid = $structuredFallback -replace "artifact=$([regex]::Escape($fallbackRelativePath)); sha256=$fallbackHash; identity=ordered cards 1-8 matched source metadata and exact problem bodies", "있음"
      Expect-Rejection $item $invalid "must use" $fallbackTestRoot
    }
    "InvalidFallbackMissingHash" {
      $invalid = $structuredFallback -replace "; sha256=$fallbackHash", ""
      Expect-Rejection $item $invalid "must use" $fallbackTestRoot
    }
    "InvalidFallbackTraversal" {
      $invalid = $structuredFallback -replace "artifact=$([regex]::Escape($fallbackRelativePath))", "artifact=../outside/session-card-bundle.json"
      Expect-Rejection $item $invalid "must not escape" $fallbackTestRoot
    }
    "InvalidFallbackMissingArtifact" {
      $invalid = $structuredFallback -replace "artifact=$([regex]::Escape($fallbackRelativePath))", "artifact=.omo/evidence/missing-card-bundle.json"
      Expect-Rejection $item $invalid "does not exist" $fallbackTestRoot
    }
    "InvalidFallbackHashMismatch" {
      $invalid = $structuredFallback -replace "sha256=$fallbackHash", ("sha256=" + ('0' * 64))
      Expect-Rejection $item $invalid "does not match" $fallbackTestRoot
    }
    "InvalidFallbackAbsolutePath" {
      $absoluteArtifact = $fallbackArtifactPath -replace '\\', '/'
      $invalid = $structuredFallback -replace "artifact=$([regex]::Escape($fallbackRelativePath))", "artifact=$absoluteArtifact"
      Expect-Rejection $item $invalid "must be relative" $fallbackTestRoot
    }
    "InvalidZeroLabel" {
      Expect-Rejection $item ($zero -replace "검색 완료/0선택", "미완성(0선택)") "Forbidden stale zero-selection label"
    }
    "InvalidSearchAttemptOneReceiptMultipleMisses" {
      $invalid = Set-SearchAttemptReceipt $partial $q2BadReceipt
      Expect-Rejection $item $invalid "receipt count must equal missed source problem number count"
    }
    "InvalidSearchAttemptWrongTargetBinding" {
      $wrongTargetEntries = @(
        (New-SearchAttemptFixtureReceipt "report-target-1" "miss-closure-ready" $script:SearchReceiptZeroRelativePath),
        (New-SearchAttemptFixtureReceipt "report-target-2" "miss-closure-ready" $script:SearchReceiptPartialRelativePath)
      )
      $invalid = Set-SearchAttemptReceipt $partial ($wrongTargetEntries -join " || ")
      Expect-Rejection $item $invalid "targetBinding.sourceProblemNumber does not match missed problem number"
    }
    "InvalidSearchAttemptDuplicateTargetBinding" {
      $invalid = Set-SearchAttemptReceipt $partial ($duplicateTargetReceipts -join " || ")
      Expect-Rejection $item $invalid "reuse a target source problem number"
    }
    "InvalidSearchAttemptMissingReceipt" {
      $invalid = Set-SearchAttemptReceipt $partial (New-SearchAttemptFixtureReceipt "report-target-1" "miss-closure-ready" $script:SearchReceiptPartialRelativePath)
      Expect-Rejection $item $invalid "receipt count must equal missed source problem number count"
    }
    "InvalidSearchAttemptExtraReceipt" {
      $extraEntries = @(
        (New-SearchAttemptFixtureReceipt "report-target-1" "miss-closure-ready" $script:SearchReceiptPartialRelativePath),
        (New-SearchAttemptFixtureReceipt "report-target-2" "miss-closure-ready" $script:SearchReceiptPartialRelativePath),
        (New-SearchAttemptFixtureReceipt "report-target-3" "miss-closure-ready" $script:SearchReceiptZeroRelativePath)
      )
      $invalid = Set-SearchAttemptReceipt $partial ($extraEntries -join " || ")
      Expect-Rejection $item $invalid "receipt count must equal missed source problem number count"
    }
    }
  }
  if ($Case -eq "All") {
    $readyProjection = Invoke-MathSecrReportLint $partial
    Assert-True ($readyProjection.SearchAttemptStatus -ceq "miss-closure-ready") "Ready search receipt must project derived miss-closure-ready status"
    Assert-True ($readyProjection.SearchAttemptCanCloseMiss -eq $true) "Ready search receipt must project CanCloseMiss=true"
    $readyCommonChips = @($readyProjection.SearchAttemptCommonChips)
    Assert-True ($readyCommonChips.Count -eq 2 -and $readyCommonChips[0] -ceq "직선" -and $readyCommonChips[1] -ceq "곡선") "Ready search receipt must project ordered common literal chips"
    $readyFixture = Get-Content -LiteralPath $searchReceiptPartialPath -Raw | ConvertFrom-Json
    $expectedReadyAttempts = @($readyFixture.cases | ForEach-Object { $_.packet.attempts }).Count
    Assert-True (@($readyProjection.SearchAttemptAttempts).Count -eq $expectedReadyAttempts) "Ready search receipt must project all ordered attempts"

    $phraseProjection = Invoke-MathSecrReportLint $phrasePartial
    $phraseFixture = Get-Content -LiteralPath $searchReceiptPhrasePath -Raw | ConvertFrom-Json
    $expectedPhraseAttempts = @($phraseFixture.cases | ForEach-Object { $_.packet.attempts }).Count + @($phraseFixture.cases).Count
    $projectedPhraseAttempts = @($phraseProjection.SearchAttemptAttempts)
    Assert-True ($projectedPhraseAttempts.Count -eq $expectedPhraseAttempts) "Phrase search receipt must project prepass plus all proof attempts"
    $projectedPrepasses = @($projectedPhraseAttempts | Where-Object { $_.AttemptKind -ceq "phrase-prepass" })
    Assert-True ($projectedPrepasses.Count -eq 2) "Phrase search receipt must expose one ordered prepass per missed target"
    Assert-True ($projectedPrepasses[0].OrderedChips[0] -ceq "두 직선의 교점" -and $projectedPrepasses[0].OrderedProvenance[0] -ceq "literal-body") "Phrase search receipt must expose ordered prepass chips and provenance"

    $pendingProjection = Invoke-MathSecrReportLint $pendingPartial
    Assert-True ($pendingProjection.SearchAttemptStatus -ceq "candidate-recovery-pending") "Toxic search receipt may pass only as candidate-recovery-pending diagnostic"
    Assert-True ($pendingProjection.SearchAttemptCanCloseMiss -eq $false) "Toxic search receipt must never project miss closure"
    $pendingCommonChips = @($pendingProjection.SearchAttemptCommonChips)
    Assert-True ($pendingCommonChips.Count -eq 1 -and $pendingCommonChips[0] -ceq "양수") "Toxic receipt must expose the common poisoned chip"

    $pendingZeroError = $null
    try {
      $null = Invoke-MathSecrReportLint $pendingZero
    } catch {
      $pendingZeroError = $_.Exception.Message
    }
    Assert-True ($pendingZeroError -like "*miss-closure-ready*") "검색 완료/0선택 must reject a pending toxic receipt"
    $blockedPendingProjection = Invoke-MathSecrReportLint $pendingBlockedZero
    Assert-True ($blockedPendingProjection.Status -ceq "차단" -and $blockedPendingProjection.SearchAttemptStatus -ceq "candidate-recovery-pending" -and $blockedPendingProjection.SearchAttemptCanCloseMiss -eq $false) "Pending toxic zero-selection evidence must remain 차단 and unresolved"

    $forgedExpectedEntries = @(1, 2 | ForEach-Object {
        New-SearchAttemptFixtureReceipt "report-target-$_" "candidate-recovery-pending" $script:SearchReceiptPartialRelativePath
      })
    $forgedExpected = Set-SearchAttemptReceipt $partial ($forgedExpectedEntries -join " || ")
    Expect-Rejection "InvalidSearchAttemptForgedExpected" $forgedExpected "expected status does not match derived status"

    $singleMiss = $singleMissPartial
    $missingArtifact = Set-SearchAttemptReceipt $singleMiss "artifact=mathsecr-paper-builder-kit/test-fixtures/search-attempts/missing.json; sha256=$([string]('0' * 64)); case=report-target-1; expected=miss-closure-ready"
    Expect-Rejection "InvalidSearchAttemptMissingArtifact" $missingArtifact "does not exist"

    $hashMismatch = Set-SearchAttemptReceipt $singleMiss "artifact=mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json; sha256=$([string]('0' * 64)); case=synthetic-absence-control; expected=miss-closure-ready"
    Expect-Rejection "InvalidSearchAttemptHashMismatch" $hashMismatch "SHA-256 does not match"

    $traversal = Set-SearchAttemptReceipt $singleMiss "artifact=../outside/fixture.json; sha256=$([string]('0' * 64)); case=report-target-1; expected=miss-closure-ready"
    Expect-Rejection "InvalidSearchAttemptTraversal" $traversal "parent traversal"

    $unknownCase = Set-SearchAttemptReceipt $singleMiss "artifact=mathsecr-paper-builder-kit/test-fixtures/search-attempts/goguk2-mid-q2.json; sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $script:SearchReceiptSourcePath).Hash); case=missing-case; expected=miss-closure-ready"
    Expect-Rejection "InvalidSearchAttemptUnknownCase" $unknownCase "appear exactly once"

    $duplicateCaseReport = Set-SearchAttemptReceipt $singleMiss $searchReceiptDuplicateReceipt
    Expect-Rejection "InvalidSearchAttemptDuplicateCase" $duplicateCaseReport "appear exactly once" $searchReceiptTestRoot

    $tamperedAggregateReport = Set-SearchAttemptReceipt $singleMiss $searchReceiptTamperedReceipt
    Expect-Rejection "InvalidSearchAttemptTamperedAggregate" $tamperedAggregateReport "expected status does not match derived status" $searchReceiptTestRoot

    $isolatedReceiptReport = Set-SearchAttemptReceipt $singleMiss $searchReceiptFixtureReceipt
    $isolatedProjection = Invoke-MathSecrReportLint $isolatedReceiptReport $searchReceiptTestRoot
    Assert-True ($isolatedProjection.SearchAttemptCanCloseMiss -eq $true) "Trusted relative receipt artifact must validate outside the repository root"

    # A raw DOM observation contains ISO timestamp strings. Exercise the actual
    # file loader, including PowerShell 7.5+ automatic JSON date conversion.
    . (Join-Path $ProjectRoot 'mathsecr-paper-builder-kit/test-fixtures/body-comparison/synthetic_selection_test_support.ps1')
    $observedFixture = $searchReceiptFixtureRaw | ConvertFrom-MathSecrSyntheticTestJson
    foreach ($fixtureCase in $observedFixture.cases) {
      foreach ($attempt in $fixtureCase.packet.attempts) {
        $visibleIds = @(if ($attempt.resultCount -gt 0) { 'synthetic-visible-id' })
        $observation = New-MathSecrSyntheticSelectionObservation -AttemptId $attempt.attemptId `
          -Chips @($attempt.chips | ForEach-Object { $_.value }) -ResultCount $attempt.resultCount -OrderedIds $visibleIds
        if ($attempt.scope -ceq 'whole-db') {
          $observation.submission.criteria.scopeMode = '전체 DB'
          $observation.beforeSubmit.raw.criteria.scopeMode = '전체 DB'
          foreach ($read in $observation.observations) { $read.raw.criteria.scopeMode = '전체 DB' }
        }
        $attempt | Add-Member -NotePropertyName observationReceipt -NotePropertyValue $observation
      }
    }
    $observedFixturePath = Join-Path $searchReceiptTestRoot 'observed-fixture.json'
    [IO.File]::WriteAllText($observedFixturePath, ($observedFixture | ConvertTo-Json -Depth 70), [Text.UTF8Encoding]::new($false))
    $observedReceipt = New-SearchAttemptReceiptForArtifact $searchReceiptTestRoot 'observed-fixture.json' 'report-target-1' 'miss-closure-ready'
    $observedReport = Set-SearchAttemptReceipt $singleMiss $observedReceipt
    $observedProjection = Invoke-MathSecrReportLint $observedReport $searchReceiptTestRoot
    Assert-True $observedProjection.SearchAttemptCanCloseMiss 'Typed observation timestamps survive actual report receipt JSON loading'
    Assert-True ($null -ne $observedProjection.SearchAttemptAttempts[0].SearchObservation) 'Report reuses the validated observation projection'
  }
} finally {
  $resolvedFallbackRoot = [IO.Path]::GetFullPath($fallbackTestRoot)
  $resolvedSummaryRoot = [IO.Path]::GetFullPath($summaryTestRoot)
  $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (-not $resolvedFallbackRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing fallback fixture cleanup outside temp: $resolvedFallbackRoot"
  }
  if (-not $resolvedSummaryRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing public-summary fixture cleanup outside temp: $resolvedSummaryRoot"
  }
  if (Test-Path -LiteralPath $resolvedFallbackRoot) {
    Remove-Item -LiteralPath $resolvedFallbackRoot -Recurse -Force
  }
  if (Test-Path -LiteralPath $resolvedSummaryRoot) {
    Remove-Item -LiteralPath $resolvedSummaryRoot -Recurse -Force
  }
  $resolvedSearchReceiptRoot = [IO.Path]::GetFullPath($searchReceiptTestRoot)
  $resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
  $projectPrefix = $resolvedProjectRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $resolvedSearchReceiptRoot.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing search-receipt fixture cleanup outside project temp: $resolvedSearchReceiptRoot"
  }
  if (Test-Path -LiteralPath $resolvedSearchReceiptRoot) {
    Remove-Item -LiteralPath $resolvedSearchReceiptRoot -Recurse -Force
  }
}

Write-Host "ReportLint PASS"
