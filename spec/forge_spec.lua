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

describe('forge.kind', function()
  after_each(function()
    vim.g.ci_forges = nil
  end)

  it('knows a forge by its name', function()
    assert.equals('github', forge.kind('github.com'))
    assert.equals('gitlab', forge.kind('gitlab.com'))
    assert.equals('azure', forge.kind('dev.azure.com'))
    assert.equals('azure', forge.kind('ssh.dev.azure.com'))
    assert.equals('azure', forge.kind('acme.visualstudio.com'))
    assert.equals('forgejo', forge.kind('codeberg.org'))
  end)

  it('takes a host with a gitlab label of its own for a gitlab', function()
    assert.equals('gitlab', forge.kind('gitlab.example.com'))
    assert.equals('gitlab', forge.kind('git.gitlab.example.com'))
    assert.equals('forgejo', forge.kind('notgitlab.example.com'))
  end)

  it('lets vim.g.ci_forges say what a host is', function()
    vim.g.ci_forges = { ['git.example.com'] = 'gitlab', ['code.example.com'] = 'github' }
    assert.equals('gitlab', forge.kind('git.example.com'))
    assert.equals('glab', forge.cli('git.example.com'))
    -- gh would still ask github.com, so github is not something to be told
    assert.equals('forgejo', forge.kind('code.example.com'))
  end)
end)
