local forge = require('ci.forge')

describe('forge.host', function()
  local dir, cwd

  local function git(...)
    vim.system({ 'git', '-C', dir, ... }):wait(10000)
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    git('init', '--quiet')
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
  end)

  after_each(function()
    vim.g.ci_remotes = nil
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, 'rf')
  end)

  it('asks upstream, then origin', function()
    git('remote', 'add', 'origin', 'https://gitlab.com/o/r.git')
    assert.equals('gitlab.com', forge.host())
    git('remote', 'add', 'upstream', 'https://github.com/o/r.git')
    assert.equals('github.com', forge.host())
  end)

  it('asks the remotes vim.g.ci_remotes names, in order', function()
    git('remote', 'add', 'origin', 'https://gitlab.com/o/r.git')
    git('remote', 'add', 'gh', 'https://github.com/o/r.git')
    vim.g.ci_remotes = { 'upstream', 'gh', 'origin' }
    assert.equals('github.com', forge.host())
  end)

  it('falls back to the first remote, then to github', function()
    assert.equals('github.com', forge.host())
    git('remote', 'add', 'fork', 'git@forge.example.org:o/r.git')
    assert.equals('forge.example.org', forge.host())
  end)

  it('reads a remote through insteadOf', function()
    git('config', 'url.https://gitlab.com/.insteadOf', 'gl:')
    git('remote', 'add', 'origin', 'gl:o/r.git')
    assert.equals('gitlab.com', forge.host())
  end)
end)
