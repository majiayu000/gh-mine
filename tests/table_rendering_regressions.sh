# shellcheck shell=bash
table_display_widths() {
  jq -Rr '
    def display_width:
      explode
      | map(
          if (. >= 768 and . <= 879)
             or (. >= 6832 and . <= 6911)
             or (. >= 7616 and . <= 7679)
             or (. >= 8400 and . <= 8447)
             or (. >= 65024 and . <= 65039)
          then 0
          elif (. >= 4352 and . <= 4607)
             or (. >= 9001 and . <= 9002)
             or (. >= 11904 and . <= 42191)
             or (. >= 44032 and . <= 55203)
             or (. >= 63744 and . <= 64255)
             or (. >= 65040 and . <= 65055)
             or (. >= 65072 and . <= 65135)
             or (. >= 65280 and . <= 65376)
             or (. >= 65504 and . <= 65510)
             or (. >= 127744 and . <= 129791)
          then 2
          else 1
          end
        )
      | add // 0;
    rtrimstr("\r")
    | gsub("\u001b\\[[0-9;]*m"; "")
    | select(test("^[┌├└│]"))
    | display_width
  ' "$1"
}

test_table_fit_and_sort() {
  begin_case table_fit_and_sort
  make_rest "${CASE_DIR}/fixtures/rest-issue-1.json" 3 false 1 \
    zeta repository-with-a-very-long-name 300
  jq '.items[0].title = "中文 😀 café title that must truncate safely"
      | .items += [
        {
          repository_url:"https://api.github.com/repos/Alpha/short",
          number:2,title:"alpha",html_url:"u",state:"open",
          updated_at:"2024-01-01T00:00:00Z"
        },
        {
          repository_url:"https://api.github.com/repos/beta/middle",
          number:20,title:"beta",html_url:"u",state:"open",
          updated_at:"2024-01-01T00:00:00Z"
        }
      ]' "${CASE_DIR}/fixtures/rest-issue-1.json" >"${CASE_DIR}/rest.next"
  mv "${CASE_DIR}/rest.next" "${CASE_DIR}/fixtures/rest-issue-1.json"

  local columns widths
  for columns in 80 100 120; do
    run_tty_cli "${CASE_DIR}/table-${columns}.tty" "$columns" \
      --account me --issues || fail_test "table ${columns}" "command failed"
    widths="$(table_display_widths "${CASE_DIR}/table-${columns}.tty" |
      sort -u | paste -sd ',' -)"
    assert_eq "$columns" "$widths" \
      "all table rows fit ${columns} display columns"
  done
  assert_not_contains "${CASE_DIR}/table-80.tty" \
    "zeta/repository-with-a-very-long-name" \
    "narrow table truncates repository"

  status="$(run_cli --account me --issues)"
  assert_eq 0 "$status" "repository sort status"
  repos="$(awk -F '│' '/^│ Issue/ {
    value=$3; sub(/^ +/, "", value); sub(/ +$/, "", value); print value
  }' "${CASE_DIR}/stdout" | paste -sd ',' -)"
  assert_eq "Alpha/short,beta/middle,zeta/repository-with-a-very-long-name" \
    "$repos" "default table sorts by repository name"
  pass table_fit_and_sort
}
