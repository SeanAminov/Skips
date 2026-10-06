--[[
	StudioHarness — how to run `RunSim.spec.lua` in Studio without leaving anything behind.

	Paste this whole file into an Edit-mode `execute_luau` call (or the command bar) after copying
	the spec into place and letting Rojo sync:

	    cp tests/RunSim.spec.lua src/shared/_Spec.lua    -- then run this, then:
	    rm src/shared/_Spec.lua

	WHY NOT JUST `require(ReplicatedStorage.Shared._Spec)()`. Studio caches a ModuleScript's result
	per instance for the life of the session, and Rojo edits Source in place, so the second run of
	the day tests the first run's code. The old workaround cloned all of `Shared` into a
	`_SpecSandbox` folder and required the clone -- which creates and destroys a folder of scripts in
	the user's place every time. This harness creates NOTHING: `loadstring` compiles each module's
	live Source and a small proxy stands in for `script` and `require`, so every run reads exactly
	what Rojo last synced and the place is never touched.

	It reports two things: whether every shipping source compiles, and only the FAIL lines plus the
	final tally from the suite (the PASS lines run to hundreds).
]]

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SP = game:GetService("StarterPlayer")
local out = {}

-- 1. Every shipping source compiles.
local total, bad = 0, {}
for _, root in { RS:FindFirstChild("Shared"), SSS:FindFirstChild("Server"), SP.StarterPlayerScripts:FindFirstChild("Client") } do
	for _, s in root:GetDescendants() do
		if s:IsA("LuaSourceContainer") and s.Name ~= "_Spec" then
			total += 1
			local fn, err = loadstring(s.Source, "=" .. s.Name)
			if not fn then table.insert(bad, tostring(err)) end
		end
	end
end
table.insert(out, string.format("%d/%d sources compile%s", total - #bad, total,
	if #bad > 0 then ": " .. table.concat(bad, " | ") else ""))

-- 2. A fresh module system over Shared.
local shared = RS:FindFirstChild("Shared")
local cache, realOf, proxyOf = {}, {}, {}
local folderProxy
local baseEnv = getfenv(1)
local function moduleProxy(real)
	local existing = proxyOf[real]
	if existing then return existing end
	local p = setmetatable({}, {
		__index = function(_, k)
			if k == "Parent" then return folderProxy end
			local v = real[k]
			if typeof(v) == "function" then
				return function(_, ...) return v(real, ...) end
			end
			return v
		end,
	})
	proxyOf[real] = p
	realOf[p] = real
	return p
end
local function wrapChild(child)
	if child and child:IsA("ModuleScript") then return moduleProxy(child) end
	return child
end
folderProxy = setmetatable({}, {
	__index = function(_, k)
		if k == "WaitForChild" or k == "FindFirstChild" then
			return function(_, name) return wrapChild(shared:FindFirstChild(name)) end
		elseif k == "GetChildren" then
			return function()
				local list = {}
				for _, c in shared:GetChildren() do table.insert(list, wrapChild(c)) end
				return list
			end
		elseif k == "Name" then
			return shared.Name
		end
		local child = shared:FindFirstChild(k)
		if child then return wrapChild(child) end
		local v = shared[k]
		if typeof(v) == "function" then return function(_, ...) return v(shared, ...) end end
		return v
	end,
})
local shimRequire
shimRequire = function(target)
	local real = realOf[target]
	if real == nil and typeof(target) == "Instance" and target:IsDescendantOf(shared) then
		real = target
	end
	if real then
		local cached = cache[real]
		if cached ~= nil then return cached.value end
		local fn, err = loadstring(real.Source, "=" .. real.Name)
		if not fn then error(err, 2) end
		setfenv(fn, setmetatable({ script = moduleProxy(real), require = shimRequire }, { __index = baseEnv }))
		local value = fn()
		cache[real] = { value = value }
		return value
	end
	return require(target)
end

local okRun, report = pcall(function()
	local spec = shimRequire(shared:FindFirstChild("_Spec"))
	return spec()
end)
if not okRun then
	table.insert(out, "SPEC ERROR: " .. tostring(report))
else
	local keep = {}
	for line in string.gmatch(report, "[^\n]+") do
		if line:find("FAIL") or line:find("^===") then table.insert(keep, line) end
	end
	table.insert(out, table.concat(keep, "\n"))
end
return table.concat(out, "\n")
