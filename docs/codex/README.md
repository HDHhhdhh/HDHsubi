# Codex 작업 지시서

이 폴더의 파일은 Codex(GPT-6.1 Sol)에 그대로 넣는 프롬프트다. 각 파일은 한 스레드에서 끝내는 한 단위 작업이다.

| 파일 | 내용 | 선행 조건 |
|---|---|---|
| [phase-0.md](phase-0.md) | 공개본 회귀 실행 가능화, CI, 성능 기준선 | 없음 |
| [phase-1.md](phase-1.md) | AfterReload 중복 검증 제거 | Phase 0 병합 |
| [phase-2.md](phase-2.md) | 관측 어댑터·조립 자동화·상주 검증 | Phase 0 병합 |
| [phase-3.md](phase-3.md) | surface 추상화 | Phase 1·2 병합, 사용자 승인 D1 |
| [phase-4.md](phase-4.md) | 지침 축소·구조 정리 | Phase 3 병합 |
| [research-tasks.md](research-tasks.md) | Aside·수학비서 UI·Codex 브라우저 조사 | 없음. Phase 2·3와 병행 |

## 프롬프트 형식

모든 지시서는 같은 네 부분으로 쓴다.

1. 목표.
2. 맥락. 읽을 파일과 줄 번호.
3. 제약. 바꾸지 말 것과 금지.
4. 완료 조건. 실행할 명령과 기대 결과.

Codex 실행 권장값: 추론 노력은 `high`다. Phase 1은 `extra high`다. 모호하면 구현 전에 질문한다. 질문은 Issue #1 코멘트로 남긴다.

## 공통 제약

- 기존 테스트의 단정을 지우거나 약화하지 않는다.
- 새 파일 확장자는 `.ps1 .py .js .md .yaml .json .html`만 쓴다.
- 개인 자료를 커밋하지 않는다. `validate_publication.py`가 PASS여야 한다.
- 정책 문서(AGENTS, SKILL, prompts)는 해당 Phase가 허용할 때만 바꾼다.
- PR 본문에 실행한 명령과 출력 요약을 쓴다.

## 공통 검사 명령

Windows, PowerShell 7, Python 3에서 실행한다.

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1   # Phase 0 이후
```
