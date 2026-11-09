local M = {}

local API = 15000
local GIT = 2000
local LOG = 30000
local VERSION = '7.1'

--- Builds scanned for the ones of a commit: the API filters builds by branch
--- and by repository, never by commit.
local SCAN = 100

--- A job's id is its build's times this plus its log's. A timeline names a job
--- by GUID, and a `ci://` name, a check and a log all want one integer that
--- leads back to the build.
M.JOB = 100000

---@type ci.Nouns
M.nouns = { run = 'run', group = 'stage', pr = 'pull request', ref = '!' }

---@type table<ci.gh.Act, boolean>
M.acts = { rerun = true, ['rerun-failed-jobs'] = true, cancel = true }

---@class ci.az.Parts
---@field org string
---@field project string
---@field repo? string a run is named by its project alone

--- Undoes the percent-encoding a project or repository name carries in a URL.
---@param s string
---@return string
local function decode(s)
  return (s:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param s string
---@return string
local function encode(s)
  return (s:gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- The organization, project and repository of a clone URL:
--- `https://[org@]dev.azure.com/org/project/_git/repo`,
--- `git@ssh.dev.azure.com:v3/org/project/repo`, and
--- `https://org.visualstudio.com/[DefaultCollection/]project/_git/repo`.
---@param url string
---@return ci.az.Parts?
function M.parse_url(url)
  local org, project, repo = url:match('dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)$')
  if not org then
    org, project, repo = url:match('ssh%.dev%.azure%.com:v3/([^/]+)/([^/]+)/([^/]+)$')
  end
  if not org then
    org, project, repo = url:match('vs%-ssh%.visualstudio%.com:v3/([^/]+)/([^/]+)/([^/]+)$')
  end
  if not org then
    local path
    org, path = url:match('([%w-]+)%.visualstudio%.com/(.*)$')
    path = path and path:gsub('^DefaultCollection/', '')
    project, repo = (path or ''):match('^([^/]+)/_git/([^/]+)$')
  end
  if not (org and project and repo) or not org:match('^%w[%w-]*$') then
    return nil
  end
  return { org = org, project = decode(project), repo = decode((repo:gsub('%.git$', ''))) }
end

--- `org/project/repo`, the shape a `ci://` name spells a repository in.
---@param p ci.az.Parts
---@return string
local function slug(p)
  return table.concat({ p.org, p.project, p.repo }, '/')
end

---@param repo? string
---@return ci.az.Parts?
function M.parts(repo)
  local org, project, name = (repo or ''):match('^([^/]+)/([^/]+)/?([^/]*)$')
  if not org then
    return nil
  end
  return { org = org, project = project, repo = name ~= '' and name or nil }
end

--- The browser page behind `gX`. A job's page is its build's: the one the
--- portal opens a job on is keyed by a GUID the id here does not keep.
---@param repo string
---@param kind ci.Uri.Kind|'repo'
---@param id? string|integer
---@return string
function M.web(repo, kind, id)
  local p = M.parts(repo)
  if not p then
    return 'https://dev.azure.com'
  end
  local base = ('https://dev.azure.com/%s/%s'):format(p.org, encode(p.project))
  local git = p.repo and ('%s/_git/%s'):format(base, encode(p.repo)) or base
  if kind == 'pr' then
    return ('%s/pullrequest/%s'):format(git, id)
  elseif kind == 'checks' then
    return ('%s/commit/%s'):format(git, id)
  elseif kind == 'run' then
    return ('%s/_build/results?buildId=%s'):format(base, id)
  elseif kind == 'job' and tonumber(id) then
    return ('%s/_build/results?buildId=%d&view=logs'):format(base, math.floor(tonumber(id) / M.JOB))
  end
  return ('%s/_build'):format(base)
end

---@param r vim.SystemCompleted
---@return string
local function errmsg(r)
  local s = vim.trim(r.stderr or '')
  if s == '' then
    s = vim.trim(r.stdout or '')
  end
  -- az prefixes its own complaint, and an API error arrives as one more line
  -- of it; the first line is the sentence worth showing.
  s = s:gsub('^ERROR:%s*', ''):gsub('\n.*$', '')
  if s == '' then
    s = ('az exited with code %d'):format(r.code)
  end
  return s
end

---@param p ci.az.Parts
---@return string[]
local function scope(p)
  return { '--org', 'https://dev.azure.com/' .. p.org, '--project', p.project }
end

--- Runs `az` and decodes what it printed.
---@param args string[]
---@param on_done fun(data?: any, err?: string)
---@param timeout? integer
local function az(args, on_done, timeout)
  timeout = timeout or API
  local cmd = vim.list_extend({ 'az' }, args)
  vim.list_extend(cmd, { '--output', 'json', '--only-show-errors' })
  return vim.system(cmd, { text = true, timeout = timeout }, function(r)
    vim.schedule(function()
      if r.code == 124 then
        return on_done(nil, ('az did not answer within %ds'):format(timeout / 1000))
      end
      if r.code ~= 0 then
        return on_done(nil, errmsg(r))
      end
      local out = vim.trim(r.stdout or '')
      if out == '' then
        return on_done({})
      end
      local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
      if not ok then
        return on_done(nil, 'malformed JSON from az')
      end
      on_done(decoded)
    end)
  end)
end

--- A REST call `az` has no command of its own for, made with the sign-in
--- `az devops` already uses. {body} is written to a file, the only way
--- `invoke` takes one, and removed once the call returns.
---@param p ci.az.Parts
---@param resource string
---@param route string[] `key=value` route parameters besides the project
---@param opts? { query?: string[], method?: string, body?: table, timeout?: integer }
---@param on_done fun(data?: any, err?: string)
local function invoke(p, resource, route, opts, on_done)
  opts = opts or {}
  local args = {
    'devops',
    'invoke',
    '--org',
    'https://dev.azure.com/' .. p.org,
    '--area',
    'build',
    '--resource',
    resource,
    '--api-version',
    VERSION,
    '--route-parameters',
    'project=' .. p.project,
  }
  vim.list_extend(args, route)
  if opts.query then
    args[#args + 1] = '--query-parameters'
    vim.list_extend(args, opts.query)
  end
  local file
  if opts.method then
    vim.list_extend(args, { '--http-method', opts.method })
  end
  if opts.body then
    file = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode(opts.body) }, file)
    vim.list_extend(args, { '--in-file', file })
  end
  return az(args, function(data, err)
    if file then
      vim.fn.delete(file)
    end
    on_done(data, err)
  end, opts.timeout)
end

---@param p ci.az.Parts
---@param build integer
---@param on_done fun(build?: table, err?: string)
local function build_of(p, build, on_done)
  local args = { 'pipelines', 'runs', 'show', '--id', tostring(build) }
  az(vim.list_extend(args, scope(p)), on_done)
end

---@param p ci.az.Parts
---@param build integer
---@param on_done fun(records?: table[], err?: string)
local function timeline(p, build, on_done)
  invoke(p, 'timeline', { 'buildId=' .. build }, nil, function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(type(data) == 'table' and data.records or {})
  end)
end

---@param on_done fun(repo?: string, err?: string)
function M.repo(on_done)
  local url = require('ci.forge').remote_url()
  local p = url and M.parse_url(url)
  vim.schedule(function()
    if not p then
      return on_done(nil, 'cannot read an Azure DevOps repository from the remote')
    end
    on_done(slug(p))
  end)
end

--- The repository to ask: the one named, or the remote's.
---@param repo? string
---@return ci.az.Parts?
---@return string? err
local function where(repo)
  local p = M.parts(repo)
  if p then
    return p
  end
  local url = require('ci.forge').remote_url()
  p = url and M.parse_url(url)
  if not p then
    return nil, 'cannot read an Azure DevOps repository from the remote'
  end
  return p
end

--- How far a timeline record or a build got, in GitHub's words.
---@param state? string
---@return ci.Status
local function status_of(state)
  if state == 'completed' then
    return 'completed'
  end
  if state == 'inProgress' or state == 'cancelling' then
    return 'in_progress'
  end
  return 'queued'
end

local RESULTS = {
  succeeded = 'success',
  succeededWithIssues = 'warning',
  partiallySucceeded = 'warning',
  failed = 'failure',
  canceled = 'cancelled',
  abandoned = 'cancelled',
  skipped = 'skipped',
}

---@param result? string
---@return ci.Conclusion?
local function conclusion_of(result)
  return RESULTS[result or '']
end

---@param records table[]
---@return table<string, table>
local function by_id(records)
  local out = {}
  for _, r in ipairs(records) do
    out[r.id] = r
  end
  return out
end

--- The stage a timeline record sits under, by walking up its parents.
---@param rec table
---@param index table<string, table>
---@return string?
local function stage_of(rec, index)
  local at = rec
  while at and at.type ~= 'Stage' do
    at = at.parentId and index[at.parentId] or nil
  end
  return at and at.name or nil
end

---@param a table
---@param b table
---@return boolean
local function in_order(a, b)
  return (a.order or 0) < (b.order or 0)
end

--- The steps of job record {job}: its tasks, in the order they run.
---@param job table
---@param records table[]
---@return ci.gh.JobStep[]
local function steps_of(job, records)
  local tasks = {}
  for _, r in ipairs(records) do
    if r.type == 'Task' and r.parentId == job.id then
      tasks[#tasks + 1] = r
    end
  end
  table.sort(tasks, in_order)
  ---@type ci.gh.JobStep[]
  local out = {}
  for i, t in ipairs(tasks) do
    out[i] = {
      name = t.name,
      number = i,
      status = status_of(t.state),
      conclusion = conclusion_of(t.result),
      started_at = t.startTime,
      log = t.log and t.log.id,
    }
  end
  return out
end

--- A job record as the shared job shape. One with no log yet has no id that
--- could lead back to it, so it is drawn but cannot be opened.
---@param build integer
---@param rec table
---@param records table[]
---@param index table<string, table>
---@param sha? string
---@return ci.gh.Job
local function to_job(build, rec, records, index, sha)
  local log = rec.log and rec.log.id
  return {
    id = log and build * M.JOB + log or nil,
    run_id = build,
    head_sha = sha,
    name = rec.name,
    status = status_of(rec.state),
    conclusion = conclusion_of(rec.result),
    workflow_name = stage_of(rec, index),
    steps = steps_of(rec, records),
  }
end

---@param records table[]
---@return table[]
local function jobs_in(records)
  local jobs = {}
  for _, r in ipairs(records) do
    if r.type == 'Job' then
      jobs[#jobs + 1] = r
    end
  end
  table.sort(jobs, function(a, b)
    local sa, sb = a.startTime or '~', b.startTime or '~'
    if sa ~= sb then
      return sa < sb
    end
    return in_order(a, b)
  end)
  return jobs
end

---@param id integer
---@param _attempt? integer a retry runs in the same build and keeps no attempts
---@param repo? string
---@param on_done fun(jobs?: ci.gh.Job[], err?: string)
function M.run_jobs(id, _attempt, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(nil, perr)
  end
  build_of(p, id, function(b, berr)
    if berr then
      return on_done(nil, berr)
    end
    timeline(p, id, function(records, err)
      if err then
        return on_done(nil, err)
      end
      local index = by_id(records)
      local out = {}
      for _, rec in ipairs(jobs_in(records)) do
        out[#out + 1] = to_job(id, rec, records, index, b and b.sourceVersion)
      end
      on_done(out)
    end)
  end)
end

---@param id integer
---@return integer build
---@return integer log
local function split(id)
  return math.floor(id / M.JOB), id % M.JOB
end

--- The job record whose log is {log}, and the whole timeline it came from.
---@param p ci.az.Parts
---@param id integer
---@param on_done fun(rec?: table, records?: table[], err?: string)
local function find_job(p, id, on_done)
  local build, log = split(id)
  timeline(p, build, function(records, err)
    if err then
      return on_done(nil, nil, err)
    end
    for _, r in ipairs(records) do
      if r.type == 'Job' and r.log and r.log.id == log then
        return on_done(r, records)
      end
    end
    on_done(nil, nil, ('build %d has no job with log %d'):format(build, log))
  end)
end

---@param id integer
---@param repo? string
---@param on_done fun(job?: ci.gh.Job, err?: string)
function M.job(id, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(nil, perr)
  end
  find_job(p, id, function(rec, records, err)
    if not rec then
      return on_done(nil, err)
    end
    on_done(to_job(split(id), rec, records, by_id(records)))
  end)
end

--- The text of one log. Asked for as JSON, the API answers with its lines.
---@param p ci.az.Parts
---@param build integer
---@param log integer
---@param on_done fun(text?: string, err?: string)
local function log_text(p, build, log, on_done)
  local route = { 'buildId=' .. build, 'logId=' .. log }
  invoke(p, 'logs', route, { timeout = LOG }, function(data, err)
    if err then
      return on_done(nil, err)
    end
    if type(data) == 'string' then
      return on_done(data)
    end
    local lines = type(data) == 'table' and (data.value or data) or {}
    on_done(#lines > 0 and table.concat(lines, '\n') .. '\n' or '')
  end)
end

--- A job's log is its tasks' logs one after another, so a step starts where
--- its own log does; the job's log alone holds only what ran around them.
---@param id integer
---@param repo? string
---@param on_done fun(text?: string, err?: string)
function M.job_log(id, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(nil, perr)
  end
  local build = split(id)
  find_job(p, id, function(rec, records, err)
    if not rec then
      return on_done(nil, err)
    end
    local logs = {}
    for _, s in ipairs(steps_of(rec, records)) do
      if s.log then
        logs[#logs + 1] = s.log
      end
    end
    if #logs == 0 then
      return log_text(p, build, rec.log.id, on_done)
    end
    local parts, left, failed = {}, #logs, nil
    for i, log in ipairs(logs) do
      log_text(p, build, log, function(text, e)
        parts[i] = text or ''
        failed = failed or e
        left = left - 1
        if left == 0 then
          if failed then
            return on_done(nil, failed)
          end
          on_done(table.concat(parts))
        end
      end)
    end
  end)
end

--- The sha {expr} names. HEAD and an expression like `HEAD~3` are answered by
--- git; a branch or a tag is asked of the repository by name first, which
--- sees one not fetched yet and where the remote's is now.
---@param p ci.az.Parts
---@param expr string
---@param on_done fun(sha?: string, err?: string)
local function resolve_rev(p, expr, on_done)
  local rev = (expr:gsub('%^{commit}$', ''))
  if rev:match('^%x%x%x%x%x%x%x+$') then
    return on_done(rev)
  end
  local function locally()
    local r = vim
      .system({ 'git', 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' }, { text = true })
      :wait(GIT)
    local sha = r.code == 0 and vim.trim(r.stdout or '') or ''
    if sha == '' then
      return on_done(nil, ('no such revision on %s or here: %s'):format(slug(p), rev))
    end
    on_done(sha)
  end
  if rev == 'HEAD' or rev:find('[~^@:]') or not p.repo then
    return locally()
  end
  local function ref(filter, otherwise)
    local args = { 'repos', 'ref', 'list', '--repository', p.repo, '--filter', filter }
    az(vim.list_extend(args, scope(p)), function(rows)
      for _, row in ipairs(type(rows) == 'table' and rows or {}) do
        if row.name == 'refs/' .. filter then
          return on_done(row.peeledObjectId or row.objectId)
        end
      end
      otherwise()
    end)
  end
  ref('heads/' .. rev, function()
    ref('tags/' .. rev, locally)
  end)
end

---@param b table a build
---@param records table[]
---@return ci.Check[]
local function checks_of(b, records)
  local index = by_id(records)
  local out = {}
  for _, rec in ipairs(jobs_in(records)) do
    local j = to_job(b.id, rec, records, index)
    out[#out + 1] = {
      name = j.name,
      status = j.status,
      conclusion = j.conclusion,
      job_id = j.id,
      run_id = b.id,
      group = vim.tbl_get(b, 'definition', 'name'),
      started_at = rec.startTime,
    }
  end
  return out
end

--- The builds of a commit and their jobs. The builds are found by scanning
--- the newest of the repository's, since none is filed by commit.
---@param expr string
---@param repo? string
---@param on_done fun(res?: ci.gh.Rollup, err?: string)
function M.rollup(expr, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(nil, perr)
  end
  resolve_rev(p, expr, function(sha, rerr)
    if not sha then
      return on_done(nil, rerr)
    end
    local args =
      { 'pipelines', 'runs', 'list', '--top', tostring(SCAN), '--query-order', 'QueueTimeDesc' }
    az(vim.list_extend(args, scope(p)), function(rows, err)
      if err then
        return on_done(nil, err)
      end
      local builds = {}
      for _, b in ipairs(type(rows) == 'table' and rows or {}) do
        local same = not p.repo or vim.tbl_get(b, 'repository', 'name') == p.repo
        if same and b.sourceVersion and vim.startswith(b.sourceVersion, sha) then
          builds[#builds + 1] = b
        end
      end
      ---@type ci.gh.Rollup
      local res = {
        repo = slug(p),
        oid = builds[1] and builds[1].sourceVersion or sha,
        headline = builds[1] and vim.tbl_get(builds[1], 'triggerInfo', 'ci.message') or '',
        checks = {},
      }
      if #builds == 0 then
        return on_done(res)
      end
      local per, left = {}, #builds
      for i, b in ipairs(builds) do
        timeline(p, b.id, function(records)
          per[i] = checks_of(b, records or {})
          left = left - 1
          if left == 0 then
            for _, checks in ipairs(per) do
              vim.list_extend(res.checks, checks)
            end
            on_done(res)
          end
        end)
      end
    end)
  end)
end

--- A pull request's builds run on the merge of it into its target, so that
--- merge, not the source branch's head, is the commit whose checks it has.
---@param pr table
---@param p ci.az.Parts
---@return ci.gh.Pr
local function to_pr(pr, p)
  return {
    number = pr.pullRequestId,
    title = pr.title,
    headRefOid = vim.tbl_get(pr, 'lastMergeCommit', 'commitId')
      or vim.tbl_get(pr, 'lastMergeSourceCommit', 'commitId'),
    repo = slug({
      org = p.org,
      project = vim.tbl_get(pr, 'repository', 'project', 'name') or p.project,
      repo = vim.tbl_get(pr, 'repository', 'name') or p.repo,
    }),
  }
end

---@param branch string
---@param repo? string
---@param on_done fun(pr?: ci.gh.BranchPr, err?: string)
function M.pr_for_branch(branch, repo, on_done)
  local p, perr = where(repo)
  if not p or not p.repo then
    return on_done(nil, perr or 'no repository to look for pull requests in')
  end
  local args = {
    'repos',
    'pr',
    'list',
    '--repository',
    p.repo,
    '--source-branch',
    branch,
    '--status',
    'active',
  }
  az(vim.list_extend(args, scope(p)), function(rows, err)
    if err then
      return on_done(nil, err)
    end
    local pr = type(rows) == 'table' and rows[1] or nil
    on_done(pr and to_pr(pr, p) --[[@as ci.gh.BranchPr]] or nil)
  end)
end

---@param number integer
---@param repo? string
---@param on_done fun(pr?: ci.gh.Pr, err?: string)
function M.pr_by_number(number, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(nil, perr)
  end
  local args =
    { 'repos', 'pr', 'show', '--id', tostring(number), '--org', 'https://dev.azure.com/' .. p.org }
  az(args, function(pr, err)
    if err then
      return on_done(nil, err)
    end
    on_done(to_pr(pr, p))
  end)
end

--- Retrying runs again the jobs of a build that did not pass; re-running all
--- of it queues a new build of the same commit, as the portal's "Run new"
--- does. Cancelling cannot be forced.
---@param id integer
---@param what ci.gh.Act
---@param repo? string
---@param on_done fun(err?: string)
function M.act(id, what, repo, on_done)
  local p, perr = where(repo)
  if not p then
    return on_done(perr)
  end
  local route = { 'buildId=' .. id }
  if what == 'cancel' or what == 'force-cancel' then
    return invoke(
      p,
      'builds',
      route,
      { method = 'PATCH', body = { status = 'cancelling' } },
      function(_, err)
        on_done(err)
      end
    )
  end
  if what == 'rerun-failed-jobs' then
    local opts = { method = 'PATCH', body = {}, query = { 'retry=true' } }
    return invoke(p, 'builds', route, opts, function(_, err)
      on_done(err)
    end)
  end
  build_of(p, id, function(b, err)
    if err then
      return on_done(err)
    end
    local args = {
      'pipelines',
      'run',
      '--id',
      tostring(vim.tbl_get(b, 'definition', 'id')),
      '--branch',
      b.sourceBranch,
      '--commit-id',
      b.sourceVersion,
    }
    az(vim.list_extend(args, scope(p)), function(_, e)
      on_done(e)
    end)
  end)
end

return M
