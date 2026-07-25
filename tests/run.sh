#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/gh-mine"
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-mine-tests.XXXXXX")"
trap 'rm -rf "$SUITE_TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
CASE_DIR=""

pass() {
  printf 'ok - %s\n' "$1"
  PASS=$((PASS + 1))
}

fail_test() {
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
  FAIL=$((FAIL + 1))
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] ||
    { printf 'expected: %s\nactual: %s\n' "$expected" "$actual" >&2
      fail_test "$message" "values differ"; }
}

assert_contains() {
  local file="$1" value="$2" message="$3"
  grep -F -- "$value" "$file" >/dev/null ||
    fail_test "$message" "missing '$value'"
}

assert_not_contains() {
  local file="$1" value="$2" message="$3"
  if grep -F -- "$value" "$file" >/dev/null; then
    fail_test "$message" "unexpected '$value'"
  fi
}

begin_case() {
  local name="$1"
  CASE_DIR="${SUITE_TMP}/${name}"
  mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/fixtures"
  : >"${CASE_DIR}/requests.log"
  cat >"${CASE_DIR}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_GH_DIR}/requests.log"
if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
  [[ ! -f "${FAKE_GH_DIR}/fixtures/fail-user" ]] || exit 1
  if [[ -f "${FAKE_GH_DIR}/fixtures/user.txt" ]]; then
    cat "${FAKE_GH_DIR}/fixtures/user.txt"
  else
    printf 'me\n'
  fi
  exit 0
fi
if [[ "$1" == "api" && "${2:-}" == search/issues* ]]; then
  path="$2"
  page="${path##*page=}"
  page="${page%%&*}"
  kind=issue
  [[ "$path" == *is%3Apr* ]] && kind=pr
  [[ "$path" == *is%3Aclosed* ]] && kind=moved
  fixture="${FAKE_GH_DIR}/fixtures/rest-${kind}-${page}.json"
  [[ -f "$fixture" ]] || exit 44
  cat "$fixture"
  exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
  all="$*"
  operation=unknown
  [[ "$all" == *OuterRepositories* ]] && operation=outer
  [[ "$all" == *RepositoryDiscussions* ]] && operation=repo
  [[ "$all" == *DiscussionLabels* ]] && operation=labels
  counter="${FAKE_GH_DIR}/${operation}.count"
  count=0
  [[ ! -f "$counter" ]] || count="$(cat "$counter")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter"
  fixture="${FAKE_GH_DIR}/fixtures/graphql-${operation}-${count}.json"
  [[ -f "$fixture" ]] || exit 45
  cat "$fixture"
  exit 0
fi
exit 46
FAKE
  cat >"${CASE_DIR}/bin/tput" <<'TPUT'
#!/usr/bin/env bash
[[ "${1:-}" == "cols" ]] || exit 1
printf '%s\n' "${FAKE_TPUT_COLS}"
TPUT
  chmod +x "${CASE_DIR}/bin/gh" "${CASE_DIR}/bin/tput"
}

run_cli() {
  local status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_GH_DIR="$CASE_DIR" \
    /bin/bash "$CLI" "$@" >"${CASE_DIR}/stdout" 2>"${CASE_DIR}/stderr" ||
    status=$?
  printf '%s' "$status"
}

run_tty_cli() {
  local output="$1" columns="$2"
  shift 2
  local command="" quoted argument
  command -v script >/dev/null 2>&1 || fail_test "pseudo TTY" "script missing"
  if script --version >/dev/null 2>&1; then
    for argument in env -u NO_COLOR "PATH=${CASE_DIR}/bin:${PATH}" \
      "FAKE_GH_DIR=${CASE_DIR}" "FAKE_TPUT_COLS=${columns}" \
      /bin/bash "$CLI" "$@"; do
      printf -v quoted '%q' "$argument"
      command="${command} ${quoted}"
    done
    script -q -c "$command" "$output" >/dev/null 2>&1
  else
    script -q "$output" env -u NO_COLOR PATH="${CASE_DIR}/bin:${PATH}" \
      FAKE_GH_DIR="$CASE_DIR" FAKE_TPUT_COLS="$columns" \
      /bin/bash "$CLI" "$@" >/dev/null 2>&1
  fi
}

make_rest() {
  local file="$1" total="$2" incomplete="$3" count="$4"
  local owner="${5:-acme}" repo_name="${6:-repo}" start="${7:-1}"
  jq -n \
    --argjson total "$total" --argjson incomplete "$incomplete" \
    --argjson count "$count" --argjson start "$start" \
    --arg owner "$owner" --arg repo "$repo_name" '
    {
      total_count: $total,
      incomplete_results: $incomplete,
      items: [range(0; $count) as $i | {
        repository_url:
          ("https://api.github.com/repos/" + $owner + "/" + $repo),
        number: ($start + $i),
        title: ("title " + (($start + $i) | tostring)),
        html_url:
          ("https://github.com/" + $owner + "/" + $repo + "/issues/" +
           (($start + $i) | tostring)),
        state: "open",
        updated_at: "2024-01-01T00:00:00Z",
        closed_at: null
      }]
    }
  ' >"$file"
}

empty_rest() {
  make_rest "$1" 0 false 0
}

discussion_node() {
  local number="$1" updated="$2" closed="$3" closed_at="$4"
  local labels_json="${5:-[]}" label_total="${6:-0}"
  local label_next="${7:-false}" label_cursor="${8:-null}"
  jq -n \
    --argjson number "$number" --arg updated "$updated" \
    --argjson closed "$closed" --argjson closed_at "$closed_at" \
    --argjson names "$labels_json" --argjson label_total "$label_total" \
    --argjson label_next "$label_next" --argjson label_cursor "$label_cursor" '
    {
      number: $number,
      title: ("discussion " + ($number | tostring)),
      url: ("https://github.com/acme/repo/discussions/" + ($number | tostring)),
      createdAt: "2023-01-01T00:00:00Z",
      updatedAt: $updated,
      closed: $closed,
      closedAt: $closed_at,
      category: {name: "General"},
      author: {login: "alice"},
      labels: {
        totalCount: $label_total,
        nodes: ($names | map({name:.})),
        pageInfo: {hasNextPage:$label_next, endCursor:$label_cursor}
      }
    }
  '
}

repo_response() {
  local file="$1" repo_full="$2" total="$3" nodes_json="$4"
  local has_next="$5" cursor="$6"
  jq -n --arg repo "$repo_full" --argjson total "$total" \
    --argjson nodes "$nodes_json" --argjson has_next "$has_next" \
    --argjson cursor "$cursor" '
    {data:{repository:{
      nameWithOwner:$repo,
      hasDiscussionsEnabled:true,
      discussions:{
        totalCount:$total,
        nodes:$nodes,
        pageInfo:{hasNextPage:$has_next,endCursor:$cursor}
      }
    }}}
  ' >"$file"
}

followup_response() {
  local file="$1" repo_full="$2" total="$3" nodes_json="$4"
  local has_next="$5" cursor="$6"
  repo_response "$file" "$repo_full" "$total" "$nodes_json" "$has_next" "$cursor"
}

outer_response() {
  local file="$1" total="$2" repos_json="$3" has_next="$4" cursor="$5"
  jq -n --argjson total "$total" --argjson repos "$repos_json" \
    --argjson has_next "$has_next" --argjson cursor "$cursor" '
    {data:{user:{repositories:{
      totalCount:$total,
      nodes:$repos,
      pageInfo:{hasNextPage:$has_next,endCursor:$cursor}
    }}}}
  ' >"$file"
}

test_rest_pagination() {
  begin_case rest_pagination
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 101 false 100 acme repo 1
  make_rest "${CASE_DIR}/fixtures/rest-issue-2.json" 101 false 1 acme repo 101
  status="$(run_cli --account me --issues --json)"
  assert_eq 0 "$status" "REST two-page status"
  assert_eq 101 "$(jq 'length' "${CASE_DIR}/stdout")" "REST two-page count"
  assert_contains "${CASE_DIR}/requests.log" "page=2" "REST requests second page"

  begin_case rest_incomplete
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 101 false 100
  make_rest "${CASE_DIR}/fixtures/rest-issue-2.json" 101 true 1
  status="$(run_cli --account me --issues --json)"
  assert_eq 1 "$status" "REST later incomplete fails"
  assert_eq "" "$(cat "${CASE_DIR}/stdout")" "REST failure emits no stdout"

  begin_case rest_premature
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 101 false 99
  status="$(run_cli --account me --issues --json)"
  assert_eq 1 "$status" "REST short page fails"

  begin_case rest_cap
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 1001 false 100
  status="$(run_cli --account me --issues --json)"
  assert_eq 1 "$status" "REST over 1000 fails"
  pass rest_pagination
}

test_api_failures() {
  begin_case later_collector_failure
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 1 false 1
  status="$(run_cli --account me --json)"
  assert_eq 1 "$status" "later PR collector failure status"
  assert_eq "" "$(cat "${CASE_DIR}/stdout")" "later failure has no partial output"

  begin_case graphql_errors
  printf '%s\n' '{"data":{"user":null},"errors":[{"message":"boom"}]}' \
    >"${CASE_DIR}/fixtures/graphql-outer-1.json"
  status="$(run_cli --account me --discussions --json)"
  assert_eq 1 "$status" "HTTP-200 GraphQL errors fail"
  assert_eq "" "$(cat "${CASE_DIR}/stdout")" "GraphQL error has no stdout"

  begin_case null_user
  printf '%s\n' '{"data":{"user":null}}' \
    >"${CASE_DIR}/fixtures/graphql-outer-1.json"
  status="$(run_cli --account me --discussions --json)"
  assert_eq 1 "$status" "null GraphQL user fails"

  begin_case malformed_rest
  printf '%s\n' '{}' >"${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues --json)"
  assert_eq 1 "$status" "malformed REST response fails"
  assert_eq "" "$(cat "${CASE_DIR}/stdout")" "malformed REST has no stdout"
  pass api_failures
}

test_scope_combinations() {
  begin_case authored_cross_repo
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --authored --issues --json)"
  assert_eq 0 "$status" "authored cross-repo status"
  assert_contains "${CASE_DIR}/requests.log" "author%3Ame" "authored qualifier"
  assert_not_contains "${CASE_DIR}/requests.log" "user%3Ame" \
    "authored excludes owner qualifier"

  begin_case assigned_moved_cross_repo
  empty_rest "${CASE_DIR}/fixtures/rest-moved-1.json"
  status="$(run_cli --account me --assigned --moved-to-discussion --json)"
  assert_eq 0 "$status" "assigned moved cross-repo status"
  assert_contains "${CASE_DIR}/requests.log" "assignee%3Ame" "assigned qualifier"
  assert_not_contains "${CASE_DIR}/requests.log" "user%3Ame" \
    "assigned moved excludes owner qualifier"

  begin_case default_owner_scope
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues --json)"
  assert_eq 0 "$status" "default owner status"
  assert_contains "${CASE_DIR}/requests.log" "user%3Ame" "default owner qualifier"

  begin_case default_moved_owner_scope
  empty_rest "${CASE_DIR}/fixtures/rest-moved-1.json"
  status="$(run_cli --account me --moved-to-discussion --json)"
  assert_eq 0 "$status" "default moved owner status"
  assert_contains "${CASE_DIR}/requests.log" "user%3Ame" \
    "default moved owner qualifier"

  begin_case repo_scope
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --repo acme/repo --authored --issues --json)"
  assert_eq 0 "$status" "repo+scope intersection status"
  assert_contains "${CASE_DIR}/requests.log" "repo%3Aacme%2Frepo" "repo qualifier"
  assert_contains "${CASE_DIR}/requests.log" "author%3Ame" "author qualifier"

  begin_case moved_repo_scope
  empty_rest "${CASE_DIR}/fixtures/rest-moved-1.json"
  status="$(run_cli --account me --repo acme/repo --assigned \
    --moved-to-discussion --json)"
  assert_eq 0 "$status" "moved repo+scope intersection status"
  assert_contains "${CASE_DIR}/requests.log" "repo%3Aacme%2Frepo" \
    "moved repo qualifier"
  assert_contains "${CASE_DIR}/requests.log" "assignee%3Ame" \
    "moved assignee qualifier"

  begin_case reject_discussion_scope
  status="$(run_cli --account me --repo acme/repo --authored --discussions)"
  assert_eq 2 "$status" "discussion scope rejected even with repo"
  assert_eq "" "$(cat "${CASE_DIR}/requests.log")" "rejection occurs before API"
  pass scope_combinations
}

selector_case() {
  local name="$1" expected="$2"
  shift 2
  begin_case "$name"
  case "$expected" in
    issue|pr|moved) empty_rest "${CASE_DIR}/fixtures/rest-${expected}-1.json" ;;
    discussion)
      repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 0 \
        '[]' false null ;;
    hygiene)
      empty_rest "${CASE_DIR}/fixtures/rest-moved-1.json"
      repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 0 \
        '[]' false null ;;
  esac
  status="$(run_cli --account me --repo acme/repo "$@" --json)"
  assert_eq 0 "$status" "last selector wins: $name"
  expected_requests=1; [[ "$expected" == "hygiene" ]] && expected_requests=2
  assert_eq "$expected_requests" "$(grep -c '^api ' "${CASE_DIR}/requests.log")" \
    "selector request count: $name"
}

test_selector_modes() {
  selector_case discussion_then_issue issue --discussions --issues
  selector_case issue_then_discussion discussion --issues --discussions
  selector_case moved_then_pr pr --moved-to-discussion --prs
  selector_case pr_then_moved moved --prs --moved-to-discussion
  selector_case discussion_then_moved moved --discussions --moved-to-discussion
  selector_case moved_then_discussion discussion --moved-to-discussion --discussions
  selector_case issue_then_hygiene hygiene --issues --hygiene
  selector_case hygiene_then_issue issue --hygiene --issues
  pass selector_modes
}

test_label_filters() {
  begin_case search_label_escape
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues --json --label 'say "hi"\path')"
  assert_eq 0 "$status" "quoted label status"
  assert_contains "${CASE_DIR}/requests.log" "label%3A%22say%20%5C%22hi%5C%22%5C%5Cpath%22" \
    "label is escaped as one quoted qualifier"

  begin_case discussion_label_cursor
  labels100="$(jq -nc '[range(0;100) | "label-\(.)"]')"
  node="$(discussion_node 7 "2024-01-01T00:00:00Z" false null \
    "$labels100" 101 true '"LC1"')"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 1 \
    "[$node]" false null
  jq -n '{data:{repository:{discussion:{labels:{
    totalCount:101,
    nodes:[{name:"wanted"}],
    pageInfo:{hasNextPage:false,endCursor:null}
  }}}}}' >"${CASE_DIR}/fixtures/graphql-labels-1.json"
  status="$(run_cli --account me --repo acme/repo --discussions --label wanted --json)"
  assert_eq 0 "$status" "label beyond first 100 status"
  assert_eq 1 "$(jq 'length' "${CASE_DIR}/stdout")" "label beyond first 100 matches"
  assert_eq 1 "$(cat "${CASE_DIR}/labels.count")" "label cursor requested"
  pass label_filters
}

test_json_contract() {
  begin_case json_contract
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 2 false 1 alpha same 1
  jq '.items += [{
    repository_url:"https://api.github.com/repos/beta/same",
    number:2,title:"other",html_url:"https://github.com/beta/same/issues/2",
    state:"open",updated_at:"2024-01-01T00:00:00Z",closed_at:null
  }]' "${CASE_DIR}/fixtures/rest-issue-1.json" \
    >"${CASE_DIR}/fixtures/rest-issue-1.next"
  mv "${CASE_DIR}/fixtures/rest-issue-1.next" \
    "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues --json)"
  assert_eq 0 "$status" "JSON contract status"
  assert_eq '["alpha/same","beta/same"]' \
    "$(jq -c '[.[].repo_full_name]' "${CASE_DIR}/stdout")" \
    "full repo identity retained"
  assert_eq '["same","same"]' "$(jq -c '[.[].repo]' "${CASE_DIR}/stdout")" \
    "legacy repo retained"
  assert_eq '["alpha","beta"]' "$(jq -c '[.[].owner]' "${CASE_DIR}/stdout")" \
    "owner added"

  begin_case moved_closed_at
  make_rest "${CASE_DIR}/fixtures/rest-moved-1.json" 1 false 1 acme repo 9
  jq '.items[0].state = "closed" |
      .items[0].closed_at = "2024-02-03T04:05:06Z"' \
    "${CASE_DIR}/fixtures/rest-moved-1.json" >"${CASE_DIR}/moved.next"
  mv "${CASE_DIR}/moved.next" "${CASE_DIR}/fixtures/rest-moved-1.json"
  status="$(run_cli --account me --moved-to-discussion --json)"
  assert_eq 0 "$status" "moved JSON status"
  assert_eq '"2024-02-03T04:05:06Z"' \
    "$(jq -c '.[0].closed_at' "${CASE_DIR}/stdout")" \
    "moved JSON preserves non-null closed_at"
  pass json_contract
}

test_discussion_pagination() {
  begin_case discussion_limit_1
  one_node="$(discussion_node 1 "2024-01-01T00:00:00Z" false null)"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 1 \
    "[$one_node]" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 1 --json)"
  assert_eq 0 "$status" "discussion limit 1 status"
  assert_eq 1 "$(jq 'length' "${CASE_DIR}/stdout")" "discussion limit 1 count"
  assert_contains "${CASE_DIR}/requests.log" "-F first=1" "GraphQL first lower bound"

  begin_case discussion_limit_100
  nodes_exact="$(jq -nc '[range(1;101) | {
    number:.,title:"d",url:"u",createdAt:"2023-01-01T00:00:00Z",
    updatedAt:"2024-01-01T00:00:00Z",closed:false,closedAt:null,
    category:null,author:null,
    labels:{totalCount:0,nodes:[],pageInfo:{hasNextPage:false,endCursor:null}}
  }]')"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 100 \
    "$nodes_exact" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 100 --json)"
  assert_eq 0 "$status" "discussion limit 100 status"
  assert_eq 100 "$(jq 'length' "${CASE_DIR}/stdout")" "discussion limit 100 count"
  assert_eq 1 "$(cat "${CASE_DIR}/repo.count")" "limit 100 needs one request"

  begin_case discussion_limit_101
  nodes100="$(jq -nc '[range(1;101) | {
    number:.,title:("d"+tostring),url:"u",createdAt:"2023-01-01T00:00:00Z",
    updatedAt:"2024-01-01T00:00:00Z",closed:false,closedAt:null,
    category:null,author:null,
    labels:{totalCount:0,nodes:[],pageInfo:{hasNextPage:false,endCursor:null}}
  }]')"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 101 \
    "$nodes100" true '"D100"'
  node101="$(discussion_node 101 "2024-01-01T00:00:00Z" false null)"
  followup_response "${CASE_DIR}/fixtures/graphql-repo-2.json" acme/repo 101 \
    "[$node101]" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 101 --json)"
  assert_eq 0 "$status" "discussion limit 101 status"
  assert_eq 101 "$(jq 'length' "${CASE_DIR}/stdout")" "discussion cursor count"
  assert_contains "${CASE_DIR}/requests.log" "-F first=100" "GraphQL first capped 100"
  assert_contains "${CASE_DIR}/requests.log" "-F first=1" "GraphQL remainder first 1"
  pass discussion_pagination
}

test_discussion_stale_scan() {
  begin_case stale_scan
  recent1="$(discussion_node 1 "2099-01-02T00:00:00Z" false null)"
  cutoff="$(date -v-1d +%Y-%m-%d 2>/dev/null ||
    date -d '1 day ago' +%Y-%m-%d)"
  recent2="$(discussion_node 2 "${cutoff}T00:00:00Z" false null)"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 4 \
    "[$recent1,$recent2]" true '"D2"'
  old1="$(discussion_node 3 "2000-01-02T00:00:00Z" false null)"
  old2="$(discussion_node 4 "2000-01-01T00:00:00Z" false null)"
  followup_response "${CASE_DIR}/fixtures/graphql-repo-2.json" acme/repo 4 \
    "[$old1,$old2]" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 2 --stale 1 --json)"
  assert_eq 0 "$status" "stale scan status"
  assert_eq '[3,4]' "$(jq -c '[.[].number]' "${CASE_DIR}/stdout")" \
    "stale scans beyond recent page"
  pass discussion_stale_scan
}

test_discussion_state() {
  begin_case discussion_state
  open_node="$(discussion_node 1 "2024-01-01T00:00:00Z" false null)"
  closed_node="$(discussion_node 2 "2024-01-01T00:00:00Z" true \
    '"2024-02-01T00:00:00Z"')"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 2 \
    "[$open_node,$closed_node]" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 2 --json)"
  assert_eq 0 "$status" "discussion state status"
  assert_eq '[["open",null],["closed","2024-02-01T00:00:00Z"]]' \
    "$(jq -c '[.[] | [.state,.closed_at]]' "${CASE_DIR}/stdout")" \
    "real discussion state and closed_at"

  begin_case canonical_repo_casing
  canonical_node="$(discussion_node 3 "2024-01-01T00:00:00Z" false null)"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" Acme/Repo 1 \
    "[$canonical_node]" false null
  status="$(run_cli --account me --repo acme/repo --discussions --json)"
  assert_eq 0 "$status" "canonical repo casing status"
  assert_eq '"Acme/Repo"' "$(jq -c '.[0].repo_full_name' "${CASE_DIR}/stdout")" \
    "explicit repo uses canonical API casing"
  pass discussion_state
}

test_discussion_repo_enumeration() {
  begin_case repo_enumeration
  a_node="$(discussion_node 1 "2024-01-01T00:00:00Z" false null)"
  b_node="$(discussion_node 2 "2024-01-01T00:00:00Z" false null)"
  repos1="$(jq -nc --argjson a "$a_node" --argjson b "$b_node" '[
    {nameWithOwner:"one/same",isFork:false,hasDiscussionsEnabled:true,
     discussions:{totalCount:1,nodes:[$a],
       pageInfo:{hasNextPage:false,endCursor:null}}},
    {nameWithOwner:"two/same",isFork:false,hasDiscussionsEnabled:true,
     discussions:{totalCount:2,nodes:[$b],
       pageInfo:{hasNextPage:true,endCursor:"B1"}}}
  ]')"
  outer_response "${CASE_DIR}/fixtures/graphql-outer-1.json" 3 "$repos1" \
    true '"R1"'
  repos2='[{"nameWithOwner":"me/no-discussions","isFork":false,
    "hasDiscussionsEnabled":false,"discussions":null}]'
  outer_response "${CASE_DIR}/fixtures/graphql-outer-2.json" 3 "$repos2" \
    false null
  b2="$(discussion_node 3 "2023-01-01T00:00:00Z" false null)"
  followup_response "${CASE_DIR}/fixtures/graphql-repo-1.json" two/same 2 \
    "[$b2]" false null
  status="$(run_cli --account me --discussions --discussion-limit 2 --json)"
  assert_eq 0 "$status" "outer repo enumeration status"
  assert_eq '["one/same","two/same","two/same"]' \
    "$(jq -c '[.[].repo_full_name]' "${CASE_DIR}/stdout")" \
    "outer pages and same-name repos"
  assert_eq 2 "$(cat "${CASE_DIR}/outer.count")" "outer repository cursor used"
  assert_contains "${CASE_DIR}/requests.log" "-F repoFirst=20" \
    "outer repository page is node-budget safe"
  assert_eq 1 "$(cat "${CASE_DIR}/repo.count")" "selective repo follow-up"
  assert_contains "${CASE_DIR}/requests.log" "-f owner=two" "follow-up only needy repo"
  pass discussion_repo_enumeration
}

test_table_default() {
  begin_case table_default
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 1 false 1 acme repo 42
  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "default table status"
  assert_contains "${CASE_DIR}/stdout" "┌" "Unicode top border"
  assert_contains "${CASE_DIR}/stdout" "Type" "fixed Type column"
  assert_contains "${CASE_DIR}/stdout" "Repository" "fixed Repository column"
  assert_contains "${CASE_DIR}/stdout" "acme/repo" "full repository shown"
  assert_contains "${CASE_DIR}/stdout" "Total: 1 (Issue 1)" "kind summary"
  pass table_default
}

test_table_width_and_repo_identity() {
  begin_case table_identity
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 2 false 1 one same 7
  jq '.items += [{
    repository_url:"https://api.github.com/repos/two/same",number:123,
    title:"Unicode 标题 😀 abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz",
    html_url:"u",state:"open",updated_at:"2024-01-01T00:00:00Z"
  }]' "${CASE_DIR}/fixtures/rest-issue-1.json" >"${CASE_DIR}/rest.next"
  mv "${CASE_DIR}/rest.next" "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "table identity status"
  assert_contains "${CASE_DIR}/stdout" "one/same" "first owner displayed"
  assert_contains "${CASE_DIR}/stdout" "two/same" "second owner displayed"
  iconv -f UTF-8 -t UTF-8 "${CASE_DIR}/stdout" >"${CASE_DIR}/iconv.out" ||
    fail_test "table UTF-8" "invalid UTF-8 after truncation"

  run_tty_cli "${CASE_DIR}/normal.tty" 100 --account me --issues ||
    fail_test "normal-width pseudo TTY" "command failed"
  normal_length="$(jq -Rr '
    rtrimstr("\r") | select(index("┌") != null) |
    index("┌") as $start | .[$start:] | length
  ' "${CASE_DIR}/normal.tty" | sed -n '1p')"
  assert_eq 100 "$normal_length" "normal border matches tput columns"

  pass table_width_and_repo_identity
}

test_color_modes() {
  begin_case color_modes
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "non-TTY table status"
  if LC_ALL=C grep "$(printf '\033')" "${CASE_DIR}/stdout" >/dev/null; then
    fail_test "non-TTY color" "ANSI present"
  fi
  status="$(PATH="${CASE_DIR}/bin:${PATH}" FAKE_GH_DIR="$CASE_DIR" NO_COLOR=1 \
    /bin/bash "$CLI" --account me --issues >"${CASE_DIR}/nocolor" 2>/dev/null
    printf '%s' "$?")"
  assert_eq 0 "$status" "NO_COLOR status"
  if LC_ALL=C grep "$(printf '\033')" "${CASE_DIR}/nocolor" >/dev/null; then
    fail_test "NO_COLOR" "ANSI present"
  fi
  tty_file="${CASE_DIR}/tty.out"
  run_tty_cli "$tty_file" 120 --account me --issues ||
    fail_test "color pseudo TTY" "command failed"
  LC_ALL=C grep -F "$(printf '\033[1;36m')" "$tty_file" >/dev/null ||
    fail_test "TTY color" "cyan/bold header missing"
  pass color_modes
}

test_renderer_modes() {
  begin_case renderer_modes
  empty_rest "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "empty table status"
  assert_contains "${CASE_DIR}/stdout" "Total: 0" "empty table is explicit"
  status="$(run_cli --account me --issues --json)"
  assert_eq 0 "$status" "empty JSON status"
  assert_eq "[]" "$(jq -c . "${CASE_DIR}/stdout")" "empty JSON array"
  status="$(run_cli --account me --issues --plain)"
  assert_eq 0 "$status" "empty plain status"
  assert_contains "${CASE_DIR}/stdout" "0 items" "empty plain explicit"
  status="$(run_cli --account me --plain --json)"
  assert_eq 2 "$status" "plain+json rejected"

  begin_case discussion_plain
  general="$(discussion_node 1 "2024-01-01T00:00:00Z" false null)"
  uncategorized="$(discussion_node 2 "2024-01-01T00:00:00Z" false null |
    jq '.category = null')"
  repo_response "${CASE_DIR}/fixtures/graphql-repo-1.json" acme/repo 2 \
    "[$general,$uncategorized]" false null
  status="$(run_cli --account me --repo acme/repo --discussions \
    --discussion-limit 2 --plain)"
  assert_eq 0 "$status" "non-empty Discussion plain status"
  assert_contains "${CASE_DIR}/stdout" "#1 [General] discussion 1" \
    "Discussion plain includes category"
  assert_contains "${CASE_DIR}/stdout" "#2 [-] discussion 2" \
    "Discussion plain uses missing-category fallback"
  pass renderer_modes
}

test_table_unsafe_text() {
  begin_case unsafe_text
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 1 false 1
  jq '.items[0].title = "one\ntwo\rthree\tfour"' \
    "${CASE_DIR}/fixtures/rest-issue-1.json" >"${CASE_DIR}/unsafe.next"
  mv "${CASE_DIR}/unsafe.next" "${CASE_DIR}/fixtures/rest-issue-1.json"
  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "unsafe title status"
  assert_contains "${CASE_DIR}/stdout" "one two three four" \
    "control whitespace sanitized"
  assert_eq 1 "$(grep -c 'one two three four' "${CASE_DIR}/stdout")" \
    "unsafe title remains one row"
  pass table_unsafe_text
}

test_installer_atomicity() {
  begin_case installer
  install_dir="${CASE_DIR}/install path"
  mkdir -p "$install_dir"
  printf '%s\n' '#!/usr/bin/env bash' 'echo old' >"${install_dir}/gh-mine"
  cp "${install_dir}/gh-mine" "${CASE_DIR}/old"
  cat >"${CASE_DIR}/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FAKE_CURL_FAIL:-}" ]] || exit 22
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "${FAKE_DOWNLOAD}" "$out"
CURL
  chmod +x "${CASE_DIR}/bin/curl"
  printf '%s\n' '#!/usr/bin/env bash' 'echo new' >"${CASE_DIR}/download"
  digest="$(shasum -a 256 "${CASE_DIR}/download" | awk '{print $1}')"
  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    GH_MINE_INSTALL_DIR="$install_dir" GH_MINE_VERSION=v1 \
    GH_MINE_SHA256="$digest" bash "${ROOT}/install.sh" \
    >"${CASE_DIR}/install.out" 2>"${CASE_DIR}/install.err" || status=$?
  assert_eq 0 "$status" "installer success in path with spaces"
  cmp "${CASE_DIR}/download" "${install_dir}/gh-mine" ||
    fail_test "installer success" "target mismatch"
  installed_mode="$(stat -c '%a' "${install_dir}/gh-mine" 2>/dev/null ||
    stat -f '%Lp' "${install_dir}/gh-mine")"
  assert_eq 755 "$installed_mode" "installer sets shared executable mode"

  cp "${CASE_DIR}/old" "${install_dir}/gh-mine"
  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    GH_MINE_INSTALL_DIR="$install_dir" \
    GH_MINE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    bash "${ROOT}/install.sh" >/dev/null 2>"${CASE_DIR}/checksum.err" || status=$?
  [[ "$status" -ne 0 ]] || fail_test "installer checksum" "expected failure"
  cmp "${CASE_DIR}/old" "${install_dir}/gh-mine" ||
    fail_test "installer checksum" "old target overwritten"

  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    FAKE_CURL_FAIL=1 GH_MINE_INSTALL_DIR="$install_dir" \
    bash "${ROOT}/install.sh" >/dev/null 2>"${CASE_DIR}/download.err" || status=$?
  [[ "$status" -ne 0 ]] || fail_test "installer download" "expected failure"
  cmp "${CASE_DIR}/old" "${install_dir}/gh-mine" ||
    fail_test "installer download" "old target overwritten"

  printf '%s\n' '#!/usr/bin/env bash' 'if then' >"${CASE_DIR}/download"
  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    GH_MINE_INSTALL_DIR="$install_dir" bash "${ROOT}/install.sh" \
    >/dev/null 2>"${CASE_DIR}/syntax.err" || status=$?
  [[ "$status" -ne 0 ]] || fail_test "installer syntax" "expected failure"
  cmp "${CASE_DIR}/old" "${install_dir}/gh-mine" ||
    fail_test "installer syntax" "old target overwritten"

  printf '%s\n' '#!/usr/bin/env bash' 'echo valid' >"${CASE_DIR}/download"
  cat >"${CASE_DIR}/bin/mv" <<'MV'
#!/usr/bin/env bash
exit 1
MV
  /bin/chmod +x "${CASE_DIR}/bin/mv"
  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    GH_MINE_INSTALL_DIR="$install_dir" bash "${ROOT}/install.sh" \
    >/dev/null 2>"${CASE_DIR}/mv.err" || status=$?
  [[ "$status" -ne 0 ]] || fail_test "installer mv" "expected failure"
  cmp "${CASE_DIR}/old" "${install_dir}/gh-mine" ||
    fail_test "installer mv" "old target overwritten"
  rm -f "${CASE_DIR}/bin/mv"

  cat >"${CASE_DIR}/bin/chmod" <<'CHMOD'
#!/usr/bin/env bash
exit 1
CHMOD
  /bin/chmod +x "${CASE_DIR}/bin/chmod"
  status=0
  PATH="${CASE_DIR}/bin:${PATH}" FAKE_DOWNLOAD="${CASE_DIR}/download" \
    GH_MINE_INSTALL_DIR="$install_dir" bash "${ROOT}/install.sh" \
    >/dev/null 2>"${CASE_DIR}/chmod.err" || status=$?
  [[ "$status" -ne 0 ]] || fail_test "installer chmod" "expected failure"
  cmp "${CASE_DIR}/old" "${install_dir}/gh-mine" ||
    fail_test "installer chmod" "old target overwritten"
  rm -f "${CASE_DIR}/bin/chmod"

  if find "$install_dir" -name '.gh-mine.tmp.*' | grep . >/dev/null; then
    fail_test "installer cleanup" "temporary files remain"
  fi
  pass installer_atomicity
}

should_run() {
  local name="$1"
  shift
  (( $# == 0 )) && return 0
  local selected
  for selected in "$@"; do
    [[ "$selected" == "$name" ]] && return 0
  done
  return 1
}

# shellcheck source=tests/table_rendering_regressions.sh
. "${ROOT}/tests/table_rendering_regressions.sh"
tests=(
  rest_pagination api_failures scope_combinations selector_modes label_filters json_contract
  discussion_pagination discussion_stale_scan discussion_state
  discussion_repo_enumeration table_default table_width_and_repo_identity
  table_fit_and_sort color_modes renderer_modes table_unsafe_text installer_atomicity
)

for test_name in "${tests[@]}"; do
  if should_run "$test_name" "$@"; then
    "test_${test_name}" || true
  fi
done

if (( FAIL > 0 )); then
  printf '%s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf '%s passed\n' "$PASS"
