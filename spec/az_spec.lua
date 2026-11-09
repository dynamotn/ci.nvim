local az = require('ci.az')

local REPO = 'acme/Web Shop/shop'

--- Stands in for `az`: {answer} gets the argv and returns what az would print,
--- or a table to be printed as JSON. Calls are recorded in order.
---@param answer fun(cmd: string[]): any
---@return string[][] calls
---@return fun() restore
local function fake(answer)
  local calls, system = {}, vim.system
  vim.system = function(cmd, _, on_exit)
    calls[#calls + 1] = cmd
    local out = answer(cmd)
    local r = {
      code = 0,
      stdout = type(out) == 'string' and out or vim.json.encode(out),
      stderr = '',
    }
    if on_exit then
      on_exit(r)
    end
    return {
      wait = function()
        return r
      end,
    }
  end
  return calls, function()
    vim.system = system
  end
end

---@param cmd string[]
---@param flag string
---@return string?
local function arg(cmd, flag)
  for i, a in ipairs(cmd) do
    if a == flag then
      return cmd[i + 1]
    end
  end
end

---@param cmd string[]
---@param route string
---@return boolean
local function routed(cmd, route)
  return vim.list_contains(cmd, route)
end

local TIMELINE = {
  records = {
    { id = 's1', type = 'Stage', name = 'Build' },
    { id = 'p1', type = 'Phase', parentId = 's1', name = 'Phase' },
    {
      id = 'j1',
      type = 'Job',
      parentId = 'p1',
      name = 'Linux',
      state = 'completed',
      result = 'failed',
      startTime = '2026-01-01T00:00:00Z',
      log = { id = 4 },
    },
    {
      id = 't2',
      type = 'Task',
      parentId = 'j1',
      name = 'Test',
      order = 2,
      state = 'completed',
      result = 'failed',
      startTime = '2026-01-01T00:00:10Z',
      log = { id = 6 },
    },
    {
      id = 't1',
      type = 'Task',
      parentId = 'j1',
      name = 'Checkout',
      order = 1,
      state = 'completed',
      result = 'succeeded',
      startTime = '2026-01-01T00:00:01Z',
      log = { id = 5 },
    },
    { id = 'j2', type = 'Job', parentId = 'p1', name = 'Windows', state = 'pending' },
  },
}

---@param fn fun(done: fun(...))
---@return any ...
local function await(fn)
  local got
  fn(function(...)
    got = { ... }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  return unpack(got or {})
end

describe('az.parse_url', function()
  it('reads every shape of clone URL', function()
    local want = { org = 'acme', project = 'Web Shop', repo = 'shop' }
    assert.same(want, az.parse_url('https://acme@dev.azure.com/acme/Web%20Shop/_git/shop'))
    assert.same(want, az.parse_url('git@ssh.dev.azure.com:v3/acme/Web%20Shop/shop'))
    assert.same(want, az.parse_url('https://acme.visualstudio.com/Web%20Shop/_git/shop'))
    assert.same(
      want,
      az.parse_url('https://acme.visualstudio.com/DefaultCollection/Web%20Shop/_git/shop')
    )
  end)

  it('refuses a URL that is not Azure DevOps', function()
    assert.is_nil(az.parse_url('https://github.com/o/r.git'))
  end)
end)

describe('az.web', function()
  it('builds the portal pages', function()
    local base = 'https://dev.azure.com/acme/Web%20Shop'
    assert.same(base .. '/_build/results?buildId=7', az.web(REPO, 'run', 7))
    assert.same(base .. '/_git/shop/pullrequest/3', az.web(REPO, 'pr', 3))
    assert.same(base .. '/_git/shop/commit/abc', az.web(REPO, 'checks', 'abc'))
    assert.same(base .. '/_build/results?buildId=7&view=logs', az.web(REPO, 'job', 7 * az.JOB + 4))
  end)
end)

describe('az.run_jobs', function()
  local restore
  after_each(function()
    restore()
  end)

  it('lists the jobs of a build with their stage and steps in order', function()
    _, restore = fake(function(cmd)
      if routed(cmd, 'show') then
        return { id = 7, sourceVersion = 'abc123' }
      end
      return TIMELINE
    end)
    local jobs = await(function(done)
      az.run_jobs(7, nil, REPO, done)
    end)
    assert.same(2, #jobs)
    local linux = jobs[1]
    assert.same('Linux', linux.name)
    assert.same(7 * az.JOB + 4, linux.id)
    assert.same('Build', linux.workflow_name)
    assert.same('failure', linux.conclusion)
    assert.same('abc123', linux.head_sha)
    assert.same({ 'Checkout', 'Test' }, {
      linux.steps[1].name,
      linux.steps[2].name,
    })
    -- Not started, so no log to lead back to it
    assert.is_nil(jobs[2].id)
    assert.same('queued', jobs[2].status)
  end)
end)

describe('az.job_log', function()
  local restore
  after_each(function()
    restore()
  end)

  it('joins the logs of its tasks in the order they ran', function()
    local calls
    calls, restore = fake(function(cmd)
      if arg(cmd, '--resource') == 'timeline' then
        return TIMELINE
      end
      if routed(cmd, 'logId=5') then
        return { count = 1, value = { 'checkout' } }
      end
      return { count = 2, value = { 'test 1', 'test 2' } }
    end)
    local text = await(function(done)
      az.job_log(7 * az.JOB + 4, REPO, done)
    end)
    assert.same('checkout\ntest 1\ntest 2\n', text)
    assert.same('acme', arg(calls[1], '--org'):match('[^/]+$'))
    assert.same('project=Web Shop', arg(calls[1], '--route-parameters'))
  end)
end)

describe('az.act', function()
  local restore
  after_each(function()
    restore()
  end)

  it('cancels through a PATCH of the build', function()
    local calls, body
    calls, restore = fake(function(cmd)
      body = vim.fn.readfile(arg(cmd, '--in-file'))[1]
      return {}
    end)
    local err = await(function(done)
      az.act(7, 'cancel', REPO, done)
    end)
    assert.is_nil(err)
    assert.same('PATCH', arg(calls[1], '--http-method'))
    assert.same({ status = 'cancelling' }, vim.json.decode(body))
    assert.same(0, vim.fn.filereadable(arg(calls[1], '--in-file')))
  end)

  it('retries the failed jobs in place', function()
    local calls
    calls, restore = fake(function()
      return {}
    end)
    await(function(done)
      az.act(7, 'rerun-failed-jobs', REPO, done)
    end)
    assert.same('retry=true', arg(calls[1], '--query-parameters'))
  end)

  it('queues a new build of the same commit to run it all again', function()
    local calls
    calls, restore = fake(function(cmd)
      if routed(cmd, 'show') then
        return {
          id = 7,
          definition = { id = 12 },
          sourceBranch = 'refs/heads/main',
          sourceVersion = 'abc',
        }
      end
      return { id = 8 }
    end)
    await(function(done)
      az.act(7, 'rerun', REPO, done)
    end)
    local queued = calls[2]
    assert.same({ 'az', 'pipelines', 'run' }, { queued[1], queued[2], queued[3] })
    assert.same('12', arg(queued, '--id'))
    assert.same('abc', arg(queued, '--commit-id'))
  end)
end)

describe('az.rollup', function()
  local restore
  after_each(function()
    restore()
  end)

  it('asks for a branch by name and keeps the builds of its commit', function()
    _, restore = fake(function(cmd)
      if routed(cmd, 'ref') then
        return { { name = 'refs/heads/main', objectId = 'abc123' } }
      end
      if routed(cmd, 'runs') then
        return {
          { id = 9, sourceVersion = 'fff', repository = { name = 'shop' } },
          {
            id = 7,
            sourceVersion = 'abc123',
            repository = { name = 'shop' },
            definition = { name = 'CI' },
          },
          { id = 6, sourceVersion = 'abc123', repository = { name = 'other' } },
        }
      end
      return TIMELINE
    end)
    local res = await(function(done)
      az.rollup('main^{commit}', REPO, done)
    end)
    assert.same('abc123', res.oid)
    assert.same(2, #res.checks)
    assert.same('CI', res.checks[1].group)
    assert.same(7, res.checks[1].run_id)
  end)
end)
