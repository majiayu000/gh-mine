# Tech Spec

## Linked Issue

GH-1 — https://github.com/majiayu000/gh-mine/issues/1

<!-- specrail-requires-planned-changes-v1 -->
<!-- specrail-planned-changes
{"version":1,"issue":1,"complete":true,"paths":["gh-mine","install.sh","README.md","CONTRIBUTING.md",".github/workflows/ci.yml","tests/run.sh","specs/GH1/product.md","specs/GH1/tech.md","specs/GH1/tasks.md"],"spec_refs":["specs/GH1/product.md","specs/GH1/tech.md","specs/GH1/tasks.md"]}
-->

## Product Spec

见 `product.md`。

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 参数与模式 | `gh-mine:55` | mode 由多个布尔值累积；只有 `--json`，没有 `--plain`；`--repo` 与 scope 组合未统一校验 | B-003、B-004、B-011 |
| REST query | `gh-mine:123`、`gh-mine:145` | `--repo` 分支替代而不是叠加 author/assignee；label 拼入 query | B-011、B-012 |
| 仓库枚举 | `gh-mine:167` | `gh repo list --limit 200` 固定截断；调用失败位于进程替换时可能不传播 | B-007、B-013 |
| Discussion GraphQL | `gh-mine:193` | 单次把用户 limit 传给 `first`，无 cursor；先取最近 N 条再 stale 过滤；未查询 closed/labels | B-008 至 B-010、B-012、B-013 |
| REST 收集/输出 | `gh-mine:262`、`gh-mine:295` | 两条路径各取 Search 第一页；JSON 和文本重复投影；repo 只取短名 | B-005、B-006、B-010 |
| 最终渲染 | `gh-mine:326` | collector 与 renderer 耦合，按 kind 打印多个分组，没有统一表格模型 | B-001 至 B-004、B-014 |
| 安装 | `install.sh:5`、`install.sh:14` | 从 main 直接下载并原地覆盖目标，未做语法/checksum 验证 | B-015 |
| CI | `.github/workflows/ci.yml:13` | 仅 Ubuntu；ShellCheck 使用 `|| true`；无行为测试 | B-016、B-017 |
| 文档 | `README.md:45`、`CONTRIBUTING.md:18` | 文档描述旧分组输出和仅 syntax/ShellCheck 流程 | 所有用户可见变更与验证命令需同步 |

## 设计方案

### 1. 统一 item 数据管线

`gh-mine` 先把所有选中 kind 收集为一个 JSONL 临时流，成功收集后才选择 renderer：

1. 参数解析与组合校验。
2. `collect_search_items` 收集 issue/PR/moved-to-discussion。
3. `collect_discussion_items` 收集 Discussion。
4. 对每条记录投影同一核心契约：
   `scope`、`kind`、`owner`、`repo`、`repo_full_name`、`number`、`title`、
   `url`、`state`、`updated_at`，以及 kind 专属可空字段。
5. 全部 collector 成功后，`render_table`、`render_plain` 或 `render_json`
   只消费统一 JSONL；任一 collector 失败时不输出部分 stdout。

全局 trap 清理结果文件和 Discussion 工作目录。API 响应先写入局部变量并通过
`jq -e` 校验结构，再追加到结果流，禁止 warning + fallback。

### 2. REST Search 分页

新增单一 `collect_search_pages(query, kind, out)`：

- query 用 `jq @uri` 编码，page 从 1 开始，每页固定 `per_page=100`。
- 每页要求 HTTP/`gh` 成功、JSON 结构合法且 `incomplete_results == false`。
- 记录第一页 `total_count`，逐页追加 `.items[]`；空页或无 next page 前，
  收集数必须达到 `total_count`。
- GitHub Search 只允许访问前 1000 条；当 `total_count > 1000` 或服务端在
  collected < total 时终止，返回明确非零错误，要求 `--repo`/`--label`/
  `--stale` 缩小范围。
- issue、PR、moved-to-discussion 共用同一投影函数，避免分页策略漂移。

### 3. Discussion 分页与仓库批量首屏

账号级路径使用 GraphQL `user(login).repositories` connection 分页获取全部
owned、non-fork 且启用 Discussions 的仓库，并在同一 outer query 中读取每个
仓库的首屏 Discussion；显式 `--repo` 直接读取目标 repository。

- 单次 `first` 取 `min(remaining_or_scan_page, 100)`，始终在 1..100。
- node 查询 `closed`、`closedAt`、`labels(first:100)` 和既有字段。
- 无 `--stale` 时累计到每仓库 N 条即停止。
- 有 `--stale` 时按 `UPDATED_AT DESC` 翻页，跳过未到 cutoff 的节点；累计 N 条
  matching 节点或 connection exhausted 后停止。
- 首屏已满足 limit 的仓库不再发后续请求；只有 `hasNextPage` 且仍需数据的仓库
  使用 repository-specific cursor 继续，从而减少默认 N+1。
- 所有 label 在 jq 中作为数组比较，要求 requested labels 是 node labels 的
  子集，避免 query string 注入。
- outer 仓库枚举失败、任一必要后续页失败或 GraphQL `.errors` 非空均使整体失败。

### 4. 参数契约

- `--plain` 新增 `plain_mode=1`；与 `--json` 冲突时退出 2。
- issue/PR/moved query 在 `--repo` 存在时仍追加选定的 `author:` 或
  `assignee:` qualifier，形成交集。
- 只要 `want_discussions=1` 且 scope 非空就拒绝，是否有 `--repo` 不改变判定。
- `--label` 对 Discussion 使用本地集合 AND 过滤，对 Search 使用安全转义后的
  qualifier；测试包含引号和空格标签。

### 5. ccstats 风格表格

不新增 `column`/Python/Rust 依赖，使用 Bash `printf` 和 `jq`：

- 先把 title 中 `\r`/`\n`/`\t` 规范化为空格。
- 终端宽度：TTY 时优先 `tput cols`，失败或非 TTY 时使用 120；固定列先按数据
  上限分配，Title 获得剩余宽度且不低于 20。
- jq 负责按 Unicode code point 截断，避免拆分 UTF-8 byte；Bash 只对已截断
  文本做 padding。East Asian 宽字符的视觉宽度差异作为已知限制，测试保证不会
  产生非法 UTF-8 或破坏行数。
- 使用 `┌─┬┐`、`├─┼┤`、`└─┴┘` 边框；表头仅在允许 color 时包裹
  bold/cyan ANSI，padding 在加 ANSI 前完成。
- `Type` 映射为短显示值 `Issue`、`PR`、`Discussion`、`Moved`；机器 `kind`
  不变。末尾打印按 kind 的计数摘要。
- `render_plain` 复用统一 JSONL，按 `repo_full_name` 分组，因此旧视觉样式保留
  但不再合并同名仓库。

### 6. 安装与 CI

- `install.sh` 接受 `GH_MINE_VERSION`（默认 `main`）和可选
  `GH_MINE_SHA256`；在 `INSTALL_DIR` 内 `mktemp`，trap 清理。
- `curl` 写临时文件，随后 `bash -n`；提供 checksum 时使用可用的
  `sha256sum` 或 `shasum -a 256` 验证，缺少验证工具时明确失败。
- `chmod +x` 后用同一文件系统内的 `mv` 原子替换 `TARGET`。
- `tests/run.sh` 使用临时 PATH 注入 fake `gh`，所有 fixture 本地生成；每个
  case 独立临时目录并在退出时清理。
- CI 拆为阻断 lint job（Ubuntu syntax + ShellCheck）和
  `ubuntu-latest`/`macos-latest` behavior-test matrix；不并行修改共享状态。

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `gh-mine` unified pipeline + `render_table` | `bash tests/run.sh table_default` |
| B-002 | table width/padding + full repo identity | `bash tests/run.sh table_width_and_repo_identity` |
| B-003 | color capability detection | `bash tests/run.sh color_modes` |
| B-004 | renderer selection + empty result | `bash tests/run.sh renderer_modes` |
| B-005 | common JSON projection | `bash tests/run.sh json_contract` |
| B-006 | `collect_search_pages` | `bash tests/run.sh rest_pagination` |
| B-007 | collector error propagation + cleanup | `bash tests/run.sh api_failures` |
| B-008 | Discussion page sizing/cursor | `bash tests/run.sh discussion_pagination` |
| B-009 | stale Discussion scan | `bash tests/run.sh discussion_stale_scan` |
| B-010 | Discussion state projection | `bash tests/run.sh discussion_state` |
| B-011 | query construction + validation | `bash tests/run.sh scope_combinations` |
| B-012 | Search escaping + Discussion label set | `bash tests/run.sh label_filters` |
| B-013 | repository outer pagination + selective follow-up | `bash tests/run.sh discussion_repo_enumeration` |
| B-014 | table cell normalization | `bash tests/run.sh table_unsafe_text` |
| B-015 | `install.sh` staged replacement | `bash tests/run.sh installer_atomicity` |
| B-016 | `tests/run.sh` scenario inventory | `bash tests/run.sh` |
| B-017 | `.github/workflows/ci.yml` | `bash -n gh-mine install.sh tests/run.sh && shellcheck gh-mine install.sh tests/run.sh`；PR CI matrix 通过 |

## 数据流

```text
CLI args
  -> validated query/filter state
  -> REST Search pages + GraphQL repository/discussion pages
  -> validated common JSONL item stream
  -> table | plain | JSON renderer
  -> stdout only after complete collection
```

不新增持久化。临时文件只存在于单次进程生命周期，退出时清理。GitHub 调用均为
read-only。installer 的唯一持久写入是最终经验证的目标 binary。

## 备选方案

- **改写为 Rust 并复用 `comfy_table`**：视觉效果最好，但违反项目保持单 Bash
  脚本和无新运行时依赖的目标，本次不采用。
- **依赖系统 `column`**：实现更短，但 macOS/BSD 与 util-linux 行为、Unicode
  宽度和边框能力不同，本次不新增该依赖。
- **保留每个 collector 即时打印**：修改量较小，但无法保证失败时不产生部分
  stdout，也会继续复制 JSON/文本投影，不采用。
- **Discussion 永远逐仓库调用**：实现简单但默认 N+1 明显；采用批量首屏 +
  selective follow-up。

## 风险

- Security：标签和账号属于用户输入；Search 值必须转义、GraphQL 必须使用变量，
  禁止把输入拼成 shell。installer checksum 只能在用户提供可信 digest 时提供
  完整性保证。
- Compatibility：默认文本视觉变化较大，以 `--plain` 提供迁移路径；JSON 只
  增字段，不删改旧字段。
- Performance：账号拥有大量仓库或 stale cutoff 很老时仍需多页 GraphQL；批量
  首屏与按需 follow-up 限制请求数，测试断言不会对已满足仓库继续请求。
- Maintenance：`gh-mine` 可能接近文件大小上限；collector/renderer 用清晰函数
  边界组织，若实现超过 800 行则在不引入运行时依赖的前提下重新评估拆分。
- Portability：macOS Bash 3.2 不支持关联数组、`wait -n` 等新语法；实现只使用
  当前脚本已采用的可移植 Bash 特性，并由 macOS CI 验证。

## 测试计划

- [ ] Syntax：`bash -n gh-mine install.sh tests/run.sh`
- [ ] Static lint：`shellcheck gh-mine install.sh tests/run.sh`
- [ ] Integration：`bash tests/run.sh`
- [ ] Contract：`bash tests/run.sh json_contract`
- [ ] Failure paths：`bash tests/run.sh api_failures installer_atomicity`
- [ ] Manual：在真实 TTY 运行 `./gh-mine --repo majiayu000/gh-mine`，只观察
  表格布局；该项不替代自动化测试。

## 回滚方案

- 在 PR 合并前可直接丢弃 feature branch；`main` 不受影响。
- 合并后若表格有终端兼容问题，可先把默认 renderer 切回 plain，同时保留统一
  collector、分页和 JSON 修复，不回滚数据正确性。
- installer 可单独回退到上一版本，但不得恢复原地下载覆盖；原子替换是安全底线。
- 无 schema、数据库或持久数据迁移，因此代码回退不需要数据回滚。
