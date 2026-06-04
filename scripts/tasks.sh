#!/usr/bin/env bash
# ===========================================================================
# Claude Code 용 Task Board 헬퍼 (Supabase REST / PostgREST)
#
# 필요한 환경변수 (이 값들은 절대 repo에 커밋하지 마세요):
#   SUPABASE_URL          예) https://xxxx.supabase.co
#   SUPABASE_SERVICE_KEY  service_role 키 (RLS 우회, 서버측 전용)
#   TB_OWNER_ID           대상 사용자의 auth UID (개인별 격리용)
#       └ 조회: 이 사용자 데이터만 필터 / 추가: 이 사용자 소유로 생성
#       └ UID 확인: Supabase Authentication > Users, 또는
#         select id,email from auth.users;  (SQL Editor)
#
# 사용 예:
#   ./scripts/tasks.sh nodes                 # 폴더/페이지 트리 목록(JSON)
#   ./scripts/tasks.sh tasks                 # 전체 태스크(JSON)
#   ./scripts/tasks.sh open                  # 미완료 태스크만
#   ./scripts/tasks.sh page "<node_id>"      # 특정 페이지의 태스크
#   ./scripts/tasks.sh add "<node_id>" "(A) 보고서 작성 @2026-06-10 #업무"
#   ./scripts/tasks.sh done "<task_id>"      # 완료 처리(done_at 자동)
#   ./scripts/tasks.sh sql                   # 임의 조회는 jq 로 파이프해서 가공
# ===========================================================================
set -euo pipefail

: "${SUPABASE_URL:?SUPABASE_URL 환경변수를 설정하세요}"
: "${SUPABASE_SERVICE_KEY:?SUPABASE_SERVICE_KEY 환경변수를 설정하세요}"
REST="${SUPABASE_URL%/}/rest/v1"
H_KEY=(-H "apikey: ${SUPABASE_SERVICE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}")
JSON=(-H "Content-Type: application/json")

get(){ curl -sS "${H_KEY[@]}" "${REST}/$1"; }
# TB_OWNER_ID 가 있으면 본인 데이터만 필터(개인별 격리). service_role 은 RLS 우회라 직접 필터 필요.
OWN=""; [[ -n "${TB_OWNER_ID:-}" ]] && OWN="&owner_id=eq.${TB_OWNER_ID}"

cmd="${1:-help}"
case "$cmd" in
  nodes) get "nodes?select=id,parent_id,type,title,position&order=position${OWN}" ;;
  tasks) get "tasks?select=*&order=created_at${OWN}" ;;
  open)  get "tasks?done=eq.false&select=*&order=due_date${OWN}" ;;
  page)  get "tasks?node_id=eq.$2&select=*&order=position${OWN}" ;;
  add)
    : "${TB_OWNER_ID:?add 에는 TB_OWNER_ID(대상 사용자 UID)가 필요합니다}"
    node_id="$2"; raw="$3"
    # (A) / @YYYY-MM-DD / #tag 파싱
    prio=""; due=""; text="$raw"; tags="[]"
    if [[ "$text" =~ ^\(([ABC])\)\ * ]]; then prio="${BASH_REMATCH[1]}"; text="${text#*\) }"; fi
    if [[ "$text" =~ @([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then due="${BASH_REMATCH[1]}"; text="${text/@${due}/}"; fi
    # 태그 추출
    tag_arr=$(echo "$text" | grep -oE '#[^[:space:]#]+' | sed 's/#//' || true)
    if [[ -n "$tag_arr" ]]; then tags=$(echo "$tag_arr" | python3 -c 'import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'); fi
    text=$(echo "$text" | sed -E 's/#[^[:space:]#]+//g' | sed -E 's/^ +| +$//g')
    body=$(python3 -c 'import sys,json;n,t,p,d,g,o_=sys.argv[1:7];o={"node_id":n,"text":t,"owner_id":o_};
p=p or None; d=d or None
if p:o["priority"]=p
if d:o["due_date"]=d
o["tags"]=json.loads(g);print(json.dumps(o))' "$node_id" "$text" "$prio" "$due" "$tags" "$TB_OWNER_ID")
    curl -sS "${H_KEY[@]}" "${JSON[@]}" -X POST "${REST}/tasks" -d "$body"
    ;;
  done)  curl -sS "${H_KEY[@]}" "${JSON[@]}" -X PATCH "${REST}/tasks?id=eq.$2" -d '{"done":true}' ;;
  undone)curl -sS "${H_KEY[@]}" "${JSON[@]}" -X PATCH "${REST}/tasks?id=eq.$2" -d '{"done":false}' ;;
  *) sed -n '2,30p' "$0" ;;
esac
echo
