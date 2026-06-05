# Task Board 오프라인(Offline) 지원 계획서

> 작성일: 2026-06-05
> 대상: Task Board 웹앱(`index.html`, GitHub Pages 호스팅) 의 "페이지 오프라인" 동작
> 범위: 효과 / 오버헤드 / 사이드 이펙트 + 단계별 실행 계획 + 자료 조사 요약

---

## 1. 목적 (Why)

현재 웹앱(`index.html`)은 **온라인 전제**로 동작한다. 페이지 자체(HTML/JS/CSS)와 데이터(Supabase)를
모두 네트워크에서 받아오므로, 네트워크가 끊기거나 사내 프록시가 외부 접속을 차단하면 **빈 화면 또는
로딩 실패**가 된다.

"페이지 오프라인" 지원의 목표는:

- 네트워크가 없거나 불안정해도 **앱 셸(화면)이 즉시 뜨고**, 이미 본 데이터는 **읽을 수 있게** 한다.
- 재방문 시 **로딩 속도**를 개선한다(캐시 우선 제공).
- (선택) 오프라인 중 변경분을 **로컬에 쌓아두었다가 온라인 복귀 시 동기화**한다.

> 참고: 별도로 만든 `desktop.html` 은 이미 100% 로컬(서버 불필요)이라 이 계획의 대상이 아니다.
> 이 문서는 "Supabase 기반 온라인 웹앱"을 오프라인에서도 견디게 만드는 것에 관한 것이다.

---

## 2. 현재 구조 분석 (As-Is)

| 구성 | 현재 | 오프라인 시 문제 |
|---|---|---|
| 앱 셸(HTML/JS/CSS, vendor 스크립트) | 매 방문 네트워크 로드 | 네트워크 없으면 화면 자체가 안 뜸 |
| 데이터(nodes/tasks) | Supabase REST 실시간 조회 | 끊기면 빈 목록 + 오류 |
| 인증 세션 | Supabase Auth(localStorage 토큰) | 토큰은 남지만 검증/갱신은 온라인 필요 |
| 쓰기(추가/수정/삭제) | 즉시 Supabase 반영 | 끊기면 실패 |

핵심: **앱 셸**과 **데이터** 두 계층 모두 오프라인 대비가 필요하다.

---

## 3. 구현 방식 옵션 (How)

### 3-A. 앱 셸 오프라인 — Service Worker + Cache API (PWA의 핵심)
- `service-worker.js` 를 등록해 HTML/JS/CSS/vendor 파일을 **사전 캐시(precache)** 한다.
- 정적 자산은 **cache-first**, API 호출은 **network-first 또는 stale-while-revalidate** 전략 사용.
- `manifest.webmanifest` 추가 시 "홈 화면/독에 설치", 독립 창 실행 등 앱처럼 동작(PWA).

### 3-B. 데이터 오프라인 — 로컬 저장 계층
- 읽기 캐시: 마지막으로 받은 nodes/tasks 를 **IndexedDB**(권장) 또는 localStorage 에 저장 →
  오프라인에서 그 스냅샷을 표시.
- (선택) 쓰기 큐: 오프라인 변경분을 **mutation queue** 로 쌓고, 온라인 복귀 시 순서대로 전송.

### 3-C. 동기화/충돌 전략 (쓰기까지 오프라인 지원할 경우)
- **Last-Write-Wins(LWW)**: `updated_at` 타임스탬프 최신 우선. 개인용·단일 사용자엔 충분(권장 시작점).
- 필드 단위 병합 / CRDT(Yjs·Automerge) 는 협업·동시편집이 많을 때만. 본 앱엔 과함.

### 권고 단계
1. **셸만 오프라인(3-A)** → 가장 효과 크고 위험 작음. 먼저.
2. **읽기 캐시(3-B 일부)** → 오프라인 "보기" 지원.
3. **쓰기 큐+동기화(3-B/3-C)** → 필요성 확인 후 마지막. 복잡도·위험 큼.

---

## 4. 기대 효과 (Benefits)

- **즉시 로딩/재방문 속도 향상**: 셸을 캐시에서 바로 제공 → 네트워크 왕복 제거.
- **네트워크 단절 내성**: 끊겨도 화면과 본 데이터 유지(빈 화면 방지).
- **대역폭·서버 부하 절감**: 정적 자산 재다운로드 감소.
- **앱 경험(PWA)**: 설치·독립 창·아이콘으로 "앱처럼" 사용.
- 업계 현황: 서비스워커 채택 약 18.9% 의 사이트(2025 Web Almanac) — 성숙·표준 기술.

---

## 5. 오버헤드 (Cost / Overhead)

| 항목 | 내용 |
|---|---|
| **개발 복잡도** | 서비스워커 생명주기(install/activate/fetch), 캐시 버전 관리 학습 필요. Workbox 쓰면 완화. |
| **빌드/배포** | 자산 버전 해시, SW 갱신 로직 추가. 정적 단일 파일 구조엔 수동 캐시 목록 관리 부담. |
| **저장 공간** | 캐시 + IndexedDB 가 디스크 사용. 모바일 Cache API 약 50MB/파티션, 데스크탑은 대용량. |
| **메모리/CPU** | SW 별도 스레드 등록·fetch 가로채기 비용(미미하나 0은 아님). |
| **유지보수** | 캐시 무효화·SW 업데이트 테스트가 상시 필요(아래 리스크 참조). |
| **초기 로드** | precache 가 과하면 첫 방문 시 데이터 낭비 — 핵심 자산만 캐시. |

---

## 6. 사이드 이펙트 & 리스크 (Side Effects / Risks) — 가장 중요

### 6-1. "갱신이 안 됨" — Stale Cache 문제 (대표적 함정)
- cache-first 로 **버전 없는 자산**을 캐시하면, 파일을 바꿔도 옛 버전이 계속 제공됨.
- **service-worker.js 자체가 캐시**되면 신규 배포가 사용자에게 최대 ~24시간 반영 안 됨.
- API 응답을 무분별 캐시하면 **오래된 데이터**가 새로고침해도 그대로 보임.
- 완화: 자산 파일명/캐시 이름에 **버전 부여**, SW 파일은 `no-cache`, API는 network-first,
  배포 시 옛 캐시 정리(activate에서 cleanup), "새 버전 있음 → 새로고침" 안내.

### 6-2. 저장소 제거(Eviction) / 용량
- 브라우저는 디스크 부족 시 **LRU(가장 오래 안 쓴 출처)** 부터 데이터 삭제.
- **Safari/iOS: 7일 미사용 시 스크립트 저장소 전체 삭제** → 오프라인 캐시·로컬 데이터 소실 가능.
- 완화: 중요 데이터는 `navigator.storage.persist()` 로 지속성 요청 + **명시적 백업(JSON 내보내기)**.

### 6-3. 동기화 충돌 / 데이터 정합성 (쓰기 오프라인 시)
- 같은 항목을 두 곳에서 오프라인 수정하면 충돌. LWW는 **늦게 쓴 쪽이 이전 변경을 덮어씀**(데이터 손실 가능).
- 완화: 우선 읽기 전용 오프라인부터, 쓰기는 충돌 빈도 확인 후. 멱등 서버 처리·동기화 지표 관측.

### 6-4. 보안 사이드 이펙트 ⚠️ (사내 환경에서 특히 중요)
- 오프라인 캐시/IndexedDB는 **데이터를 디스크에 평문으로 남긴다** → 공용/회사 PC에 잔존 위험.
- 서비스워커는 **세션을 넘어 지속**되므로, XSS가 한 번 성공하면 SW 캐시를 오염시켜
  **지속적 스크립트 주입/중간자 공격**으로 악화될 수 있다(연구사례 다수).
- 완화 원칙:
  - **민감/회사 데이터는 캐시하지 않는다**(never cache sensitive data).
  - **CSP**(Content-Security-Policy)로 스크립트 출처 제한, XSS 차단.
  - 필요 시 캐시/IndexedDB 데이터 **암호화**, 로그아웃 시 캐시·SW 등록 해제(cleanup).
  - HTTPS 전제(서비스워커는 보안 컨텍스트에서만 동작).
- **회사 정책 관점**: 오프라인 캐시는 곧 "회사 화면/데이터가 단말 디스크에 남는 것"이므로,
  사내 보안 기준(특히 반도체 환경)에 부합하는지 별도 검토 필요.

### 6-5. 디버깅 난이도
- "새로고침해도 안 바뀜" 류의 캐시 이슈는 재현·진단이 까다로움 → 개발자도구 SW 패널/하드리셋 절차 표준화 필요.

---

## 7. 단계별 실행 계획 (Roadmap)

### Phase 0 — 사전 검토 (0.5d)
- HTTPS 호스팅 확인(GitHub Pages = OK), 캐시 대상 자산 목록 확정.
- **보안 검토**: 어떤 데이터를 캐시할지/안 할지 정책 결정(민감정보 제외 원칙).

### Phase 1 — 앱 셸 오프라인 + PWA (1~2d)
- `manifest.webmanifest`(이름/아이콘/표시 모드) 추가.
- `service-worker.js`: 정적 자산 precache(cache-first), **버전드 캐시 이름**, activate에서 옛 캐시 정리.
- "오프라인 폴백" 페이지, 업데이트 감지 시 새로고침 안내 UI.
- 검증: Lighthouse PWA/Best-Practices, 비행기 모드 로드 테스트.

### Phase 2 — 데이터 읽기 오프라인 (1~2d)
- nodes/tasks 스냅샷을 IndexedDB에 저장, 온라인 시 갱신(stale-while-revalidate).
- 오프라인 표시 배지("오프라인 — 마지막 동기화 시각") 추가.

### Phase 3 — (선택) 쓰기 큐 + 동기화 (3~5d, 위험 큼)
- mutation queue + 온라인 복귀 시 전송, LWW 충돌 처리, 실패 재시도.
- 충돌·손실 시나리오 테스트, 동기화 지표 로깅.

### Phase 4 — 관측/운영
- 캐시 적중률, 저장 사용량(`navigator.storage.estimate()`), SW 업데이트 반영률 모니터링.

---

## 8. 검증 / 측정 지표

- **Lighthouse**: PWA·Performance·Best-Practices 점수.
- **오프라인 로드 성공률**: 비행기 모드에서 셸/데이터 표시 여부.
- **재방문 로드 시간**(캐시 적중 전후).
- **저장 사용량 / eviction 발생률**.
- (Phase 3) **동기화 지연·충돌·손실 건수**.

---

## 9. 의사결정 포인트 & 권고

1. **어디까지 오프라인?** — 권고: *Phase 1(셸)+Phase 2(읽기)* 까지. 쓰기 오프라인(Phase 3)은
   복잡도·데이터손실·보안 위험 대비 효용을 확인한 뒤 결정.
2. **민감/회사 데이터 캐시 여부** — 권고: **캐시하지 않음**(보안 사이드 이펙트 6-4). 개인·비민감만.
3. **Workbox 사용 여부** — 캐시 전략·SW 생명주기 보일러플레이트를 크게 줄여줌(단일 파일 구조라면
   간단한 수제 SW도 가능).

---

## 10. 참고 자료 (Research / References)

- MDN — Offline and background operation (PWA): https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Offline_and_background_operation
- MDN — js13kGames: Making the PWA work offline with service workers: https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Tutorials/js13kGames/Offline_Service_workers
- MDN — Storage quotas and eviction criteria: https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria
- web.dev — Storage for the web (Cache API / IndexedDB 용량): https://web.dev/articles/storage-for-the-web
- HTTP Archive — Web Almanac 2025: PWA(채택 현황): https://almanac.httparchive.org/en/2025/pwa
- Workbox — Expectations around service worker deployment(배포/갱신 함정): https://developer.chrome.com/docs/workbox/service-worker-deployment
- Infinity Interactive — Taming PWA Cache Behavior("그냥 새로고침"이 안 될 때): https://iinteractive.com/resources/blog/taming-pwa-cache-behavior
- MagicBell — Offline-First PWAs: Service Worker Caching Strategies: https://www.magicbell.com/blog/offline-first-pwas-service-worker-caching-strategies
- LogRocket — Offline-first frontend apps in 2025 (IndexedDB/SQLite): https://blog.logrocket.com/offline-first-frontend-apps-2025-indexeddb-sqlite/
- "The Remote on the Local: Exacerbating Web Attacks Via Service Workers Caches"(보안 연구): https://secpriv.wien/fulltext/publik_296700.pdf
- Chromium — Service Worker Security FAQ: https://chromium.googlesource.com/chromium/src/+/main/docs/security/service-worker-security-faq.md
- Securing Service Workers and Handling Sensitive Data: https://medium.com/@lmssrinivas/securing-service-workers-and-handling-sensitive-data-f6a3312ef755

---

*요약: 셸 오프라인(PWA)은 효과 크고 위험 작아 우선 추진 권장. 데이터 읽기 캐시까지가 합리적 지점.
쓰기 오프라인·민감데이터 캐시는 보안·정합성 사이드 이펙트가 커서 신중히. 특히 사내(보안 민감) 환경에서는
"민감 데이터는 캐시하지 않는다"를 기본 원칙으로 한다.*
