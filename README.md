# 🗂️ Task Board

로그인으로 보호되는 개인용 task/노트 웹앱입니다. **Supabase**(이메일/비밀번호 로그인 +
비공개 Postgres DB)를 백엔드로 쓰고, 프론트엔드(단일 페이지 앱)는 **GitHub Pages**에서
호스팅합니다. 데이터는 Supabase의 Row Level Security(RLS)로 **사용자별로 격리**되어
**각자 자기 데이터만** 보고 편집합니다(다른 사람 데이터는 보이지 않음). 같은 데이터를
**Claude**(claude.ai 앱 / Claude Code)가 읽고 정리할 수 있습니다.

- 가입은 **관리자 승인** 후 이용(미승인 시 "승인 대기" 화면).
- 승인된 사용자는 **자기 데이터**를 데스크탑/폰 어디서나 보고 편집.
- Claude: 같은 DB를 읽어 task를 정리하고 다시 써 줌.

## 주요 기능
- OneNote식 **자유 중첩 폴더**(섹션그룹 > 섹션 > 페이지) — 좌측에서 계층을 한눈에.
- 구조화 **태스크**: 우선순위 `(A/B/C)`, 마감일 `@YYYY-MM-DD`, 태그 `#tag`.
- 상단 **전체 검색** + **태그 필터**.
- **대시보드**: 최근 30일 완료 추이 라인차트(순수 SVG, 외부 차트 라이브러리 없음).
- 페이지별 **메모(markdown)** — DOMPurify로 살균 렌더(XSS 방지).
- 라이브러리는 CDN이 아니라 `vendor/`에 동봉 → 회사망 CDN 차단 환경에서도 동작.

---

## 1) Supabase 설정 (1회)

1. https://supabase.com 에서 무료 프로젝트 생성.
2. **SQL Editor** 에 `supabase/schema.sql` 전체를 붙여넣고 실행 (테이블 · RLS · 트리거 생성).
3. **Project Settings → API** 에서 두 값 복사:
   - `Project URL`
   - `anon` `public` 키
4. `index.html` 상단 `CONFIG` 에 입력하고 커밋:
   ```js
   const CONFIG = {
     SUPABASE_URL: "https://xxxx.supabase.co",
     SUPABASE_ANON_KEY: "eyJhbGciOi....",   // anon(public) 키만!
   };
   ```
   > ⚠️ **`service_role` 키는 절대 `index.html`/repo에 넣지 마세요.** anon 키는 공개돼도
   > RLS가 데이터를 보호하므로 안전합니다.
5. (선택) **Authentication → Providers → Email** 에서 "Confirm email"을 끄면 가입 즉시
   로그인 테스트가 쉽습니다(개인용이면 꺼도 무방).

## 2) 첫 관리자(admin) 승인

1. 배포된 앱(또는 로컬)에서 본인 이메일로 **가입 요청**.
2. Supabase **SQL Editor** 에서 본인을 admin 으로 승인:
   ```sql
   update public.profiles
     set approved = true, role = 'admin'
     where email = 'skyrytj@gmail.com';
   ```
3. 이후 다른 사람 승인은 같은 식으로 `approved = true` 로 바꾸면 됩니다. 각 사용자는
   **자기 데이터만** 보고 편집합니다(개인별 격리). `role`은 관리용 구분이며 `admin`만
   다른 사람을 승인할 수 있습니다.

## 3) GitHub Pages 배포

1. 이 repo를 **Public** 으로 두고(앱 코드 + anon 키만 들어 있어 안전), 작업 브랜치를
   `main` 에 머지.
2. **Settings → Pages → Source: `main` / `/ (root)`** 활성화.
3. 배포 주소: **https://skyrytj-afk.github.io/task-board/**
   - 회사 데스크탑/폰 모두 이 주소로 접속 → 로그인.

> 참고: 폰(iOS Safari)은 저장공간 압박이나 장기간 미사용 시 로그인 세션을 비울 수 있어
> 가끔 재로그인이 필요할 수 있습니다(정상 동작).

---

## 4) Claude 연동

### A. Claude Code (터미널 / 웹 세션)
`service_role` 키를 **환경변수(시크릿)** 로만 두고, 헬퍼 스크립트로 읽기/쓰기:
```bash
export SUPABASE_URL="https://xxxx.supabase.co"
export SUPABASE_SERVICE_KEY="eyJ...service_role..."   # 절대 커밋 금지
export TB_OWNER_ID="<본인 auth UID>"   # 개인별 격리: 대상 사용자 한정
#   UID 확인: Supabase Authentication > Users, 또는 SQL: select id,email from auth.users;

./scripts/tasks.sh nodes                 # 폴더/페이지 트리
./scripts/tasks.sh open                  # 미완료 태스크
./scripts/tasks.sh add "<page_id>" "(A) 보고서 작성 @2026-06-10 #업무"
./scripts/tasks.sh done "<task_id>"      # 완료(done_at 자동 기록)
```
Claude에게 "미완료 task 정리해줘"라고 하면 이 스크립트로 읽어서 가공/추가할 수 있습니다.

### B. claude.ai 앱 (폰/웹 채팅)
공식 **Supabase MCP 커넥터**를 연결하면 채팅에서 직접 DB를 조회/수정할 수 있습니다.
Supabase의 personal access token + project ref 로 설정합니다(Supabase MCP 문서 참고).

---

## 데이터 모델 요약
- `nodes` — 자유 중첩 트리. `owner_id`, `type`=`folder`|`page`, `title`, `content`(메모 markdown), `parent_id`.
- `tasks` — `owner_id`, `node_id`(페이지), `text`, `priority`(A/B/C), `due_date`, `done`, `done_at`(완료 시 자동), `tags[]`.
- `profiles` — `role`(admin/editor/viewer), `approved`. **admin이 승인.**
- **개인별 격리**: 모든 `nodes`/`tasks` 는 `owner_id = auth.uid()` 인 행만 RLS로 접근 가능.

태스크 입력 문법(앱 빠른추가 / 스크립트 공통):
```
(A) 보고서 초안 작성 @2026-06-10 #업무 #긴급
└우선순위   └내용              └마감일       └태그
```

## 보안 메모
- 실제 접근 통제는 **Supabase RLS** 가 담당합니다. 프론트엔드의 로그인은 그 위의 UI일 뿐이며,
  데이터 보호의 본질은 RLS 정책입니다(`supabase/schema.sql`).
- 프론트엔드/repo: **anon 키만**. `service_role` 키: **Claude Code 환경변수에만**.
- 페이지 메모는 DOMPurify로 살균 후 렌더해 저장형 XSS를 방지합니다.

## 로컬 미리보기
```bash
python3 -m http.server 8000
# http://localhost:8000 접속 (CONFIG 미설정 시 "설정이 필요합니다" 화면)
```
