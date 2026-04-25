# Issue-Agent GitHub App Authentication

The issue agent should use a dedicated GitHub App installation token for GitHub mutations instead of relying on the workflow `GITHUB_TOKEN`.

This gives the agent a distinct bot identity, avoids changes appearing as a human user's personal token, and avoids the `GITHUB_TOKEN` bot-to-bot suppression that prevented relay labels from starting the next workflow run.

## Desired Identity

Issue-agent mutations should be made by a dedicated GitHub App, for example:

- comments that announce runs and summarize outcomes
- labels such as `issue-agent-running`, `issue-agent-complete`, `issue-agent-blocked`, and relay labels for the next issue
- branches, commits, and pull requests opened by the agent
- pull request comments that link validation artifacts and screenshots

The default Actions `GITHUB_TOKEN` should remain available only as bootstrap fallback while the app is being installed.

## App Permissions

Recommended repository permissions for the app installation:

- Contents: read and write
- Issues: read and write
- Pull requests: read and write
- Metadata: read

If we move relay handoff to `repository_dispatch` or `workflow_dispatch`, include whichever permission GitHub requires for the selected dispatch path.

## Repository Configuration

Set these repository variables/secrets:

- variable `ISSUE_AGENT_APP_ID`: numeric GitHub App ID
- secret `ISSUE_AGENT_APP_PRIVATE_KEY`: PEM private key for the GitHub App

The workflow scaffold does not require an installation ID when using `actions/create-github-app-token`; the action resolves the installation for the configured repository owner.

## Workflow Shape

Resolve the token once, immediately after checkout or before the first GitHub mutation:

```yaml
- name: Resolve issue-agent GitHub token
  id: issue-agent-token
  uses: ./.github/actions/issue-agent-github-token
  with:
    app-id: ${{ vars.ISSUE_AGENT_APP_ID }}
    private-key: ${{ secrets.ISSUE_AGENT_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    fallback-token: ${{ github.token }}
```

Then pass the selected token to every GitHub-mutating step:

```yaml
env:
  GH_TOKEN: ${{ steps.issue-agent-token.outputs.token }}
```

For the Claude issue-agent invocation, this makes `gh issue`, `gh pr`, `git push`, and label mutations use the app identity when the app is configured.

## Permissions During Transition

While fallback is still allowed, the workflow needs the existing write permissions:

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
```

After the app token is mandatory and proven, reduce the workflow token to the minimum required by Actions itself:

```yaml
permissions:
  contents: read
```

At that point, any accidental GitHub mutation through `${{ github.token }}` should fail, which makes identity drift obvious.

## Acceptance Checks

Before considering the transition complete:

- A test issue run posts its start comment as the GitHub App identity.
- The agent labels the issue complete or blocked as the GitHub App identity.
- A code-changing test issue opens a pull request as the GitHub App identity.
- The PR body or comments include screenshot/artifact links for live STS2 validation.
- The relay handoff to the next issue starts a new run without manual relabeling.
- A missing app configuration is either an explicit fallback during transition or a hard failure after fallback is removed.
