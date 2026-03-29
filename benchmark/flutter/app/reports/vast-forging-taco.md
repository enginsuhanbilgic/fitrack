# Plan: Attach Branch to GitHub Issue #1 with Analysis Report Comment

## Context

The user wants to:
1. Link the current branch `benchmark-alihan` to GitHub issue #1 in the `enginsuhanbilgic/fitrack` repo
2. Post the contents of `benchmark/analysis_report.md` as a comment on that issue

## Steps

### 1. Post the analysis report as a comment on issue #1

Use `gh issue comment` to post the full markdown content of `benchmark/analysis_report.md`:

```bash
gh issue comment 1 \
  --repo enginsuhanbilgic/fitrack \
  --body "$(cat benchmark/analysis_report.md)"
```

### 2. Link the branch to the issue

GitHub links a branch to an issue automatically when the branch name or a PR references it. To make the link explicit and visible in the issue sidebar, create a development link via the GitHub API:

```bash
gh issue develop 1 \
  --repo enginsuhanbilgic/fitrack \
  --branch benchmark-alihan
```

This adds `benchmark-alihan` to the "Development" section of issue #1.

## Critical Files

- `benchmark/analysis_report.md` — content to post as comment

## Verification

- Visit `https://github.com/enginsuhanbilgic/fitrack/issues/1`
- Confirm the comment with the benchmark table appears
- Confirm `benchmark-alihan` appears under the "Development" section in the right sidebar
