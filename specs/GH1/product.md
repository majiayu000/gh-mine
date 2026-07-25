# Product Spec

## Linked Issue

GH-1 — https://github.com/majiayu000/gh-mine/issues/1

complexity: medium

## 用户问题

`gh-mine` 当前按 scope 和类型输出多段缩进文本；当 issue、PR 和 Discussion
数量增加时，用户难以横向比较仓库、编号、状态、更新时间和标题。与此同时，
REST/GraphQL 分页、Discussion 状态、仓库身份和失败传播存在静默漏数或错误
成功的路径，使人类输出和 `--json` 都可能给出不完整或不准确的数据。

## 目标

- 默认提供类似 `ccstats` 的紧凑 Unicode 终端表格。
- 确保所有成功输出均来自完整、可验证的 API 结果，不把失败或截断伪装成空结果。
- 统一 issue、PR、Discussion 和 moved-to-discussion 的仓库身份、过滤和状态语义。
- 保持 Bash 单文件 CLI 的轻量定位，并保留机器可读和旧版分组输出。
- 用确定性测试与 Linux/macOS CI 固化行为。

## 非目标

- 不实现 Excel、网页、GUI 或交互式 TUI。
- 不增加 Bash、`gh`、`jq`、`curl` 之外的新运行时依赖。
- 不新增 GitHub 写操作；该 CLI 继续只读取 GitHub 数据。
- 不保证 API 搜索超过 GitHub 服务端可访问上限时仍能返回完整数据；此时必须明确失败。
- 不改变 `--account` 的认证身份；它仍只改变查询目标。

## Behavior Invariants

1. **B-001** 默认人类输出必须用一个 Unicode 边框表格展示所有匹配项，每个
   item 恰好一行，列顺序固定为 `Type`、`Repository`、`#`、`State`、
   `Updated`、`Title`；同一次运行的不同 kind 不再拆成互相分离的缩进列表。
2. **B-002** `Repository` 必须显示完整 `owner/name`，跨 owner 的同名仓库
   不得被合并；`#` 必须右对齐。标题列使用剩余终端宽度且至少保留 20 个字符，
   并在需要时按 Unicode 字符边界截断且以省略号结尾。当终端宽度不足以同时容纳
   固定列、完整仓库名和 20 字符标题时，表格必须采用满足这些约束的最小可读宽度，
   可以横向超出终端，但不得截断仓库身份。
3. **B-003** 仅当 stdout 是 TTY 且未设置 `NO_COLOR` 时，表头才使用克制的
   ANSI 粗体/青色；非 TTY、设置 `NO_COLOR` 或 `--json` 时不得输出 ANSI。
4. **B-004** `--plain` 必须保留旧版分组文本；`--plain` 与 `--json` 同时出现
   属于非法组合并以退出码 2 失败。未匹配到任何 item 时，人类模式必须明确显示
   0 条结果，`--json` 必须输出 `[]`。
5. **B-005** `--json` 中现有字段继续存在且类型不变；每个 item 新增稳定的
   `owner` 和 `repo_full_name`，其中 `repo` 继续保留短仓库名以兼容现有管道，
   `repo_full_name` 唯一标识 `owner/name`。适用时 `closed_at` 可为 `null`，
   缺失数据不得伪造。
6. **B-006** Issue、PR 和 moved-to-discussion 的 REST Search 必须遍历所有
   可访问页面；任何响应声明 `incomplete_results: true`、分页提前终止或
   `total_count` 大于已收集且服务端不再提供可访问页面时，命令必须非零退出并
   解释需要缩小查询，不得输出部分结果并声称成功。
7. **B-007** 任何必需的 `gh`、GraphQL、REST 或 `jq` 步骤失败时，命令必须
   非零退出并向 stderr 报告失败阶段；仓库枚举失败不得变成“0 条 Discussion”。
   重试整条命令不得复用上一次运行的临时数据。
8. **B-008** GraphQL connection 的单次 `first` 必须在 1..100；用户设置
   `--discussion-limit N` 时，每个仓库最多输出 N 条符合全部过滤条件的
   Discussion，N 大于 100 时通过 cursor 翻页而不是向单次请求传入越界值。
9. **B-009** `--stale D` 对 Discussion 的语义是从仓库的完整更新时间序列中
   找到最多 N 条早于 cutoff 的记录；不得只过滤最近 N 条。实现可以在已证明
   后续记录都更旧且已收集 N 条后停止。
10. **B-010** Discussion 必须使用 API 返回的真实 open/closed 状态；
    `state` 与 `closed_at` 必须一致：open 对应 `closed_at: null`，closed
    对应 API 的关闭时间，不得硬编码状态。
11. **B-011** 对 issue/PR/moved-to-discussion，`--repo` 与 `--authored` 或
    `--assigned` 组合时必须取交集，不得静默忽略 scope；对包含 Discussion
    枚举的 `--discussions`/`--hygiene`，任何 authored/assigned scope 都不
    支持，即使同时给出 `--repo` 也必须以退出码 2 明确拒绝。
12. **B-012** 重复的 `--label` 使用 AND 语义并一致作用于本次输出的所有 kind，
    包括 Discussion；标签值必须作为数据传递或正确转义，不能改变查询结构。
13. **B-013** 默认 Discussion 仓库枚举必须遍历账号拥有的全部非 fork、已启用
    Discussions 的仓库，不得使用静默固定的 200 仓库上限；实现应批量获取首屏
    Discussion，并只对确需更多页的仓库发送后续请求，避免无界 N+1 扫描。
14. **B-014** 表格单元格中的换行、回车和制表符必须规范化为空格，不能破坏表格
    行结构；空标题、缺失 author/category 等 API 允许的空值必须显示为空白或
    `-`，不得导致整次命令失败。
15. **B-015** 安装器必须先下载到目标目录内的临时文件，完成下载、Bash 语法
    验证和可选 checksum 验证后才原子替换目标；任何中断或验证失败都必须清理
    临时文件并保留已有安装。用户可显式选择版本/引用，默认行为仍安装 main。
16. **B-016** 行为测试必须以 fake `gh` 覆盖 REST 多页、GraphQL 多页、同名
    仓库、closed Discussion、stale 越过首屏、API 失败、非法参数组合、颜色
    抑制和 JSON 兼容；测试不得访问真实 GitHub。
17. **B-017** CI 必须在 Linux 和 macOS 上执行 Bash 语法检查与行为测试；
    ShellCheck 必须是阻断检查，不能用 `|| true`、warning 或其他方式吞掉失败。

## 验收标准

- [ ] 默认命令与 hygiene 模式均输出 B-001 至 B-004 定义的表格/空结果。
- [ ] `--plain` 和 `--json` 分别保持可读兼容与机器契约，满足 B-004/B-005。
- [ ] REST 与 GraphQL 正向和失败 fixture 满足 B-006 至 B-013。
- [ ] 表格异常文本 fixture 满足 B-014。
- [ ] 安装失败 fixture 证明旧目标文件未被覆盖，满足 B-015。
- [ ] fake-`gh` 测试、`bash -n`、ShellCheck 和 Linux/macOS CI 满足 B-016/B-017。

## 边界情况

| Category | Verdict |
| --- | --- |
| Empty / missing input | covered: B-004、B-005、B-014 |
| Error and failure paths | covered: B-006、B-007、B-015 |
| Authorization / permission | N/A：CLI 不改变 GitHub 权限或认证，只读取当前 token 可见数据；认证失败由 B-007 覆盖 |
| Concurrency / race / ordering | covered: B-009、B-013、B-015；API 结果按显式排序/游标消费，安装替换为原子步骤 |
| Retry / repetition / idempotency | covered: B-007、B-015；每次运行使用独立临时状态 |
| Illegal state transitions | covered: B-004、B-010、B-011 |
| Compatibility / migration | covered: B-004、B-005、B-015 |
| Degradation / fallback | covered: B-006、B-007；不允许部分或失败路径表现为成功 |
| Evidence and audit integrity | covered: B-006、B-016、B-017 |
| Cancellation / interruption / partial completion | covered: B-007、B-015 |

## 发布说明

- 默认人类输出会从分组列表切换为终端表格；需要旧样式的用户使用 `--plain`。
- `--json` 保留原字段并新增 `owner`、`repo_full_name`，属于向后兼容扩展。
- 对以前静默截断或失败降级的查询，新版本会明确非零退出；自动化调用方应检查退出码。
- 安装器新增可选版本引用与 checksum 验证，但默认安装入口保持不变。
