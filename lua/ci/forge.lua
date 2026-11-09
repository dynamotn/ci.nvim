local M = {}

--- What a forge calls the things ci.nvim has no neutral word for. Prose only:
--- the `ci://` kind stays `run` whatever the forge calls it.
---@class ci.Nouns
---@field run string a collection of jobs
---@field group string what a job belongs to, shown beside its name
---@field pr string what it calls a change proposed against a branch
---@field ref string the sigil it writes before that change's number

---@class ci.Backend
---@field nouns ci.Nouns
---@field repo fun(on_done: fun(repo?: string, err?: string))
---@field rollup fun(expr: string, repo?: string, on_done: fun(res?: ci.gh.Rollup, err?: string))
---@field pr_for_branch fun(branch: string, repo?: string, on_done: fun(pr?: ci.gh.BranchPr, err?: string))
---@field pr_by_number fun(number: integer, repo?: string, on_done: fun(pr?: ci.gh.Pr, err?: string))
---@field job fun(id: integer, repo?: string, on_done: fun(job?: ci.gh.Job, err?: string))
---@field job_log fun(id: integer, repo?: string, on_done: fun(text?: string, err?: string))
---@field job_log_from? fun(id: integer, offset: integer, repo?: string, on_done: fun(text?: string, err?: string))
---@field run_jobs fun(id: integer, attempt?: integer, repo?: string, on_done: fun(jobs?: ci.gh.Job[], err?: string))
---@field latest_run? fun(file: string, repo?: string, on_done: fun(run?: ci.gh.WorkflowRun, err?: string))
---@field act? fun(id: integer, what: ci.gh.Act, repo?: string, on_done: fun(err?: string))
---@field acts? table<ci.gh.Act, boolean> which of the four it takes; all, unsaid
---@field play? fun(id: integer, repo?: string, on_done: fun(err?: string))
---@field run_by_index? fun(index: integer, repo?: string, on_done: fun(run?: ci.tea.Run, err?: string))
---@field run? fun(id: integer, repo?: string, on_done: fun(run?: ci.tea.Run, err?: string))
---@field finished? fun(text: string): boolean
---@field prefix? fun(raw: string): string?, string
---@field marks? fun(body: string): ci.log.Kind?, string?, integer?

M.GITHUB = 'github.com'
M.GITLAB = 'gitlab.com'

local GIT = 2000

---@param url string
---@return string? host
function M.host_of(url)
  local scheme, authority = url:match('^(%a[%w+.%-]*)://([^/]+)')
  authority = authority or url:match('^([^/]+):')
  if not authority then
    return nil
  end
  authority = authority:gsub('^[^@]*@', '')
  if scheme == 'http' or scheme == 'https' then
    return authority
  end
  return (authority:gsub(':%d+$', ''))
end

--- The remotes asked in turn for the forge, unless `vim.g.ci_remotes` names
--- others.
M.REMOTES = { 'upstream', 'origin' }

--- The remote that picks the CLI, and nothing more: they resolve
--- `{owner}`/`{repo}` themselves. `tea` prefers a remote named `upstream` over
--- `origin`, so the same order is used here; picking the CLI from one remote
--- while it reads another is how a fork gets answered for by the wrong
--- repository. With none of them, the first remote git lists speaks for the
--- repository.
---@return string? url the remote that speaks for the repository
function M.remote_url()
  -- Every remote in one call, with `insteadOf` applied: `:CI` waits on it
  local r = vim.system({ 'git', 'remote', '-v' }, { text = true }):wait(GIT)
  local urls, first = {}, nil
  if r.code == 0 then
    for name, url in (r.stdout or ''):gmatch('(%S+)%s+(%S+) %(fetch%)') do
      urls[name] = url
      first = first or url
    end
  end
  local url
  for _, name in ipairs(vim.g.ci_remotes or M.REMOTES) do
    url = url or urls[name]
  end
  return url or first
end

---@return string host
function M.host()
  local url = M.remote_url()
  return url and M.host_of(url) or M.GITHUB
end

---@alias ci.Kind 'github'|'gitlab'|'forgejo'|'azure'

--- What `vim.g.ci_forges` may call a host. github is not among them: `gh`
--- would still ask github.com.
local TOLD = { gitlab = true, forgejo = true, azure = true }

local MODULES = { github = 'ci.gh', gitlab = 'ci.glab', forgejo = 'ci.tea', azure = 'ci.az' }
local CLIS = { github = 'gh', gitlab = 'glab', forgejo = 'tea', azure = 'az' }

--- The kind of forge {host} is. `vim.g.ci_forges` names the ones a hostname
--- cannot, `{ ['git.example.com'] = 'gitlab' }`; otherwise a host is known by
--- its name, a gitlab hosted elsewhere by a `gitlab` label of its own, and
--- anything else is taken to speak Forgejo. A host `tea` has no login for
--- fails at the first request, which is a clearer error than one invented here.
---@param host? string
---@return ci.Kind
function M.kind(host)
  host = host or M.GITHUB
  local forges = vim.g.ci_forges
  local told = type(forges) == 'table' and forges[host] or nil
  if TOLD[told] then
    return told
  end
  if host == M.GITHUB or host:match('%.github%.com$') then
    return 'github'
  end
  if
    host == 'dev.azure.com'
    or host == 'ssh.dev.azure.com'
    or host:match('^[%w-]+%.visualstudio%.com$')
  then
    return 'azure'
  end
  if ('.' .. host .. '.'):find('.gitlab.', 1, true) then
    return 'gitlab'
  end
  return 'forgejo'
end

---@param host? string
---@return boolean
function M.is_github(host)
  return M.kind(host) == 'github'
end

---@param host? string
---@return boolean
function M.is_gitlab(host)
  return M.kind(host) == 'gitlab'
end

---@param host? string
---@return ci.Backend
function M.of(host)
  return require(MODULES[M.kind(host)])
end

---@param host? string
---@return string
function M.cli(host)
  return CLIS[M.kind(host)]
end

--- The browser page behind `gX`. The forges disagree on nearly every
--- path: `pull` against `pulls` against `merge_requests`, no `/checks` suffix
--- off github, and a `/-/` between the project and the noun on gitlab, which
--- is what keeps a subgroup from being mistaken for one.
---@param host string
---@param repo string
---@param kind ci.Uri.Kind|'repo'
---@param id? string|integer
---@param attempt? integer
---@return string
function M.web(host, repo, kind, id, attempt)
  if M.kind(host) == 'azure' then
    return require('ci.az').web(repo, kind, id)
  end
  local base = ('https://%s/%s'):format(host, repo)
  if M.is_github(host) then
    if kind == 'pr' then
      return ('%s/pull/%s/checks'):format(base, id)
    elseif kind == 'run' then
      local u = ('%s/actions/runs/%s'):format(base, id)
      return attempt and ('%s/attempts/%d'):format(u, attempt) or u
    elseif kind == 'checks' then
      return ('%s/commit/%s/checks'):format(base, id)
    end
    return base
  end
  if M.is_gitlab(host) then
    if kind == 'pr' then
      return ('%s/-/merge_requests/%s'):format(base, id)
    elseif kind == 'run' then
      return ('%s/-/pipelines/%s'):format(base, id)
    elseif kind == 'checks' then
      return ('%s/-/commit/%s'):format(base, id)
    end
    return ('%s/-/pipelines'):format(base)
  end
  -- A Forgejo run or job page is keyed on the run's index within the
  -- repository, which cannot be derived from the id its API answers to. Those
  -- pages name themselves; until one says so, the repository's is the honest
  -- answer.
  if kind == 'pr' then
    return ('%s/pulls/%s'):format(base, id)
  elseif kind == 'checks' then
    return ('%s/commit/%s'):format(base, id)
  end
  return ('%s/actions'):format(base)
end

return M
