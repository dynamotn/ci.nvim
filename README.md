# ci.nvim

**GitHub Actions, GitLab CI/CD, Forgejo/Gitea Actions and Azure Pipelines in Neovim**

A fork of Barrett Ruth's ci.nvim, whose repository is no longer public. It
adds Azure Pipelines, a GitLab hosted anywhere, re-running and cancelling on
Forgejo and Gitea, and `g:ci_remotes` and `g:ci_forges` to say which remote
and which forge to ask.

Experience the power of `:CI`. Native CI logs in normal Neovim buffers with
real ANSI colours, step-level folds, and more.

## Requirements

- Neovim 0.13+
- `git`
- At least one of:
  - [`gh`](https://cli.github.com), authenticated (`gh auth login`), for github.com
  - [`glab`](https://gitlab.com/gitlab-org/cli), authenticated (`glab auth login`), for gitlab.com and GitLab hosted elsewhere
  - [`tea`](https://gitea.com/gitea/tea), authenticated (`tea login add`), for Forgejo 16+ and Gitea
  - [`az`](https://learn.microsoft.com/cli/azure/install-azure-cli) with the `azure-devops` extension, signed in (`az login` or `AZURE_DEVOPS_EXT_PAT`), for Azure DevOps

## Installation

With `vim.pack`:

```lua
vim.pack.add({
  'https://github.com/dynamotn/ci.nvim',
})
```

## Usage

```vim
" checks for the active pull request on this branch
:CI
:CI 123

" git revision
:CI master
:CI v0.11.0
:CI HEAD~3

" github.com, GitLab, Forgejo or Azure DevOps CI URLs
:CI https://github.com/neovim/neovim/actions/runs/30208531214/job/89810718120
:CI https://github.com/neovim/neovim/pull/40993
:CI https://gitlab.com/gitlab-org/cli/-/pipelines/2767853157
:CI https://gitlab.com/gitlab-org/cli/-/merge_requests/3734
:CI https://codeberg.org/forgejo/forgejo/actions/runs/12
:CI https://dev.azure.com/acme/Shop/_build/results?buildId=42

" the <cWORD> under the cursor
:CI .
```

Without an argument, `:CI` falls back to branch-head checks if no pull request
is open.

Work with a `ci://` buffer via buffer-local mappings. `<CR>` opens the check
under the cursor, and `-` goes back to the list you came from. Walk log steps
or sections with `[[` and `]]`.

Automatic refresh is best-effort. Use `R` or `:e` to reload a stale buffer.

## Documentation

```vim
:help ci
```

## Known limitations

What is left is what the forges' APIs do not offer; `:help ci-limitations` has
the details.

- **Numbers (all forges)**: a bare `:CI 123` is a pull or merge request. Use `:CI refs/heads/123` for a numeric branch name.
- **In-progress jobs (GitHub)**: no public API serves a running job's log ([cli/cli#3484](https://github.com/cli/cli/issues/3484)). Running jobs display their step status instead.
- **In-progress jobs (GitLab)**: opening a running job follows its trace best-effort; updates can arrive in bursts tens of seconds apart.
- **Steps (GitLab)**: jobs have no steps, so a log's own sections fold in their place and `[[`/`]]` move between sections.
- **Stages (GitLab)**: a checks list names no stage, because a commit's statuses do not carry one. A pipeline's own job list does.
- **Steps and single jobs (Forgejo, Gitea)**: logs fold on `##[group]` alone, and a job URL opened directly shows no name or status.
- **Re-run and cancel (Forgejo, Gitea)**: cancelling needs Forgejo 16, re-running Forgejo 17 or Gitea 1.26.
- **Commits (Azure DevOps)**: builds are not filed by commit, so a commit's checks come from the project's newest 100 builds.
- **GitHub Enterprise**: not supported; `gh` asks github.com.
