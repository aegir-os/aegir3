-- check-golden: run a command on each test file and compare its output with
-- the expected result.
--
-- Usage: lua check-golden.lua NAME COMMAND FILE...
--
-- NAME names the suite in the summary line. COMMAND is a shell command in
-- which {} stands for the test file, for example "build/o5ir {} SEXPR".
--
-- For each FILE.ext, the expected result is the first of these that exists:
--   FILE.refused   the command must fail, and print exactly this
--   FILE.expected  the command must print exactly this
--   FILE.ext       the file itself, for files already in canonical form
--
-- Standard Lua cannot list directories, so the Makefile passes the files.

local name, command = arg[1], arg[2]
if not command or #arg < 3 then
  io.stderr:write("refused: check-golden: usage: NAME COMMAND FILE...\n")
  os.exit(1)
end

local function slurp(file)
  local f = io.open(file, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Run the command on file; return its combined output and whether it
-- succeeded.
local function run(file)
  local cmd = command:gsub("{}", function () return shellQuote(file) end)
  local p = io.popen(cmd .. " 2>&1")
  if not p then return "could not run: " .. cmd, false end
  local out = p:read("a")
  local ok = p:close()
  return out, ok == true
end

-- First line where want and got differ, for the failure report.
local function firstDifference(want, got)
  local n = 1
  local wi, gi = want:gmatch("([^\n]*)\n?"), got:gmatch("([^\n]*)\n?")
  while true do
    local w, g = wi(), gi()
    if w ~= g then
      return n, w or "(end of text)", g or "(end of text)"
    end
    if w == nil then return nil end
    n = n + 1
  end
end

local failed = 0
for i = 3, #arg do
  local file = arg[i]
  local base = file:gsub("%.[^./]+$", "")
  local refused = slurp(base .. ".refused")
  local want = refused or slurp(base .. ".expected") or slurp(file)
  local got, ok = run(file)
  local problem
  if refused and ok then
    problem = "succeeded, but should have been refused"
  elseif not refused and not ok then
    problem = "was refused"
  elseif got ~= want then
    problem = "output differs"
  end
  if problem then
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: %s\n", file, problem))
    local line, w, g = firstDifference(want, got)
    if line then
      io.stderr:write(string.format("  line %d\n  want: %s\n  got:  %s\n", line, w, g))
    end
  end
end

print(string.format("%s: %d cases, %d failed", name, #arg - 2, failed))
if failed > 0 then os.exit(1) end
