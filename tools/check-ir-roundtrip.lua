-- check-ir-roundtrip: run o5ir over IR text files and compare the result.
--
-- Usage: lua check-ir-roundtrip.lua O5IR FILE.o5ir...
--
-- For each FILE.o5ir, the expected result is the first of these that exists:
--   FILE.refused   o5ir must fail, and print exactly this
--   FILE.expected  o5ir must print exactly this
--   FILE.o5ir      itself: the file is already canonical, so o5ir must print
--                  it unchanged
--
-- Standard Lua cannot list directories, so the Makefile passes the files.

local o5ir = arg[1]
if not o5ir or #arg < 2 then
  io.stderr:write("refused: check-ir-roundtrip: usage: O5IR FILE.o5ir...\n")
  os.exit(1)
end

local function slurp(name)
  local f = io.open(name, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Run o5ir on file; return its combined output and whether it succeeded.
local function run(file)
  local p = io.popen(shellQuote(o5ir) .. " " .. shellQuote(file) .. " 2>&1")
  local out = p:read("a")
  local ok = p:close()
  return out, ok == true
end

-- First line where a and b differ, for the failure report.
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
for i = 2, #arg do
  local file = arg[i]
  local base = file:gsub("%.o5ir$", "")
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

local total = #arg - 1
print(string.format("check-ir-roundtrip: %d cases, %d failed", total, failed))
if failed > 0 then os.exit(1) end
