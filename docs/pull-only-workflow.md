# Pull-Only Workflow

This repo is operated in **pull-only** mode, with GitHub as the source of truth for repository state.

## Policy

- Do not read from the local filesystem to determine repo state.
- Do not write to the local filesystem to make repo changes.
- Do not use local `git` or local `gh` as the normal repo mutation path.
- Use GitHub-backed tools to read files, create branches, update files, and open pull requests.
- If a remote branch, commit, or PR cannot be produced, stop and report the blocker.

## Expected Flow

1. Read the current repo state from GitHub.
2. Create or update a remote branch.
3. Materialize changes as remote commits.
4. Open or update a pull request early so progress is visible.
5. Pull or fetch locally only when a human explicitly wants to inspect or sync the remote result.

## Why

Local repository state is hidden, mutable, and workstation-specific. Remote GitHub artifacts are visible, reviewable, and durable.

This workflow keeps the unit of change explicit:

- branch URL instead of "I changed it"
- commit URL instead of "it's ready locally"
- pull request URL instead of "I can push next"

## Communication Contract

Report outcomes as:

- `no local changes made`
- `remote branch created`
- `commit pushed`
- `PR opened`
- `blocked`

Avoid ambiguous wording like "I updated it" unless the remote artifact is named explicitly.
