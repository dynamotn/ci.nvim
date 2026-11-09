local glab = require('ci.glab')
local tea = require('ci.tea')

--- Stands in for the forge CLIs: {answer} gets the argv and returns what the
--- CLI printed, and optionally an exit code. Calls are recorded in order;
--- `git` is let through to the real one.
---@param answer fun(cmd: string[]): string, integer?
---@return string[][] calls
---@return fun() restore
local function fake(answer)
  local calls, system = {}, vim.system
  vim.system = function(cmd, opts, on_exit)
    if cmd[1] == 'git' then
      return system(cmd, opts, on_exit)
    end
    calls[#calls + 1] = cmd
    local out, code = answer(cmd)
    local r = { code = code or 0, stdout = out or '', stderr = '' }
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

---@param cmd string[]
---@return string
local function last(cmd)
  return cmd[#cmd]
end

describe('glab.revision', function()
  local dir, cwd

  local function git(...)
    return vim.system({ 'git', '-C', dir, ... }, { text = true }):wait(10000)
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    git('init', '--quiet')
    git(
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '--quiet',
      '--allow-empty',
      '-m',
      'a'
    )
    git(
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '--quiet',
      '--allow-empty',
      '-m',
      'b'
    )
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
  end)

  after_each(function()
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, 'rf')
  end)

  it('leaves a name to gitlab, which knows where the remote has it', function()
    assert.same('main', glab.revision('main^{commit}'))
    assert.same('v1.0', glab.revision('v1.0'))
  end)

  it('answers HEAD and an expression with git', function()
    local parent = vim.trim(git('rev-parse', 'HEAD~1').stdout)
    assert.same(parent, glab.revision('HEAD~1^{commit}'))
    assert.same(vim.trim(git('rev-parse', 'HEAD').stdout), glab.revision('HEAD^{commit}'))
  end)
end)

describe('glab.act', function()
  local restore
  after_each(function()
    restore()
  end)

  it('re-runs a whole pipeline job by job, in the order they were created', function()
    local calls
    calls, restore = fake(function(cmd)
      if vim.list_contains(cmd, '--paginate') then
        return table.concat({
          vim.json.encode({ id = 12, status = 'success' }),
          vim.json.encode({ id = 10, status = 'success' }),
          vim.json.encode({ id = 11, status = 'manual' }),
        }, '\n')
      end
      return '{}'
    end)
    local err = await(function(done)
      glab.act(5, 'rerun', 'g/p', done)
    end)
    assert.is_nil(err)
    assert.same(3, #calls)
    assert.same('projects/g%2Fp/jobs/10/retry', last(calls[2]))
    assert.same('projects/g%2Fp/jobs/12/retry', last(calls[3]))
  end)

  it('still retries only what failed through the pipeline', function()
    local calls
    calls, restore = fake(function()
      return '{}'
    end)
    await(function(done)
      glab.act(5, 'rerun-failed-jobs', 'g/p', done)
    end)
    assert.same(1, #calls)
    assert.same('projects/g%2Fp/pipelines/5/retry', last(calls[1]))
  end)
end)

describe('tea.act', function()
  local restore
  after_each(function()
    restore()
  end)

  it('cancels and re-runs a run', function()
    local calls
    calls, restore = fake(function()
      return ''
    end)
    assert.is_nil(await(function(done)
      tea.act(9, 'cancel', 'o/r', done)
    end))
    assert.is_nil(await(function(done)
      tea.act(9, 'rerun', 'o/r', done)
    end))
    assert.same({ 'tea', 'api', '--method', 'POST', 'repos/o/r/actions/runs/9/cancel' }, calls[1])
    assert.same('repos/o/r/actions/runs/9/rerun', last(calls[2]))
  end)

  it('re-runs the jobs that failed one by one', function()
    local calls
    calls, restore = fake(function(cmd)
      if last(cmd):match('/jobs$') then
        return vim.json.encode({
          { id = 1, status = 'success' },
          { id = 2, status = 'failure' },
          { id = 3, status = 'cancelled' },
        })
      end
      return ''
    end)
    assert.is_nil(await(function(done)
      tea.act(9, 'rerun-failed-jobs', 'o/r', done)
    end))
    assert.same('repos/o/r/actions/jobs/2/rerun', last(calls[2]))
    assert.same('repos/o/r/actions/jobs/3/rerun', last(calls[3]))
  end)

  it('says which release a server too old for it needs', function()
    _, restore = fake(function()
      return '{"message":"Not Found","url":"https://forge.example/api/swagger"}'
    end)
    local err = await(function(done)
      tea.act(9, 'rerun', 'o/r', done)
    end)
    assert.truthy(err:find('Forgejo 17 or Gitea 1.26', 1, true))
  end)
end)

describe('tea.rollup', function()
  local restore
  after_each(function()
    restore()
  end)

  it('asks Forgejo where a branch is', function()
    local calls
    calls, restore = fake(function(cmd)
      local path = last(cmd)
      if path:match('/branches/main$') then
        return vim.json.encode({ commit = { id = 'abc1234' } })
      end
      if path:match('/actions/runs%?') then
        return vim.json.encode({ workflow_runs = {} })
      end
      return '[]'
    end)
    local res = await(function(done)
      tea.rollup('main^{commit}', 'o/r', done)
    end)
    assert.same('abc1234', res.oid)
    assert.same('repos/o/r/branches/main', last(calls[1]))
  end)
end)
