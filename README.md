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

The installer stages the download in the target directory, validates Bash
syntax, and atomically replaces an existing install only after validation. Set
`GH_MINE_VERSION` to install another tag, branch, or commit. For an exact
integrity check, also set `GH_MINE_SHA256` to the expected 64-digit SHA256:

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/gh-mine/main/install.sh |
  env GH_MINE_VERSION=v1.2.3 GH_MINE_SHA256=YOUR_64_HEX_SHA256 bash
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
gh-mine --discussions    # latest Discussions in repos you own
gh-mine --moved-to-discussion # closed issues whose body/comments link to discussions/
gh-mine --hygiene        # Discussions + moved-to-discussion view
gh-mine --discussion-limit 50 # max Discussions read per repo (default: 20)
gh-mine --authored       # scope: everything you created (all repos)
gh-mine --assigned       # scope: everything assigned to you (all repos)
gh-mine --repo <name>    # limit to one repo (owner optional)
gh-mine --stale <days>   # only items not updated in <days> days
gh-mine --label <name>   # filter by label (repeatable, AND)
gh-mine --account <user> # query another account (does not switch `gh` login)
gh-mine --plain          # legacy grouped text output
gh-mine --json           # emit a JSON array (for jq / piping)
gh-mine -h | --help
```

### Scopes

| Scope | Query | Meaning |
|---|---|---|
| default | `user:<login>` | repos you own (excludes upstream repos) |
| `--authored` | `author:<login>` | everything you created, across all repos |
| `--assigned` | `assignee:<login>` | everything assigned to you, across all repos |

The default output is one Unicode table with fixed columns:
`Type | Repository | # | State | Updated | Title`. Repository values use full
`owner/name` identity, so repositories with the same short name remain distinct.
The `#` column is right-aligned, unsafe control whitespace is normalized, and
long titles are truncated at Unicode code-point boundaries. TTY headers use
restrained cyan/bold styling; pipes, `NO_COLOR`, and JSON never contain ANSI.
If the terminal is too narrow, the table expands past it to preserve the full
repository name and a readable Title column of at least 20 characters.
Use `--plain` for the legacy grouped view. `--plain --json` is invalid.

### Example output

```text
$ gh-mine
┌────────────┬──────────────────────┬──────┬────────┬────────────┬──────────────────────┐
│ Type       │ Repository           │    # │ State  │ Updated    │ Title                │
├────────────┼──────────────────────┼──────┼────────┼────────────┼──────────────────────┤
│ Issue      │ majiayu000/gh-mine   │    1 │ open   │ 2026-07-24 │ Improve reliability  │
└────────────┴──────────────────────┴──────┴────────┴────────────┴──────────────────────┘
Total: 1 (Issue 1)

$ gh-mine --stale 30 --issues   # only issues not updated in 30+ days
$ gh-mine --label bug           # only items labelled "bug"
$ gh-mine --hygiene             # Discussions plus issues moved to Discussions
$ gh-mine --repo remem --discussions --json
```

`--stale <days>` filters to items not updated in the last `<days>` days (added as
an `updated:<date` qualifier). `--label <name>` can be repeated and combines with
AND.

### Discussion hygiene

`--discussions` uses cursor-paginated GitHub GraphQL to scan Discussions in every
owned, non-fork repository that has Discussions enabled. `--repo` limits the
scan to a single repository, and `--discussion-limit` controls how many matching
Discussions are returned per repository. Stale and label filters continue
scanning until the limit is met or the connection is exhausted. Discussion
enumeration is repository scoped, so `--authored` and `--assigned` are rejected
with `--discussions` or `--hygiene`, even when `--repo` is present.

`--moved-to-discussion` reports closed issues whose body or comments contain
`discussions/`. This is a lightweight way to find roadmap or umbrella issues
that were moved out of the issue tracker. `--hygiene` combines both views.

### JSON output

`--json` emits a flat JSON array (one object per issue/PR) instead of the grouped
text — useful for piping into `jq` or other tools:

```bash
gh-mine --json | jq '.[] | select(.kind=="issue") | .repo'
gh-mine --json --repo litellm-rs --issues | jq '[.[].number]'
gh-mine --json --hygiene | jq '.[] | select(.kind=="moved_to_discussion")'
```

Each element carries `scope`, `kind`, legacy short `repo`, stable `owner` and
`repo_full_name`, `number`, `title`, `url`, `state`, and `updated_at`.
Discussion items add `created_at`, nullable `closed_at`, `category`, and
`author`; moved-to-discussion issue items add nullable `closed_at`. Empty
results emit `[]`.

## Notes

- The GitHub Search endpoint only accepts `GET`, so the query is URL-encoded into
  the request path rather than passed as `gh api ... -f q=` (which triggers a
  non-GET request and returns 404).
- Search requests consume every accessible 100-item page. Incomplete Search
  responses, premature pagination, and totals above GitHub's accessible
  1,000-result Search limit fail explicitly instead of returning partial data.
- Discussion listing uses batched repository first screens and selective cursor
  follow-up because Discussions are not returned by the Issues search endpoint.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Keep it simple and dependency-light.

## License

[MIT](LICENSE)
