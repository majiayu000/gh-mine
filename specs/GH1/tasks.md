# Task Plan

## Linked Issue

GH-1 — https://github.com/majiayu000/gh-mine/issues/1

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

### SP1-T1：建立统一 item collector 与 REST 完整性契约

- Owner：implementation worker
- Dependencies：none
- Writable files：`gh-mine`、`tests/run.sh`
- Covers：B-005、B-006、B-007、B-011、B-012
- Done-when：
  - issue/PR/moved-to-discussion 共用分页 helper 和统一 JSONL projection。
  - repo + scope 为交集；Search 值安全转义。
  - `incomplete_results`、API/jq 失败和服务端可访问上限均非零退出且不输出部分 stdout。
- Verify：
  - `bash tests/run.sh rest_pagination`
  - `bash tests/run.sh api_failures`
  - `bash tests/run.sh scope_combinations`
  - `bash tests/run.sh label_filters`
  - `bash tests/run.sh json_contract`

### SP1-T2：实现 Discussion 仓库批量首屏与 cursor follow-up

- Owner：implementation worker
- Dependencies：SP1-T1
- Writable files：`gh-mine`、`tests/run.sh`
- Covers：B-007、B-008、B-009、B-010、B-012、B-013
- Done-when：
  - 单次 GraphQL `first` 始终为 1..100，limit >100 与 stale 均正确翻页。
  - 查询并投影真实 closed/closedAt 和 labels。
  - outer repository connection 遍历全部目标仓库；首屏满足后不再请求该仓库。
  - 任何 GraphQL errors/命令失败中止整体结果。
- Verify：
  - `bash tests/run.sh discussion_pagination`
  - `bash tests/run.sh discussion_stale_scan`
  - `bash tests/run.sh discussion_state`
  - `bash tests/run.sh discussion_repo_enumeration`
  - `bash tests/run.sh label_filters`

### SP1-T3：实现 ccstats 风格 renderer 与兼容模式

- Owner：implementation worker
- Dependencies：SP1-T1、SP1-T2
- Writable files：`gh-mine`、`README.md`、`tests/run.sh`
- Covers：B-001、B-002、B-003、B-004、B-005、B-014
- Done-when：
  - 默认输出 Type、Repository、编号和更新时间四列 Unicode 表格。
  - 默认表格按短仓库名稳定排序；短名称完整显示，跨 owner 同名时用
    `repo_full_name` 消歧，超长名称续行且不使用省略号。
  - `--plain`、`--json` 和非法组合符合 product spec。
  - TTY/`NO_COLOR`、终端宽度、异常标题和空结果行为确定。
  - README 包含新默认输出、迁移方式和 JSON 新字段。
- Verify：
  - `bash tests/run.sh table_default`
  - `bash tests/run.sh table_width_and_repo_identity`
  - `bash tests/run.sh table_fit_and_sort`
  - `bash tests/run.sh color_modes`
  - `bash tests/run.sh renderer_modes`
  - `bash tests/run.sh table_unsafe_text`
  - `bash tests/run.sh json_contract`

### SP1-T4：加固 installer

- Owner：implementation worker
- Dependencies：none；与 SP1-T1/T2/T3 文件不重叠，可在独立 writable lane 执行
- Writable files：`install.sh`、`tests/run.sh`、`README.md`
- Covers：B-015、B-016
- Done-when：
  - 支持 `GH_MINE_VERSION` 与可选 `GH_MINE_SHA256`。
  - 下载、syntax/checksum 验证、chmod、atomic mv 顺序固定。
  - 下载或验证失败保留原目标并清理临时文件。
- Verify：
  - `bash tests/run.sh installer_atomicity`
  - `bash -n install.sh`
  - `shellcheck install.sh`

### SP1-T5：收紧 CI 与贡献文档

- Owner：implementation worker
- Dependencies：SP1-T1 至 SP1-T4
- Writable files：`.github/workflows/ci.yml`、`CONTRIBUTING.md`
- Covers：B-016、B-017
- Done-when：
  - Linux/macOS matrix 执行 syntax 与完整行为测试。
  - ShellCheck 为阻断 job，无 `|| true`。
  - CONTRIBUTING 列出本地完整验证命令。
- Verify：
  - `bash -n gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
  - `shellcheck gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
  - `bash tests/run.sh`
  - PR CI 全绿。

### SP1-T6：完整验证与实现对规格核对

- Owner：coordinator verification owner
- Dependencies：SP1-T1 至 SP1-T5
- Writable files：none（发现问题后返回原 implementation worker）
- Covers：B-001、B-002、B-003、B-004、B-005、B-006、B-007、B-008、B-009、B-010、B-011、B-012、B-013、B-014、B-015、B-016、B-017
- Done-when：
  - product invariant 集合与测试映射无遗漏。
  - 当前 head 上 syntax、ShellCheck、完整行为测试各执行一次且通过。
  - 独立 reviewer lane 对照 GH-1 和三个 spec 文件返回 clean/non_blocking。
  - PR gate、review threads、merge state、CI 均使用当前 head 证据。
- Verify：
  - `bash -n gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
  - `shellcheck gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
  - `bash tests/run.sh`
  - `git diff --check`

## 并行拆分

- SP1-T1、SP1-T2、SP1-T3 都修改 `gh-mine`/`tests/run.sh`，必须由同一
  implementation worker 串行完成，禁止多个 writable lane 共享文件。
- SP1-T4 的 `install.sh` 可与核心 collector 研究并行，但最终仍会触碰共享的
  `tests/run.sh`/`README.md`；实际写入在 coordinator 确认所有权后串行集成。
- SP1-T5 依赖测试入口稳定后再执行。
- Reviewer lane 全程只读；完整 suite 只由 coordinator verification owner 执行。

## 验证

- [ ] `bash -n gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
- [ ] `shellcheck gh-mine install.sh tests/run.sh tests/table_rendering_regressions.sh`
- [ ] `bash tests/run.sh`
- [ ] `git diff --check`
- [ ] Product IDs：
  `B-001..B-017`
- [ ] Task coverage union：
  `B-001..B-017`
- [ ] 当前 PR head 的 Linux/macOS CI、review threads、merge state、PR gate 已刷新。

## Handoff Notes

- `auth_mode: review`；该 packet 未自称 approved。实现前必须由用户在当前会话确认。
- `queue_mode: full_queue_drain`，当前只有 GH-1。
- `pr_tier: heavy`：独立 reviewer 认定该变更同时涉及 API 完整性、installer
  替换/校验和 CI enforcement，必须保留人工合并授权。
- 2026-07-26 用户随后纠正 B-002：默认表格必须严格适配终端显示宽度，允许
  Repository/Title 截断；完整仓库名由 `--plain`/`--json` 保留，不再允许横向溢出。
- 2026-07-26 用户再次纠正默认表格：State 与 Title 不需要展示；Repository
  必须优先显示完整短名称，禁止省略号，超长名称通过续行保留全部字符。
- 实现基线为本地 `6c07e76`，其中包含尚未推送到 `origin/main` 的 Discussion
  hygiene 功能；最终 PR 相对 `origin/main` 将同时包含该基线提交和 GH-1 实现，
  PR 描述必须明确这一点。
- 不修改主工作树 `/Users/apple/Desktop/code/AI/tool/gh-mine`；实现 worktree 为
  `/Users/apple/Desktop/code/AI/tool/gh-mine-gh1`。
