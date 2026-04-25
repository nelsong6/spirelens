# Issue-Agent GitHub App Authentication

The issue agent uses a selected GitHub mutation token for comments, labels, branches, commits, and pull requests.

The preferred token is a dedicated GitHub App installation token. While the app is being installed, the workflow falls back to the default Actions `GITHUB_TOKEN` so the issue-agent path keeps running.

This gives the agent a distinct bot identity, avoids changes appearing as a human user's personal token, and avoids the `GITHUB_TOKEN` bot-to-bot suppression that prevented relay labels from starting the next workflow run once fallback is removed.

## Desired Identity

Issue-agent mutations should be made by a dedicated GitHub App, for example:

- comments that announce runs and summarize outcomes
- labels such as `issue-agent-running`, `issue-agent-complete`, `issue-agent-blocked`, and relay labels for the next issue
- branches, commits, and pull requests opened by the agent
- pull request comments that link validation artifacts and screenshots

The default Actions `GITHUB_TOKEN` is only a bootstrap fallback during transition.

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

The workflow does not require an installation ID when using `actions/create-github-app-token`; the action resolves the installation for the configured repository owner.

## Workflow Shape

The issue-agent workflow resolves the mutation token immediately after checkout:

```yaml
- name: Create issue-agent GitHub App token
  id: issue-agent-app-token
  if: ${{ vars.ISSUE_AGENT_APP_ID != '' && secrets.ISSUE_AGENT_APP_PRIVATE_KEY != '' }}
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ vars.ISSUE_AGENT_APP_ID }}
    private-key: ${{ secrets.ISSUE_AGENT_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}

- name: Select issue-agent GitHub token
  id: issue-agent-token
  env:
    APP_TOKEN: ${{ steps.issue-agent-app-token.outputs.token }}
    FALLBACK_TOKEN: ${{ github.token }}
  shell: powershell -NoProfile -ExecutionPolicy Bypass -File {0}
  run: |
    if (-not [string]::IsNullOrWhiteSpace($env:APP_TOKEN)) {
      "token=$($env:APP_TOKEN)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
      "auth-mode=app-token" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
      return
    }

    "token=$($env:FALLBACK_TOKEN)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    "auth-mode=github-token-fallback" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
```

Every GitHub-mutating step then uses the selected token:

```yaml
env:
  GH_TOKEN: ${{ steps.issue-agent-token.outputs.token }}
```

The Claude issue-agent invocation also receives `ISSUE_AGENT_GH_AUTH_MODE` so logs can show whether a run used `app-token` or `github-token-fallback`.

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
- A missing app configuration is a hard failure after fallback is removed.
