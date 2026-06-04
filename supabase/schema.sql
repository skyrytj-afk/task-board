-- =============================================================================
-- Task Board — Supabase schema
-- Supabase 대시보드 > SQL Editor 에 전체를 붙여넣고 실행하세요.
-- 안전하게 여러 번 재실행할 수 있도록 작성되어 있습니다 (idempotent).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) profiles : 계정 + 승인/역할 (admin 승인 흐름의 핵심)
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  role        text not null default 'viewer' check (role in ('admin','editor','viewer')),
  approved    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- 가입 시 profiles 행 자동 생성 (approved=false, role=viewer 로 시작)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 현재 로그인 사용자가 승인되었는지 / 쓰기 권한이 있는지 (RLS 재귀 방지용 SECURITY DEFINER)
create or replace function public.is_approved()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.approved = true);
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.role = 'admin');
$$;

-- ---------------------------------------------------------------------------
-- 2) nodes : 자유 중첩 트리 (folder / page). OneNote식 섹션그룹>섹션>페이지를 표현.
-- ---------------------------------------------------------------------------
create table if not exists public.nodes (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  parent_id   uuid references public.nodes(id) on delete cascade,
  type        text not null check (type in ('folder','page')),
  title       text not null default '',
  content     text not null default '',          -- 페이지 본문(markdown)
  position    int  not null default 0,           -- 형제 정렬 순서
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists nodes_parent_idx on public.nodes(parent_id);
create index if not exists nodes_owner_idx  on public.nodes(owner_id);
-- 기존 테이블에 owner_id 가 없으면 추가(재실행 안전)
alter table public.nodes add column if not exists owner_id uuid default auth.uid() references auth.users(id) on delete cascade;

-- ---------------------------------------------------------------------------
-- 3) tasks : 구조화 태스크 (대시보드/검색 신뢰성 위해 markdown 파싱에 의존하지 않음)
-- ---------------------------------------------------------------------------
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  node_id     uuid not null references public.nodes(id) on delete cascade,
  text        text not null default '',
  priority    text check (priority in ('A','B','C')),
  due_date    date,
  done        boolean not null default false,
  done_at     timestamptz,                        -- 완료 시각(트리거로 자동 스탬프) → 30일 차트
  tags        text[] not null default '{}',
  position    int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists tasks_node_idx   on public.tasks(node_id);
create index if not exists tasks_owner_idx  on public.tasks(owner_id);
create index if not exists tasks_done_at_idx on public.tasks(done_at);
create index if not exists tasks_tags_idx    on public.tasks using gin(tags);
alter table public.tasks add column if not exists owner_id uuid default auth.uid() references auth.users(id) on delete cascade;

-- ---------------------------------------------------------------------------
-- 4) 공통 트리거: updated_at 자동 갱신 + done 전환 시 done_at 자동 스탬프
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists nodes_touch on public.nodes;
create trigger nodes_touch before update on public.nodes
  for each row execute function public.touch_updated_at();

create or replace function public.tasks_handle_done()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  if new.done = true and (old.done is distinct from true) then
    new.done_at = coalesce(new.done_at, now());     -- 완료로 전환되면 자동 스탬프
  elsif new.done = false then
    new.done_at = null;                              -- 미완료로 되돌리면 비움
  end if;
  return new;
end;
$$;

drop trigger if exists tasks_done_trg on public.tasks;
create trigger tasks_done_trg before update on public.tasks
  for each row execute function public.tasks_handle_done();

-- INSERT 시점에 done=true 로 들어오면 done_at 채우기
create or replace function public.tasks_handle_insert()
returns trigger language plpgsql as $$
begin
  if new.done = true then new.done_at = coalesce(new.done_at, now()); end if;
  return new;
end;
$$;
drop trigger if exists tasks_insert_trg on public.tasks;
create trigger tasks_insert_trg before insert on public.tasks
  for each row execute function public.tasks_handle_insert();

-- ---------------------------------------------------------------------------
-- 5) Row Level Security : 실제 접근 통제의 핵심. 모든 테이블에 정책 명시.
--    개인별 격리 모델: 승인된 사용자는 "자기 데이터만" 읽고 씁니다.
--    (owner_id = auth.uid() 인 행만 접근. 다른 사람 데이터는 보이지 않음.)
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.nodes    enable row level security;
alter table public.tasks    enable row level security;

-- profiles : 본인 행만(승인/역할 변경은 admin만). admin은 승인 관리를 위해 전체 조회/수정.
drop policy if exists profiles_self_select  on public.profiles;
drop policy if exists profiles_admin_select on public.profiles;
drop policy if exists profiles_admin_update on public.profiles;
drop policy if exists profiles_self_update  on public.profiles;
create policy profiles_self_select  on public.profiles for select using (id = auth.uid());
create policy profiles_admin_select on public.profiles for select using (public.is_admin());
create policy profiles_admin_update on public.profiles for update using (public.is_admin());

-- nodes : 승인된 본인 소유 행만 (owner_id = auth.uid())
drop policy if exists nodes_read   on public.nodes;
drop policy if exists nodes_write  on public.nodes;
drop policy if exists nodes_update on public.nodes;
drop policy if exists nodes_delete on public.nodes;
create policy nodes_read   on public.nodes for select using (owner_id = auth.uid() and public.is_approved());
create policy nodes_write  on public.nodes for insert with check (owner_id = auth.uid() and public.is_approved());
create policy nodes_update on public.nodes for update using (owner_id = auth.uid() and public.is_approved()) with check (owner_id = auth.uid());
create policy nodes_delete on public.nodes for delete using (owner_id = auth.uid() and public.is_approved());

-- tasks : 승인된 본인 소유 행만
drop policy if exists tasks_read   on public.tasks;
drop policy if exists tasks_write  on public.tasks;
drop policy if exists tasks_update on public.tasks;
drop policy if exists tasks_delete on public.tasks;
create policy tasks_read   on public.tasks for select using (owner_id = auth.uid() and public.is_approved());
create policy tasks_write  on public.tasks for insert with check (owner_id = auth.uid() and public.is_approved());
create policy tasks_update on public.tasks for update using (owner_id = auth.uid() and public.is_approved()) with check (owner_id = auth.uid());
create policy tasks_delete on public.tasks for delete using (owner_id = auth.uid() and public.is_approved());

-- ---------------------------------------------------------------------------
-- 6) 첫 admin 지정 (아래 이메일을 본인 가입 이메일로 바꾼 뒤 한 번 실행)
--    가입을 먼저 한 다음 실행하세요.
-- ---------------------------------------------------------------------------
-- update public.profiles
--   set approved = true, role = 'admin'
--   where email = 'skyrytj@gmail.com';

-- =============================================================================
-- 끝. service_role 키는 RLS를 우회합니다 — 절대 프론트엔드/repo에 넣지 마세요.
-- =============================================================================
