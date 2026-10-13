# HDHsubi 설치 소스

이 저장소는 Windows 11/macOS용 설치 소스다. 사용자가 설치·복제·사용을 요청하면 문서 소개만 하고 끝내지 말고 [설치 안내](docs/installation.md)에 따라 설치를 수행한다. 새 작업공간과 Codex home은 실제 환경과 사용자 요청에서 결정한다. 소스 checkout과 작업공간은 분리한다.

1. 현재 OS, Python 3.10 이상, PowerShell 7, Aside Browser와 CLI를 점검한다. Python 3.12가 검사 기준이다. 사용자에게 같은 정보를 다시 묻기 전에 실제 경로를 확인한다.
2. Windows는 `powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/bootstrap.ps1 -ProjectRoot <별도 작업공간> -InstallDependencies`로 설치한다. macOS는 Python이 없으면 기존 Homebrew의 `brew install python@3.12`를 사용하고, `python3 ./scripts/install.py --project-root <별도 작업공간> --install-tools`를 실행한다. Homebrew가 없으면 공식 설치 방법을 안내한다. 지원되는 승인·권한 경로를 따른다.
3. 설치기는 전용 Python 환경, 고정 버전 패키지, 한글 글꼴, 제작 도구, AGENTS와 skill을 설치한다. `--install-tools`는 누락된 PowerShell/Aside CLI와 macOS Aside 앱 설치를 시도한다. Windows Aside 앱은 [공식 다운로드](https://aside.com/download)에서 설치한다. 앱 설치 UI나 본인 로그인이 필요하면 필요한 행동만 명확히 알린다. 지원되지 않는 native control을 다른 도구로 우회하지 않는다.
4. 설치 후 `scripts/install.py --project-root <작업공간> --check`를 실행한다. 설치된 작업공간의 `scripts/run.py`로 local Aside probe를 실행한다. 공개 설치 PASS와 브라우저·로그인·실제 제작 성공을 구분한다. 서명 오류, 다운로드 실패, 연결 실패를 숨기거나 성공으로 채우지 않는다.
5. 사용자가 제작도 요청했고 원본과 문제지 URL이 있으면 설치된 작업공간의 AGENTS, mathsecr-paper-builder skill, start prompt를 따라 계속한다. 계정은 수신자 본인 것을 사용한다. 제작을 요청하지 않은 설치 작업에서 문제지를 바꾸지 않는다.

GitHub 파일만으로 공개 runtime 설치가 가능하다. 과거 비공개 `.omo/evidence`, 평가 registry, 문항 이미지를 수신자에게 요구하지 않는다. 공개 fixture를 과거 실제 근거로 위장하지 않는다. 검색·본문·저장 계약을 완화해서 설치를 통과시키지 않는다. `출제하기`는 사용자의 명시 요청 없이 클릭하지 않는다.

코드 변경 시 `python scripts/test_installation.py`, `python scripts/validate_publication.py`를 실행한다. 설치·경로·PDF 변경은 Windows/macOS CI의 새 작업공간 설치와 production smoke 결과를 확인한다. 변경한 기존 kit 파일의 SOURCE_SNAPSHOT export 해시와 runtime-package는 `python scripts/update_runtime_package.py`로 갱신한다. 실제 사용자 경로와 로그인 자료는 저장소에 올리지 않는다.
