# gh-mine

> List your own open GitHub issues and pull requests in one command.

[![CI](https://github.com/majiayu000/gh-mine/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/gh-mine/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`gh-mine` is a small shell utility built on the GitHub CLI (`gh`) that lists the
open issues and pull requests that belong to **you** — by default, only the
repositories you own (excluding upstream repos you merely filed an issue against).

## Why

`gh issue list` and the GitHub notifications view mix everything together: issues
you filed on upstream projects, PRs scattered across orgs, issues assigned to you
on someone else's repo. `gh-mine` gives you three clean scopes so you only see
what is actually yours.

## Requirements

- [`gh`](https://cli.github.com/) — authenticated (`gh auth login`)
- [`jq`](https://stedolan.github.io/jq/)
- `bash`

## Install

One-liner (drops `gh-mine` into `~/.local/bin`; override with `GH_MINE_INSTALL_DIR`):

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/gh-mine/main/install.sh | bash
```

Manual:

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/gh-mine/main/gh-mine \
  -o ~/.local/bin/gh-mine
chmod +x ~/.local/bin/gh-mine
```

Make sure `~/.local/bin` is on your `PATH`.

## Usage

```text
gh-mine                  # your own repos: open issues + PRs (default)
gh-mine -i | --issues    # issues only
gh-mine -p | --prs       # PRs only
gh-mine --authored       # scope: everything you created (all repos)
gh-mine --assigned       # scope: everything assigned to you (all repos)
gh-mine --repo <name>    # limit to one repo (owner optional)
gh-mine --stale <days>   # only items not updated in <days> days
gh-mine --label <name>   # filter by label (repeatable, AND)
gh-mine --account <user> # query another account (does not switch `gh` login)
gh-mine -h | --help
```

### Scopes

| Scope | Query | Meaning |
|---|---|---|
| default | `user:<login>` | repos you own (excludes upstream repos) |
| `--authored` | `author:<login>` | everything you created, across all repos |
| `--assigned` | `assignee:<login>` | everything assigned to you, across all repos |

Output is grouped by repository with a per-scope count. The login defaults to the
currently active `gh` account (`gh api user`).

### Example output

```text
$ gh-mine
账号: majiayu000

【自己的仓库 · open Issue】 23 条
  litellm-rs (5)
    - #715 Split provider failure facts from retry policy and HTTP mapping
    - #714 Provider registry needs a single declaration source and conformance tests
  remem (5)
    - #658 Track remaining blocked and umbrella work after #643 closure
  ...

【自己的仓库 · open PR】 15 条
  rclean (3)
    - #183 feat: report AI model stores conservatively
    - #177 feat: add IDE cache and log rules
  ...

$ gh-mine --stale 30 --issues   # only issues not updated in 30+ days
$ gh-mine --label bug           # only items labelled "bug"
```

`--stale <days>` filters to items not updated in the last `<days>` days (added as
an `updated:<date` qualifier). `--label <name>` can be repeated and combines with
AND.

## Notes

- The GitHub Search endpoint only accepts `GET`, so the query is URL-encoded into
  the request path rather than passed as `gh api ... -f q=` (which triggers a
  non-GET request and returns 404).
- Search results are capped at 100 per request; if a scope exceeds that, the tool
  prints a warning and lists the first 100.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Keep it simple and dependency-light.

## License

[MIT](LICENSE)
