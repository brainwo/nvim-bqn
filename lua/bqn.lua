local ns = vim.api.nvim_create_namespace('bqnout')

local function enumerate(it)
  local idx, v = 0, nil
  return function()
    v, idx = it(), idx + 1
    return v, idx
  end
end

function clearBQN(from, to)
  vim.diagnostic.reset(ns, 0)
  vim.api.nvim_buf_clear_namespace(0, ns, from, to)
  vim.api.nvim_command("redraw!")
end

function computeCoords(from, to)
    if to < 0 then
      to = vim.api.nvim_buf_line_count(0) + to + 1
    end
    -- Compute `to` position by looking back till we find first non-empty line.
    while to > 0 do
      local line = vim.api.nvim_buf_get_lines(0, to - 1, to, true)[1]
      if #line ~= 0 and line:find("^%s*#") == nil then break end
      to = to - 1
    end

    if from > to then
      from = to
    end

    from = math.max(from, 0)
    to = math.max(to, 1)

    return from, to
end

function getSelection(from, to)
    local code = vim.api.nvim_buf_get_lines(0, from, to, true)
    local ret = ""
    for k, v in ipairs(code) do
        ret = ret .. v .. "\n"
    end

    -- Escape input for shell
    ret = string.gsub(ret, '\\', '\\\\')
    ret = string.gsub(ret, '"', '\\"')
    ret = string.gsub(ret, '`', '\\`')

    return ret
end

function evalBQN(from, to, explain)
    from, to = computeCoords(from, to)
    program = getSelection(from, to)

    local found, bqn = pcall(vim.api.nvim_get_var, "nvim_bqn")
    if not found then
        bqn = "BQN"
    end

    -- NOTE: BQN imports from relative paths only work by setting the
    -- working directory to that of the script. We will set it back
    -- afterwards.
    local origdir = vim.api.nvim_eval("getcwd()")
    local bufdir = vim.fn.expand("%:p:h")

    -- FIXME: Lua's io.popen() does not support reading stderr, nor combining
    -- stdout and stderr to a single stream. Using 2>&1 to combine the streams
    -- in the meantime.
    local cmd = bqn .. " -"
    if explain then
        cmd = "printf \")e " .. program .. "\" | " .. cmd .. "s 2>&1"
    else
        cmd = cmd .. "p \"" .. program .. "\" 2>&1"
    end

    vim.cmd.cd(bufdir)
    local p = assert(io.popen(cmd))
    local output = p:read('*all')
    p:close()
    vim.cmd.cd(origdir)

    local error = nil
    local lines = {}
    for line, lnum in enumerate(output:gmatch("[^\n]+")) do
        if lnum == 1 then
          local message = line:gsub("^Error: (.*)", "%1")
          if message ~= line then
            error = {message=message}
          end
        elseif error ~= nil and not explain then
          -- Check if this line has the line number of the error
          -- The error for the current file looks like: (-p):linenumber:
          local lnum, count = line:gsub("^%(%-p%):(%d+):", "%1")
          if count ~= 0 then
            error.lnum = tonumber(lnum) + from - 1
          end
        end
        local hl = 'bqnoutok'
        if error ~= nil then hl = 'bqnouterr' end

        -- Substitute (-p) with the path of the current buffer
        local local_path_subst_pat = vim.api.nvim_buf_get_name(0) .. ":%1"
        local line_with_current_buf = line:gsub("^%(%-p%):(%d+):", local_path_subst_pat)

        table.insert(lines, {{' ' .. line_with_current_buf, hl}})
    end
    table.insert(lines, {{' ', 'bqnoutok'}})

    -- Reset and show diagnostics
    vim.diagnostic.reset(ns, 0)
    if error ~= nil and error.lnum ~= nil then
      vim.diagnostic.set(ns, 0, {{
        message=error.message,
        lnum=error.lnum,
        col=0,
        severity=vim.diagnostic.severity.ERROR,
        source='BQN',
      }})
    end

    -- Compute `cto` (clear to) position by looking forward from `to` till we
    -- find first non-empty line. We do this so we clear all "orphaned" virtual
    -- line blocks (which correspond to already deleted lines).
    local total_lines = vim.api.nvim_buf_line_count(0)
    local cto = to
    while cto < total_lines do
      local line = vim.api.nvim_buf_get_lines(0, cto, cto + 1, true)[1]
      if #line ~= 0 and line:find("^%s*#") == nil then break end
      cto = cto + 1
    end

    vim.api.nvim_buf_clear_namespace(0, ns, to - 1, cto)
    vim.api.nvim_buf_set_extmark(0, ns, to - 1, 0, {
      virt_lines=lines,
    })

    vim.api.nvim_command("redraw!")
end

return {
    evalBQN = evalBQN,
    clearBQN = clearBQN,
}
