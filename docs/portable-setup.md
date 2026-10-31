# 다른 Windows PC에서 HML → 서식 HWPX → PDF

이 경로는 다운로드한 수학비서 HML부터 시작한다. 공장 서버·4417·collector·
도리 설치·사용자 홈의 숨은 파일을 요구하지 않는다. 검색·자동 출제·HML
다운로드는 별도 사이트 단계이며 수신자 계정과 승인이 필요하다.
사이트 도구 설치는 [기존 설치 안내](installation.md)를 따른다.

## 외부 전제조건

| 필요 항목 | 준비 방법 / 범위 |
|---|---|
| Windows 11, 로그인된 사용자 데스크톱 | macOS/Linux에서는 한컴 COM 변환을 실행할 수 없다. 사이트 도구의 macOS 지원과 별개다. |
| 정식 한컴오피스 한글 | **한컴 설치 필수. 이 저장소에 번들하지 않는다.** 한글 2024의 HWPFrame.HwpObject 자동화와 HWPX/PDF 저장 경로를 기준으로 한다. Viewer나 웹 한글은 대체가 아니다. |
| 32비트 한글 자동화 엔진 | HDHangyul에 포함된 보안 DLL은 x86이다. 다른 비트수 설치는 별도 호환성 검증이 필요하다. |
| Git, Python 3.12, Windows PowerShell 5.1 | PATH에서 `git`, `py -3.12`, `powershell.exe`가 실행되어야 한다. 사이트 검사에는 별도로 PowerShell 7이 필요하다. |
| GitHub 접근과 Python 패키지 다운로드 | HDHangyul 저장소를 읽을 계정 권한이 필요한 경우 수신자 본인 계정으로 인증한다. 토큰을 설정 파일에 넣지 않는다. |
| 글꼴 | 기본 매크로는 나눔명조, -윤고딕320, -윤고딕340을 사용한다. 한컴 수식 글꼴과 원문/서식에서 참조하는 글꼴도 설치해야 동일 조판이 된다. 상용 글꼴은 별도 라이선스가 필요하며 업로드하지 않는다. |
| 사용할 권리가 있는 HML | 원본과 결과를 보존한다. 실제 시험 콘텐츠와 로그인 자료는 저장소에 추가하지 않는다. |

다른 한컴 버전·다른 글꼴의 동일 조판은 보장하지 않는다. 필요한 글꼴이 없으면
실행 전에 설치하거나 아래 style JSON으로 명시적으로 바꾸고 PDF를 검수한다.

## Clone / 설치

PowerShell 창에서 실행한다. PR 검토 중에는 브랜치명을 유지하고, 머지 후에는
원하는 배포 커밋을 checkout한다. 두 저장소 모두 고정된 커밋으로 재현한다.

```powershell
git clone --branch repro/portable-setup https://github.com/HDHhhdhh/HDHsubi.git C:\src\HDHsubi
Set-Location C:\src\HDHsubi
git rev-parse HEAD
py -3.12 portable/setup.py --runtime C:\subi-runtime
```

설치기는 `C:\subi-runtime\HDHangyul`을 clone하고
`95ae566391396e849ee196772d3560d7f67a75e2`로 detached checkout한다.
서브모듈은 사용하지 않으므로 `git submodule update`는 필요 없다.
기존 엔진 checkout이 다른 커밋이거나 수정됐으면 덮어쓰지 않고 실패한다.
다른 runtime 디렉터리를 지정해서 새로 설치한다.

같은 runtime에 `.venv`를 만들고 `lxml==6.1.3`, `pywin32==312`를 설치한다.
업스트림 DLL SHA-256을 확인한 뒤 현재 사용자 레지스트리의
`SOFTWARE\HNC\HwpAutomation\Modules` 32/64비트 뷰에
`HDHsubiPortableFilePathChecker`만 등록한다. 같은 이름이 다른 파일을 가리키면
중단하고 타 앱의 등록은 바꾸지 않는다. 설치 중에는 한글을 열지 않는다.
다운로드/설치만 검사하려면 `--skip-registration`을 사용하고,
실제 변환 전에는 이 옵션 없이 다시 설치 명령을 실행한다.

## 실행

원본 HML을 예를 들어 `C:\subi-input\paper.hml`에 둔다.
출력은 존재하지 않는 새 디렉터리로 지정한다.
한 PC의 다른 한컴 자동화 작업이 끝난 안전한 시간에 실행한다.

```powershell
& C:\subi-runtime\.venv\Scripts\python.exe portable/run.py `
  --runtime C:\subi-runtime `
  --input C:\subi-input\paper.hml `
  --title "요청한 문제지 이름" `
  --output C:\subi-output\attempt-001
```

처리는 순서대로 수행된다.

1. HDHangyul `scripts/convert-hwp.ps1 -InputJsonPath`의 격리 worker로 HML을
   HWPX로 변환한다. 원본삭제 옵션을 보내지 않는다.
2. 전사·수식·해설 수와 masterpage 문구를 대조한다.
3. 제목을 머릿말·빠른정답·해설 상자에 적용하고, 빠른정답이 아닌 각 endnote
   해설 영역에 매크로를 적용한다. `Alt+4 / Alt+Shift+4`에 대응하는 COM/
   XML 처리가 코드에 있으므로 개인 HMI 설치나 키보드 단축키 등록은 필요 없다.
4. 한컴 실측 높이로 단별 남는 여백을 균등 배분한다. 한 단 최대 두 문제이며
   넘치면 한 문제로 분리한다. 축소·잘라내기는 하지 않는다.
5. 알려진 첫 해설 참조번호의 중복 번호 패턴만 교정하고, 한글로 다시 열어
   본문·수식·해설과 실제 위치·높이가 유지됐는지 검사한다.
6. HDHangyul로 최종 HWPX를 PDF로 저장한다. 외부 발송·인쇄는 하지 않는다.

`paper.hwpx`, `paper.pdf`가 최종 산출물이다. `converted.hwpx`, `styled.hwpx`,
`validation.json`, `receipt.json`, 잡 JSON과 이벤트 로그도 남긴다.
`receipt.json.status=produced-needs-visual-qa`는 파일 생성과 자동 검증 성공이며
납품 승인이나 시각 검수 완료가 아니다.

한컴을 열지 않는 준비 검사:

```powershell
& C:\subi-runtime\.venv\Scripts\python.exe portable/run.py `
  --runtime C:\subi-runtime --input C:\subi-input\paper.hml `
  --title "준비 검사" --output C:\subi-output\plan-001 --plan-only
```

이 검사는 엔진 커밋·무결성·runtime 경로·출력 충돌과 서식 조립까지만 확인한다.
한글 설치·글꼴·COM 실행·문항 보존·PDF 출력 성공의 증거로 쓰지 않는다.

## 서식과 글꼴

clone에 필요한 비밀 아닌 서식·매크로 코드는 모두 들어 있다:
[후처리 코드](../portable/postprocess.py),
[서식 원본](../portable/template-parts.json),
[서식 조립기](../portable/template.py),
[의존성 고정](../portable/dependencies.json).
빈 서식의 머릿말·빠른정답·해설 상자와 스타일만 보존했다.
개인 서명과 학원 원본 이미지는 **중립 회색 이미지 두 개로 대체**했다.
이는 원래 브랜드의 동일 복제가 아니다. 정확한 브랜드가 필요한 경우 권한이 있는
서식을 로컬에 두고 `--template C:\subi-input\approved-template.hwpx`로 전달한다.
서식은 세 상자를 유일하게 식별할 수 있어야 하고 각 상자에 `프린트 제목`
슬롯 하나가 있어야 한다.

글꼴을 명시적으로 바꾸려면 로컬 JSON을 UTF-8로 저장하고
`--style-json C:\subi-input\style.json`을 붙인다. 예:

```json
{
  "problemFont": "나눔명조",
  "problemSize": 11,
  "noteFont": "나눔명조",
  "numberFont": "나눔명조",
  "numberSize": 17,
  "problemIndent": -10
}
```

이 옵션은 매크로 대상 글꼴을 바꾼다. 템플릿·원문에 참조된 모든 글꼴을
자동 대체하거나 설치하지 않는다.

## 검증 / 오류

```powershell
python -B portable/test_portable.py
python -B scripts/test_installation.py
python -B scripts/validate_publication.py
```

오프라인 검사는 공개 서식의 세 상자·참조·개인 이미지 제외, 매크로 여백 규칙,
변환기 작업 형식, 실패 응답과 출력 덮어쓰기 거부를 검사한다.
실제 한컴 결과 검수는 수신 PC에서 한 번 별도로 해야 한다:
문서 열림, 문제 수·순서·수식·그림, 세 제목, 해설 수·서식,
단별 여백, 첫 번호 중복, PDF 페이지와 글꼴 대체 여부를 원본과 대조한다.

변환·매크로·여백 검사 실패 시 PDF를 내보내지 않는다.
`validation.json.status=partial`도 완료로 취급하지 않는다. 출력과 로그를
보존하고 원인을 고친 뒤 새 attempt 디렉터리로 실행한다. 실패했다고 사이트
문제지를 재생성하거나 서버를 재시작하지 않는다.
`hancom.lock`이 남아 있으면 소유 PID와 진행 중 작업을 확인한다.
실행기는 기존 lock을 탈취하거나 다른 한글 프로세스를 종료하지 않는다.

## 누락 의존성 조사 결과

| 최초 clone 상태 | 이번 추가 / 외부 의존 |
|---|---|
| 사이트 검색·구성 kit와 installer 있음 | 그대로 사용 |
| HML→PDF 실행 진입점 없음 | `portable/setup.py`, `portable/run.py` 추가 |
| HDHangyul 없음 | setup이 정본 저장소를 고정 커밋으로 clone |
| 공장 경로에만 매크로·실측 여백 코드 있음 | 독립 `portable/postprocess.py`와 출처 추가 |
| 사용자 홈의 HWPX·HMI 의존 | 비밀 아닌 서식만 JSON으로 포함, HMI 대신 실행 코드 포함 |
| 한컴·보안 등록·Python COM 패키지·상용 글꼴 없음 | 한컴/글꼴은 수신자 준비, DLL은 upstream에서 수령·검증, 패키지/전용 등록은 setup |
| 실제 시험지와 개인 서명·로그인 정보 없음 | 계속 제외; 실제 HML은 수신자 입력, 원본 브랜드는 로컬 선택 입력 |

JSON 서식 자산은 텍스트 소스로 보관하므로 전역 `*.hwpx/*.hwp/*.pdf` 제외를
풀 필요가 없다. 자격증명, 개인 문서, 생성 결과를 실수로 게시하지 않는다.
