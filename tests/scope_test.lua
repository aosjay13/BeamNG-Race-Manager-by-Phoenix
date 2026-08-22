-- Static check: nothing uses a top-level local before it is declared.
--
-- Why this exists: it is the one mistake in these files that compiles perfectly
-- and then fails only when the code actually runs, which in a race mod means it
-- fails in front of a full grid.
--
-- Lua resolves an identifier at COMPILE time. A function body that names
-- something whose `local` appears later in the file does not get an upvalue --
-- it gets a global read, and that global is nil. There is no warning, no load
-- error, and nothing wrong with the file until the moment that line executes:
--
--     local function clearEverything()
--       editorMsg('cleared')          -- nil global: throws when pressed
--     end
--     ...five thousand lines...
--     local function editorMsg(msg) ... end
--
-- Both big files are long enough that "is this declared above me?" is not a
-- question anybody can answer by looking, and it has been got wrong repeatedly:
-- reaching for the derby module from the top of the extension, and for
-- editorMsg from the track-clearing code, both of which are thousands of lines
-- out of order.
--
-- The check is exact rather than heuristic. Any textual use of the name before
-- its declaration line is a global read, because scope in Lua is lexical and
-- runs from the declaration to the end of the block -- it does not matter
-- whether the enclosing function is called before or after the local exists.
--
-- Run from the repo root: lua5.3 tests/scope_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local FILES = {
  'lua/ge/extensions/raceManager.lua',
  'lua/ge/extensions/raceManager/derby.lua',
  'server/RaceManager/main.lua',
}

-- Comments and string literals are stripped first. Without that, a name
-- mentioned in the prose above its own declaration reads as a use of it, and
-- these files carry more comment than code in places.
local function stripped(line)
  local s = line:gsub('%-%-.*$', '')
  s = s:gsub('"[^"]*"', '""')
  s = s:gsub("'[^']*'", "''")
  return s
end

local function scan(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('*a')
  f:close()

  local code = {}
  for line in (src .. '\n'):gmatch('([^\n]*)\n') do
    code[#code + 1] = stripped(line)
  end

  -- TOP-LEVEL declarations only, anchored at column 0. An indented `local` is
  -- inside some function and has its own scope, which this check has no opinion
  -- about: a name shadowed in a nested block is a different question.
  local declAt = {}
  for i, l in ipairs(code) do
    local fn = l:match('^local function ([%w_]+)')
    if fn and not declAt[fn] then declAt[fn] = i end
    local v = l:match('^local ([%w_]+)%s*=')
    if v and not declAt[v] then declAt[v] = i end
  end

  -- Only uses that look like a CALL or a field access (`name(`, `name.`,
  -- `name:`). A bare mention is usually the name being assigned or passed and
  -- is not worth the false positives.
  local bad = {}
  for name, declLine in pairs(declAt) do
    for i = 1, declLine - 1 do
      local l = code[i]
      if l:find('[^%w_%.]' .. name .. '%s*[%(%.:]')
         or l:find('^' .. name .. '%s*[%(%.:]') then
        bad[#bad + 1] = string.format('%s:%d uses "%s", which is declared at line %d',
          path, i, name, declLine)
      end
    end
  end
  return bad
end

for _, path in ipairs(FILES) do
  local bad = scan(path)
  if #bad > 0 then
    for _, line in ipairs(bad) do print('  ' .. line) end
  end
  check(#bad == 0, path .. ' has no use of a top-level local before its '
    .. 'declaration (found ' .. #bad .. '). Each one compiles fine and reads a '
    .. 'nil global at runtime: move the declaration up, or reach the value '
    .. 'through a global RM_* handler, which resolves when it is called')
end

-- The check has to be able to FAIL, or a broken pattern would report every file
-- as clean forever. A file that is wrong on purpose, scanned the same way.
local sample = {
  'local function top()',
  '  helper()',
  'end',
  'local function helper() end',
}
local tmp = os.tmpname()
local w = assert(io.open(tmp, 'w'))
w:write(table.concat(sample, '\n'))
w:close()
local caught = scan(tmp)
os.remove(tmp)
check(#caught == 1, 'the scanner detects a use-before-declaration when there is one '
  .. '(found ' .. #caught .. ')')

print(string.format('scope_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
