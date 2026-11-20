--[[ SVCLUTCHER HUB — universal build
Royale logic restored to original. Battles gets its own logic + Farm.

CHANGELOG
- Auto game detection (place id -> name -> workspace heuristics)
- Battles only: Farm tab, Slap Farm, glove auto-equip, direct-snap teleports,
  Noclip, Anti-AFK
- Royale: original glove handling, original pressF, original priority/early
  auto collect, early bus jump restored
- Royale-only UI hidden in Battles; Farm hidden in Royale
- ESP + Item ESP + hitbox: neon green hacker theme
- Velocity speed: full power, safer profile
- Battles Farm: ground-locked slap farm (no far TPs, no run-drag, no ground clip)
- Slap Aura: fixed 3 hits/sec with drift compensation
]]

local Services = {
	Players = game:GetService("Players"),
	RunService = game:GetService("RunService"),
	TweenService = game:GetService("TweenService"),
	UserInputService = game:GetService("UserInputService"),
	MarketplaceService = game:GetService("MarketplaceService"),
	ContextActionService = game:GetService("ContextActionService"),
	ReplicatedStorage = game:GetService("ReplicatedStorage"),
	TeleportService = game:GetService("TeleportService"),
	GuiService = game:GetService("GuiService"),
	ProximityPromptService = game:GetService("ProximityPromptService"),
	HttpService = game:GetService("HttpService"),
	VirtualUser = game:GetService("VirtualUser"),
	VirtualInputManager = game:GetService("VirtualInputManager"),
}

local Players = Services.Players
local RunService = Services.RunService
local TweenService = Services.TweenService
local UserInputService = Services.UserInputService
local MarketplaceService = Services.MarketplaceService
local ContextActionService = Services.ContextActionService
local ReplicatedStorage = Services.ReplicatedStorage
local ProximityPromptService = Services.ProximityPromptService
local HttpService = Services.HttpService
local VirtualInputManager = Services.VirtualInputManager
local player = Players.LocalPlayer

--=====================================================================
-- MODE
--=====================================================================
local Game = { Mode = "battles", IsRoyale = false, IsBattles = true, Label = "SLAP BATTLES" }
local ROYALE_PLACES = { [9426795465] = true }
local BATTLES_PLACES = { [6403373529] = true }

local function detectMode()
	local placeId = game.PlaceId
	if ROYALE_PLACES[placeId] then return "royale" end
	if BATTLES_PLACES[placeId] then return "battles" end
	local ok, info = pcall(function() return MarketplaceService:GetProductInfo(placeId) end)
	local name = ok and type(info) == "table" and tostring(info.Name or "") or ""
	local lower = string.lower(name)
	if string.find(lower, "royale", 1, true) then return "royale" end
	if string.find(lower, "slap battle", 1, true) then return "battles" end
	if workspace:FindFirstChild("Shipments") or workspace:FindFirstChild("Items") then return "royale" end
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats and leaderstats:FindFirstChild("Slaps") then return "battles" end
	return "battles"
end

Game.Mode = detectMode()
Game.IsRoyale = Game.Mode == "royale"
Game.IsBattles = not Game.IsRoyale
Game.Label = Game.IsRoyale and "SLAP ROYALE" or "SLAP BATTLES"

--=====================================================================
-- NET
--=====================================================================
local Net = {
	SlapRemote = nil, LastRemoteScan = 0, RemoteMissing = false, Queue = {}, QueueCount = 0,
	LastPartFire = {}, LastPruneAt = 0, Tokens = 10, Capacity = 10, RefillRate = 55,
	MaxDrainPerTick = 3, SamePartGap = 0.03, MaxVelocity = 520, SettleFrames = 2,
	RespawnGrace = 0.6, LastSpawnAt = -math.huge, HumanoidDefaults = nil,
	Stats = { Fired = 0, Dropped = 0, Teleports = 0 },
}

function Net.GetSlapRemote()
	if Net.SlapRemote and Net.SlapRemote.Parent then return Net.SlapRemote end
	if Net.RemoteMissing and os.clock() - Net.LastRemoteScan < 10 then return nil end
	if os.clock() - Net.LastRemoteScan < 3 then return nil end
	Net.LastRemoteScan = os.clock()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local direct = remotes and remotes:FindFirstChild("Slap")
	if direct and direct:IsA("RemoteEvent") then Net.SlapRemote = direct return direct end
	for _, object in ipairs(ReplicatedStorage:GetDescendants()) do
		if object:IsA("RemoteEvent") and string.find(string.lower(object.Name), "slap", 1, true) then
			Net.SlapRemote = object
			return object
		end
	end
	Net.RemoteMissing = true
	return nil
end

function Net.CaptureHumanoid(humanoid)
	if not humanoid then return end
	Net.HumanoidDefaults = {
		WalkSpeed = humanoid.WalkSpeed, JumpPower = humanoid.JumpPower,
		JumpHeight = humanoid.JumpHeight, AutoRotate = humanoid.AutoRotate,
	}
end

function Net.QueueSlap(target)
	if not target or not target.Parent then return false end
	local now = os.clock()
	local last = Net.LastPartFire[target]
	if last and now - last < Net.SamePartGap then Net.Stats.Dropped += 1 return false end
	if Net.QueueCount >= 64 then Net.Stats.Dropped += 1 return false end
	Net.LastPartFire[target] = now
	Net.QueueCount += 1
	table.insert(Net.Queue, target)
	return true
end

function Net.FireSlap(target)
	local remote = Net.GetSlapRemote()
	if not remote then return false end
	Net.Stats.Fired += 1
	return pcall(function() remote:FireServer(target) end)
end

RunService.Heartbeat:Connect(function(dt)
	Net.Tokens = math.min(Net.Capacity, Net.Tokens + Net.RefillRate * dt)
	if os.clock() - Net.LastPruneAt > 1 then
		Net.LastPruneAt = os.clock()
		local cutoff = os.clock() - 2
		for part, at in pairs(Net.LastPartFire) do
			if at < cutoff then Net.LastPartFire[part] = nil end
		end
	end
	if Net.QueueCount == 0 then return end
	local drained = 0
	while Net.QueueCount > 0 and Net.Tokens >= 1 and drained < Net.MaxDrainPerTick do
		local target = table.remove(Net.Queue, 1)
		Net.QueueCount -= 1
		drained += 1
		Net.Tokens -= 1
		if target and target.Parent then Net.FireSlap(target) end
	end
end)

function Net.Teleport(root, cframe, lookAt)
	if not root or not root.Parent or typeof(cframe) ~= "CFrame" then return false end
	local origin = root.Position
	local target = cframe.Position
	local delta = target - origin
	local distance = delta.Magnitude
	local hops = distance > 1200 and math.clamp(math.ceil(distance / 1200), 2, 4) or 1
	local stepVector = hops > 1 and (delta / hops) or delta
	root.AssemblyAngularVelocity = Vector3.zero
	for index = 1, hops do
		if not root.Parent then return false end
		local point = index == hops and target or (origin + stepVector * index)
		local facing = lookAt or (root.CFrame.Position + root.CFrame.LookVector)
		local flatFacing = Vector3.new(facing.X, point.Y, facing.Z)
		if (flatFacing - point).Magnitude > 0.1 then
			root.CFrame = CFrame.lookAt(point, flatFacing)
		else
			root.CFrame = CFrame.new(point)
		end
		if hops > 1 and index < hops then
			root.AssemblyLinearVelocity = Vector3.zero
			RunService.Heartbeat:Wait()
		end
	end
	local travel = target - origin
	local velocity = travel / (math.max(hops, 1) / 60)
	root.AssemblyLinearVelocity = Vector3.new(
		math.clamp(velocity.X, -Net.MaxVelocity, Net.MaxVelocity),
		math.clamp(velocity.Y, -Net.MaxVelocity, Net.MaxVelocity),
		math.clamp(velocity.Z, -Net.MaxVelocity, Net.MaxVelocity)
	)
	Net.Stats.Teleports += 1
	for _ = 1, Net.SettleFrames do
		if not root.Parent then break end
		RunService.Heartbeat:Wait()
		root.AssemblyLinearVelocity = Vector3.zero
	end
	return true
end

Net.CaptureHumanoid(player.Character and player.Character:FindFirstChildOfClass("Humanoid"))

player.CharacterAdded:Connect(function(character)
	Net.LastSpawnAt = os.clock()
	Net.Queue = {}
	Net.QueueCount = 0
	table.clear(Net.LastPartFire)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid then
		task.delay(0.2, function() Net.CaptureHumanoid(humanoid) end)
	end
end)

--=====================================================================
-- WAIT
--=====================================================================
local Wait = {}

function Wait.Sleep(seconds, keepGoing)
	local deadline = os.clock() + (tonumber(seconds) or 0)
	while os.clock() < deadline do
		if keepGoing and not keepGoing() then return false end
		task.wait(math.clamp(deadline - os.clock(), 0.01, 0.05))
	end
	return true
end

function Wait.For(predicate, timeout, interval)
	local deadline = os.clock() + (tonumber(timeout) or 5)
	local step = interval or 0.05
	while os.clock() < deadline do
		local ok, value = pcall(predicate)
		if ok and value then return value end
		task.wait(step)
	end
	return nil
end

function Wait.ForChild(parent, name, timeout)
	if not parent or not parent.Parent then return nil end
	return Wait.For(function()
		local child = parent:FindFirstChild(name)
		return child and child.Parent and child
	end, timeout or 5)
end

function Wait.ForCharacter(instance, timeout)
	local owner = instance or player
	local found = Wait.For(function()
		local character = owner.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if character and root and root.Parent then return { Character = character, Root = root } end
	end, timeout or 5)
	if not found then return nil, nil end
	local graceLeft = Net.RespawnGrace - (os.clock() - Net.LastSpawnAt)
	if graceLeft > 0 then
		Wait.Sleep(graceLeft, function() return found.Root.Parent ~= nil end)
	end
	if not found.Root.Parent then return nil, nil end
	return found.Character, found.Root
end

--=====================================================================
-- UNDER MAP PLATFORM
--=====================================================================
local UNDER_MAP_PLATFORM_Y = -35
local UNDER_MAP_SAFE_OFFSET = 4
local UNDER_MAP_PLATFORM_SIZE = Vector3.new(12000, 0.2, 12000)
local UnderMapSafetyPlatform = nil

local function isUnderMapSafetyPlatform(object)
	return object:IsA("BasePart") and object.Name == "Part" and object.Transparency >= 1 and object.Anchored
		and math.abs(object.Position.Y - UNDER_MAP_PLATFORM_Y) <= 1
		and object.Size.X >= UNDER_MAP_PLATFORM_SIZE.X * 0.9
		and object.Size.Z >= UNDER_MAP_PLATFORM_SIZE.Z * 0.9
end

local function clearUnderMapSafetyPlatform()
	if UnderMapSafetyPlatform and UnderMapSafetyPlatform.Parent then
		UnderMapSafetyPlatform.CanCollide = false
		UnderMapSafetyPlatform.CanTouch = false
		UnderMapSafetyPlatform.CanQuery = false
	end
	for _, object in ipairs(workspace:GetChildren()) do
		if isUnderMapSafetyPlatform(object) then
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
		end
	end
	UnderMapSafetyPlatform = nil
end

local function ensureUnderMapSafetyPlatform()
	if UnderMapSafetyPlatform and UnderMapSafetyPlatform.Parent then return UnderMapSafetyPlatform end
	for _, object in ipairs(workspace:GetChildren()) do
		if isUnderMapSafetyPlatform(object) then
			UnderMapSafetyPlatform = object
			return object
		end
	end
	local platform = Instance.new("Part")
	platform.Name = "Part"
	platform.Size = UNDER_MAP_PLATFORM_SIZE
	platform.Position = Vector3.new(0, UNDER_MAP_PLATFORM_Y, 0)
	platform.Anchored = true
	platform.CanCollide = false
	platform.CanTouch = false
	platform.CanQuery = false
	platform.Transparency = 1
	platform.Material = Enum.Material.SmoothPlastic
	platform.Parent = workspace
	UnderMapSafetyPlatform = platform
	return platform
end

--=====================================================================
-- ENV / LIB / NOTIFY
--=====================================================================
local sharedEnvironment = nil
do
	local success, environment = pcall(function() return type(getgenv) == "function" and getgenv() or nil end)
	if success and type(environment) == "table" then
		sharedEnvironment = environment
		if type(sharedEnvironment.SVCLUTCHER_HUBCleanup) == "function" then pcall(sharedEnvironment.SVCLUTCHER_HUBCleanup) end
		sharedEnvironment.SVCLUTCHER_HUBCleanup = nil
	end
end

clearUnderMapSafetyPlatform()

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Settings = nil
local NotificationsDisabled = false
local Notify = {}

function Notify.Show(title, message, kind, icon, duration, important)
	if NotificationsDisabled then return end
	local payload = {
		Title = tostring(title or "SVCLUTCHER HUB"),
		Content = tostring(message or ""),
		Icon = icon or "bell",
		Duration = duration or (important and 4 or 3),
	}
	local ok = pcall(function()
		if WindUI and type(WindUI.Notify) == "function" then
			WindUI:Notify(payload)
		elseif WindUI and type(WindUI.Notification) == "function" then
			WindUI:Notification(payload)
		end
	end)
	if not ok then pcall(function() warn("[SVCLUTCHER HUB] " .. payload.Title .. ": " .. payload.Content) end) end
end

local createNotification = Notify.Show

local UI = {
	AutoEarlyBusJumpEnabled = false, AutoEarlyBusJumpThread = nil, AutoEarlyBusJumpFiredInBus = false,
	InfiniteJumpEnabled = false, InfiniteJumpConnection = nil, LastAutoEarlyBusJumpAt = 0,
	LastJumpBusSeenAt = 0, JumpBusSearchActive = false, InstantLandEnabled = false,
	SpeedBoostEnabled = false, HideUsernameEnabled = false, ToggleRefs = {}, InputRefs = {},
	NoclipEnabled = false, NoclipConnection = nil, AntiAfkEnabled = false, AntiAfkConnection = nil,
	AutoRejoinEnabled = false, JumpBusExitSent = false, JumpBusTrackedObject = nil,
	LastSlapRoyaleTimerNumber = nil, LastSlapRoyaleTimerZeroAt = -math.huge,
	JumpBusSearchStartedAt = 0, JumpBusTimerSeen = false, BusSearchCache = {}, LastBusSearchAt = 0,
}

local gui = nil
local HubGuiObjects = {}

local function registerHubGui(object)
	if not object then return end
	gui = object
	if not HubGuiObjects[object] then
		HubGuiObjects[object] = true
		if object.Destroying then
			object.Destroying:Connect(function()
				HubGuiObjects[object] = nil
				if gui == object then gui = nil end
			end)
		end
	end
end

local function isHubGuiObject(object)
	if not object then return false end
	if gui and gui.Parent and (object == gui or object:IsDescendantOf(gui)) then return true end
	for hubGui in pairs(HubGuiObjects) do
		if hubGui.Parent and (object == hubGui or object:IsDescendantOf(hubGui)) then return true end
	end
	return false
end

local isTouchDevice = UserInputService.TouchEnabled

local Utility = {}
local Main = {}
local Teleport = {}
local Items = {}
local Combat = {}
local Anti = {}
local Farm = {}
local normalizeName

Teleport.DefaultMaxStrikes = 4
Teleport.DefaultCooldown = 5.0
Teleport.DefaultDebounce = 0.5
Teleport.DefaultPostFLock = 0.2
Teleport.MaxStrikes = Teleport.DefaultMaxStrikes
Teleport.Cooldown = Teleport.DefaultCooldown
Teleport.Debounce = Teleport.DefaultDebounce
Teleport.PostFLock = Teleport.DefaultPostFLock
Teleport.Strikes = 0
Teleport.LockedUntil = 0
Teleport.LastClickAt = 0
Teleport.BlockFUntil = 0
Teleport.StabilityWait = 4
Teleport.LastJumpAt = 0
Teleport.LastRagdolledAt = 0
Teleport.LastBusLandingAt = 0
Teleport.StabilityConnection = nil
Teleport.LastStabilityCheckAt = 0
Teleport.BusTopRidePlatform = nil
Teleport.BusTopRideConnection = nil
Teleport.BusTopRideLastCFrame = nil

Items.SearchCache = {}
Items.SearchChildrenCache = {}
Items.SearchCacheBusy = false
Items.LastSearchCacheAt = 0
Items.SearchCacheCooldown = 60
Items.SearchCacheDirty = true
Items.SearchCacheRootConnections = {}
Items.TeleportDebounce = Teleport.Debounce
Items.AutoPickupTouching = {}
Items.Crates = {}
Items.KnownCrates = {}
Items.CrateWatcherConnections = {}
Items.CratePartCache = {}
Items.CrateFireCache = {}
Items.CrateUsedCache = {}
Items.MovementPaused = false
Items.CollectCratesBusy = false
Items.CollectCratesSlapInterval = 0.06
Items.CollectCratesMaxRuntime = 180
Items.CrateFireCacheInterval = 0.35
Items.CrateUsedCacheInterval = 0.08
Items.FastCollectCratesInterval = 0.08
Items.FastCollectCratesScanInterval = 1.5
Items.CrateAuraInterval = 0.04
Items.AutoCollectCratesStartCooldown = 1
Items.AutoPickupScanInterval = 0.25
Items.FastCollectCratesBoxSize = Vector3.new(20, 20, 20)
Items.AutoHealEnabled = false
Items.AutoSortEnabled = false
Items.AutoPermanentEnabled = false
Items.AutoCollectEnabled = false
Items.EarlyAutoCollectEnabled = false
Items.AutoPickupEnabled = false
Items.FastCollectCratesEnabled = false
Items.CrateAuraEnabled = false
Items.EarlyAutoCollectPauseUntil = 0
Items.EarlyBusFBlockActive = false
Items.BusLandingFBlockActive = false
Items.PermanentCollectStopOrder = { "True Power", "Potion of Strength", "Bull's Essence", "Boba", "Speed Potion" }

--=====================================================================
-- SPEED — full power, safer profile
--=====================================================================
local Speed = {
	Enabled = false, Value = 32, Min = 16, Max = 250, Step = 2,
	Connection = nil, ApplyThread = nil, LastApplied = 0,
	OvershootTolerance = 1.35, Hysteresis = 1.5, AirBlend = 0.45,
}

function Speed.Apply(dt)
	if not Speed.Enabled then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 or not root.Parent then return end
	if Items.MovementPaused or humanoid.PlatformStand then return end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Climbing then
		return
	end
	local direction = humanoid.MoveDirection
	if direction.Magnitude <= 0.01 then return end
	direction = Vector3.new(direction.X, 0, direction.Z).Unit

	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local target = direction * Speed.Value

	if horizontal.Magnitude > Speed.Value * Speed.OvershootTolerance then return end

	local delta = target - horizontal
	if delta.Magnitude <= Speed.Hysteresis then return end

	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local blend = grounded and 1 or Speed.AirBlend

	local nextHorizontal = horizontal + delta * blend
	if nextHorizontal.Magnitude > Speed.Value then
		nextHorizontal = nextHorizontal.Unit * Speed.Value
	end

	root.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
	Speed.LastApplied = os.clock()
end

function Speed.ApplyWalkSpeed()
	if not Speed.Enabled then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	if humanoid.WalkSpeed ~= Speed.Value then humanoid.WalkSpeed = Speed.Value end
end

function Speed.Release()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if Game.IsRoyale then
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local velocity = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
		end
	elseif humanoid and Net.HumanoidDefaults then
		humanoid.WalkSpeed = Net.HumanoidDefaults.WalkSpeed
	end
end

function Speed.SetEnabled(state, silent)
	Speed.Enabled = state == true
	if Speed.Enabled then
		if Game.IsRoyale then
			if not Speed.Connection then Speed.Connection = RunService.RenderStepped:Connect(Speed.Apply) end
		elseif not Speed.ApplyThread then
			Speed.ApplyThread = task.spawn(function()
				while Speed.Enabled do
					Speed.ApplyWalkSpeed()
					task.wait(0.1)
				end
				Speed.ApplyThread = nil
			end)
		end
		if not silent then createNotification("Speed", "Enabled at " .. tostring(Speed.Value) .. ".", "Success") end
	else
		if Speed.Connection then
			Speed.Connection:Disconnect()
			Speed.Connection = nil
		end
		Speed.Release()
		if not silent then createNotification("Speed", "Disabled.") end
	end
end

function Speed.SetValue(value, silent)
	Speed.Value = math.clamp(tonumber(value) or Speed.Value, Speed.Min, Speed.Max)
	if Speed.Enabled and not silent then
		createNotification("Speed", "Set to " .. tostring(math.floor(Speed.Value + 0.5)) .. ".")
	end
end

--=====================================================================
-- TELEPORT CORE
--=====================================================================
Teleport.Locations = {
	{ Name = "Acid", Position = Vector3.new(-113, 14, -625) },
	{ Name = "Barn", Position = Vector3.new(477, 87, 318) },
	{ Name = "Beach", Position = Vector3.new(-463, 13, -702) },
	{ Name = "Bob Cave", Position = Vector3.new(315, 49, -576) },
	{ Name = "Bone Pit", Position = Vector3.new(-344, -150, -414) },
	{ Name = "Bunker", Position = Vector3.new(464, 29, 323) },
	{ Name = "Crystal", Position = Vector3.new(488, -50, -272) },
	{ Name = "Forest", Position = Vector3.new(7, 18, 4) },
	{ Name = "Lighthouse", Position = Vector3.new(113, 14, -625) },
	{ Name = "Saloon", Position = Vector3.new(-576, 17, -188) },
	{ Name = "School", Position = Vector3.new(494, 47, -322) },
	{ Name = "Shop", Position = Vector3.new(-575, 13, -481) },
	{ Name = "Towers", Position = Vector3.new(-31, 93, 428) },
	{ Name = "Tunnels", Position = Vector3.new(-561, -35, -234) },
	{ Name = "Volcano", Position = Vector3.new(-304, -26, 379) },
	{ Name = "Watch Tower", Position = Vector3.new(78, 124, 101) },
}

function Utility.NormalizeName(text) return string.lower(tostring(text):gsub("’", "'")) end
normalizeName = Utility.NormalizeName

local function findPartByKeyword(keyword)
	for _, object in ipairs(workspace:GetDescendants()) do
		if object:IsA("BasePart") and string.find(string.lower(object.Name), keyword, 1, true) then
			return object
		end
	end
	return nil
end

function Teleport.GetLocations()
	if Game.IsRoyale then return Teleport.Locations end
	local list = {}
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	local base = spawn and spawn.Position or Vector3.new(0, 20, 0)
	table.insert(list, { Name = "Spawn", Position = base })
	local dummyPart = findPartByKeyword("dummy")
	if dummyPart then table.insert(list, { Name = "Dummies", Position = dummyPart.Position }) end
	local portal = findPartByKeyword("royale") or findPartByKeyword("portal")
	if portal then table.insert(list, { Name = "Portals", Position = portal.Position }) end
	local arena = findPartByKeyword("duel") or findPartByKeyword("arena")
	if arena then table.insert(list, { Name = "Arena", Position = arena.Position }) end
	return list
end

function Teleport.GetCooldownLeft() return math.max(0, math.ceil(Teleport.LockedUntil - os.clock())) end
function Teleport.IsLocked() return os.clock() < Teleport.LockedUntil end

function Teleport.ResetStrikesIfReady()
	local lastClickAt = tonumber(Teleport.LastClickAt) or 0
	local cooldown = tonumber(Teleport.Cooldown) or 0
	if lastClickAt == 0 or os.clock() - lastClickAt >= cooldown then
		Teleport.Strikes = 0
		Teleport.LockedUntil = 0
	end
end

function Teleport.ShowWarning(secondsText)
	Notify.Show("Cooldown", "Wait " .. secondsText .. " before teleporting again.", "Warning", nil, 2.2, true)
end

function Teleport.ShowStabilityWarning(reason, secondsLeft)
	Notify.Show("Teleport", reason .. " Wait " .. tostring(math.max(1, math.ceil(secondsLeft))) .. " seconds.", "Warning", nil, 2.2, true)
end

function Teleport.IsLocalRagdolled(character, humanoid)
	if not character or not humanoid then return false end
	local statuses = { "Ragdoll", "Ragdolled", "IsRagdolled", "Knocked", "KnockedDown", "Downed" }
	for _, statusName in ipairs(statuses) do
		if character:GetAttribute(statusName) == true or humanoid:GetAttribute(statusName) == true then return true end
		local statusObject = character:FindFirstChild(statusName, true) or humanoid:FindFirstChild(statusName, true)
		if statusObject then
			if statusObject:IsA("BoolValue") then
				if statusObject.Value == true then return true end
			else
				return true
			end
		end
	end
	local state = humanoid:GetState()
	return humanoid.PlatformStand or state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown
end

function Teleport.UpdateLocalStability()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local now = os.clock()
	if not humanoid or not root or humanoid.Health <= 0 then
		Teleport.LastRagdolledAt = now
		return
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then Teleport.LastJumpAt = now end
	if Teleport.IsLocalRagdolled(character, humanoid) then Teleport.LastRagdolledAt = now end
end

function Teleport.StartStabilityWatcher()
	if Teleport.StabilityConnection then return end
	Teleport.StabilityConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - Teleport.LastStabilityCheckAt < 0.3 then return end
		Teleport.LastStabilityCheckAt = now
		Teleport.UpdateLocalStability()
	end)
end

function Teleport.CanPassStabilityGate()
	if Game.IsBattles then return true end
	local now = os.clock()
	local waitTime = Teleport.StabilityWait or 4
	local jumpLeft = waitTime - (now - (Teleport.LastJumpAt or 0))
	if jumpLeft > 0 then
		Teleport.ShowStabilityWarning("Wait after jumping before teleporting.", jumpLeft)
		return false
	end
	local ragdollLeft = waitTime - (now - (Teleport.LastRagdolledAt or now))
	if ragdollLeft > 0 then
		Teleport.ShowStabilityWarning("Recover from ragdoll before teleporting.", ragdollLeft)
		return false
	end
	local busLeft = waitTime - (now - (Teleport.LastBusLandingAt or 0))
	if busLeft > 0 then
		Teleport.ShowStabilityWarning("Wait after landing from the bus.", busLeft)
		return false
	end
	return true
end

function Teleport.GetWaitBeforeTeleport(debounceOverride)
	local now = os.clock()
	if Teleport.IsLocked() then return math.max(0, Teleport.LockedUntil - now) end
	local debounce = tonumber(debounceOverride or Teleport.Debounce) or 0
	local lastClickAt = tonumber(Teleport.LastClickAt) or 0
	if lastClickAt ~= 0 then return math.max(0, debounce - (now - lastClickAt)) end
	return 0
end

function Teleport.CanTeleport(debounceOverride, ignoreStability, silent)
	if not ignoreStability and not Teleport.CanPassStabilityGate() then return false end
	if Teleport.IsLocked() then
		if not silent then Teleport.ShowWarning(tostring(Teleport.GetCooldownLeft())) end
		return false
	end
	local now = os.clock()
	local debounce = tonumber(debounceOverride or Teleport.Debounce) or 0
	local lastClickAt = tonumber(Teleport.LastClickAt) or 0
	local debounceLeft = debounce - (now - lastClickAt)
	if lastClickAt ~= 0 and debounceLeft > 0 then
		if not silent then Teleport.ShowWarning(tostring(math.max(1, math.ceil(debounceLeft)))) end
		return false
	end
	Teleport.ResetStrikesIfReady()
	return true
end

if Game.IsRoyale then Teleport.StartStabilityWatcher() end

function Teleport.AddStrike()
	Teleport.LastClickAt = os.clock()
	Teleport.Strikes += 1
	if Teleport.Strikes >= Teleport.MaxStrikes then
		Teleport.LockedUntil = os.clock() + Teleport.Cooldown
		Teleport.Strikes = 0
	end
end

function Teleport.AddFixedStrike(maxStrikes, cooldown)
	Teleport.LastClickAt = os.clock()
	Teleport.Strikes += 1
	if Teleport.Strikes >= (maxStrikes or Teleport.DefaultMaxStrikes) then
		Teleport.LockedUntil = os.clock() + (cooldown or Teleport.DefaultCooldown)
		Teleport.Strikes = 0
	end
end

function Teleport.RefreshPickupLock()
	if not Game.IsRoyale then return end
	local unlockAt = Teleport.BlockFUntil
	pcall(function() ProximityPromptService.Enabled = false end)
	task.delay(math.max(0.05, unlockAt - os.clock()), function()
		if Teleport.BlockFUntil <= unlockAt + 0.02 then
			pcall(function() ProximityPromptService.Enabled = true end)
		end
	end)
end

function Teleport.StartFBlock(duration)
	local fLock = Teleport.GetCustomFLockDuration and Teleport.GetCustomFLockDuration(duration) or (duration or Teleport.PostFLock)
	Teleport.BlockFUntil = math.max(Teleport.BlockFUntil or 0, os.clock() + fLock)
	Teleport.RefreshPickupLock()
end

function Teleport.StartBusLandingFBlock(duration)
	local now = os.clock()
	local fLock = Teleport.GetCustomFLockDuration and Teleport.GetCustomFLockDuration(duration or 10) or (duration or 10)
	local unlockAt = now + fLock
	Teleport.BlockFUntil = math.max(Teleport.BlockFUntil or 0, unlockAt)
	Items.BusLandingFBlockActive = true
	Teleport.RefreshPickupLock()
	task.delay(math.max(0.05, unlockAt - os.clock()), function()
		if Teleport.BlockFUntil <= unlockAt + 0.02 then Items.BusLandingFBlockActive = false end
	end)
end

function Teleport.ShowFBlockedWarning()
	local secondsLeft = math.max(0.1, Teleport.BlockFUntil - os.clock())
	Notify.Show("Cooldown", "Wait " .. string.format("%.1f", secondsLeft) .. "s before pressing F again.", "Warning", nil, 1.4, true)
end

function Teleport.MoveRoot(root, targetCFrame, lookAtPosition)
	if not root or not root.Parent or typeof(targetCFrame) ~= "CFrame" then return false end
	return Net.Teleport(root, targetCFrame, lookAtPosition)
end

function Teleport.StabilizeItemView(root, itemPart)
	if not root or not root.Parent or not itemPart or not itemPart.Parent then return end
	local camera = workspace.CurrentCamera
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if not camera then return end
	local focus = itemPart.Position + Vector3.new(0, 0.8, 0)
	local ignore = { character, itemPart }
	if itemPart.Parent then table.insert(ignore, itemPart.Parent) end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignore
	local function clear(position)
		local parts = workspace:GetPartBoundsInBox(CFrame.new(position), Vector3.new(1.6, 1.6, 1.6), rayParams)
		for _, part in ipairs(parts) do
			if part:IsA("BasePart") and part.CanCollide and part.Transparency < 0.95 then return false end
		end
		local head = root.Position + Vector3.new(0, 2.5, 0)
		local hit = workspace:Raycast(head, position - head, rayParams)
		if hit and hit.Instance and hit.Instance.CanCollide and hit.Instance.Transparency < 0.95 then return false end
		return true
	end
	local candidates = {
		root.Position + Vector3.new(0, 13, 0),
		root.Position + root.CFrame.LookVector * 2 + Vector3.new(0, 10, 0),
		root.Position - root.CFrame.LookVector * 10 + Vector3.new(0, 4, 0),
		root.Position + root.CFrame.RightVector * 8 + Vector3.new(0, 5, 0),
	}
	local chosen = candidates[3]
	for _, position in ipairs(candidates) do
		if clear(position) then
			chosen = position
			break
		end
	end
	if humanoid then camera.CameraSubject = humanoid end
	camera.CameraType = Enum.CameraType.Custom
	camera.CFrame = CFrame.lookAt(chosen, focus)
end

function Teleport.GetGroundCFrame(position, excludeInstances, stayClose)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeInstances or {}
	local offsets = stayClose and {
		Vector3.zero, Vector3.new(2, 0, 0), Vector3.new(-2, 0, 0), Vector3.new(0, 0, 2), Vector3.new(0, 0, -2),
	} or {
		Vector3.zero, Vector3.new(6, 0, 0), Vector3.new(-6, 0, 0), Vector3.new(0, 0, 6), Vector3.new(0, 0, -6),
		Vector3.new(8, 0, 8), Vector3.new(-8, 0, 8), Vector3.new(8, 0, -8), Vector3.new(-8, 0, -8),
	}
	for _, offset in ipairs(offsets) do
		local result = workspace:Raycast(position + offset + Vector3.new(0, 6, 0), Vector3.new(0, -90, 0), params)
		local candidate = result and (result.Position + Vector3.new(0, 4, 0)) or (position + offset + Vector3.new(0, 4, 0))
		local touching = workspace:GetPartBoundsInBox(CFrame.new(candidate + Vector3.new(0, 2, 0)), Vector3.new(4, 5, 4), params)
		local blocked = false
		for _, part in ipairs(touching) do
			if part.CanCollide and part.Transparency < 0.95 then
				blocked = true
				break
			end
		end
		if not blocked then return CFrame.new(candidate) end
	end
	return CFrame.new(position + Vector3.new(0, 4, 0))
end

function Teleport.GetItemCFrame(itemPart, excludeInstances)
	local position = itemPart.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeInstances or {}
	local offsets = {
		Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
		Vector3.new(2, 0, 0), Vector3.new(-2, 0, 0), Vector3.new(0, 0, 2), Vector3.new(0, 0, -2),
	}
	for _, offset in ipairs(offsets) do
		local result = workspace:Raycast(position + offset + Vector3.new(0, 4, 0), Vector3.new(0, -35, 0), params)
		if result and math.abs(result.Position.Y - position.Y) <= 16 then
			local candidate = result.Position + Vector3.new(0, 4, 0)
			local touching = workspace:GetPartBoundsInBox(CFrame.new(candidate + Vector3.new(0, 1.8, 0)), Vector3.new(2.8, 4.4, 2.8), params)
			local blocked = false
			for _, part in ipairs(touching) do
				if part ~= itemPart and part.CanCollide and part.Transparency < 0.95 then
					blocked = true
					break
				end
			end
			if not blocked then return CFrame.new(candidate) end
		end
	end
	return CFrame.new(position + Vector3.new(0, 4, 0))
end

function Teleport.ToLocation(locationName, position, forceTeleport)
	if forceTeleport then
		Teleport.LockedUntil = 0
		Teleport.LastClickAt = 0
		Teleport.Strikes = 0
	elseif not Teleport.CanTeleport() then
		return
	end
	if typeof(position) == "CFrame" then position = position.Position end
	if typeof(position) ~= "Vector3" then
		for _, location in ipairs(Teleport.GetLocations()) do
			if location.Name == locationName then
				position = location.Position
				break
			end
		end
	end
	if typeof(position) ~= "Vector3" then
		createNotification("Teleport", "Could not find location: " .. tostring(locationName), "Error")
		return
	end
	local character, root = Wait.ForCharacter(player, 6)
	if not character or not root then
		createNotification("Teleport", "Could not find your character.", "Error")
		return
	end
	if Game.IsBattles then
		root.CFrame = CFrame.new(position + Vector3.new(0, 4, 0))
		root.AssemblyLinearVelocity = Vector3.zero
	else
		Teleport.MoveRoot(root, Teleport.GetGroundCFrame(position, { character }))
	end
	if not forceTeleport then
		Teleport.AddStrike()
		Teleport.StartFBlock()
	end
	createNotification("Teleport", "Teleported to " .. locationName)
end

--=====================================================================
-- BUS / LOBBY HIDER
--=====================================================================
function Teleport.GetBusCandidateFromObject(object)
	local current = object
	local candidate = nil
	while current and current ~= workspace do
		local name = Utility.NormalizeName(current.Name)
		if string.find(name, "bus", 1, true) and (current:IsA("Model") or current:IsA("BasePart")) then candidate = current end
		current = current.Parent
	end
	return candidate
end

function Teleport.GetBusParts(candidate)
	local parts = {}
	if not candidate or not candidate.Parent then return parts end
	if candidate:IsA("BasePart") then
		table.insert(parts, candidate)
		return parts
	end
	for _, object in ipairs(candidate:GetDescendants()) do
		if object:IsA("BasePart") then table.insert(parts, object) end
	end
	return parts
end

function Teleport.GetObjectWorldPosition(object)
	if object:IsA("BasePart") then return object.Position end
	if object:IsA("Model") then
		local ok, pivot = pcall(function() return object:GetPivot() end)
		if ok and pivot then return pivot.Position end
	end
	return nil
end

function Teleport.IsSchoolHouseBusCandidate(candidate)
	local position = Teleport.GetObjectWorldPosition(candidate)
	return position and (position - Vector3.new(494, 47, -322)).Magnitude <= 220
end

function Teleport.FindSchoolBusTopTarget()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local seen = {}
	local bestCandidate, bestParts, bestDistance = nil, nil, math.huge
	for _, object in ipairs(workspace:GetDescendants()) do
		local candidate = Teleport.GetBusCandidateFromObject(object)
		if candidate and candidate.Parent and not seen[candidate] and not Teleport.IsSchoolHouseBusCandidate(candidate) then
			seen[candidate] = true
			local parts = Teleport.GetBusParts(candidate)
			local position = Teleport.GetObjectWorldPosition(candidate)
			if #parts > 0 and position then
				local distance = root and (root.Position - position).Magnitude or 0
				if distance < bestDistance then
					bestDistance = distance
					bestCandidate = candidate
					bestParts = parts
				end
			end
		end
	end
	return bestCandidate, bestParts
end

function Teleport.MakeBusCollidable(parts)
	for _, part in ipairs(parts or {}) do
		if part and part.Parent then
			pcall(function()
				part.CanCollide = true
				part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 1, 0, 100, 0)
			end)
		end
	end
end

function Teleport.ClearBusTopRidePlatform()
	if Teleport.BusTopRideConnection then
		Teleport.BusTopRideConnection:Disconnect()
		Teleport.BusTopRideConnection = nil
	end
	if Teleport.BusTopRidePlatform and Teleport.BusTopRidePlatform.Parent then Teleport.BusTopRidePlatform:Destroy() end
	Teleport.BusTopRidePlatform = nil
	Teleport.BusTopRideLastCFrame = nil
end

function Teleport.GetBusTopCFrame(candidate, parts)
	local topPart, topY = nil, -math.huge
	for _, part in ipairs(parts or {}) do
		if part and part.Parent then
			local partTopY = part.Position.Y + (part.Size.Y * 0.5)
			if partTopY > topY then
				topY = partTopY
				topPart = part
			end
		end
	end
	if not topPart then return nil end
	local target = topPart.Position + Vector3.new(0, (topPart.Size.Y * 0.5) + 5, 0)
	local platformPosition = Vector3.new(topPart.Position.X, topY + 0.15, topPart.Position.Z)
	if candidate and candidate:IsA("Model") then
		local ok, boxCFrame, boxSize = pcall(function() return candidate:GetBoundingBox() end)
		if ok and boxCFrame and boxSize then
			target = Vector3.new(boxCFrame.Position.X, boxCFrame.Position.Y + (boxSize.Y * 0.5) + 5, boxCFrame.Position.Z)
			platformPosition = Vector3.new(boxCFrame.Position.X, boxCFrame.Position.Y + (boxSize.Y * 0.5) + 0.15, boxCFrame.Position.Z)
		end
	end
	return CFrame.new(target), CFrame.new(platformPosition), topPart
end

function Teleport.IsRootOnBusTopRide(root, platformCFrame)
	if not root or not platformCFrame then return false end
	local localPosition = platformCFrame:PointToObjectSpace(root.Position)
	return math.abs(localPosition.X) <= 18 and math.abs(localPosition.Z) <= 18
		and localPosition.Y >= -4 and localPosition.Y <= 12
end

function Teleport.CreateBusTopRidePlatform(candidate, parts, platformCFrame, topPart)
	Teleport.ClearBusTopRidePlatform()
	if not platformCFrame then return end
	local platform = Instance.new("Part")
	platform.Name = "Part"
	platform.Size = Vector3.new(18, 0.3, 18)
	platform.CFrame = platformCFrame
	platform.Anchored = topPart == nil
	platform.Massless = true
	platform.CanCollide = true
	platform.CanTouch = false
	platform.CanQuery = false
	platform.Transparency = 1
	platform.CustomPhysicalProperties = PhysicalProperties.new(0.7, 1, 0, 100, 0)
	platform.Parent = workspace
	if topPart and topPart.Parent then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = platform
		weld.Part1 = topPart
		weld.Parent = platform
	end
	Teleport.BusTopRidePlatform = platform
	Teleport.BusTopRideLastCFrame = platformCFrame
	Teleport.BusTopRideConnection = RunService.Heartbeat:Connect(function(dt)
		if not platform.Parent or not candidate or not candidate.Parent or (topPart and not topPart.Parent) then
			Teleport.ClearBusTopRidePlatform()
			return
		end
		local _, nextCFrame = Teleport.GetBusTopCFrame(candidate, parts)
		if not nextCFrame then return end
		local lastCFrame = Teleport.BusTopRideLastCFrame or platform.CFrame
		local delta = nextCFrame.Position - lastCFrame.Position
		local horizontalDelta = Vector3.new(delta.X, 0, delta.Z)
		if platform.Anchored then platform.CFrame = nextCFrame end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and Teleport.IsRootOnBusTopRide(root, lastCFrame) and horizontalDelta.Magnitude > 0.001 and horizontalDelta.Magnitude < 80 then
			root.CFrame = root.CFrame + horizontalDelta
			local velocity = root.AssemblyLinearVelocity
			local followDt = math.max(dt or 0, 1 / 240)
			root.AssemblyLinearVelocity = Vector3.new(horizontalDelta.X / followDt, velocity.Y, horizontalDelta.Z / followDt)
		end
		Teleport.BusTopRideLastCFrame = nextCFrame
	end)
end

function Teleport.ToSchoolBusTop()
	if not Teleport.CanTeleport(Teleport.DefaultDebounce) then return end
	local character, root = Wait.ForCharacter(player, 6)
	if not character or not root then
		createNotification("School Bus", "Could not find your character.", "Error")
		return
	end
	local bus, parts = Teleport.FindSchoolBusTopTarget()
	local targetCFrame, platformCFrame, topPart = Teleport.GetBusTopCFrame(bus, parts)
	if not bus or not targetCFrame then
		createNotification("School Bus", "No bus found.", "Warning")
		return
	end
	Teleport.MakeBusCollidable(parts)
	Teleport.CreateBusTopRidePlatform(bus, parts, platformCFrame, topPart)
	UI.SkipNextBusLandingLockUntil = os.clock() + 3
	UI.BusLandingWasInBus = false
	Teleport.MoveRoot(root, targetCFrame)
	Teleport.AddFixedStrike(Teleport.DefaultMaxStrikes, Teleport.DefaultCooldown)
	Teleport.StartFBlock()
	createNotification("School Bus", "Teleported on top of the bus.", "Success")
end

function Teleport.ToLobbyHider()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local lobby = workspace:FindFirstChild("Lobby")
	local ceiling = lobby and lobby:FindFirstChild("Ceiling")
	if not root or not ceiling then
		createNotification("Lobby Hider", "Could not find the lobby ceiling.", "Warning")
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local base = ceiling.Position
	local result = workspace:Raycast(base + Vector3.new(0, 50, 0), Vector3.new(0, -600, 0), params)
	local top = result and (result.Position + Vector3.new(0, 4, 0)) or (base + Vector3.new(0, 50, 0))
	root.CFrame = CFrame.new(top, root.Position + root.CFrame.LookVector)
	createNotification("Lobby Hider", "Hid above the lobby.", "Success")
end

--=====================================================================
-- ITEMS
--=====================================================================
local itemNames = {
	"Apple", "Bandage", "Boba", "Bomb", "Bull's Essence", "Cube of Ice", "First Aid Kit",
	"Forcefield Crystal", "Frog Potion", "Gravitation Shard", "Healing Potion", "Lightning Potion",
	"Potion of Strength", "Speed Potion", "Sphere of Fury", "Tomahawk", "True Power", "Bombs",
}

local autoCollectPriority = {
	"True Power", "Potion of Strength", "Bull's Essence", "Boba", "Speed Potion",
	"Sphere of Fury", "First Aid Kit", "Apple", "Forcefield Crystal", "Lightning Potion",
}

local permanentUseItems = { "Potion of Strength", "Bull's Essence", "Boba", "Speed Potion", "Frog Potion" }
local healingItems = { "First Aid Kit", "Healing Potion", "Apple", "Bandage" }

local function matchesItem(toolName, itemList)
	if not toolName or not itemList then return false end
	local normalized = normalizeName(toolName)
	for _, itemName in ipairs(itemList) do
		if normalized == normalizeName(itemName) then return true end
	end
	return false
end

local itemNameAliases = { ["Bull's Essence"] = { "Bull's essence" }, ["Sphere of Fury"] = { "Sphere of fury" } }

local function strictItemNameMatches(candidateName, wantedName)
	local normalizedCandidate = Utility.NormalizeName(candidateName)
	local normalizedWanted = Utility.NormalizeName(wantedName)
	if candidateName == wantedName or normalizedCandidate == normalizedWanted then return true end
	local aliases = itemNameAliases[wantedName]
	if aliases then
		for _, alias in ipairs(aliases) do
			if candidateName == alias or normalizedCandidate == Utility.NormalizeName(alias) then return true end
		end
	end
	return false
end

function getStrictItemMatchObject(object, wantedName)
	local current = object
	while current and current ~= workspace do
		if strictItemNameMatches(current.Name, wantedName) then return current end
		current = current.Parent
	end
	return nil
end

local function itemNameMatches(object, wantedName) return getStrictItemMatchObject(object, wantedName) ~= nil end

function Items.GetSearchRoot()
	local exactRoot = workspace:FindFirstChild("Items")
	if exactRoot then return exactRoot end
	for _, child in ipairs(workspace:GetChildren()) do
		if string.lower(child.Name) == "items" then return child end
	end
	return nil
end

function Items.RebuildSearchCache()
	if Items.SearchCacheBusy then return end
	Items.SearchCacheBusy = true
	local root = Items.GetSearchRoot()
	if not root then
		Items.SearchCache = {}
		Items.SearchChildrenCache = {}
		Items.LastSearchCacheAt = os.clock()
		Items.SearchCacheDirty = false
		Items.SearchCacheBusy = false
		return
	end
	local children = root:GetChildren()
	local results = {}
	local lookup = Items.SearchNameLookup
	for _, object in ipairs(children) do
		if not lookup or lookup[Utility.NormalizeName(object.Name)] then table.insert(results, object) end
	end
	Items.SearchCache = results
	Items.SearchChildrenCache = children
	Items.LastSearchCacheAt = os.clock()
	Items.SearchCacheDirty = false
	Items.SearchCacheBusy = false
end

function Items.GetSearchDescendants()
	if Items.SearchCacheDirty or os.clock() - Items.LastSearchCacheAt > Items.SearchCacheCooldown then Items.RebuildSearchCache() end
	return Items.SearchCache
end

function Items.GetSearchChildren()
	if Items.SearchCacheDirty or os.clock() - Items.LastSearchCacheAt > Items.SearchCacheCooldown then Items.RebuildSearchCache() end
	return Items.SearchChildrenCache
end

local function getCollectibleSearchPool() return Items.GetSearchChildren() end

local function getLiveItemPart(object)
	if not object or not object.Parent or not object:IsDescendantOf(workspace) then return nil end
	local part = object:IsA("BasePart") and object or object:FindFirstChildWhichIsA("BasePart", true)
	if not part or not part.Parent or not part:IsDescendantOf(workspace) then return nil end
	if part.Transparency >= 0.95 or part.Size.X <= 0 or part.Size.Y <= 0 or part.Size.Z <= 0 then return nil end
	local characterModel = part:FindFirstAncestorOfClass("Model")
	if characterModel and Players:GetPlayerFromCharacter(characterModel) then return nil end
	return part
end

function Items.FindManualItem(itemName)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil, nil end
	local closestObject, closestPart, closestDistance = nil, nil, math.huge
	for _, object in ipairs(getCollectibleSearchPool()) do
		local matchObject = getStrictItemMatchObject(object, itemName)
		if matchObject or strictItemNameMatches(object.Name, itemName) then
			local itemObject = matchObject or object
			local part = getLiveItemPart(itemObject)
			if part then
				local distance = (root.Position - part.Position).Magnitude
				if distance < closestDistance then
					closestDistance = distance
					closestObject = itemObject
					closestPart = part
				end
			end
		end
	end
	return closestObject, closestPart
end

function Items.TeleportTo(itemName)
	if not Teleport.CanTeleport(Items.TeleportDebounce) then return end
	local character, root = Wait.ForCharacter(player, 5)
	if not character or not root then
		createNotification("Items", "Could not find your character.", "Error")
		return
	end
	local itemObject, itemPart = Items.FindManualItem(itemName)
	if not itemObject or not itemPart then
		createNotification("Items", itemName .. " is not available.")
		return
	end
	Wait.Sleep(0.08)
	if not itemObject.Parent or not itemPart.Parent or not itemPart:IsDescendantOf(workspace) or itemPart.Transparency >= 0.95 then
		createNotification("Items", itemName .. " disappeared before teleporting.")
		return
	end
	Teleport.MoveRoot(root, Teleport.GetItemCFrame(itemPart, { character, itemObject }), itemPart.Position)
	Teleport.StabilizeItemView(root, itemPart)
	Teleport.AddStrike()
	Teleport.StartFBlock()
	createNotification("Items", "Teleported to " .. itemName)
end

local movementSave = nil

local function setMovementPaused(paused)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	Items.MovementPaused = paused == true
	if not humanoid then return end
	if paused then
		if not movementSave or movementSave.Character ~= character then
			movementSave = {
				Character = character, WalkSpeed = humanoid.WalkSpeed, JumpPower = humanoid.JumpPower,
				JumpHeight = humanoid.JumpHeight, AutoRotate = humanoid.AutoRotate,
			}
		end
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.AutoRotate = false
	elseif movementSave then
		if movementSave.Character == character then
			humanoid.WalkSpeed = movementSave.WalkSpeed
			humanoid.JumpPower = movementSave.JumpPower
			humanoid.JumpHeight = movementSave.JumpHeight
			humanoid.AutoRotate = movementSave.AutoRotate
		end
		movementSave = nil
	end
end

function Items.GetCratePart(crate)
	if not crate or not crate.Parent or not crate:IsDescendantOf(workspace) then return nil end
	if crate:IsA("BasePart") then
		Items.CratePartCache[crate] = crate
		return crate
	end
	local cached = Items.CratePartCache[crate]
	if cached and cached.Parent and cached:IsDescendantOf(crate) then return cached end
	local part = crate:FindFirstChildWhichIsA("BasePart", true)
	if part then Items.CratePartCache[crate] = part end
	return part
end

function Items.GetShipmentCratesRoot()
	local shipments = workspace:FindFirstChild("Shipments")
	return shipments and shipments:FindFirstChild("Crates")
end

function Items.GetShipmentCrates()
	local cratesRoot = Items.GetShipmentCratesRoot()
	local crates = {}
	if not cratesRoot then return crates end
	for _, object in ipairs(cratesRoot:GetChildren()) do
		if object.Name == "Crate" then table.insert(crates, object) end
	end
	return crates
end

function Items.GetCrateRoot(object)
	local cratesRoot = Items.GetShipmentCratesRoot()
	if cratesRoot and object and object:IsDescendantOf(cratesRoot) then
		local current = object
		while current and current ~= cratesRoot do
			if current.Name == "Crate" and Items.GetCratePart(current) then return current end
			current = current.Parent
		end
	end
	return nil
end

function Items.RefreshCrates()
	local live = {}
	for _, crate in ipairs(Items.Crates) do
		if Items.GetCratePart(crate) then
			table.insert(live, crate)
		else
			Items.KnownCrates[crate] = nil
			Items.CratePartCache[crate] = nil
			Items.CrateFireCache[crate] = nil
			Items.CrateUsedCache[crate] = nil
		end
	end
	Items.Crates = live
end

function Items.TrackCrate(crate)
	local crateRoot = Items.GetCrateRoot(crate)
	if not crateRoot or Items.KnownCrates[crateRoot] then return end
	Items.KnownCrates[crateRoot] = true
	Items.CratePartCache[crateRoot] = Items.GetCratePart(crateRoot)
	table.insert(Items.Crates, crateRoot)
	Items.RefreshCrates()
	table.insert(Items.CrateWatcherConnections, crateRoot.AncestryChanged:Connect(function()
		if not crateRoot.Parent then
			Items.KnownCrates[crateRoot] = nil
			Items.CratePartCache[crateRoot] = nil
			Items.CrateFireCache[crateRoot] = nil
			Items.CrateUsedCache[crateRoot] = nil
		end
		Items.RefreshCrates()
	end))
	if Items.FastCollectCratesEnabled and not Items.CollectCratesBusy then
		task.defer(Items.TryStartAutoCollectCrates)
	end
end

function Items.ClearFastCollectCratesBox()
	if Items.FastCollectCratesBox then
		pcall(function() Items.FastCollectCratesBox:Destroy() end)
		Items.FastCollectCratesBox = nil
	end
end

function Items.UpdateFastCollectCratesBox(root)
	if not Items.FastCollectCratesEnabled or not root or not root.Parent then
		Items.ClearFastCollectCratesBox()
		return
	end
	local box = Items.FastCollectCratesBox
	if not box or not box.Parent then
		box = Instance.new("Part")
		box.Name = "Part"
		box.Anchored = true
		box.CanCollide = false
		box.CanTouch = false
		box.CanQuery = false
		box.Transparency = 1
		box.Color = Color3.fromRGB(0, 255, 70)
		box.Material = Enum.Material.Neon
		box.Parent = workspace
		Items.FastCollectCratesBox = box
	end
	box.Size = Items.FastCollectCratesBoxSize
	box.CFrame = root.CFrame
end

function Items.IsCratePartInFastCollectBox(cratePart, root)
	if not cratePart or not cratePart.Parent or not root or not root.Parent then return false end
	local relative = root.CFrame:PointToObjectSpace(cratePart.Position)
	local half = Items.FastCollectCratesBoxSize / 2
	return math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z
end

function Items.GetTrackedCrateParts(root)
	local parts = {}
	if os.clock() - (Items.FastCollectCratesLastScan or 0) >= Items.FastCollectCratesScanInterval then
		Items.FastCollectCratesLastScan = os.clock()
		Items.ScanCratesNow()
	end
	for _, crate in ipairs(Items.Crates) do
		local part = Items.GetCratePart(crate)
		if part and (not root or Items.IsCratePartInFastCollectBox(part, root)) then
			table.insert(parts, part)
		end
	end
	return parts
end

function Items.StartFastCollectCrates()
	if Items.FastCollectCratesThread then return end
	Items.FastCollectCratesThread = task.spawn(function()
		while Items.FastCollectCratesEnabled do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			Items.UpdateFastCollectCratesBox(root)
			if not Items.CollectCratesBusy then
				for _, cratePart in ipairs(Items.GetTrackedCrateParts(root)) do
					if not Items.FastCollectCratesEnabled then break end
					Items.SlapCrate(cratePart)
				end
			end
			task.wait(Items.FastCollectCratesInterval)
		end
		Items.FastCollectCratesThread = nil
	end)
end

function Items.SetFastCollectCrates(state, silent)
	Items.FastCollectCratesEnabled = state == true
	if Items.FastCollectCratesEnabled then
		Items.StartCrateWatcher()
		Items.StartFastCollectCrates()
		if not silent then createNotification("Auto collect crates", "Enabled.", "Success") end
	else
		Items.ClearFastCollectCratesBox()
		if not silent then createNotification("Auto collect crates", "Disabled.") end
	end
end

function Items.StartCrateAura()
	if Items.CrateAuraThread then return end
	Items.CrateAuraThread = task.spawn(function()
		while Items.CrateAuraEnabled do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				for _, cratePart in ipairs(Items.GetTrackedCrateParts(root)) do
					if not Items.CrateAuraEnabled then break end
					Items.SlapCrate(cratePart)
				end
			end
			task.wait(Items.CrateAuraInterval)
		end
		Items.CrateAuraThread = nil
	end)
end

function Items.SetCrateAura(state, silent)
	Items.CrateAuraEnabled = state == true
	if Items.CrateAuraEnabled then
		Items.StartCrateWatcher()
		Items.StartCrateAura()
		if not silent then createNotification("Crate Aura", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Crate Aura", "Disabled.")
	end
end

function Items.FindNearestCrate()
	Items.ScanCratesNow()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local nearest, nearestPart, nearestDistance = nil, nil, math.huge
	for _, crate in ipairs(Items.Crates) do
		local part = Items.GetCratePart(crate)
		if part then
			local distance = root and (root.Position - part.Position).Magnitude or 0
			if distance < nearestDistance then
				nearestDistance = distance
				nearest = crate
				nearestPart = part
			end
		end
	end
	return nearest, nearestPart
end

function Items.TeleportToCrate()
	if not Teleport.CanTeleport(Items.TeleportDebounce) then return end
	local character, root = Wait.ForCharacter(player, 5)
	if not character or not root then return end
	local crate, part = Items.FindNearestCrate()
	if not crate or not part then return end
	Teleport.MoveRoot(root, CFrame.new(part.Position + Vector3.new(0, (part.Size.Y / 2) + 4, 0)))
	Teleport.AddStrike()
	Teleport.StartFBlock()
end

function Items.ClearCrateCollectPart()
	if Items.CrateCollectPart then
		pcall(function() Items.CrateCollectPart:Destroy() end)
		Items.CrateCollectPart = nil
	end
end

function Items.GetCrateUnderMapCFrame(crate, cratePart)
	local centerPosition = cratePart.Position
	local bottomY = cratePart.Position.Y - (cratePart.Size.Y / 2)
	if crate and crate:IsA("Model") then
		local ok, modelCFrame, modelSize = pcall(function() return crate:GetBoundingBox() end)
		if ok and modelCFrame and modelSize then
			centerPosition = modelCFrame.Position
			bottomY = modelCFrame.Position.Y - (modelSize.Y / 2)
		end
	elseif crate and crate:IsA("BasePart") then
		centerPosition = crate.Position
		bottomY = crate.Position.Y - (crate.Size.Y / 2)
	end
	return CFrame.new(Vector3.new(centerPosition.X, bottomY - 4, centerPosition.Z), cratePart.Position)
end

function Items.EnsureCrateCollectPart(targetCFrame)
	Items.ClearCrateCollectPart()
	local part = Instance.new("Part")
	part.Name = "Part"
	part.Size = Vector3.new(64, 6, 64)
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.CFrame = CFrame.new(targetCFrame.Position - Vector3.new(0, 6, 0))
	part.Parent = workspace
	Items.CrateCollectPart = part
	return part
end

function Items.IsCrateUsedUp(crate)
	if not crate or not crate.Parent or not crate:IsDescendantOf(workspace) then return true end
	local now = os.clock()
	local cached = Items.CrateUsedCache[crate]
	if cached and now - cached.At < Items.CrateUsedCacheInterval then return cached.Value end
	local usedUp = false
	local durability = crate:GetAttribute("Durability") or crate:GetAttribute("Health") or crate:GetAttribute("HP")
	if type(durability) == "number" and durability <= 0 then usedUp = true end
	if not usedUp then
		local found = false
		for _, object in ipairs(crate:GetDescendants()) do
			if object:IsA("BasePart") and object.Parent and object.Size.X > 0 then
				found = true
				break
			end
		end
		usedUp = not found
	end
	Items.CrateUsedCache[crate] = { At = now, Value = usedUp }
	return usedUp
end

function Items.GetCrateCollectTargets()
	Items.ScanCratesNow()
	local targets, seen = {}, {}
	for _, crate in ipairs(Items.GetShipmentCrates()) do
		if crate and crate.Parent and not seen[crate] then
			seen[crate] = true
			table.insert(targets, crate)
		end
	end
	for _, crate in ipairs(Items.Crates) do
		if crate and crate.Parent and not seen[crate] and Items.GetCratePart(crate) then
			seen[crate] = true
			table.insert(targets, crate)
		end
	end
	return targets
end

function Items.GetReadyCrateTarget()
	local liveCount = 0
	for _, crate in ipairs(Items.GetCrateCollectTargets()) do
		if crate and not Items.IsCrateUsedUp(crate) then
			liveCount += 1
			if not Items.CrateHasActiveFire(crate) then return crate, liveCount end
		end
	end
	return nil, liveCount
end

function Items.GetFirstLiveCrateTarget()
	for _, crate in ipairs(Items.GetCrateCollectTargets()) do
		if crate and crate.Parent and Items.GetCratePart(crate) then return crate end
	end
	return nil
end

function Items.TeleportUnderCrate(crate)
	if not crate or not crate.Parent then return false end
	local character, root = Wait.ForCharacter(player, 5)
	local part = Items.GetCratePart(crate)
	if not character or not root or not part then return false end
	local targetCFrame = Items.GetCrateUnderMapCFrame(crate, part)
	Items.EnsureCrateCollectPart(targetCFrame)
	Teleport.MoveRoot(root, targetCFrame, part.Position)
	return true
end

function Items.HasLiveCrateTargets()
	for _, crate in ipairs(Items.GetCrateCollectTargets()) do
		if crate and not Items.IsCrateUsedUp(crate) then return true end
	end
	return false
end

function Items.TryStartAutoCollectCrates()
	if not Items.FastCollectCratesEnabled or Items.CollectCratesBusy then return false end
	local now = os.clock()
	if now - (Items.AutoCollectCratesLastStart or 0) < Items.AutoCollectCratesStartCooldown then return false end
	if not Items.HasLiveCrateTargets() then return false end
	Items.AutoCollectCratesLastStart = now
	task.delay(0.2, function()
		if Items.FastCollectCratesEnabled and not Items.CollectCratesBusy then Items.CollectCrates() end
	end)
	return true
end

function Items.IsActiveCrateFireObject(object)
	if not object then return false end
	local name = Utility.NormalizeName(object.Name)
	if object:IsA("Fire") and object.Enabled ~= false then return true end
	if object:IsA("ParticleEmitter") and object.Enabled ~= false then
		return string.find(name, "fire") or string.find(name, "flame") or string.find(name, "burn")
	end
	return false
end

function Items.CrateHasActiveFire(crate)
	if not crate or not crate.Parent then return false end
	local now = os.clock()
	local cached = Items.CrateFireCache[crate]
	if cached and now - cached.At < Items.CrateFireCacheInterval then return cached.Value end
	local hasFire = Items.IsActiveCrateFireObject(crate)
	if not hasFire then
		for _, object in ipairs(crate:GetDescendants()) do
			if Items.IsActiveCrateFireObject(object) then
				hasFire = true
				break
			end
		end
	end
	Items.CrateFireCache[crate] = { At = now, Value = hasFire }
	return hasFire
end

function Items.SlapCrate(cratePart)
	if not cratePart or not cratePart.Parent then return false end
	local crateRoot = Items.GetCrateRoot(cratePart) or cratePart
	if Items.CrateHasActiveFire(crateRoot) or Items.CrateHasActiveFire(cratePart) then return false end
	if not Net.QueueSlap(cratePart) then return false end
	local now = os.clock()
	if now - (Items.LastCrateActivateAt or 0) > 0.12 then
		Items.LastCrateActivateAt = now
		local tool = Combat.GetEquippedTool and Combat.GetEquippedTool()
		if tool then pcall(function() tool:Activate() end) end
	end
	return true
end

function Items.ScanCratesNow()
	local root = Items.GetShipmentCratesRoot()
	if not root then return end
	for _, object in ipairs(root:GetChildren()) do
		if object.Name == "Crate" then Items.TrackCrate(object) end
	end
	Items.RefreshCrates()
end

function Items.ClearCrateWatcher()
	for _, connection in ipairs(Items.CrateWatcherConnections) do
		pcall(function() connection:Disconnect() end)
	end
	Items.CrateWatcherConnections = {}
	Items.Crates = {}
	Items.KnownCrates = {}
	Items.CrateWatcherStarted = false
end

function Items.StartCrateWatcher()
	if not Game.IsRoyale or Items.CrateWatcherStarted then return end
	local root = Items.GetShipmentCratesRoot()
	if not root then return end
	Items.CrateWatcherStarted = true
	table.insert(Items.CrateWatcherConnections, root.ChildAdded:Connect(function(object)
		if object.Name == "Crate" then task.defer(Items.TrackCrate, object) end
	end))
	table.insert(Items.CrateWatcherConnections, root.ChildRemoved:Connect(function(object)
		Items.KnownCrates[object] = nil
		Items.CratePartCache[object] = nil
		Items.RefreshCrates()
	end))
	task.defer(Items.ScanCratesNow)
end

if Game.IsRoyale then task.defer(Items.StartCrateWatcher) end

ContextActionService:BindActionAtPriority("BlockFAfterTeleport", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and os.clock() < Teleport.BlockFUntil then
		Teleport.ShowFBlockedWarning()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, false, 3000, Enum.KeyCode.F)

local pressF
function Items.IsPickupInputLocked()
	return os.clock() < (Teleport.BlockFUntil or 0)
		or Items.EarlyBusFBlockActive == true or Items.BusLandingFBlockActive == true
end

function pressF(skipPickupLock)
	local pressed = false
	if not skipPickupLock and Items.IsPickupInputLocked() then return false end
	pcall(function()
		local deadline = os.clock() + 12
		while not skipPickupLock and os.clock() < (Teleport.BlockFUntil or 0) and os.clock() < deadline do
			if Items.EarlyBusFBlockActive == true or Items.BusLandingFBlockActive == true then return end
			task.wait(0.03)
		end
		if not skipPickupLock and Items.IsPickupInputLocked() then return end
		VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
		task.wait(0.05)
		VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
		pressed = true
	end)
	return pressed
end

function Items.UsePickupInput(itemObject, itemPart, skipPickupLock)
	if not skipPickupLock and Items.IsPickupInputLocked() then return false end
	return pressF(skipPickupLock) == true
end

function Items.GetAutoPickupRoot()
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

function Items.IsPartInsideAutoPickupZone(itemPart, root)
	if not itemPart or not itemPart.Parent or not root then return false end
	local localPosition = root.CFrame:PointToObjectSpace(itemPart.Position)
	local half = itemPart.Size * 0.5
	local zone = 15
	return math.abs(localPosition.X) <= zone + half.X and math.abs(localPosition.Y) <= zone + half.Y
		and math.abs(localPosition.Z) <= zone + half.Z
end

function Items.ClearAutoPickupPart()
	if Items.AutoPickupFollowConnection then
		Items.AutoPickupFollowConnection:Disconnect()
		Items.AutoPickupFollowConnection = nil
	end
	if Items.AutoPickupPart then
		pcall(function() Items.AutoPickupPart:Destroy() end)
		Items.AutoPickupPart = nil
	end
	Items.AutoPickupTouching = {}
end

function Items.ScanAutoPickupItems()
	local root = Items.GetAutoPickupRoot()
	if not root then return end
	for _, object in ipairs(getCollectibleSearchPool()) do
		local part = getLiveItemPart(object)
		if part and Items.IsPartInsideAutoPickupZone(part, root) then
			for _, itemName in ipairs(itemNames) do
				if itemNameMatches(object, itemName) then
					Items.AutoPickupTouching[object] = { Part = part, Name = itemName }
					break
				end
			end
		end
	end
end

function Items.SetAutoPickup(state, silent)
	Items.AutoPickupEnabled = state == true
	if Items.AutoPickupEnabled then
		if not Items.AutoPickupThread then
			Items.AutoPickupThread = task.spawn(function()
				while Items.AutoPickupEnabled do
					Items.ScanAutoPickupItems()
					local root = Items.GetAutoPickupRoot()
					local shouldPress = false
					for object, entry in pairs(Items.AutoPickupTouching) do
						local part = getLiveItemPart(object)
						if not root or not part or not Items.IsPartInsideAutoPickupZone(part, root) then
							Items.AutoPickupTouching[object] = nil
						else
							shouldPress = true
							if not Items.IsPickupInputLocked() then
								pcall(function() ProximityPromptService.Enabled = true end)
							end
							if isTouchDevice then Items.UsePickupInput(object, part) end
						end
					end
					if shouldPress and not isTouchDevice then Items.UsePickupInput(nil, nil) end
					task.wait(Items.AutoPickupScanInterval)
				end
				Items.AutoPickupThread = nil
			end)
		end
		if not silent then createNotification("Auto pick up", "Enabled.", "Success") end
	else
		Items.ClearAutoPickupPart()
		if not silent then createNotification("Auto pick up", "Disabled.") end
	end
end

local toolUseBusy = false

local function getInventoryTools()
	local tools = {}
	local character = player.Character
	local backpack = player:FindFirstChild("Backpack")
	if character then
		for _, tool in ipairs(character:GetChildren()) do
			if tool:IsA("Tool") then table.insert(tools, tool) end
		end
	end
	if backpack then
		for _, tool in ipairs(backpack:GetChildren()) do
			if tool:IsA("Tool") then table.insert(tools, tool) end
		end
	end
	return tools
end

local function findMatchingTool(itemList)
	for _, tool in ipairs(getInventoryTools()) do
		if matchesItem(tool.Name, itemList) then return tool end
	end
	return nil
end

local function useTool(tool)
	if toolUseBusy or not tool or not tool:IsA("Tool") then return false end
	local character, root = Wait.ForCharacter(player, 4)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	toolUseBusy = true
	local used = false
	pcall(function()
		if root then root.AssemblyLinearVelocity = Vector3.zero end
		if tool.Parent ~= character then
			humanoid:EquipTool(tool)
			Wait.For(function() return tool.Parent == character end, 0.6, 0.02)
		end
		if tool.Parent == character then
			used = pcall(function() tool:Activate() end)
			task.wait(0.06)
		end
	end)
	toolUseBusy = false
	return used
end

function Items.UseAllMatchingTools(itemList, label, pluralName)
	task.spawn(function()
		local tools = {}
		for _, tool in ipairs(getInventoryTools()) do
			if matchesItem(tool.Name, itemList) then table.insert(tools, tool) end
		end
		if #tools == 0 then
			createNotification(label, "No " .. pluralName .. " found.", "Warning")
			return
		end
		local used = 0
		for _, tool in ipairs(tools) do
			if tool and tool.Parent and useTool(tool) then used += 1 end
			task.wait(0.05)
		end
		createNotification(label, "Used " .. tostring(used) .. " " .. pluralName .. ".")
	end)
end

function Items.UseAllItems() Items.UseAllMatchingTools(itemNames, "Use All Items", "item(s)") end

function Items.DropTool(tool)
	if not tool or not tool:IsA("Tool") or not tool.Parent then return false end
	local character = Wait.ForCharacter(player, 4)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	pcall(function() tool.CanBeDropped = true end)
	if tool.Parent ~= character then
		pcall(function() humanoid:EquipTool(tool) end)
		Wait.For(function() return tool.Parent == character end, 0.4, 0.02)
	end
	if tool.Parent ~= character then return false end
	pcall(function()
		VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Backspace, false, game)
		task.wait(0.02)
		VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Backspace, false, game)
	end)
	return true
end

function Items.DropMatchingTools(itemList, label, pluralName)
	task.spawn(function()
		local tools = {}
		for _, tool in ipairs(getInventoryTools()) do
			if matchesItem(tool.Name, itemList) then table.insert(tools, tool) end
		end
		if #tools == 0 then
			createNotification(label, "No " .. pluralName .. " found.", "Warning")
			return
		end
		local dropped = 0
		for _, tool in ipairs(tools) do
			if tool and tool.Parent and Items.DropTool(tool) then dropped += 1 end
			task.wait(0.03)
		end
		createNotification(label, "Dropped " .. tostring(dropped) .. " " .. pluralName .. ".")
	end)
end

function Items.DropAllItems() Items.DropMatchingTools(itemNames, "Drop All Items", "item(s)") end
function Items.DropAllPermanents() Items.DropMatchingTools(permanentUseItems, "Drop Permanent Items", "permanent item(s)") end

function Items.GetTemporaryDropItems()
	local temp = {}
	for _, itemName in ipairs(itemNames) do
		if not matchesItem(itemName, permanentUseItems) then table.insert(temp, itemName) end
	end
	return temp
end

function Items.DropTempItems() Items.DropMatchingTools(Items.GetTemporaryDropItems(), "Drop Temp Items", "temporary item(s)") end

local autoHealConnection = nil

function Items.SetAutoHeal(state, silent)
	Items.AutoHealEnabled = state == true
	if autoHealConnection then
		autoHealConnection:Disconnect()
		autoHealConnection = nil
	end
	if Items.AutoHealEnabled then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			autoHealConnection = humanoid.HealthChanged:Connect(function()
				if not Items.AutoHealEnabled or toolUseBusy then return end
				if humanoid.Health > 0 and humanoid.Health <= humanoid.MaxHealth * 0.45 then
					local tool = findMatchingTool(healingItems)
					if tool then useTool(tool) end
				end
			end)
		end
		if not silent then createNotification("Auto Heal", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Auto Heal", "Disabled.")
	end
end

function Items.SetAutoSort(state, silent)
	Items.AutoSortEnabled = state == true
	if Items.AutoSortEnabled then
		local backpack = player:FindFirstChild("Backpack")
		local character = player.Character
		if backpack and character then
			for _, tool in ipairs(backpack:GetChildren()) do
				if tool:IsA("Tool") and not matchesItem(tool.Name, itemNames) then
					tool.Parent = character
					task.wait()
				end
			end
		end
		if not silent then createNotification("Auto Sort", "Gloves first.", "Success") end
	elseif not silent then
		createNotification("Auto Sort", "Disabled.")
	end
end

-- auto permanent items (original: off while collecting)
function Items.SetAutoPermanentItems(state, silent)
	if state == true and (Items.AutoCollectEnabled or Items.EarlyAutoCollectEnabled) then
		Items.AutoPermanentEnabled = false
		if Items.AutoPermanentToggle then Items.AutoPermanentToggle.Set(false, false) end
		if not silent then createNotification("Auto Use", "Off while collecting.", "Info") end
		return
	end
	Items.AutoPermanentEnabled = state == true
	if Items.AutoPermanentEnabled then
		if not Items.AutoPermanentThread then
			Items.AutoPermanentThread = task.spawn(function()
				while Items.AutoPermanentEnabled do
					local tool = findMatchingTool(permanentUseItems)
					if tool and not toolUseBusy then useTool(tool) end
					task.wait(0.3)
				end
				Items.AutoPermanentThread = nil
			end)
		end
		if not silent then createNotification("Auto Use", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Auto Use", "Disabled.")
	end
end

function Items.ForceAutoPermanentOff()
	Items.AutoPermanentEnabled = false
	if Items.AutoPermanentToggle then Items.AutoPermanentToggle.Set(false, false) end
end

-- priority auto collect
local visitedPositions = {}
local ignoredPositions = {}

local function isVisited(position)
	local now = os.clock()
	for index = #ignoredPositions, 1, -1 do
		local entry = ignoredPositions[index]
		if not entry or entry.Until <= now then
			table.remove(ignoredPositions, index)
		elseif (entry.Position - position).Magnitude <= 12 then
			return true
		end
	end
	for _, visited in ipairs(visitedPositions) do
		if (visited - position).Magnitude <= 7 then return true end
	end
	return false
end

local function ignoreTarget(position)
	local untilTime = os.clock() + 8
	table.insert(ignoredPositions, { Position = position, Until = untilTime })
	table.insert(visitedPositions, position)
end

local function findLiveItemByName(wantedName, allowVisited)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	local best, bestPart, bestDistance = nil, nil, math.huge
	for _, object in ipairs(getCollectibleSearchPool()) do
		if itemNameMatches(object, wantedName) then
			local part = getLiveItemPart(object)
			if part and (allowVisited or not isVisited(part.Position)) then
				local distance = (root.Position - part.Position).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					best = object
					bestPart = part
				end
			end
		end
	end
	return bestPart and wantedName or nil, best, bestPart
end

local function findNextCollectTarget()
	local order = Items.PermanentCollectStopOrder
	for _, wantedName in ipairs(autoCollectPriority) do
		local name, object, part = findLiveItemByName(wantedName)
		if name and part then return name, object, part end
	end
	for _, wantedName in ipairs(autoCollectPriority) do
		local name, object, part = findLiveItemByName(wantedName, true)
		if name and part then return name, object, part end
	end
	for _, wantedName in ipairs(order) do
		local name, object, part = findLiveItemByName(wantedName, true)
		if name and part then return name, object, part end
	end
	return nil, nil, nil
end

local function isSameItemStillThere(itemObject, itemPart)
	if not itemObject or not itemPart or not itemObject.Parent or not itemPart.Parent then return false end
	if not itemPart:IsDescendantOf(workspace) or itemPart.Transparency >= 0.95 then return false end
	local characterModel = itemPart:FindFirstAncestorOfClass("Model")
	if characterModel and Players:GetPlayerFromCharacter(characterModel) then return false end
	return true
end

local function spamPickup(itemObject, itemPart, duration, mode)
	local stopAt = os.clock() + duration
	task.spawn(function()
		while os.clock() < stopAt and isSameItemStillThere(itemObject, itemPart) do
			if mode == "Early" and os.clock() < (Items.EarlyAutoCollectPauseUntil or 0) then break end
			if mode == "Auto" and not Items.AutoCollectEnabled then break end
			if mode == "Early" and not Items.EarlyAutoCollectEnabled then break end
			Items.UsePickupInput(itemObject, itemPart)
			task.wait(0.08)
		end
	end)
end

local function runPriorityCollect(mode)
	local isEarly = mode ~= "Auto"
	local title = isEarly and "Early Auto Collect" or "Auto collect"
	setMovementPaused(true)
	if isEarly then
		local deadline = os.clock() + 120
		local sawTimer = false
		while Items.EarlyAutoCollectEnabled and os.clock() < deadline do
			local number = Main.FindRoundTimer()
			if number then
				sawTimer = true
				if number <= 3 then break end
			elseif sawTimer then
				break
			end
			task.wait(0.1)
		end
	end
	local enabledCheck = function()
		return isEarly and Items.EarlyAutoCollectEnabled or Items.AutoCollectEnabled
	end
	if not enabledCheck() then
		setMovementPaused(false)
		return
	end
	createNotification(title, isEarly and "Timer hit 3. Starting." or "Starting.", "Success")
	local empty = 0
	local deadline = os.clock() + 600
	while enabledCheck() and os.clock() < deadline do
		setMovementPaused(true)
		while isEarly and enabledCheck() and os.clock() < (Items.EarlyAutoCollectPauseUntil or 0) do
			setMovementPaused(false)
			task.wait(0.05)
		end
		if isEarly and enabledCheck() then setMovementPaused(true) end
		local waitTime = Teleport.GetWaitBeforeTeleport(Items.TeleportDebounce)
		if waitTime > 0 then
			task.wait(math.clamp(waitTime, 0.1, 0.5))
		else
			local name, object, part = findNextCollectTarget()
			if not name or not part then
				empty += 1
				if empty >= 8 then break end
				task.wait(0.1)
			else
				empty = 0
				local character, root = Wait.ForCharacter(player, 5)
				if root then
					ignoreTarget(part.Position)
					Teleport.MoveRoot(root, Teleport.GetItemCFrame(part, { character, object }), part.Position)
					Teleport.StabilizeItemView(root, part)
					Teleport.AddStrike()
					Teleport.StartFBlock()
					createNotification(title, "Collected " .. name)
					spamPickup(object, part, 1.35, mode)
				end
				task.wait(0.5)
			end
		end
	end
	setMovementPaused(false)
end

function Items.SetAutoCollect(state, silent)
	if state and Items.AutoCollectEnabled then return end
	if state and Items.EarlyAutoCollectEnabled then
		if not silent then createNotification("Auto collect", "Turn Early Auto Collect off first.", "Warning") end
		if Items.AutoCollectToggle then Items.AutoCollectToggle.Set(false, false) end
		return
	end
	Items.AutoCollectEnabled = state == true
	if Items.AutoCollectEnabled then
		Items.ForceAutoPermanentOff()
		visitedPositions = {}
		ignoredPositions = {}
		if not Items.AutoCollectThread then
			Items.AutoCollectThread = task.spawn(function()
				runPriorityCollect("Auto")
				Items.AutoCollectThread = nil
			end)
		end
		if not silent then createNotification("Auto collect", "Starting priority collection.", "Info") end
	else
		setMovementPaused(false)
		if not silent then createNotification("Auto collect", "Disabled.") end
	end
end

function Items.SetEarlyAutoCollect(state, silent)
	if state and Items.EarlyAutoCollectEnabled then return end
	if state then
		if Items.AutoCollectEnabled then
			if not silent then createNotification("Early Auto Collect", "Turn Auto collect off first.", "Warning") end
			if Items.AutoCollectToggle then Items.AutoCollectToggle.Set(false, false) end
			return
		end
		local timerNumber = Main.FindRoundTimer()
		if not timerNumber then
			if not silent then createNotification("Early Auto Collect", "No countdown detected.", "Warning") end
			if Items.EarlyAutoCollectToggle then Items.EarlyAutoCollectToggle.Set(false, false) end
			return
		end
		if timerNumber <= 3 then
			if not silent then createNotification("Early Auto Collect", "Activate before 3 seconds left.", "Warning") end
			if Items.EarlyAutoCollectToggle then Items.EarlyAutoCollectToggle.Set(false, false) end
			return
		end
		if UI.ToggleRefs.EarlyBusJump then UI.ToggleRefs.EarlyBusJump.Set(true, false) end
		if UI.SetAutoEarlyBusJump then UI.SetAutoEarlyBusJump(true, true) end
		Items.ForceAutoPermanentOff()
	end
	Items.EarlyAutoCollectEnabled = state == true
	if Items.EarlyAutoCollectEnabled then
		Items.EarlyAutoCollectPauseUntil = 0
		visitedPositions = {}
		ignoredPositions = {}
		if not Items.EarlyAutoCollectThread then
			Items.EarlyAutoCollectThread = task.spawn(function()
				runPriorityCollect("Early")
				Items.EarlyAutoCollectThread = nil
			end)
		end
		if not silent then createNotification("Early Auto Collect", "Waiting for countdown to end.", "Info") end
	else
		setMovementPaused(false)
		if not silent then createNotification("Early Auto Collect", "Disabled.") end
	end
end

function Items.CollectCrates()
	if Items.CollectCratesBusy then return end
	Items.CollectCratesBusy = true
	Items.StartCrateWatcher()
	setMovementPaused(true)
	task.spawn(function()
		local deadline = os.clock() + (Items.CollectCratesMaxRuntime or 180)
		local ok, err = pcall(function()
			local targets = Items.GetCrateCollectTargets()
			if #targets == 0 then
				createNotification("Collect Crates", "No crates found.", "Warning")
				return
			end
			local current = nil
			local function move(crate)
				if not crate or not crate.Parent or not Items.GetCratePart(crate) then return false end
				if Items.TeleportUnderCrate(crate) then
					current = crate
					return true
				end
				return false
			end
			move(Items.GetReadyCrateTarget() or Items.GetFirstLiveCrateTarget())
			while Items.CollectCratesBusy do
				if os.clock() > deadline then break end
				setMovementPaused(true)
				if current and Items.IsCrateUsedUp(current) then current = nil end
				if not current then
					local ready, liveCount = Items.GetReadyCrateTarget()
					if liveCount <= 0 then break end
					move(ready or Items.GetFirstLiveCrateTarget())
				else
					local part = Items.GetCratePart(current)
					if part then Items.SlapCrate(part) end
					task.wait(Items.CollectCratesSlapInterval)
				end
			end
			Items.RefreshCrates()
		end)
		Items.CollectCratesBusy = false
		setMovementPaused(false)
		Items.ClearCrateCollectPart()
		if ok then
			createNotification("Collect Crates", "Finished.", "Success")
		else
			createNotification("Collect Crates", "Stopped: " .. tostring(err), "Error")
		end
	end)
end

function Items.CleanupAutomation()
	Items.AutoHealEnabled = false
	Items.AutoSortEnabled = false
	Items.AutoPermanentEnabled = false
	Items.AutoPickupEnabled = false
	Items.AutoCollectEnabled = false
	Items.EarlyAutoCollectEnabled = false
	Items.CollectCratesBusy = false
	setMovementPaused(false)
	Items.ClearAutoPickupPart()
	Items.ClearCrateCollectPart()
	Items.ClearCrateWatcher()
	if autoHealConnection then
		autoHealConnection:Disconnect()
		autoHealConnection = nil
	end
	pcall(function() ProximityPromptService.Enabled = true end)
end

--=====================================================================
-- COMBAT
--=====================================================================
Combat = {
	HitboxSize = 10, HitboxMinSize = 10, HitboxMaxSize = 20, HitboxTransparency = 0.7,
	HitboxColor = Color3.fromRGB(0, 255, 70), HitboxExpanded = false, HitboxVisible = true,
	SavedHitboxes = {}, HitboxConnection = nil, HitboxRefreshInterval = 0.35, LastHitboxRefresh = 0,
	AutoGloveTapEnabled = false, AutoGloveTapThread = nil, AutoGloveTapScanInterval = 0.22,
	SlapAuraEnabled = false, SlapAuraThread = nil, SlapAuraRange = 20, SlapAuraInterval = 1 / 3, SlapAuraRate = 3,
	AutoWinEnabled = false, AutoWinMode = "One at a time",
	KillTargetPlayer = nil, KillTeleportEnabled = false, KillTargetDropdown = nil,
	GloveTpSlapEnabled = false, GloveTpSlapConnections = {}, GloveTpSlapBusy = false,
	GloveTpSlapInternalActivate = false, GloveTpSlapHoldTime = 0.5, GloveTpSlapDebounce = 1,
	GloveTpSlapActionName = "GloveTpSlapClickBlock", LastGloveTpSlap = 0,
	AntiSlapEnabled = false, AntiSlapConnections = {}, AntiSlapBoxFolder = nil,
	AntiSlapActiveUntil = 0, LastAntiSlapBoxAt = 0, LastAntiSlapCheckAt = 0,
	GloveSizeScale = 1, GloveSizeMin = 1, GloveSizeMax = 8, GloveSizeStep = 0.25,
	GloveSizeOriginals = {}, GloveSizeConnections = {}, LastGloveActivate = 0,
}

Combat.KnownItemToolLookup = {}
for _, name in ipairs(itemNames) do Combat.KnownItemToolLookup[normalizeName(name)] = true end
Combat.KnownItemToolLookup[normalizeName("Bull's essence")] = true
Combat.KnownItemToolLookup[normalizeName("Sphere of fury")] = true

function Combat.IsKnownItemToolName(toolName)
	if not toolName then return false end
	return Combat.KnownItemToolLookup[normalizeName(toolName)] == true
end

-- ORIGINAL behaviour: first tool held, item tools included
function Combat.GetEquippedTool()
	local character = player.Character
	if not character then return nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then return child end
	end
	return nil
end

-- Battles only helper: first non-item tool
function Combat.GetGlove()
	local character = player.Character
	if not character then return nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and not Combat.IsKnownItemToolName(child.Name) then
			return child
		end
	end
	return nil
end

-- Battles only: equip a glove from the backpack if none held
function Combat.EnsureGlove()
	local existing = Combat.GetGlove()
	if existing then return existing end
	local character = player.Character
	local backpack = player:FindFirstChild("Backpack")
	if not character or not backpack then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return nil end
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:IsA("Tool") and not Combat.IsKnownItemToolName(tool.Name) then
			pcall(function() humanoid:EquipTool(tool) end)
			return tool
		end
	end
	return nil
end

function Combat.ActivateGlove(force)
	local tool
	if Game.IsRoyale then
		tool = Combat.GetEquippedTool()
	else
		tool = Combat.GetGlove() or Combat.EnsureGlove()
	end
	if not tool then return false end
	local now = os.clock()
	local gap = Game.IsRoyale and 0.045 or 0.04
	if not force and now - Combat.LastGloveActivate < gap then return false end
	Combat.LastGloveActivate = now
	return pcall(function() tool:Activate() end)
end

function Combat.Slap(targetPart)
	if Net.GetSlapRemote() then
		if targetPart then return Net.QueueSlap(targetPart) end
		return false
	end
	return Combat.ActivateGlove()
end

function Combat.GetPlayerHumanoid(targetPlayer)
	local character = targetPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function Combat.SaveOriginalHitbox(otherPlayer, root)
	if Combat.SavedHitboxes[otherPlayer] then return end
	Combat.SavedHitboxes[otherPlayer] = {
		Size = root.Size, Transparency = root.Transparency, Color = root.Color,
		Material = root.Material, CanCollide = root.CanCollide,
	}
end

function Combat.ApplyHitbox(otherPlayer)
	local character = otherPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = Combat.GetPlayerHumanoid(otherPlayer)
	if not root or not humanoid or humanoid.Health <= 0 then
		Combat.ResetHitbox(otherPlayer)
		return
	end
	Combat.SaveOriginalHitbox(otherPlayer, root)
	local size = Vector3.new(Combat.HitboxSize, Combat.HitboxSize, Combat.HitboxSize)
	if root.Size ~= size then root.Size = size end
	if Combat.HitboxVisible then
		root.Transparency = Combat.HitboxTransparency
		if root.Material ~= Enum.Material.Neon then
			root.Material = Enum.Material.Neon
			root.Color = Combat.HitboxColor
		end
	else
		root.Transparency = 1
	end
	root.CanCollide = false
end

function Combat.ResetHitbox(otherPlayer)
	local character = otherPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local saved = Combat.SavedHitboxes[otherPlayer]
	if root and saved then
		root.Size = saved.Size
		root.Transparency = saved.Transparency
		root.Color = saved.Color
		root.Material = saved.Material
		root.CanCollide = saved.CanCollide
	end
	Combat.SavedHitboxes[otherPlayer] = nil
end

function Combat.StartHitboxLoop()
	if Combat.HitboxConnection then return end
	Combat.HitboxConnection = RunService.Heartbeat:Connect(function()
		if not Combat.HitboxExpanded then return end
		local now = os.clock()
		if now - Combat.LastHitboxRefresh < Combat.HitboxRefreshInterval then return end
		Combat.LastHitboxRefresh = now
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			local humanoid = Combat.GetPlayerHumanoid(otherPlayer)
			if humanoid and humanoid.Health > 0 then
				Combat.ApplyHitbox(otherPlayer)
			else
				Combat.ResetHitbox(otherPlayer)
			end
		end
	end)
end

function Combat.StopHitboxLoop()
	if Combat.HitboxConnection then
		Combat.HitboxConnection:Disconnect()
		Combat.HitboxConnection = nil
	end
	for _, otherPlayer in ipairs(Players:GetPlayers()) do Combat.ResetHitbox(otherPlayer) end
end

function Combat.RefreshHitboxes()
	if Combat.HitboxExpanded then
		Combat.StartHitboxLoop()
		Combat.LastHitboxRefresh = 0
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			local humanoid = Combat.GetPlayerHumanoid(otherPlayer)
			if humanoid and humanoid.Health > 0 then Combat.ApplyHitbox(otherPlayer) end
		end
	else
		Combat.StopHitboxLoop()
	end
end

function Combat.HasTruthyStatus(object, statusNames)
	if not object then return false end
	for _, statusName in ipairs(statusNames) do
		if object:GetAttribute(statusName) == true then return true end
		local statusObject = object:FindFirstChild(statusName)
		if statusObject then
			if statusObject:IsA("BoolValue") then
				if statusObject.Value == true then return true end
			else
				return true
			end
		end
	end
	return false
end

function Combat.HasStrictTruthyStatus(object, statusNames)
	if not object then return false end
	for _, statusName in ipairs(statusNames) do
		local attribute = object:GetAttribute(statusName)
		if attribute == true or attribute == 1 then return true end
		local statusObject = object:FindFirstChild(statusName, true)
		if statusObject then
			if statusObject:IsA("BoolValue") then
				if statusObject.Value == true then return true end
			elseif statusObject:IsA("NumberValue") then
				if statusObject.Value ~= 0 then return true end
			end
		end
	end
	return false
end

function Combat.IsRagdolledTarget(character, humanoid, targetPlayer)
	local statuses = {
		"Ragdoll", "Ragdolled", "IsRagdolled", "IsInRagdoll", "Ragdolling",
		"Knocked", "KnockedDown", "Downed", "Stunned",
	}
	if Combat.HasTruthyStatus(targetPlayer, statuses) or Combat.HasTruthyStatus(character, statuses)
		or Combat.HasTruthyStatus(humanoid, statuses) then
		return true
	end
	if humanoid.PlatformStand or humanoid:GetState() == Enum.HumanoidStateType.Ragdoll then return true end
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.FallingDown or state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.GettingUp
end

function Combat.GetValidPlayerTarget(targetPlayer)
	if not targetPlayer or targetPlayer == player then return nil, nil, nil end
	local character = targetPlayer.Character
	if not character then return nil, nil, nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then return nil, nil, nil end
	if Game.IsRoyale and Combat.IsRagdolledTarget(character, humanoid, targetPlayer) then return nil, nil, nil end
	return character, humanoid, root
end

function Combat.StartAutoGloveTap()
	if Combat.AutoGloveTapThread then return end
	Combat.AutoGloveTapThread = task.spawn(function()
		while Combat.AutoGloveTapEnabled do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				for _, targetPlayer in ipairs(Players:GetPlayers()) do
					local _, _, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
					if targetRoot and (root.Position - targetRoot.Position).Magnitude <= Combat.SlapAuraRange then
						Combat.ActivateGlove()
						break
					end
				end
			end
			task.wait(Combat.AutoGloveTapScanInterval)
		end
		Combat.AutoGloveTapThread = nil
	end)
end

function Combat.SetAutoGloveTap(state, silent)
	Combat.AutoGloveTapEnabled = state == true
	if Combat.AutoGloveTapEnabled then
		if Game.IsBattles then Combat.EnsureGlove() end
		Combat.StartAutoGloveTap()
		if not silent then createNotification("Auto Slap", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Auto Slap", "Disabled.")
	end
end

function Combat.CanUseSlapAuraTarget(targetPlayer)
	if targetPlayer == player then return nil end
	local localCharacter = player.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
	local targetCharacter = targetPlayer.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not localRoot or not targetRoot then return nil end
	if targetCharacter:FindFirstChild("Dead") then return nil end
	if Game.IsRoyale then
		if targetCharacter:GetAttribute("inBus") == true or localCharacter:GetAttribute("inBus") == true then return nil end
		if targetCharacter:GetAttribute("inMatch") ~= true or localCharacter:GetAttribute("inMatch") ~= true then return nil end
		if localCharacter:GetAttribute("Ragdolled") ~= false then return nil end
	end
	if (localRoot.Position - targetRoot.Position).Magnitude > Combat.SlapAuraRange then return nil end
	return targetRoot
end

function Combat.StartSlapAura()
	if Combat.SlapAuraThread then return end
	Combat.SlapAuraThread = task.spawn(function()
		while Combat.SlapAuraEnabled do
			local startedAt = os.clock()
			for _, targetPlayer in ipairs(Players:GetPlayers()) do
				local targetRoot = Combat.CanUseSlapAuraTarget(targetPlayer)
				if targetRoot then
					if Net.GetSlapRemote() then Net.QueueSlap(targetRoot) else Combat.ActivateGlove(true) end
				end
			end
			local spent = os.clock() - startedAt
			task.wait(math.max(0, Combat.SlapAuraInterval - spent))
		end
		Combat.SlapAuraThread = nil
	end)
end

function Combat.SetSlapAura(state, silent)
	Combat.SlapAuraEnabled = state == true
	if Combat.SlapAuraEnabled then
		if Game.IsBattles then Combat.EnsureGlove() end
		Combat.StartSlapAura()
		if not silent then createNotification("Slap Aura", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Slap Aura", "Disabled.")
	end
end

function Combat.SetSlapAuraSpeed(mode)
	if mode == "Fast (May get you kicked)" then
		Combat.SlapAuraRate = 8
	else
		Combat.SlapAuraRate = 3
	end
	Combat.SlapAuraInterval = 1 / Combat.SlapAuraRate
end

function Combat.IsEquippedGloveTool(tool)
	local character = player.Character
	if not character or not tool or not tool:IsA("Tool") or tool.Parent ~= character then return false end
	if Game.IsRoyale and Combat.IsKnownItemToolName(tool.Name) then return false end
	local name = normalizeName(tool.Name)
	if string.find(name, "glove") or string.find(name, "slap") then return true end
	for _, object in ipairs(tool:GetDescendants()) do
		if object:IsA("BasePart") then return true end
	end
	return false
end

function Combat.StabilizeCharacter(character, root)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.Sit = false
		if humanoid:GetState() ~= Enum.HumanoidStateType.Running then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end
end

function Combat.GetPlayerGroundCFrame(targetRoot, character, targetCharacter)
	local exclude = { character }
	if targetCharacter then table.insert(exclude, targetCharacter) end
	local rightVector = targetRoot.CFrame.RightVector
	local lookVector = targetRoot.CFrame.LookVector
	local candidates = {
		targetRoot.Position + rightVector * 2.2, targetRoot.Position - rightVector * 2.2,
		targetRoot.Position - lookVector * 2, targetRoot.Position + lookVector * 1.5, targetRoot.Position,
	}
	for _, candidate in ipairs(candidates) do
		local ground = Teleport.GetGroundCFrame(candidate, exclude, true)
		if (ground.Position - targetRoot.Position).Magnitude <= 7 then return ground end
	end
	return Teleport.GetGroundCFrame(targetRoot.Position, exclude, true)
end

function Combat.TeleportToPlayer(targetPlayer)
	if not Teleport.CanTeleport() then return false end
	local character, root = Wait.ForCharacter(player, 5)
	local targetCharacter, _, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
	if not character or not root then
		createNotification("Players", "Could not find your character.", "Error")
		return false
	end
	if not targetRoot then
		createNotification("Players", "Target unavailable.", "Warning")
		return false
	end
	Combat.StabilizeCharacter(character, root)
	if Game.IsBattles then
		root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 2.4)
		root.AssemblyLinearVelocity = Vector3.zero
	else
		Teleport.MoveRoot(root, Combat.GetPlayerGroundCFrame(targetRoot, character, targetCharacter))
	end
	task.delay(0.15, function()
		if character.Parent and root.Parent then Combat.StabilizeCharacter(character, root) end
	end)
	Teleport.AddStrike()
	Teleport.StartFBlock()
	createNotification("Players", "Teleported to " .. targetPlayer.Name)
	return true
end

function Combat.TeleportToLowestHealthPlayer()
	local lowestPlayer, lowestHealth = nil, math.huge
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local _, humanoid, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
		if humanoid and targetRoot and humanoid.Health < lowestHealth then
			lowestHealth = humanoid.Health
			lowestPlayer = targetPlayer
		end
	end
	if lowestPlayer then
		Combat.TeleportToPlayer(lowestPlayer)
	else
		createNotification("Players", "No valid lowest health player.")
	end
end

function Combat.TeleportToNearestPlayer()
	local _, root = Wait.ForCharacter(player, 5)
	if not root then
		createNotification("Players", "Could not find your character.", "Error")
		return false
	end
	local nearestPlayer, nearestDistance = nil, math.huge
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local _, humanoid, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
		if humanoid and targetRoot then
			local distance = (root.Position - targetRoot.Position).Magnitude
			if distance < nearestDistance then
				nearestDistance = distance
				nearestPlayer = targetPlayer
			end
		end
	end
	if nearestPlayer then return Combat.TeleportToPlayer(nearestPlayer) end
	createNotification("Players", "No valid nearest player.")
	return false
end

function Combat.SetHitboxSize(newSize)
	Combat.HitboxSize = math.clamp(newSize, Combat.HitboxMinSize, Combat.HitboxMaxSize)
	if Combat.HitboxExpanded then Combat.RefreshHitboxes() end
end

function Combat.SetHitboxExpanded(state)
	Combat.HitboxExpanded = state == true
	Combat.RefreshHitboxes()
end

function Combat.SetHitboxVisible(state)
	Combat.HitboxVisible = state == true
	if Combat.HitboxExpanded then Combat.RefreshHitboxes() end
end

function Combat.SaveGloveOriginal(part)
	if Combat.GloveSizeOriginals[part] then return end
	local meshes = {}
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("SpecialMesh") then meshes[child] = child.Scale end
	end
	Combat.GloveSizeOriginals[part] = { Size = part.Size, Meshes = meshes }
end

function Combat.RestoreGloveSize()
	for part, original in pairs(Combat.GloveSizeOriginals) do
		if part and part.Parent then
			pcall(function() part.Size = original.Size end)
			for mesh, scale in pairs(original.Meshes or {}) do
				if mesh and mesh.Parent then pcall(function() mesh.Scale = scale end) end
			end
		end
	end
	Combat.GloveSizeOriginals = {}
end

function Combat.ApplyGloveSize()
	local tool = Combat.GetEquippedTool()
	if not tool then return false end
	local scale = Combat.GloveSizeScale
	Combat.RestoreGloveSize()
	Combat.GloveSizeScale = scale
	for _, part in ipairs(tool:GetDescendants()) do
		if part:IsA("BasePart") then
			Combat.SaveGloveOriginal(part)
			local original = Combat.GloveSizeOriginals[part]
			if original then
				pcall(function() part.Size = original.Size * Combat.GloveSizeScale end)
				for mesh, meshScale in pairs(original.Meshes or {}) do
					if mesh and mesh.Parent then pcall(function() mesh.Scale = meshScale * Combat.GloveSizeScale end) end
				end
			end
		end
	end
	return true
end

function Combat.SetGloveSizeScale(newScale, showNotification)
	local stepped = math.floor((newScale / Combat.GloveSizeStep) + 0.5) * Combat.GloveSizeStep
	Combat.GloveSizeScale = math.clamp(stepped, Combat.GloveSizeMin, Combat.GloveSizeMax)
	if not Combat.ApplyGloveSize() and showNotification then
		createNotification("Glove Size", "Equip your glove first.", "Warning")
	end
end

function Combat.HookGloveSize(character)
	for _, connection in ipairs(Combat.GloveSizeConnections) do
		pcall(function() connection:Disconnect() end)
	end
	Combat.GloveSizeConnections = {}
	if not character then return end
	table.insert(Combat.GloveSizeConnections, character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			task.wait(0.05)
			Combat.ApplyGloveSize()
		end
	end))
end

Combat.HookGloveSize(player.Character)
player.CharacterAdded:Connect(function(character)
	task.wait(0.3)
	Combat.HookGloveSize(character)
	Combat.ApplyGloveSize()
end)

function Combat.CreateAntiSlapPart(folder, cframe, size)
	local part = Instance.new("Part")
	part.Name = "Part"
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Parent = folder
	return part
end

function Combat.SpawnAntiSlapBox()
	if Combat.AntiSlapBoxFolder or os.clock() - Combat.LastAntiSlapBoxAt < 0.2 then return end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	Combat.LastAntiSlapBoxAt = os.clock()
	local folder = Instance.new("Folder")
	folder.Name = "Part"
	folder.Parent = workspace
	Combat.AntiSlapBoxFolder = folder
	local center = root.CFrame
	local inner, thickness = 8, 40
	local outer = inner + thickness * 2
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(0, -(inner / 2 + thickness / 2), 0), Vector3.new(outer, thickness, outer))
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(0, inner / 2 + thickness / 2, 0), Vector3.new(outer, thickness, outer))
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(inner / 2 + thickness / 2, 0, 0), Vector3.new(thickness, outer, outer))
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(-(inner / 2 + thickness / 2), 0, 0), Vector3.new(thickness, outer, outer))
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(0, 0, inner / 2 + thickness / 2), Vector3.new(outer, outer, thickness))
	Combat.CreateAntiSlapPart(folder, center * CFrame.new(0, 0, -(inner / 2 + thickness / 2)), Vector3.new(outer, outer, thickness))
end

function Combat.ClearAntiSlapBox()
	if Combat.AntiSlapBoxFolder then
		Combat.AntiSlapBoxFolder:Destroy()
		Combat.AntiSlapBoxFolder = nil
	end
end

function Combat.IsLocalAntiSlapRagdolled(character, humanoid)
	if not character or not humanoid or humanoid.Health <= 0 then return false end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed then
		return false
	end
	local statuses = { "Ragdoll", "Ragdolled", "IsRagdolled", "IsInRagdoll", "Ragdolling" }
	return Combat.HasStrictTruthyStatus(character, statuses) or Combat.HasStrictTruthyStatus(humanoid, statuses)
		or state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.Physics
		or state == Enum.HumanoidStateType.FallingDown
end

function Combat.UpdateAntiSlapBox(character, humanoid)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local now = os.clock()
	local ragdolled = Combat.IsLocalAntiSlapRagdolled(character, humanoid)
	local state = humanoid:GetState()
	local recovered = state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
	if recovered then Combat.AntiSlapActiveUntil = 0 end
	if not recovered and ragdolled then Combat.AntiSlapActiveUntil = math.max(Combat.AntiSlapActiveUntil, now + 1) end
	if not recovered and (ragdolled or now < Combat.AntiSlapActiveUntil) then
		Combat.SpawnAntiSlapBox()
	else
		Combat.ClearAntiSlapBox()
	end
end

function Combat.HookAntiSlapCharacter()
	for _, connection in ipairs(Combat.AntiSlapConnections) do connection:Disconnect() end
	Combat.AntiSlapConnections = {}
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then return end
	Combat.ClearAntiSlapBox()
	Combat.AntiSlapActiveUntil = 0
	table.insert(Combat.AntiSlapConnections, humanoid.StateChanged:Connect(function()
		Combat.UpdateAntiSlapBox(character, humanoid)
	end))
	for _, statusName in ipairs({ "Ragdoll", "Ragdolled", "IsRagdolled", "IsInRagdoll", "Ragdolling" }) do
		table.insert(Combat.AntiSlapConnections, character:GetAttributeChangedSignal(statusName):Connect(function()
			Combat.UpdateAntiSlapBox(character, humanoid)
		end))
	end
	table.insert(Combat.AntiSlapConnections, RunService.Heartbeat:Connect(function()
		if not Combat.AntiSlapEnabled then return end
		local now = os.clock()
		if now - Combat.LastAntiSlapCheckAt < 0.3 then return end
		Combat.LastAntiSlapCheckAt = now
		Combat.UpdateAntiSlapBox(character, humanoid)
	end))
end

function Combat.SetAntiSlap(state, silent)
	Combat.AntiSlapEnabled = state == true
	if Combat.AntiSlapEnabled then
		Combat.AntiSlapActiveUntil = 0
		Combat.HookAntiSlapCharacter()
		if not silent then createNotification("Anti-Ragdoll", "Enabled.", "Success") end
	else
		for _, connection in ipairs(Combat.AntiSlapConnections) do connection:Disconnect() end
		Combat.AntiSlapConnections = {}
		Combat.ClearAntiSlapBox()
		if not silent then createNotification("Anti-Ragdoll", "Disabled.") end
	end
end

player.CharacterAdded:Connect(function()
	task.wait(0.35)
	if Combat.AntiSlapEnabled then Combat.HookAntiSlapCharacter() end
end)

for _, otherPlayer in ipairs(Players:GetPlayers()) do Combat.ResetHitbox(otherPlayer) end
Players.PlayerRemoving:Connect(function(otherPlayer)
	Combat.ResetHitbox(otherPlayer)
	Combat.SavedHitboxes[otherPlayer] = nil
end)

local autoWinTarget, autoWinHitCount, autoWinPauseUntil = nil, 0, 0

local function autoWinRoot(targetPlayer)
	local character = targetPlayer and targetPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then return nil end
	return root
end

task.spawn(function()
	while true do
		task.wait(3)
		if Combat.AutoWinEnabled and os.clock() >= autoWinPauseUntil then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and humanoid.Health > 0 and root then
				if not autoWinTarget or not autoWinRoot(autoWinTarget) then
					autoWinTarget = nil
					local bestDistance = math.huge
					for _, targetPlayer in ipairs(Players:GetPlayers()) do
						local targetRoot = autoWinRoot(targetPlayer)
						if targetRoot then
							local distance = (root.Position - targetRoot.Position).Magnitude
							if distance < bestDistance then
								bestDistance = distance
								autoWinTarget = targetPlayer
							end
						end
					end
				end
				local targetRoot = autoWinRoot(autoWinTarget)
				if targetRoot then
					root.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
					root.AssemblyLinearVelocity = Vector3.zero
					Combat.ActivateGlove()
					if Combat.AutoWinMode ~= "One at a time" then
						autoWinHitCount += 1
						if autoWinHitCount >= 5 then
							autoWinHitCount = 0
							autoWinPauseUntil = os.clock() + 10
							autoWinTarget = nil
						end
					end
				end
			end
		end
	end
end)

function Combat.SetAutoWin(state, silent)
	Combat.AutoWinEnabled = state == true
	if not Combat.AutoWinEnabled then
		autoWinTarget, autoWinHitCount, autoWinPauseUntil = nil, 0, 0
	end
	if not silent then createNotification("Auto Win", state and "Enabled." or "Disabled.") end
end

function Combat.SetAutoWinMode(mode)
	Combat.AutoWinMode = mode or "One at a time"
	autoWinTarget = nil
end

local killLoopRunning, killRagdollWaits = false, 0

local function killTargetRoot()
	local character = Combat.KillTargetPlayer and Combat.KillTargetPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function killIsDead()
	local targetPlayer = Combat.KillTargetPlayer
	if not targetPlayer then return true end
	local character = targetPlayer.Character
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health <= 0
end

local function killIsRagdolled()
	local character = Combat.KillTargetPlayer and Combat.KillTargetPlayer.Character
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.Physics
end

local function killLoop()
	if killLoopRunning then return end
	killLoopRunning = true
	task.spawn(function()
		while Combat.KillTeleportEnabled do
			if not Combat.KillTargetPlayer or not Combat.KillTargetPlayer.Parent or killIsDead() then
				Combat.KillTeleportEnabled = false
				break
			end
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local targetRoot = killTargetRoot()
			if not root or not targetRoot then
				task.wait(0.1)
			else
				local original = root.CFrame
				root.CFrame = targetRoot.CFrame
				task.wait(0.5)
				if Combat.KillTeleportEnabled and root.Parent then root.CFrame = original end
				task.wait(0.5)
				if killIsRagdolled() then
					killRagdollWaits += 1
					if killRagdollWaits >= 5 then
						killRagdollWaits = 0
						Wait.Sleep(15, function() return Combat.KillTeleportEnabled end)
					end
				end
			end
		end
		killLoopRunning = false
	end)
end

function Combat.SetKillPlayer(state)
	Combat.KillTeleportEnabled = state == true
	if not Combat.KillTeleportEnabled then return end
	if not Combat.KillTargetPlayer or not Combat.KillTargetPlayer.Parent or killIsDead() then
		Combat.KillTeleportEnabled = false
		createNotification("Kill Player", "Pick a live target first.")
		if UI.ToggleRefs.KillPlayer then UI.ToggleRefs.KillPlayer.Set(false, false) end
		return
	end
	killLoop()
end

function Combat.SetKillTarget(selectedName)
	Combat.KillTargetPlayer = selectedName and Players:FindFirstChild(selectedName) or nil
	if Combat.KillTargetPlayer then
		createNotification("Target", "Selected: " .. Combat.KillTargetPlayer.Name)
	else
		createNotification("Target", "Cleared.")
	end
end

function Combat.GetKillTargetNames()
	local names = {}
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then table.insert(names, targetPlayer.Name) end
	end
	table.sort(names)
	if #names == 0 then table.insert(names, "(none)") end
	return names
end

function Combat.TeleportToNearestPlayerOnGloveSlap(tool)
	local now = os.clock()
	if Combat.GloveTpSlapBusy or now - Combat.LastGloveTpSlap < Combat.GloveTpSlapDebounce then return end
	if not Combat.IsEquippedGloveTool(tool) then return end
	Combat.GloveTpSlapBusy = true
	Combat.LastGloveTpSlap = now
	if not Combat.TeleportToNearestPlayer() then
		Combat.GloveTpSlapBusy = false
		return
	end
	task.delay(Combat.GloveTpSlapHoldTime, function()
		if Combat.GloveTpSlapEnabled and Combat.IsEquippedGloveTool(tool) then
			Combat.GloveTpSlapInternalActivate = true
			pcall(function() tool:Activate() end)
			task.delay(0.1, function() Combat.GloveTpSlapInternalActivate = false end)
		end
	end)
	task.delay(Combat.GloveTpSlapDebounce, function() Combat.GloveTpSlapBusy = false end)
end

function Combat.RefreshGloveTpSlapHooks()
	for tool, connection in pairs(Combat.GloveTpSlapConnections) do
		connection:Disconnect()
		Combat.GloveTpSlapConnections[tool] = nil
	end
	local character = player.Character
	if not character then return end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and Combat.IsEquippedGloveTool(child) and not Combat.GloveTpSlapConnections[child] then
			Combat.GloveTpSlapConnections[child] = child.Activated:Connect(function()
				if Combat.GloveTpSlapEnabled and not Combat.GloveTpSlapInternalActivate then
					Combat.TeleportToNearestPlayerOnGloveSlap(child)
				end
			end)
		end
	end
end

function Combat.SetGloveTpSlap(state, silent)
	Combat.GloveTpSlapEnabled = state == true
	if Combat.GloveTpSlapEnabled then
		ContextActionService:BindActionAtPriority(Combat.GloveTpSlapActionName, function(_, inputState)
			if inputState ~= Enum.UserInputState.Begin or not Combat.GloveTpSlapEnabled then
				return Enum.ContextActionResult.Pass
			end
			local tool = Combat.GetEquippedTool()
			if not Combat.IsEquippedGloveTool(tool) then return Enum.ContextActionResult.Pass end
			Combat.TeleportToNearestPlayerOnGloveSlap(tool)
			return Enum.ContextActionResult.Sink
		end, false, 4000, Enum.UserInputType.MouseButton1)
		Combat.RefreshGloveTpSlapHooks()
		if not silent then createNotification("Glove TP Slap", "Enabled.", "Success") end
	else
		ContextActionService:UnbindAction(Combat.GloveTpSlapActionName)
		for tool, connection in pairs(Combat.GloveTpSlapConnections) do
			connection:Disconnect()
			Combat.GloveTpSlapConnections[tool] = nil
		end
		if not silent then createNotification("Glove TP Slap", "Disabled.") end
	end
end

player.CharacterAdded:Connect(function()
	task.wait(0.3)
	if Combat.GloveTpSlapEnabled then Combat.RefreshGloveTpSlapHooks() end
end)

--=====================================================================
-- FARM (Battles only)
--=====================================================================
Farm = {
	AutoSlapEnabled = false, AutoSlapThread = nil, AutoSlapInterval = 0.12,
	DummyEnabled = false, DummyThread = nil, DummyRange = 12,
	PlayerFarmEnabled = false, PlayerFarmThread = nil,
	AuraEnabled = false, AuraThread = nil, AuraRange = 22, AuraInterval = 1 / 3, AuraRate = 3,
	SlapFarmEnabled = false, SlapFarmThread = nil, SlapFarmInterval = 0.05, SlapFarmRotate = 4,
	SlapFarmSnapDistance = 5.5, SlapFarmSnapCooldown = 0.3, SlapFarmVerticalTolerance = 4,
	SlapFarmStandOffset = 2.6, SlapFarmHeight = 3.1, SlapFarmRayLength = 70,
	DummyCache = {}, LastDummyScan = 0, LastFarmTeleport = 0, FarmTeleportInterval = 0.6,
	DummyKeywords = { "dummy", "dummies", "trainer", "spar", "bot", "npc" },
}

local function isDummyCandidate(model)
	if not model or not model.Parent then return false end
	if Players:GetPlayerFromCharacter(model) then return false end
	local name = string.lower(model.Name)
	local keywordHit = false
	for _, keyword in ipairs(Farm.DummyKeywords) do
		if string.find(name, keyword, 1, true) then
			keywordHit = true
			break
		end
	end
	if model:IsA("BasePart") then return keywordHit end
	if not model:IsA("Model") or not model:FindFirstChildOfClass("Humanoid") then return false end
	return true
end

function Farm.ScanDummies()
	local now = os.clock()
	if now - Farm.LastDummyScan < 0.75 then return Farm.DummyCache end
	Farm.LastDummyScan = now
	local list, seen = {}, {}
	local function consider(object)
		if object and not seen[object] and isDummyCandidate(object) then
			seen[object] = true
			table.insert(list, object)
		end
	end
	local folder = workspace:FindFirstChild("Dummies") or workspace:FindFirstChild("Dummy") or workspace:FindFirstChild("NPCs")
	if folder then
		for _, child in ipairs(folder:GetChildren()) do consider(child) end
	end
	if #list == 0 then
		for _, object in ipairs(workspace:GetChildren()) do consider(object) end
	end
	Farm.DummyCache = list
	return list
end

function Farm.GetDummyPosition(dummy)
	if not dummy or not dummy.Parent then return nil end
	if dummy:IsA("BasePart") then return dummy.Position end
	local root = dummy:FindFirstChild("HumanoidRootPart") or dummy.PrimaryPart
	if root then return root.Position end
	local ok, pivot = pcall(function() return dummy:GetPivot() end)
	return ok and pivot and pivot.Position or nil
end

function Farm.GetNearestDummy()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil, math.huge end
	local best, bestDistance = nil, math.huge
	for _, dummy in ipairs(Farm.ScanDummies()) do
		local position = Farm.GetDummyPosition(dummy)
		if position then
			local distance = (root.Position - position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = dummy
			end
		end
	end
	return best, bestDistance
end

function Farm.GetNearestPlayerRoot()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil, math.huge end
	local bestRoot, bestDistance = nil, math.huge
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local _, humanoid, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
		if humanoid and targetRoot then
			local distance = (root.Position - targetRoot.Position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestRoot = targetRoot
			end
		end
	end
	return bestRoot, bestDistance
end

function Farm.TeleportNear(position, root)
	if os.clock() - Farm.LastFarmTeleport < Farm.FarmTeleportInterval then return false end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local state = humanoid:GetState()
		if humanoid.PlatformStand or state == Enum.HumanoidStateType.Ragdoll
			or state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
			return false
		end
	end
	Farm.LastFarmTeleport = os.clock()
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = Teleport.GetGroundCFrame(position, { character }, true)
	root.AssemblyLinearVelocity = Vector3.zero
	if humanoid and humanoid:GetState() ~= Enum.HumanoidStateType.Running then
		pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
	end
	return true
end

function Farm.StartAutoSlap()
	if Farm.AutoSlapThread then return end
	Farm.AutoSlapThread = task.spawn(function()
		while Farm.AutoSlapEnabled do
			Combat.ActivateGlove(true)
			task.wait(Farm.AutoSlapInterval)
		end
		Farm.AutoSlapThread = nil
	end)
end

function Farm.SetAutoSlap(state, silent)
	Farm.AutoSlapEnabled = state == true
	if Farm.AutoSlapEnabled then
		Combat.EnsureGlove()
		Farm.StartAutoSlap()
		if not silent then createNotification("Auto Slap", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Auto Slap", "Disabled.")
	end
end

function Farm.StartDummyFarm()
	if Farm.DummyThread then return end
	Farm.DummyThread = task.spawn(function()
		while Farm.DummyEnabled do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				Combat.EnsureGlove()
				local dummy, distance = Farm.GetNearestDummy()
				local position = dummy and Farm.GetDummyPosition(dummy)
				if position then
					if distance > Farm.DummyRange then
						Farm.TeleportNear(position, root)
					else
						Combat.ActivateGlove()
					end
				end
			end
			task.wait(0.1)
		end
		Farm.DummyThread = nil
	end)
end

function Farm.SetDummyFarm(state, silent)
	Farm.DummyEnabled = state == true
	if Farm.DummyEnabled then
		Farm.LastDummyScan = 0
		Farm.StartDummyFarm()
		if not silent then createNotification("Dummy Farm", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Dummy Farm", "Disabled.")
	end
end

function Farm.StartPlayerFarm()
	if Farm.PlayerFarmThread then return end
	Farm.PlayerFarmThread = task.spawn(function()
		while Farm.PlayerFarmEnabled do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				Combat.EnsureGlove()
				local targetRoot, distance = Farm.GetNearestPlayerRoot()
				if targetRoot then
					if distance > 8 then
						Farm.TeleportNear(targetRoot.Position, root)
					else
						Combat.ActivateGlove()
					end
				end
			end
			task.wait(0.1)
		end
		Farm.PlayerFarmThread = nil
	end)
end

function Farm.SetPlayerFarm(state, silent)
	Farm.PlayerFarmEnabled = state == true
	if Farm.PlayerFarmEnabled then
		Farm.StartPlayerFarm()
		if not silent then createNotification("Player Farm", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Player Farm", "Disabled.")
	end
end

-- Slap Aura: fixed rate, drift compensated, 3 swings per second by default
function Farm.StartAura()
	if Farm.AuraThread then return end
	Farm.AuraThread = task.spawn(function()
		local ticks = 0
		while Farm.AuraEnabled do
			local startedAt = os.clock()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				ticks += 1
				if ticks % 10 == 1 then Combat.EnsureGlove() end
				local hit = false
				for _, targetPlayer in ipairs(Players:GetPlayers()) do
					local _, humanoid, targetRoot = Combat.GetValidPlayerTarget(targetPlayer)
					if humanoid and targetRoot
						and (root.Position - targetRoot.Position).Magnitude <= Farm.AuraRange then
						hit = true
						break
					end
				end
				if hit then Combat.ActivateGlove(true) end
			end
			local spent = os.clock() - startedAt
			task.wait(math.max(0, Farm.AuraInterval - spent))
		end
		Farm.AuraThread = nil
	end)
end

function Farm.SetAura(state, silent)
	Farm.AuraEnabled = state == true
	if Farm.AuraEnabled then
		Combat.EnsureGlove()
		Farm.StartAura()
		if not silent then createNotification("Slap Aura", "Enabled at " .. tostring(Farm.AuraRate) .. "/sec.", "Success") end
	elseif not silent then
		createNotification("Slap Aura", "Disabled.")
	end
end

function Farm.SetAuraRate(value)
	Farm.AuraRate = math.clamp(tonumber(value) or 3, 1, 15)
	Farm.AuraInterval = 1 / Farm.AuraRate
end

function Farm.SetAuraRange(value)
	Farm.AuraRange = math.clamp(tonumber(value) or Farm.AuraRange, 5, 120)
	Combat.SlapAuraRange = Farm.AuraRange
end

function Farm.SetSlapRate(value)
	local rate = math.clamp(tonumber(value) or 12, 1, 30)
	Farm.AutoSlapInterval = 1 / rate
end

-- ground-locked standing spot behind the target, never inside the floor
function Farm.GetTargetGroundedCFrame(targetRoot)
	local character = player.Character
	local look = targetRoot.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.05 then look = Vector3.new(0, 0, -1) else look = look.Unit end

	local exclude = {}
	if character then table.insert(exclude, character) end
	if targetRoot.Parent then table.insert(exclude, targetRoot.Parent) end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude

	local base = targetRoot.Position - look * Farm.SlapFarmStandOffset
	local right = targetRoot.CFrame.RightVector
	local candidates = {
		base,
		base + right * 1.8,
		base - right * 1.8,
		base - look * 1.5,
		targetRoot.Position,
	}

	for _, point in ipairs(candidates) do
		local origin = Vector3.new(point.X, targetRoot.Position.Y + 10, point.Z)
		local hit = workspace:Raycast(origin, Vector3.new(0, -Farm.SlapFarmRayLength, 0), params)
		if hit then
			local spot = Vector3.new(point.X, hit.Position.Y + Farm.SlapFarmHeight, point.Z)
			local box = workspace:GetPartBoundsInBox(CFrame.new(spot), Vector3.new(2.6, 4.6, 2.6), params)
			local blocked = false
			for _, part in ipairs(box) do
				if part ~= targetRoot and part.CanCollide and part.Transparency < 0.95 then
					blocked = true
					break
				end
			end
			if not blocked then
				return CFrame.lookAt(spot, Vector3.new(targetRoot.Position.X, spot.Y, targetRoot.Position.Z)), true
			end
		end
	end

	local fallback = Vector3.new(base.X, targetRoot.Position.Y, base.Z)
	return CFrame.lookAt(fallback, Vector3.new(targetRoot.Position.X, fallback.Y, targetRoot.Position.Z)), false
end

function Farm.StartSlapFarm()
	if Farm.SlapFarmThread then return end
	Farm.SlapFarmThread = task.spawn(function()
		local current, targetSince = nil, 0
		local lastSnapAt, lastSlapAt = 0, 0
		while Farm.SlapFarmEnabled do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and humanoid and humanoid.Health > 0 then
				local now = os.clock()
				local _, _, targetRoot = Combat.GetValidPlayerTarget(current)
				if not targetRoot or now - targetSince >= Farm.SlapFarmRotate then
					current = nil
					targetSince = now
					local bestDistance = math.huge
					for _, other in ipairs(Players:GetPlayers()) do
						local _, otherHumanoid, otherRoot = Combat.GetValidPlayerTarget(other)
						if otherHumanoid and otherRoot then
							local distance = (root.Position - otherRoot.Position).Magnitude
							if distance < bestDistance then
								bestDistance = distance
								current = other
							end
						end
					end
					_, _, targetRoot = Combat.GetValidPlayerTarget(current)
				end

				if targetRoot then
					local state = humanoid:GetState()
					local unstable = humanoid.PlatformStand
						or state == Enum.HumanoidStateType.Ragdoll
						or state == Enum.HumanoidStateType.Physics
						or state == Enum.HumanoidStateType.FallingDown

					local desired, grounded = Farm.GetTargetGroundedCFrame(targetRoot)
					local flatGap = (Vector3.new(desired.X, 0, desired.Z)
						- Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
					local heightGap = math.abs(desired.Y - root.Position.Y)

					local shouldSnap = not unstable
						and now - lastSnapAt >= Farm.SlapFarmSnapCooldown
						and (flatGap > Farm.SlapFarmSnapDistance or heightGap > Farm.SlapFarmVerticalTolerance)

					if shouldSnap then
						lastSnapAt = now
						pcall(function()
							root.AssemblyAngularVelocity = Vector3.zero
							root.CFrame = desired
							root.AssemblyLinearVelocity = Vector3.zero
							if grounded and humanoid:GetState() ~= Enum.HumanoidStateType.Running then
								humanoid:ChangeState(Enum.HumanoidStateType.Running)
							end
						end)
					end

					if now - lastSlapAt >= Farm.SlapFarmInterval then
						lastSlapAt = now
						Combat.EnsureGlove()
						Combat.ActivateGlove(true)
					end
				end
			end
			task.wait(Farm.SlapFarmInterval)
		end
		Farm.SlapFarmThread = nil
	end)
end

function Farm.SetSlapFarm(state, silent)
	Farm.SlapFarmEnabled = state == true
	if Farm.SlapFarmEnabled then
		Combat.EnsureGlove()
		Farm.StartSlapFarm()
		if not silent then createNotification("Slap Farm", "Enabled. Locking onto targets.", "Success") end
	elseif not silent then
		createNotification("Slap Farm", "Disabled.")
	end
end

function Farm.SetSlapFarmSpeed(value)
	local rate = math.clamp(tonumber(value) or 20, 3, 50)
	Farm.SlapFarmInterval = 1 / rate
end

function Farm.SetSlapFarmRotate(value)
	Farm.SlapFarmRotate = math.clamp(tonumber(value) or 4, 1, 30)
end

function UI.SetNoclip(state, silent)
	UI.NoclipEnabled = state == true
	if UI.NoclipConnection then
		UI.NoclipConnection:Disconnect()
		UI.NoclipConnection = nil
	end
	if UI.NoclipEnabled then
		UI.NoclipConnection = RunService.Stepped:Connect(function()
			local character = player.Character
			if not character then return end
			for _, object in ipairs(character:GetDescendants()) do
				if object:IsA("BasePart") and object.CanCollide then object.CanCollide = false end
			end
		end)
	end
	if not silent then
		createNotification("Noclip", UI.NoclipEnabled and "Enabled." or "Disabled.")
	end
end

function UI.SetAntiAfk(state, silent)
	UI.AntiAfkEnabled = state == true
	if UI.AntiAfkConnection then
		UI.AntiAfkConnection:Disconnect()
		UI.AntiAfkConnection = nil
	end
	if UI.AntiAfkEnabled then
		UI.AntiAfkConnection = player.Idled:Connect(function()
			pcall(function()
				Services.VirtualUser:CaptureController()
				Services.VirtualUser:ClickButton2(Vector2.new())
			end)
		end)
	end
	if not silent then
		createNotification("Anti-AFK", UI.AntiAfkEnabled and "Enabled." or "Disabled.")
	end
end

--=====================================================================
-- ESP (green)
--=====================================================================
local ESP = { Enabled = false, Connections = {}, Folder = nil, Billboards = {}, Highlights = {}, StatObjectCache = {}, UpdateInterval = 1 }
ESP.Green = Color3.fromRGB(0, 255, 70)

local function ensureGuiFolder(folder, name)
	if folder and folder.Parent then return folder end
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	local newFolder = Instance.new("Folder")
	newFolder.Name = name or "Part"
	newFolder.Parent = playerGui or game:GetService("CoreGui")
	return newFolder
end

function ESP.EnsureFolder()
	ESP.Folder = ensureGuiFolder(ESP.Folder, "Part")
	return ESP.Folder
end

function ESP.StatSets()
	if Game.IsRoyale then
		return { "Kills", "Kill", "KOs" }, { "Power", "Strength", "Slaps" }
	end
	return { "Slaps" }, { "Gloves", "Glove" }
end

function ESP.GetStatValue(targetPlayer, statNames)
	local cache = ESP.StatObjectCache[targetPlayer]
	if cache then
		for _, statName in ipairs(statNames) do
			local cached = cache[statName]
			if cached and cached.Parent and cached:IsA("ValueBase") then return cached.Value end
		end
	end
	local leaderstats = targetPlayer:FindFirstChild("leaderstats")
	if leaderstats then
		for _, statName in ipairs(statNames) do
			local stat = leaderstats:FindFirstChild(statName)
			if stat and stat:IsA("ValueBase") then
				ESP.StatObjectCache[targetPlayer] = ESP.StatObjectCache[targetPlayer] or {}
				ESP.StatObjectCache[targetPlayer][statName] = stat
				return stat.Value
			end
		end
	end
	for _, statName in ipairs(statNames) do
		local attribute = targetPlayer:GetAttribute(statName)
		if attribute ~= nil then return attribute end
	end
	return "?"
end

function ESP.Remove(targetPlayer)
	local billboard = ESP.Billboards[targetPlayer]
	if billboard then billboard:Destroy() end
	ESP.Billboards[targetPlayer] = nil
	local highlight = ESP.Highlights[targetPlayer]
	if highlight then highlight:Destroy() end
	ESP.Highlights[targetPlayer] = nil
	ESP.StatObjectCache[targetPlayer] = nil
end

function ESP.Create(targetPlayer)
	if targetPlayer == player then return end
	ESP.Remove(targetPlayer)
	local character = targetPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not head or not humanoid or humanoid.Health <= 0 then return end
	local highlight = Instance.new("Highlight")
	highlight.Name = "Part"
	highlight.FillColor = ESP.Green
	highlight.OutlineColor = ESP.Green
	highlight.FillTransparency = 0.72
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = character
	ESP.Highlights[targetPlayer] = highlight
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Part"
	billboard.Size = UDim2.fromOffset(340, 150)
	billboard.StudsOffset = Vector3.new(0, 5.2, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 10000
	billboard.Adornee = head
	billboard.Parent = ESP.EnsureFolder()
	ESP.Billboards[targetPlayer] = billboard
	local label = Instance.new("TextLabel")
	label.Name = "Part"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = ESP.Green
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Font = Enum.Font.Code
	label.TextSize = 26
	label.TextWrapped = true
	label.RichText = true
	label.Parent = billboard
	task.spawn(function()
		while ESP.Enabled and billboard.Parent do
			local liveCharacter = targetPlayer.Character
			local liveHumanoid = liveCharacter and liveCharacter:FindFirstChildOfClass("Humanoid")
			if not liveHumanoid or liveHumanoid.Health <= 0 then
				ESP.Remove(targetPlayer)
				break
			end
			local killStats, powerStats = ESP.StatSets()
			label.Text = '<font color="rgb(0,255,70)">' .. targetPlayer.Name .. "</font>"
				.. '\n<font color="rgb(0,255,70)">HP ' .. math.floor(liveHumanoid.Health) .. "/" .. math.floor(liveHumanoid.MaxHealth) .. "</font>"
				.. '\n<font color="rgb(0,220,60)">' .. killStats[1] .. " " .. tostring(ESP.GetStatValue(targetPlayer, killStats)) .. "</font>"
				.. '\n<font color="rgb(0,220,60)">' .. powerStats[1] .. " " .. tostring(ESP.GetStatValue(targetPlayer, powerStats)) .. "</font>"
				.. '\n<font color="rgb(0,190,55)">SPD ' .. tostring(math.floor(liveHumanoid.WalkSpeed)) .. "</font>"
			task.wait(ESP.UpdateInterval)
		end
	end)
end

function ESP.Refresh()
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if ESP.Enabled then ESP.Create(targetPlayer) else ESP.Remove(targetPlayer) end
	end
end

function ESP.Enable()
	if ESP.Enabled then return end
	ESP.Enabled = true
	ESP.EnsureFolder()
	ESP.Refresh()
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		table.insert(ESP.Connections, targetPlayer.CharacterAdded:Connect(function()
			task.wait(0.5)
			if ESP.Enabled then ESP.Create(targetPlayer) end
		end))
	end
	table.insert(ESP.Connections, Players.PlayerAdded:Connect(function(targetPlayer)
		table.insert(ESP.Connections, targetPlayer.CharacterAdded:Connect(function()
			task.wait(0.5)
			if ESP.Enabled then ESP.Create(targetPlayer) end
		end))
	end))
	table.insert(ESP.Connections, Players.PlayerRemoving:Connect(ESP.Remove))
end

function ESP.Disable()
	ESP.Enabled = false
	for _, connection in ipairs(ESP.Connections) do connection:Disconnect() end
	ESP.Connections = {}
	for _, targetPlayer in ipairs(Players:GetPlayers()) do ESP.Remove(targetPlayer) end
	if ESP.Folder then
		for _, item in ipairs(ESP.Folder:GetChildren()) do item:Destroy() end
	end
end

function UI.SetPlayerStatsESP(state, silent)
	if state then
		ESP.Enable()
		if not silent then createNotification("ESP", "Enabled.", "Success") end
	else
		ESP.Disable()
		if not silent then createNotification("ESP", "Disabled.") end
	end
end

local ItemESP = { Enabled = false, Folder = nil, Rows = {}, Thread = nil, RefreshDelay = 2.5 }

function ItemESP.ClearObject(object)
	local row = ItemESP.Rows[object]
	if not row then return end
	if row.Highlight then row.Highlight:Destroy() end
	if row.Billboard then row.Billboard:Destroy() end
	ItemESP.Rows[object] = nil
end

function ItemESP.Clear()
	for object in pairs(ItemESP.Rows) do ItemESP.ClearObject(object) end
	if ItemESP.Folder then
		ItemESP.Folder:Destroy()
		ItemESP.Folder = nil
	end
end

function ItemESP.Refresh()
	if not Game.IsRoyale then return end
	local seen = {}
	for _, object in ipairs(Items.GetSearchChildren()) do
		local part = getLiveItemPart(object)
		if part then
			seen[object] = true
			local row = ItemESP.Rows[object]
			if not row then
				ItemESP.Folder = ensureGuiFolder(ItemESP.Folder, "Part")
				row = {}
				ItemESP.Rows[object] = row
				row.Highlight = Instance.new("Highlight")
				row.Highlight.Name = "Part"
				row.Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				row.Highlight.FillColor = ESP.Green
				row.Highlight.OutlineColor = ESP.Green
				row.Highlight.FillTransparency = 0.75
				row.Highlight.Parent = ItemESP.Folder
				row.Billboard = Instance.new("BillboardGui")
				row.Billboard.Name = "Part"
				row.Billboard.Size = UDim2.fromOffset(220, 44)
				row.Billboard.StudsOffset = Vector3.new(0, 3.2, 0)
				row.Billboard.AlwaysOnTop = true
				row.Billboard.MaxDistance = 1200
				row.Billboard.Parent = ItemESP.Folder
				row.Label = Instance.new("TextLabel")
				row.Label.Size = UDim2.fromScale(1, 1)
				row.Label.BackgroundTransparency = 1
				row.Label.Font = Enum.Font.Code
				row.Label.TextSize = 19
				row.Label.TextColor3 = ESP.Green
				row.Label.TextStrokeTransparency = 0.2
				row.Label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				row.Label.Parent = row.Billboard
			end
			row.Highlight.Adornee = part
			row.Billboard.Adornee = part
			row.Label.Text = object.Name
		end
	end
	for object in pairs(ItemESP.Rows) do
		if not seen[object] then ItemESP.ClearObject(object) end
	end
end

function UI.SetItemESP(state, silent)
	ItemESP.Enabled = state == true
	if ItemESP.Enabled then
		if not ItemESP.Thread then
			ItemESP.Thread = task.spawn(function()
				while ItemESP.Enabled do
					ItemESP.Refresh()
					task.wait(ItemESP.RefreshDelay)
				end
				ItemESP.Thread = nil
			end)
		end
	else
		ItemESP.Clear()
	end
	if not silent then createNotification("Item ESP", state and "Enabled." or "Disabled.") end
end

--=====================================================================
-- ANTI
--=====================================================================
Anti = {
	HideUnderMapEnabled = false, StaffEnabled = false, AcidLavaEnabled = false, AcidLavaParts = {},
	AntiAcidEnabled = false, AntiLavaEnabled = false, AntiCubeOfDeathEnabled = false,
	RemoveZoneEffectEnabled = false, DeleteAllSeatsEnabled = false, ZoneCenterPushEnabled = false,
	ZoneCenterPushForce = 1, StaffConnections = {},
	StaffKeywords = {
		"record", "recording", "rec", "clip", "proof", "evidence", "caught", "exposed", "screen record",
		"screenshot", "video", "obs", "stream", "live", "staff", "admin", "mod", "moderator",
		"report", "reported", "ticket", "discord",
	},
}

function Anti.EnableAcidLava()
	local covers = {
		{ CFrame = CFrame.new(-113, 16, -625), Size = Vector3.new(155, 1, 155) },
		{ CFrame = CFrame.new(-304, -21, 379), Size = Vector3.new(190, 1, 190) },
	}
	Anti.AcidLavaEnabled = true
	for index, cover in ipairs(covers) do
		local part = Anti.AcidLavaParts[index]
		if not part or not part.Parent then
			part = Instance.new("Part")
			part.Name = "Part"
			part.Anchored = true
			part.Transparency = 1
			part.CanTouch = false
			part.CanQuery = false
			part.Parent = workspace
			Anti.AcidLavaParts[index] = part
		end
		part.Size = cover.Size
		part.CFrame = cover.CFrame
		part.CanCollide = true
	end
	return #covers
end

function Anti.DisableAcidLava()
	Anti.AcidLavaEnabled = false
	for _, part in ipairs(Anti.AcidLavaParts) do
		if part and part.Parent then part.CanCollide = false end
	end
end

function Anti.SetAcidLava(state)
	if state then
		createNotification("Anti-Acid & Lava", "Enabled " .. tostring(Anti.EnableAcidLava()) .. " covers.", "Success")
	else
		Anti.DisableAcidLava()
		createNotification("Anti-Acid & Lava", "Disabled.")
	end
end

function Anti.ClearStaffConnections()
	for _, connection in ipairs(Anti.StaffConnections) do connection:Disconnect() end
	Anti.StaffConnections = {}
end

function Anti.HandleStaffChat(speaker, message)
	if not Anti.StaffEnabled or speaker == player then return end
	local lower = string.lower(tostring(message or ""))
	for _, keyword in ipairs(Anti.StaffKeywords) do
		if string.find(lower, keyword, 1, true) then
			player:Kick("Anti-Staff: " .. speaker.Name .. ": " .. tostring(message))
			return
		end
	end
end

function Anti.SetStaffEnabled(state, silent)
	Anti.StaffEnabled = state == true
	Anti.ClearStaffConnections()
	if Anti.StaffEnabled then
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			if targetPlayer ~= player then
				table.insert(Anti.StaffConnections, targetPlayer.Chatted:Connect(function(message)
					Anti.HandleStaffChat(targetPlayer, message)
				end))
			end
		end
		table.insert(Anti.StaffConnections, Players.PlayerAdded:Connect(function(targetPlayer)
			table.insert(Anti.StaffConnections, targetPlayer.Chatted:Connect(function(message)
				Anti.HandleStaffChat(targetPlayer, message)
			end))
		end))
		if not silent then createNotification("Anti-Staff", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Anti-Staff", "Disabled.")
	end
end

function Anti.GetGroundReturnCFrame(root)
	local character = player.Character
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if character then table.insert(exclude, character) end
	if UnderMapSafetyPlatform then table.insert(exclude, UnderMapSafetyPlatform) end
	params.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(Vector3.new(root.Position.X, 320, root.Position.Z), Vector3.new(0, -520, 0), params)
	if result and result.Position.Y > -80 and result.Position.Y < 260 then
		return CFrame.new(root.Position.X, result.Position.Y + UNDER_MAP_SAFE_OFFSET, root.Position.Z)
	end
	return CFrame.new(root.Position.X, 30 + UNDER_MAP_SAFE_OFFSET, root.Position.Z)
end

function Anti.SetHideUnderMap(state, silent)
	local _, root = Wait.ForCharacter(player, 5)
	if not root then
		if not silent then createNotification("Hide under map", "Could not find your character.", "Error") end
		return
	end
	if state and movementSave then
		if not silent then createNotification("Hide under map", "Wait for the movement lock to end.", "Warning") end
		return
	end
	if state then
		local platform = ensureUnderMapSafetyPlatform()
		platform.CanCollide = true
		Anti.HideUnderMapEnabled = true
		Teleport.MoveRoot(root, CFrame.new(root.Position.X, platform.Position.Y + (platform.Size.Y * 0.5) + UNDER_MAP_SAFE_OFFSET, root.Position.Z))
		if not silent then createNotification("Hide under map", "Moved under the map.", "Success") end
	else
		Anti.HideUnderMapEnabled = false
		Teleport.MoveRoot(root, Anti.GetGroundReturnCFrame(root))
		if UnderMapSafetyPlatform then UnderMapSafetyPlatform.CanCollide = false end
		if not silent then createNotification("Hide under map", "Moved above ground.", "Info") end
	end
end

function Anti.SetAntiAcid(state, silent)
	Anti.AntiAcidEnabled = state == true
	if not silent then createNotification("Anti Acid", state and "Enabled." or "Disabled.") end
end

function Anti.SetAntiLava(state, silent)
	Anti.AntiLavaEnabled = state == true
	if not silent then createNotification("Anti Lava", state and "Enabled." or "Disabled.") end
end

function Anti.SetAntiCubeOfDeath(state, silent)
	Anti.AntiCubeOfDeathEnabled = state == true
	if not silent then createNotification("Anti Cube", state and "Enabled." or "Disabled.") end
end

function Anti.SetRemoveZoneEffect(state, silent)
	Anti.RemoveZoneEffectEnabled = state == true
	if not silent then createNotification("Zone Effect", state and "Enabled." or "Disabled.") end
end

function Anti.SetDeleteAllSeats(state, silent)
	Anti.DeleteAllSeatsEnabled = state == true
	if not silent then createNotification("Seats", state and "Enabled." or "Disabled.") end
end

function Anti.SetZoneCenterPushForce(value) Anti.ZoneCenterPushForce = tonumber(value) or 1 end

function Anti.SetZoneCenterPush(state, silent)
	Anti.ZoneCenterPushEnabled = state == true
	if not silent then createNotification("Zone Push", state and "Enabled." or "Disabled.") end
end

if Game.IsRoyale then
	task.spawn(function()
		while true do
			if Anti.AntiAcidEnabled then
				local whitelist = {
					Colliders = true, Effects = true, IgnoreList = true, InteractableEvents = true, Items = true,
					Map = true, MapBounds = true, ["Rubbled Remains"] = true, Shipments = true, Lobby = true,
					Halloween = true, SoundRegions = true, Part = true,
				}
				for _, object in ipairs(workspace:GetChildren()) do
					if object:IsA("Folder") and not whitelist[object.Name] and object ~= Combat.AntiSlapBoxFolder then
						for _, child in ipairs(object:GetChildren()) do child:Destroy() end
						object:Destroy()
					end
				end
			end
			task.wait(0.2)
		end
	end)

	task.spawn(function()
		while true do
			if Anti.AntiLavaEnabled then
				for _, object in ipairs(workspace:GetDescendants()) do
					if object:IsA("BasePart") and object.Name == "Lava" then object:Destroy() end
				end
			end
			task.wait(0.2)
		end
	end)

	task.spawn(function()
		while true do
			if Anti.AntiCubeOfDeathEnabled then
				local rubble = workspace:FindFirstChild("Rubbled Remains")
				if rubble then
					for _, object in ipairs(rubble:GetDescendants()) do
						if object.Name == "Cube of Death" then object:Destroy() end
					end
				end
			end
			task.wait(0.2)
		end
	end)

	task.spawn(function()
		while true do
			if Anti.RemoveZoneEffectEnabled then
				for _, object in ipairs(workspace:GetDescendants()) do
					if object.Name == "ZoneEffects" then object:Destroy() end
				end
			end
			task.wait(0.5)
		end
	end)

	task.spawn(function()
		while true do
			if Anti.DeleteAllSeatsEnabled then
				for _, object in ipairs(workspace:GetDescendants()) do
					if object:IsA("Seat") then object:Destroy() end
				end
			end
			task.wait(0.5)
		end
	end)

	task.spawn(function()
		while true do
			if Anti.ZoneCenterPushEnabled then
				local zone = workspace:FindFirstChild("Zone1", true)
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if zone and zone:IsA("BasePart") and humanoid and root and humanoid.Health > 0
					and character:GetAttribute("inZone") == true then
					local offset = zone.Position - root.Position
					local direction = Vector3.new(offset.X, 0, offset.Z)
					if direction.Magnitude > 0.1 then
						direction = direction.Unit
						local speed = math.min(Anti.ZoneCenterPushForce * 0.5, 70)
						local velocity = root.AssemblyLinearVelocity
						root.AssemblyLinearVelocity = Vector3.new(direction.X * speed, velocity.Y, direction.Z * speed)
					end
				end
			end
			task.wait(0.1)
		end
	end)
end

function UI.SetSpeedBoost(state, silent)
	UI.SpeedBoostEnabled = state == true
	if not silent then createNotification("Speed Boost", state and "Enabled." or "Disabled.") end
end

task.spawn(function()
	while true do
		if UI.SpeedBoostEnabled then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.MoveDirection.Magnitude > 0 then
				root.CFrame = root.CFrame + humanoid.MoveDirection * 0.5
			end
		end
		task.wait(0.07)
	end
end)

local hideUsernameOriginalTexts = {}
local hideUsernameConnections = {}

local function hideUsernameReplace(instance)
	if not UI.HideUsernameEnabled or not instance:IsA("TextLabel") then return end
	local currentText = instance.Text
	if type(currentText) ~= "string" or not string.find(currentText, player.Name, 1, true) then return end
	if hideUsernameOriginalTexts[instance] == nil then hideUsernameOriginalTexts[instance] = currentText end
	instance.Text = string.gsub(currentText, player.Name, "...")
end

function UI.SetHideUsername(state, silent)
	UI.HideUsernameEnabled = state == true
	if UI.HideUsernameEnabled then
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			hideUsernameConnections[playerGui] = playerGui.DescendantAdded:Connect(function(instance)
				task.defer(hideUsernameReplace, instance)
			end)
		end
		task.spawn(function()
			while UI.HideUsernameEnabled do
				local current = player:FindFirstChildOfClass("PlayerGui")
				if current then
					for _, instance in ipairs(current:GetDescendants()) do hideUsernameReplace(instance) end
				end
				task.wait(0.5)
			end
		end)
		if not silent then createNotification("Hide Username", "Enabled.", "Success") end
	else
		for container, connection in pairs(hideUsernameConnections) do
			connection:Disconnect()
			hideUsernameConnections[container] = nil
		end
		for instance, original in pairs(hideUsernameOriginalTexts) do
			if instance and instance.Parent then instance.Text = original end
		end
		hideUsernameOriginalTexts = {}
		if not silent then createNotification("Hide Username", "Disabled.") end
	end
end

function UI.SetMaxZoomOut(value)
	pcall(function() player.CameraMaxZoomDistance = tonumber(value) or 128 end)
end

--=====================================================================
-- MAIN (puzzle / lab)
--=====================================================================
Main.CodeKeywords = { "math", "equation", "problem", "code", "puzzle", "question", "solve", "answer", "number" }
Main.CodeSearchOrigin = Vector3.new(464, 29, 323)
Main.CodeSearchRadius = 180
Main.KeypadSearchRadius = 170

function Main.GetPuzzleSearchRoots()
	local roots, seen = {}, {}
	local function add(object)
		if object and not seen[object] then
			seen[object] = true
			table.insert(roots, object)
		end
	end
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, object in ipairs(map:GetChildren()) do
			local lower = string.lower(object.Name)
			for _, word in ipairs(Main.CodeKeywords) do
				if string.find(lower, word, 1, true) then
					add(object)
					break
				end
			end
		end
	end
	local ok, parts = pcall(function() return workspace:GetPartBoundsInRadius(Main.CodeSearchOrigin, Main.CodeSearchRadius) end)
	if ok and parts then
		for _, part in ipairs(parts) do
			local current = part
			while current and current ~= workspace do
				if current:IsA("Model") or current:IsA("Folder") then
					add(current)
					break
				end
				current = current.Parent
			end
		end
	end
	return roots
end

function Main.GetCodePieceFromAssetName(name)
	local text = tostring(name)
	local exact = string.match(text, "^%s*(%d+)%s*$")
	if exact and #exact <= 4 then return exact end
	return string.match(text, "^%s*[Nn]umber%s*(%d)%s*$")
end

function Main.GetPuzzleCode()
	local found, ids = {}, {}
	for _, root in ipairs(Main.GetPuzzleSearchRoots()) do
		for _, object in ipairs(root:GetDescendants()) do
			local image = nil
			if object:IsA("ImageLabel") then
				image = object.Image
			elseif object:IsA("Decal") then
				image = object.Texture
			end
			if image and image ~= "" then
				local id = tonumber(string.match(image, "%d+"))
				if id and not found[id] then
					found[id] = true
					table.insert(ids, id)
				end
			end
		end
	end
	local code = ""
	for _, id in ipairs(ids) do
		local ok, info = pcall(function() return MarketplaceService:GetProductInfo(id) end)
		if ok and info and info.Name then
			local piece = Main.GetCodePieceFromAssetName(info.Name)
			if piece then code = code .. piece end
		end
	end
	return code
end

function Main.GetBarnKeypadButtonText(object)
	local text = tostring(object.Name or "")
	for _, descendant in ipairs(object:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			text = text .. " " .. tostring(descendant.Text)
		end
	end
	return string.lower(text)
end

function Main.FindBarnKeypadButton(target, isSubmit)
	local objects = {}
	local ok, parts = pcall(function() return workspace:GetPartBoundsInRadius(Main.CodeSearchOrigin, Main.KeypadSearchRadius) end)
	if ok and parts then
		for _, part in ipairs(parts) do
			table.insert(objects, part)
			local current = part.Parent
			local depth = 0
			while current and current ~= workspace and depth < 3 do
				table.insert(objects, current)
				current = current.Parent
				depth += 1
			end
		end
	end
	local best, bestScore = nil, -1
	for _, object in ipairs(objects) do
		local text = Main.GetBarnKeypadButtonText(object)
		local score = -1
		if isSubmit then
			if string.find(text, "green") or string.find(text, "enter") or string.find(text, "submit") then score = 25 end
		elseif target then
			if string.find(text, "%f[%d]" .. tostring(target) .. "%f[%D]") then score = 25 end
		end
		if score > 0 then
			if object:IsA("BasePart") then score += 2 end
			if score > bestScore then
				bestScore = score
				best = object
			end
		end
	end
	return best
end

function Main.ActivateButton(button)
	if not button or not button.Parent then return false end
	local clicked = false
	for _, descendant in ipairs(button:GetDescendants()) do
		if descendant:IsA("ClickDetector") and type(fireclickdetector) == "function" then
			pcall(function() fireclickdetector(descendant) clicked = true end)
		end
	end
	return clicked
end

function Main.EnterBarnKeypadCode(code)
	code = tostring(code or ""):gsub("%D", "")
	if code == "" then return false end
	for digit in string.gmatch(code, "%d") do
		if not Main.ActivateButton(Main.FindBarnKeypadButton(digit, false)) then return false end
		task.wait(0.09)
	end
	return Main.ActivateButton(Main.FindBarnKeypadButton(nil, true))
end

function Main.FindRoundTimer()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return nil end
	local bestNumber, bestScore = nil, -1
	for _, object in ipairs(playerGui:GetDescendants()) do
		if object:IsA("TextLabel") then
			local number = tonumber(string.match(object.Text, "^%s*(%d+)%s*$"))
			if number and number <= 600 then
				local full = string.lower(object:GetFullName())
				local score = object.Visible and 3 or 0
				for _, word in ipairs({ "timer", "countdown", "bus", "round", "match" }) do
					if string.find(full, word, 1, true) then score += 10 end
				end
				if score > bestScore then
					bestScore = score
					bestNumber = number
				end
			end
		end
	end
	return bestNumber
end

function Main.GetCodeGoBarn()
	Teleport.ToLocation("Bunker", Main.CodeSearchOrigin, true)
	Notify.Show("Code", "Searching...", "Info", nil, 2.2, true)
	task.spawn(function()
		local code = Wait.For(function()
			local found = Main.GetPuzzleCode()
			return found ~= "" and found
		end, 3) or ""
		Notify.Show("Code Found", code ~= "" and code or "No code found.", code ~= "" and "Success" or "Info", nil, 4, true)
		if code ~= "" then
			Wait.Sleep(0.2)
			if Main.EnterBarnKeypadCode(code) then
				Notify.Show("Barn Keypad", "Entered " .. code .. ".", "Success", nil, 3.5, true)
			else
				Notify.Show("Barn Keypad", "Could not press every key.", "Warning", nil, 4, true)
			end
		end
	end)
end

local labAssetCodes = {
	["9648755440"] = "8", ["9648765536"] = "2", ["9648723237"] = "3", ["9648718450"] = "6",
	["9648769161"] = "4", ["9648730082"] = "6", ["9648734698"] = "2", ["9648712563"] = "2",
	["9648742013"] = "7", ["9648745618"] = "3", ["9648715920"] = "6", ["9648752438"] = "2",
	["9648749145"] = "8", ["9648759883"] = "9", ["9648738553"] = "8",
}

local function labGetCode()
	local map = workspace:FindFirstChild("Map")
	local brick = map and map:FindFirstChild("CodeBrick")
	local surfaceGui = brick and brick:FindFirstChild("SurfaceGui")
	if not surfaceGui then return nil, "CodeBrick not found." end
	local templates = {}
	for _, object in ipairs(surfaceGui:GetChildren()) do
		if object.Name == "IMGTemplate" then table.insert(templates, object) end
	end
	if #templates ~= 4 then return nil, "Found " .. #templates .. " images." end
	table.sort(templates, function(a, b) return a.AbsolutePosition.X < b.AbsolutePosition.X end)
	local result = {}
	for index, imageObject in ipairs(templates) do
		local image = tostring(imageObject.Image)
		local assetId = image:match("id=(%d+)") or image:match("rbxassetid://(%d+)")
		local digit = assetId and labAssetCodes[assetId]
		if not digit then return nil, "Unknown image at " .. index end
		result[index] = digit
	end
	return table.concat(result)
end

local function labGetButtons()
	local map = workspace:FindFirstChild("Map")
	local office = map and map:FindFirstChild("OriginOffice")
	local codeDoor = office and office:FindFirstChild("CodeDoor")
	local door = codeDoor and codeDoor:FindFirstChild("Door")
	local keypad = door and door:FindFirstChild("Keypad")
	local buttons = keypad and keypad:FindFirstChild("Buttons")
	if not buttons then return nil, "Keypad not found." end
	return buttons, nil, door
end

local function labEnterCode(buttons, code)
	for index = 1, #code do
		local digit = code:sub(index, index)
		local button = buttons:FindFirstChild(digit)
		local detector = button and button:FindFirstChildOfClass("ClickDetector")
		if not detector or type(fireclickdetector) ~= "function" then return false end
		pcall(fireclickdetector, detector)
		task.wait(0.15)
	end
	local enter = buttons:FindFirstChild("Enter")
	local detector = enter and enter:FindFirstChildOfClass("ClickDetector")
	if not detector then return false end
	pcall(fireclickdetector, detector)
	return true
end

function Main.OpenLabAndTeleport()
	local code, err = labGetCode()
	if not code then
		createNotification("Open Lab", err or "Could not read the code.", "Warning")
		return
	end
	local buttons, keypadErr, door = labGetButtons()
	if not buttons then
		createNotification("Open Lab", keypadErr or "Keypad not found.", "Warning")
		return
	end
	local doorPart = door and door:FindFirstChildWhichIsA("BasePart", true)
	local character, root = Wait.ForCharacter(player, 6)
	if not doorPart or not root then
		createNotification("Open Lab", "Door or character missing.", "Warning")
		return
	end
	root.CFrame = CFrame.new(doorPart.Position - doorPart.CFrame.RightVector * 20) * (root.CFrame - root.CFrame.Position)
	local reset = buttons:FindFirstChild("Reset")
	local resetDetector = reset and reset:FindFirstChildOfClass("ClickDetector")
	if resetDetector and type(fireclickdetector) == "function" then pcall(fireclickdetector, resetDetector) end
	task.wait(0.2)
	if labEnterCode(buttons, code) then
		createNotification("Code Entered [" .. code .. "]", "Opened and teleported.", "Success")
	else
		createNotification("Open Lab", "Could not enter the code.", "Warning")
	end
end

function Main.OpenBunker()
	local code, err = labGetCode()
	if not code then
		createNotification("Open Bunker", err or "Could not read the code.", "Warning")
		return
	end
	local buttons, keypadErr = labGetButtons()
	if not buttons then
		createNotification("Open Bunker", keypadErr or "Keypad not found.", "Warning")
		return
	end
	local reset = buttons:FindFirstChild("Reset")
	local resetDetector = reset and reset:FindFirstChildOfClass("ClickDetector")
	if resetDetector and type(fireclickdetector) == "function" then pcall(fireclickdetector, resetDetector) end
	task.wait(0.2)
	if labEnterCode(buttons, code) then
		createNotification("Bunker Code [" .. code .. "]", "Entered.", "Success")
	else
		createNotification("Open Bunker", "Could not enter the code.", "Warning")
	end
end

function Main.ShowLabCode()
	local code, err = labGetCode()
	if not code then
		createNotification("Show Lab Code", err or "Could not read the code.", "Warning")
		return
	end
	createNotification("Lab Code: " .. code, "Hides in 10s.", "Info", nil, 10, true)
end

--=====================================================================
-- EARLY BUS JUMP (Royale, original)
--=====================================================================
function UI.FireEarlyBusJump()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("BusJumping")
	if not remote or not remote:IsA("RemoteEvent") then
		createNotification("Early Bus Jump", "BusJumping remote not found.", "Error")
		return false
	end
	local ok = pcall(function() remote:FireServer(true) end)
	if not ok then return false end
	UI.JumpBusExitSent = true
	UI.LastAutoEarlyBusJumpAt = os.clock()
	local unlockAt = os.clock() + 10
	Items.EarlyBusFBlockActive = true
	Teleport.BlockFUntil = math.max(Teleport.BlockFUntil or 0, unlockAt)
	Teleport.RefreshPickupLock()
	task.delay(math.max(0.05, unlockAt - os.clock()), function()
		if Teleport.BlockFUntil <= unlockAt + 0.02 then
			Items.EarlyBusFBlockActive = false
			Teleport.RefreshPickupLock()
		end
	end)
	if UI.TeleportToEarlyBusPriorityItem then UI.TeleportToEarlyBusPriorityItem(true) end
	return true
end

function UI.RefreshJumpBusTimerWindow()
	local timerNumber = Main.FindRoundTimer()
	local now = os.clock()
	if timerNumber then
		UI.JumpBusTimerSeen = true
		if timerNumber <= 5 then UI.LastSlapRoyaleTimerZeroAt = now end
		UI.LastSlapRoyaleTimerNumber = timerNumber
	elseif UI.LastSlapRoyaleTimerNumber and UI.LastSlapRoyaleTimerNumber <= 5 then
		UI.LastSlapRoyaleTimerZeroAt = now
		UI.LastSlapRoyaleTimerNumber = nil
	else
		UI.LastSlapRoyaleTimerNumber = nil
	end
end

function UI.IsJumpBusDetectionActive()
	UI.RefreshJumpBusTimerWindow()
	if UI.JumpBusExitSent then return true end
	if UI.JumpBusSearchActive ~= true then return false end
	local now = os.clock()
	if now - (UI.LastSlapRoyaleTimerZeroAt or -math.huge) <= 7 then return true end
	return not UI.JumpBusTimerSeen and now - (UI.JumpBusSearchStartedAt or 0) <= 12
end

function UI.IsJumpBusCandidate(object)
	return string.find(string.lower(object.Name), "bus", 1, true) ~= nil and (object:IsA("Model") or object:IsA("BasePart"))
end

function UI.GetBusCandidates(rootPosition)
	if os.clock() - (UI.LastBusSearchAt or 0) < 0.65 then return UI.BusSearchCache or {} end
	local results = {}
	if UI.IsJumpBusDetectionActive() and rootPosition then
		local seen = {}
		local ok, nearbyParts = pcall(function()
			return workspace:GetPartBoundsInBox(CFrame.new(rootPosition), Vector3.new(180, 130, 180))
		end)
		if ok then
			for _, part in ipairs(nearbyParts) do
				local candidate = Teleport.GetBusCandidateFromObject(part)
				if candidate and not seen[candidate] then
					seen[candidate] = true
					table.insert(results, candidate)
				end
			end
		end
		if #results == 0 then
			for _, object in ipairs(workspace:GetChildren()) do
				if UI.IsJumpBusCandidate(object) and not seen[object] then
					seen[object] = true
					table.insert(results, object)
				end
			end
		end
	end
	UI.BusSearchCache = results
	UI.LastBusSearchAt = os.clock()
	return results
end

function UI.IsPointNearObjectBounds(point, object)
	if object:IsA("BasePart") then
		local localPoint = object.CFrame:PointToObjectSpace(point)
		local halfSize = (object.Size * 0.5) + Vector3.new(14, 14, 14)
		return math.abs(localPoint.X) <= halfSize.X and math.abs(localPoint.Y) <= halfSize.Y and math.abs(localPoint.Z) <= halfSize.Z
	end
	if object:IsA("Model") then
		local ok, cframe, size = pcall(function() return object:GetBoundingBox() end)
		if ok then
			local localPoint = cframe:PointToObjectSpace(point)
			local halfSize = (size * 0.5) + Vector3.new(18, 18, 18)
			return math.abs(localPoint.X) <= halfSize.X and math.abs(localPoint.Y) <= halfSize.Y and math.abs(localPoint.Z) <= halfSize.Z
		end
	end
	return false
end

function UI.IsLocalPlayerInBus()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	if UI.JumpBusTrackedObject and UI.JumpBusTrackedObject.Parent then
		if UI.IsPointNearObjectBounds(root.Position, UI.JumpBusTrackedObject) then
			UI.LastJumpBusSeenAt = os.clock()
			return true
		end
		if UI.JumpBusExitSent then return false end
	end
	for _, busObject in ipairs(UI.GetBusCandidates(root.Position)) do
		if busObject.Parent and UI.IsPointNearObjectBounds(root.Position, busObject) then
			UI.LastJumpBusSeenAt = os.clock()
			UI.JumpBusTrackedObject = busObject
			return true
		end
	end
	return false
end

function UI.FindEarlyBusPriorityLandingTarget()
	for _, wantedName in ipairs(Items.PermanentCollectStopOrder) do
		local manualObject, manualPart = Items.FindManualItem(wantedName)
		if manualObject and manualPart then
			return wantedName, manualPart.Position, manualObject, manualPart
		end
	end
	return nil, nil, nil, nil
end

function UI.PrepareEarlyBusLandingCharacter(character, root)
	if root and root.Parent then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid.Sit = false
			humanoid.PlatformStand = false
			humanoid.Jump = true
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end)
	end
end

function UI.TeleportToEarlyBusPriorityItem()
	task.spawn(function()
		local deadline = os.clock() + 18
		local name, position, object, part
		repeat
			Items.RebuildSearchCache()
			name, position, object, part = UI.FindEarlyBusPriorityLandingTarget()
			if name and part then break end
			task.wait(0.1)
		until os.clock() >= deadline
		if not name or not part then
			createNotification("Early Bus Jump", "No priority item was ready.", "Warning")
			return
		end
		local character, root = Wait.ForCharacter(player, 5)
		if not root then return end
		UI.PrepareEarlyBusLandingCharacter(character, root)
		Teleport.MoveRoot(root, Teleport.GetItemCFrame(part, { character, object }), part.Position)
		Teleport.StabilizeItemView(root, part)
		Teleport.AddFixedStrike(Teleport.DefaultMaxStrikes, Teleport.DefaultCooldown)
		createNotification("Early Bus Jump", "Teleported to " .. name .. ".", "Success")
	end)
end

function UI.RunAutoEarlyBusJump()
	if UI.AutoEarlyBusJumpThread then return end
	UI.JumpBusSearchActive = true
	UI.JumpBusExitSent = false
	UI.JumpBusTrackedObject = nil
	UI.JumpBusSearchStartedAt = os.clock()
	UI.JumpBusTimerSeen = false
	UI.LastSlapRoyaleTimerNumber = nil
	UI.LastSlapRoyaleTimerZeroAt = -math.huge
	UI.AutoEarlyBusJumpThread = task.spawn(function()
		while UI.AutoEarlyBusJumpEnabled do
			local inBus = UI.IsLocalPlayerInBus()
			if inBus and not UI.AutoEarlyBusJumpFiredInBus and os.clock() - (UI.LastAutoEarlyBusJumpAt or 0) >= 1 then
				if UI.FireEarlyBusJump() then
					UI.AutoEarlyBusJumpFiredInBus = true
				end
			elseif not inBus and not UI.JumpBusExitSent then
				UI.AutoEarlyBusJumpFiredInBus = false
			end
			task.wait(0.15)
		end
		UI.AutoEarlyBusJumpThread = nil
		UI.AutoEarlyBusJumpFiredInBus = false
		UI.JumpBusSearchActive = false
	end)
end

function UI.SetAutoEarlyBusJump(state, silent)
	UI.AutoEarlyBusJumpEnabled = state == true
	if UI.AutoEarlyBusJumpEnabled then
		UI.JumpBusSearchActive = true
		UI.JumpBusExitSent = false
		UI.JumpBusTrackedObject = nil
		UI.AutoEarlyBusJumpFiredInBus = false
		UI.JumpBusSearchStartedAt = os.clock()
		UI.JumpBusTimerSeen = false
		UI.LastSlapRoyaleTimerNumber = nil
		UI.LastSlapRoyaleTimerZeroAt = -math.huge
		UI.RunAutoEarlyBusJump()
		if not silent then createNotification("Early Bus Jump", "Enabled.", "Success") end
	else
		UI.JumpBusSearchActive = false
		UI.JumpBusExitSent = false
		UI.JumpBusTrackedObject = nil
		UI.AutoEarlyBusJumpFiredInBus = false
		if not silent then createNotification("Early Bus Jump", "Disabled.") end
	end
end

--=====================================================================
-- MISC UI
--=====================================================================
function UI.SetInfiniteJump(state, silent)
	UI.InfiniteJumpEnabled = state == true
	if UI.InfiniteJumpConnection then
		UI.InfiniteJumpConnection:Disconnect()
		UI.InfiniteJumpConnection = nil
	end
	if UI.InfiniteJumpEnabled then
		UI.InfiniteJumpConnection = UserInputService.JumpRequest:Connect(function()
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				pcall(function()
					humanoid.Jump = true
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				end)
			end
		end)
	end
	if not silent then
		createNotification("Infinite Jump", UI.InfiniteJumpEnabled and "Enabled." or "Disabled.")
	end
end

function UI.SetInstantLand(state, silent)
	UI.InstantLandEnabled = state == true
	if not silent then
		createNotification("Instant Landing", UI.InstantLandEnabled and "Enabled." or "Disabled.")
	end
end

task.spawn(function()
	local lastTransparency, canCount = 1, false
	while true do
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if UI.InstantLandEnabled and head then
			local transparency = head.Transparency
			if transparency == 1 then canCount = true end
			if transparency == 0 and lastTransparency ~= 0 and canCount then
				local crystal = workspace:FindFirstChild("CrystalBlue", true)
				local root = character:FindFirstChild("HumanoidRootPart")
				if crystal and root then
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { character }
					local result = workspace:Raycast(crystal.Position + Vector3.new(0, 40, 0), Vector3.new(0, -500, 0), params)
					root.CFrame = CFrame.new(result and result.Position + Vector3.new(0, 3, 0) or crystal.Position + Vector3.new(0, 3, 0))
				end
				canCount = false
				UI.InstantLandEnabled = false
				if UI.ToggleRefs.InstantLand then UI.ToggleRefs.InstantLand.Set(false, false) end
			end
			lastTransparency = transparency
		else
			lastTransparency = 1
			canCount = false
		end
		task.wait(0.05)
	end
end)

function UI.SetAutoRejoin(state, silent)
	UI.AutoRejoinEnabled = state == true
	if UI.AutoRejoinEnabled then
		local function hook(character)
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid then return end
			humanoid.Died:Connect(function()
				if UI.AutoRejoinEnabled then
					pcall(function() Services.TeleportService:Teleport(game.PlaceId, player) end)
				end
			end)
		end
		hook(player.Character)
		player.CharacterAdded:Connect(function(character)
			task.wait(0.3)
			if UI.AutoRejoinEnabled then hook(character) end
		end)
		if not silent then createNotification("Auto Rejoin", "Enabled.", "Success") end
	elseif not silent then
		createNotification("Auto Rejoin", "Disabled.")
	end
end

--=====================================================================
-- PREFERENCES
--=====================================================================
pcall(function()
	WindUI:AddTheme({ Name = "Matrix", Toggle = "#33C759", Accent = "#00FF41", Outline = "#33FF66", Text = "#E0FFE8", PlaceholderText = "#66CC77", Background = "#000A02", Dialog = "#001405", Icon = "#00FF41" })
	WindUI:AddTheme({ Name = "Terminal", Toggle = "#33C759", Accent = "#39FF14", Outline = "#7CFF66", Text = "#F0FFF0", PlaceholderText = "#88CC88", Background = "#020A02", Dialog = "#041404", Icon = "#39FF14" })
	WindUI:AddTheme({ Name = "Neon Orchid", Toggle = "#33C759", Accent = "#CC33FF", Outline = "#FF66DD", Text = "#FFF5FB", PlaceholderText = "#D4A0C6", Background = "#180D18", Dialog = "#241524", Icon = "#FF99DD" })
end)

local PREFERENCES_FILE = "SVCLUTCHER_HUB/preferences.json"
local PREFERENCES_FALLBACK = "SVCLUTCHER_HUB_preferences.json"
local Preferences = { Toggles = {}, Sliders = {}, Dropdowns = {}, Inputs = {}, Theme = "Matrix" }
local preferencesSaveQueued = false

local function ensurePreferenceTables()
	if type(Preferences.Toggles) ~= "table" then Preferences.Toggles = {} end
	if type(Preferences.Sliders) ~= "table" then Preferences.Sliders = {} end
	if type(Preferences.Dropdowns) ~= "table" then Preferences.Dropdowns = {} end
	if type(Preferences.Inputs) ~= "table" then Preferences.Inputs = {} end
	if type(Preferences.Theme) ~= "string" or Preferences.Theme == "" then Preferences.Theme = "Matrix" end
end

local function savePreferences()
	ensurePreferenceTables()
	if type(writefile) ~= "function" then return end
	local encoded = HttpService:JSONEncode(Preferences)
	local ok = pcall(function()
		if type(makefolder) == "function" and type(isfolder) == "function" then
			local existsOk, exists = pcall(isfolder, "SVCLUTCHER_HUB")
			if not (existsOk and exists) then pcall(makefolder, "SVCLUTCHER_HUB") end
		end
		writefile(PREFERENCES_FILE, encoded)
	end)
	if not ok then pcall(function() writefile(PREFERENCES_FALLBACK, encoded) end) end
end

local function queueSavePreferences()
	if preferencesSaveQueued then return end
	preferencesSaveQueued = true
	task.delay(0.25, function()
		preferencesSaveQueued = false
		savePreferences()
	end)
end

local function loadPreferences()
	if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
	for _, fileName in ipairs({ PREFERENCES_FILE, PREFERENCES_FALLBACK }) do
		local existsOk, exists = pcall(isfile, fileName)
		if existsOk and exists then
			local readOk, contents = pcall(readfile, fileName)
			if readOk and type(contents) == "string" and contents ~= "" then
				local decodeOk, decoded = pcall(function() return HttpService:JSONDecode(contents) end)
				if decodeOk and type(decoded) == "table" then
					for key, value in pairs(decoded) do
						if Preferences[key] == nil or type(Preferences[key]) == type(value) then Preferences[key] = value end
					end
				end
				break
			end
		end
	end
	ensurePreferenceTables()
end

loadPreferences()
ensurePreferenceTables()

Teleport.CustomSettingDefinitions = {
	CustomStrikes = { Default = Teleport.DefaultMaxStrikes, Min = 1, Max = 50, Integer = true },
	CustomTPDebounce = { Default = Teleport.DefaultDebounce, Min = 0, Max = 7 },
	CustomFLock = { Default = Teleport.DefaultPostFLock, Min = 0, Max = 60 },
}

function Teleport.GetCustomSettingValue(key)
	local definition = Teleport.CustomSettingDefinitions[key]
	if not definition then return nil end
	local number = tonumber(Preferences.Inputs[key])
	if not number then return definition.Default end
	number = math.clamp(number, definition.Min, definition.Max)
	if definition.Integer then number = math.floor(number + 0.5) end
	return number
end

function Teleport.GetCustomFLockDuration(defaultDuration)
	if tonumber(Preferences.Inputs.CustomFLock) then
		return Teleport.GetCustomSettingValue("CustomFLock") or Teleport.DefaultPostFLock
	end
	return tonumber(defaultDuration) or Teleport.PostFLock or Teleport.DefaultPostFLock
end

function Teleport.GetEarlyAutoCollectResumeDelay()
	return (Teleport.GetCustomFLockDuration(10) or 10) + 1
end

function Teleport.ApplyCustomSettings()
	Teleport.MaxStrikes = Teleport.GetCustomSettingValue("CustomStrikes") or Teleport.DefaultMaxStrikes
	Teleport.Debounce = Teleport.GetCustomSettingValue("CustomTPDebounce") or Teleport.DefaultDebounce
	Teleport.PostFLock = Teleport.GetCustomSettingValue("CustomFLock") or Teleport.DefaultPostFLock
	Items.TeleportDebounce = Teleport.Debounce
end

function Teleport.SetCustomSetting(key, rawValue)
	local definition = Teleport.CustomSettingDefinitions[key]
	if not definition then return false end
	local text = tostring(rawValue or ""):gsub("%s", "")
	if text == "" then
		Preferences.Inputs[key] = nil
	else
		local number = tonumber(text)
		if not number then return false end
		number = math.clamp(number, definition.Min, definition.Max)
		if definition.Integer then number = math.floor(number + 0.5) end
		Preferences.Inputs[key] = tostring(number)
	end
	Teleport.ApplyCustomSettings()
	queueSavePreferences()
	return true
end

function Teleport.ResetCustomSettings()
	Preferences.Inputs.CustomStrikes = nil
	Preferences.Inputs.CustomTPDebounce = nil
	Preferences.Inputs.CustomFLock = nil
	Teleport.ApplyCustomSettings()
	queueSavePreferences()
end

Teleport.ApplyCustomSettings()

--=====================================================================
-- WINDOW / TABS
--=====================================================================
local WindUIWindow = WindUI:CreateWindow({
	Title = "SVCLUTCHER HUB // " .. Game.Label,
	Icon = "terminal",
	Author = "PUMPKIN HUB FEATURE CREDITS",
	Folder = "SVCLUTCHER_HUB",
	Size = UDim2.fromOffset(580, 460),
	ToggleKey = Enum.KeyCode.T,
	Transparent = true,
	Theme = Preferences.Theme or "Matrix",
	SideBarWidth = 200,
})

local TabMain = WindUIWindow:Tab({ Title = "MAIN", Icon = "terminal" })
local TabTeleports = WindUIWindow:Tab({ Title = "GOTO", Icon = "map-pin" })
local TabCombat = WindUIWindow:Tab({ Title = "COMBAT", Icon = "swords" })
local TabItems, TabFarm, TabSafety, TabSettings
if Game.IsRoyale then TabItems = WindUIWindow:Tab({ Title = "ITEMS", Icon = "box" }) end
if Game.IsBattles then TabFarm = WindUIWindow:Tab({ Title = "FARM", Icon = "zap" }) end
TabSafety = WindUIWindow:Tab({ Title = "SAFETY", Icon = "shield" })
TabSettings = WindUIWindow:Tab({ Title = "SETTINGS", Icon = "wrench" })

local TOGGLE_ON_COLOR = Color3.fromRGB(0, 255, 70)

local function safeTask(fn, ...)
	if type(fn) ~= "function" then return end
	local args = table.pack(...)
	task.spawn(function()
		local ok, err = pcall(function() fn(table.unpack(args, 1, args.n)) end)
		if not ok then createNotification("SVCLUTCHER HUB", tostring(err), "Error", nil, 5, true) end
	end)
end

local function normalizeToggleValue(value, fallback)
	if type(value) == "table" then
		local nested = value.Value
		if nested == nil then nested = value.State end
		if nested ~= nil then return normalizeToggleValue(nested, fallback) end
		return fallback == true
	end
	if value == nil then return fallback == true end
	return value == true
end

local function AddButton(tab, title, desc, icon, callback)
	if not tab then return end
	return tab:Button({ Title = title, Desc = desc, Icon = icon or "", Callback = function() safeTask(callback) end })
end

local function AddToggle(tab, title, desc, default, callback, key)
	if not tab then return nil, nil end
	local prefKey = key or title
	local saved = Preferences.Toggles[prefKey]
	local ref = { Value = saved == nil and default == true or saved == true }
	local suppress, ready = false, false
	local toggle = tab:Toggle({
		Title = title, Desc = desc, Color = TOGGLE_ON_COLOR, Value = ref.Value, Default = ref.Value,
		Callback = function(value)
			if suppress or not ready then return end
			ref.Value = normalizeToggleValue(value, ref.Value)
			Preferences.Toggles[prefKey] = ref.Value
			queueSavePreferences()
			safeTask(callback, ref.Value)
		end,
	})
	task.defer(function()
		ready = true
		if ref.Value then safeTask(callback, true) end
	end)
	function ref.Set(value, fire)
		ref.Value = normalizeToggleValue(value, ref.Value)
		Preferences.Toggles[prefKey] = ref.Value
		queueSavePreferences()
		suppress = true
		pcall(function() if type(toggle.Value) ~= "function" then toggle.Value = ref.Value end end)
		if type(toggle.Set) == "function" then pcall(toggle.Set, toggle, ref.Value) end
		suppress = false
		if fire ~= false then safeTask(callback, ref.Value) end
	end
	function ref.Get() return ref.Value end
	function ref.Sync() ref.Set(ref.Value, false) end
	if key then UI.ToggleRefs[key] = ref end
	return toggle, ref
end

local function AddSlider(tab, title, desc, minValue, maxValue, defaultValue, step, callback, key)
	if not tab then return end
	local prefKey = key or title
	local saved = math.clamp(tonumber(Preferences.Sliders[prefKey]) or defaultValue, minValue, maxValue)
	local ready = false
	local slider = tab:Slider({
		Title = title, Desc = desc, Step = step or 1,
		Value = { Min = minValue, Max = maxValue, Default = saved },
		Callback = function(value)
			if not ready then return end
			local numeric = tonumber(value) or saved
			Preferences.Sliders[prefKey] = numeric
			queueSavePreferences()
			safeTask(callback, numeric)
		end,
	})
	task.defer(function()
		ready = true
		if Preferences.Sliders[prefKey] ~= nil then safeTask(callback, saved) end
	end)
	return slider
end

local function AddDropdown(tab, title, desc, values, defaultValue, callback, key)
	if not tab then return end
	local prefKey = key or title
	local saved = Preferences.Dropdowns[prefKey]
	local chosen = defaultValue
	if saved ~= nil then
		for _, value in ipairs(values) do
			if tostring(value) == tostring(saved) then chosen = saved end
		end
	end
	local ready = false
	local dropdown = tab:Dropdown({
		Title = title, Desc = desc, Values = values, Value = chosen,
		Callback = function(value)
			if not ready then return end
			local selected = type(value) == "table" and (value.Value or value.Title) or value
			Preferences.Dropdowns[prefKey] = selected
			queueSavePreferences()
			safeTask(callback, selected)
		end,
	})
	task.defer(function() ready = true end)
	return dropdown
end

local function AddInput(tab, title, desc, placeholder, callback, key)
	if not tab then return end
	local prefKey = key or title
	local ready = false
	local input = tab:Input({
		Title = title, Desc = desc, Value = tostring(Preferences.Inputs[prefKey] or ""),
		InputIcon = "hash", Type = "Input", Placeholder = tostring(placeholder or ""),
		Callback = function(value)
			if ready then safeTask(callback, value) end
		end,
	})
	task.defer(function() ready = true end)
	UI.InputRefs[prefKey] = input
	return input
end

function UI.SyncCustomSettingInputVisuals()
	for key, input in pairs(UI.InputRefs) do
		if input and type(input.Set) == "function" then
			pcall(function() input:Set(tostring(Preferences.Inputs[key] or "")) end)
		end
	end
end

function UI.SetToggleByKey(key, value, fireCallback)
	local toggle = UI.ToggleRefs[key]
	if toggle then toggle.Set(value, fireCallback ~= false) end
end

function UI.SetRecommendedSettings(state)
	local enabled = state == true
	local keys = { "SlapAura", "AutoHeal", "AntiRagdoll", "PlayerESP" }
	if Game.IsRoyale then
		table.insert(keys, "ItemESP")
		table.insert(keys, "AutoRejoin")
		table.insert(keys, "EarlyBusJump")
	else
		table.insert(keys, "FarmAutoSlap")
		table.insert(keys, "AntiAfk")
	end
	for _, key in ipairs(keys) do UI.SetToggleByKey(key, enabled, true) end
end

--=====================================================================
-- CONTROLS
--=====================================================================
AddButton(TabMain, "Recommended Settings", "Aura, heal, anti-ragdoll, ESP", "sparkles", function()
	UI.SetRecommendedSettings(true)
end)

AddToggle(TabMain, "Walk Speed", "Velocity speed (WalkSpeed stays untouched)", false, Speed.SetEnabled, "WalkSpeed")
AddSlider(TabMain, "Speed Value", "Top speed in studs", Speed.Min, Speed.Max, Speed.Value, Speed.Step, Speed.SetValue, "SpeedValue")
AddToggle(TabMain, "Infinite Jump", "Jump forever", false, UI.SetInfiniteJump, "InfiniteJump")
AddToggle(TabMain, "Player ESP", "Green player overlay", false, UI.SetPlayerStatsESP, "PlayerESP")
if Game.IsRoyale then
	AddToggle(TabMain, "Early Bus YEET", "Yeets you out of the bus", false, UI.SetAutoEarlyBusJump, "EarlyBusJump")
	AddToggle(TabMain, "Instant Landing", "Snap to crystal on land", false, UI.SetInstantLand, "InstantLand")
	AddToggle(TabMain, "Item ESP", "Green item overlay", false, UI.SetItemESP, "ItemESP")
	AddToggle(TabMain, "Auto Rejoin", "Rejoin on death", false, UI.SetAutoRejoin, "AutoRejoin")
	AddButton(TabMain, "Get Code + Go Barn", "Reads code and enters keypad", "hash", Main.GetCodeGoBarn)
	AddButton(TabMain, "Open Lab + Teleport", "Reads code, teleports, enters it", "door-open", Main.OpenLabAndTeleport)
	AddButton(TabMain, "Open Bunker", "Reads code and enters it", "door-closed", Main.OpenBunker)
	AddButton(TabMain, "Show Lab Code", "Shows the code for 10s", "eye", Main.ShowLabCode)
end

AddButton(TabTeleports, "Teleport To Nearest", "Closest valid player", "crosshair", Combat.TeleportToNearestPlayer)
AddButton(TabTeleports, "Teleport To Lowest HP", "Weakest player", "heart-pulse", Combat.TeleportToLowestHealthPlayer)
if Game.IsRoyale then
	AddButton(TabTeleports, "On School Bus", "Top of the bus", "bus-front", Teleport.ToSchoolBusTop)
	AddButton(TabTeleports, "Lobby Hider", "Above lobby ceiling", "home", Teleport.ToLobbyHider)
end

AddSlider(TabCombat, "Hitbox Size", "Enemy hitbox scale", Combat.HitboxMinSize, Combat.HitboxMaxSize, Combat.HitboxSize, 1, Combat.SetHitboxSize, "HitboxSize")
AddToggle(TabCombat, "Expand Hitbox", "Apply hitbox to players", false, Combat.SetHitboxExpanded, "ExpandHitbox")
AddToggle(TabCombat, "Visualize Hitboxes", "Green neon preview", Combat.HitboxVisible, Combat.SetHitboxVisible, "VisualizeHitboxes")
AddToggle(TabCombat, "Slap Aura", "Auto slap nearby players", false, Combat.SetSlapAura, "SlapAura")
AddToggle(TabCombat, "Auto Slap", "Auto activate glove in range", false, Combat.SetAutoGloveTap, "AutoSlap")
AddDropdown(TabCombat, "Aura Speed", "Safe or fast", { "Safe", "Fast (May get you kicked)" }, "Safe", Combat.SetSlapAuraSpeed, "AuraSpeed")
AddToggle(TabCombat, "Auto Win", "Sit on players and slap", false, Combat.SetAutoWin, "AutoWin")
AddDropdown(TabCombat, "Auto Win Mode", "One at a time or all", { "One at a time", "Slap All" }, "One at a time", Combat.SetAutoWinMode, "AutoWinMode")
Combat.KillTargetDropdown = AddDropdown(TabCombat, "Kill Target", "Who Kill Player chases", Combat.GetKillTargetNames(), "(none)", Combat.SetKillTarget, "KillTarget")
AddToggle(TabCombat, "Kill Player", "Teleport onto the target repeatedly", false, Combat.SetKillPlayer, "KillPlayer")
AddToggle(TabCombat, "Glove TP Slap", "Teleport to nearest on click", false, Combat.SetGloveTpSlap, "GloveTpSlap")
AddSlider(TabCombat, "Glove Size", "Visual glove scale", Combat.GloveSizeMin, Combat.GloveSizeMax, 1, Combat.GloveSizeStep, Combat.SetGloveSizeScale, "GloveSize")

if Game.IsBattles then
	AddToggle(TabFarm, "Slap Farm", "Auto-win logic, pinned and fast", false, Farm.SetSlapFarm, "SlapFarm")
	AddSlider(TabFarm, "Farm Speed", "Pin updates per second", 3, 50, 20, 1, Farm.SetSlapFarmSpeed, "SlapFarmSpeed")
	AddSlider(TabFarm, "Rotate Target", "Seconds before switching target", 1, 30, 4, 1, Farm.SetSlapFarmRotate, "SlapFarmRotate")
	AddToggle(TabFarm, "Auto Slap", "Spam glove activation", false, Farm.SetAutoSlap, "FarmAutoSlap")
	AddToggle(TabFarm, "Slap Aura", "Slap anyone in range", false, Farm.SetAura, "FarmAura")
	AddSlider(TabFarm, "Aura Hits/Sec", "Aura swings per second", 1, 15, 3, 1, Farm.SetAuraRate, "FarmAuraRate")
	AddSlider(TabFarm, "Aura Range", "Aura radius", 5, 120, 22, 1, Farm.SetAuraRange, "FarmAuraRange")
	AddToggle(TabFarm, "Dummy Farm", "Chase and slap dummies", false, Farm.SetDummyFarm, "DummyFarm")
	AddToggle(TabFarm, "Player Farm", "Chase and slap players", false, Farm.SetPlayerFarm, "PlayerFarm")
	AddSlider(TabFarm, "Slaps Per Second", "Farm activation rate", 1, 30, 12, 1, Farm.SetSlapRate, "FarmRate")
	AddToggle(TabFarm, "Noclip", "Walk through parts", false, UI.SetNoclip, "Noclip")
	AddToggle(TabFarm, "Anti-AFK", "Stay connected", true, UI.SetAntiAfk, "AntiAfk")
end

if Game.IsRoyale and TabItems then
	local _, autoCollectRef = AddToggle(TabItems, "Auto collect", "Priority item collection", false, Items.SetAutoCollect, "AutoCollect")
	Items.AutoCollectToggle = autoCollectRef
	local _, earlyRef = AddToggle(TabItems, "Early Auto Collect", "Collect before the round", false, Items.SetEarlyAutoCollect, "EarlyAutoCollect")
	Items.EarlyAutoCollectToggle = earlyRef
	local _, pickupRef = AddToggle(TabItems, "Auto pick up", "Press F near items", true, Items.SetAutoPickup, "AutoPickup")
	Items.AutoPickupToggle = pickupRef
	local _, permRef = AddToggle(TabItems, "Auto Use Permanents", "Consume permanent items", false, Items.SetAutoPermanentItems, "AutoPermanentItems")
	Items.AutoPermanentToggle = permRef
	AddToggle(TabItems, "Auto Heal", "Heal when low", false, Items.SetAutoHeal, "AutoHeal")
	AddToggle(TabItems, "Auto Sort", "Gloves first", false, Items.SetAutoSort, "AutoSort")
	AddButton(TabItems, "Use Spheres", "Use all spheres", "circle", function() Items.UseAllMatchingTools({ "Sphere of Fury" }, "Use Spheres", "sphere(s)") end)
	AddButton(TabItems, "Use Cubes", "Use all cubes", "box", function() Items.UseAllMatchingTools({ "Cube of Ice" }, "Use Cubes", "cube(s)") end)
	AddButton(TabItems, "Use All Items", "Use everything", "zap", Items.UseAllItems)
	AddButton(TabItems, "Drop All Items", "Drop everything", "trash-2", Items.DropAllItems)
	AddButton(TabItems, "Drop Permanent Items", "Drop permanents", "trash-2", Items.DropAllPermanents)
	AddButton(TabItems, "Drop Temp Items", "Drop temporary items", "trash", Items.DropTempItems)
	AddButton(TabItems, "Meteor Crate", "Nearest crate", "box", Items.TeleportToCrate)
	AddButton(TabItems, "Collect Crates", "Collect every crate", "package", Items.CollectCrates)
	AddToggle(TabItems, "Auto Collect Crates", "Slap tracked crates", false, Items.SetFastCollectCrates, "FastCollectCrates")
	AddToggle(TabItems, "Crate Aura", "Slap nearby crates", false, Items.SetCrateAura, "CrateAura")
end

AddToggle(TabSafety, "Anti-Ragdoll", "Invisible cage on knockback", false, Combat.SetAntiSlap, "AntiRagdoll")
AddToggle(TabSafety, "Hide Under Map", "Sink below the map", false, Anti.SetHideUnderMap, "HideUnderMap")
AddToggle(TabSafety, "Anti-Staff", "Leave on recording keywords", false, Anti.SetStaffEnabled, "AntiStaff")
if Game.IsRoyale then
	AddToggle(TabSafety, "Anti Acid", "Delete acid folders", false, Anti.SetAntiAcid, "AntiAcid")
	AddToggle(TabSafety, "Anti Lava", "Delete lava parts", false, Anti.SetAntiLava, "AntiLava")
	AddToggle(TabSafety, "Acid & Lava Covers", "Invisible floors", false, Anti.SetAcidLava, "AntiAcidLava")
	AddToggle(TabSafety, "Anti Cube of Death", "Delete death cubes", false, Anti.SetAntiCubeOfDeath, "AntiCubeOfDeath")
	AddToggle(TabSafety, "Remove Zone Effect", "Clear zone visuals", false, Anti.SetRemoveZoneEffect, "RemoveZoneEffect")
	AddToggle(TabSafety, "Delete All Seats", "Remove every seat", false, Anti.SetDeleteAllSeats, "DeleteAllSeats")
	AddToggle(TabSafety, "Zone Center Push", "Push toward zone center", false, Anti.SetZoneCenterPush, "ZoneCenterPush")
	AddSlider(TabSafety, "Push Force", "Zone push strength", 1, 100, 1, 1, Anti.SetZoneCenterPushForce, "PushForce")
end
AddToggle(TabSafety, "Speed Boost", "Extra movement while walking", false, UI.SetSpeedBoost, "SpeedBoost")
AddToggle(TabSafety, "Hide Username", "Mask your name in GUIs", false, UI.SetHideUsername, "HideUsername")

AddButton(TabSettings, "Reset Teleport Settings", "Restore strikes, debounce, F lock", "rotate-ccw", function()
	Teleport.ResetCustomSettings()
	UI.SyncCustomSettingInputVisuals()
	createNotification("Settings", "Reset to defaults.", "Success")
end)

AddInput(TabSettings, "Custom Strikes", "Teleports before cooldown", Teleport.DefaultMaxStrikes, function(value)
	if not Teleport.SetCustomSetting("CustomStrikes", value) then
		createNotification("Settings", "Needs a number.", "Warning")
	end
end, "CustomStrikes")

AddInput(TabSettings, "Custom TP Debounce", "Seconds between teleports", Teleport.DefaultDebounce, function(value)
	if not Teleport.SetCustomSetting("CustomTPDebounce", value) then
		createNotification("Settings", "Needs a number.", "Warning")
	end
end, "CustomTPDebounce")

AddInput(TabSettings, "Custom F Lock", "Seconds before F works again", Teleport.DefaultPostFLock, function(value)
	if not Teleport.SetCustomSetting("CustomFLock", value) then
		createNotification("Settings", "Needs a number.", "Warning")
	end
end, "CustomFLock")

AddToggle(TabSettings, "Disable Notifications", "Mute hub notices", false, function(state)
	NotificationsDisabled = state == true
end, "DisableNotifications")

AddSlider(TabSettings, "Max Zoom", "Camera zoom limit", 1, 2000, 128, 50, UI.SetMaxZoomOut, "MaxZoom")

AddDropdown(TabSettings, "Theme", "UI colors", { "Matrix", "Terminal", "Neon Orchid" }, Preferences.Theme or "Matrix", function(theme)
	Preferences.Theme = theme
	queueSavePreferences()
	pcall(function() WindUIWindow:SetTheme(theme) end)
end, "Theme")

task.defer(UI.SyncCustomSettingInputVisuals)

--=====================================================================
-- CLEANUP
--=====================================================================
if sharedEnvironment then
	sharedEnvironment.SVCLUTCHER_HUBCleanup = function()
		pcall(Items.CleanupAutomation)
		pcall(function() Combat.SetAutoGloveTap(false) end)
		pcall(function() Combat.SetSlapAura(false, true) end)
		pcall(function() Combat.SetHitboxExpanded(false) end)
		pcall(function() Combat.SetAntiSlap(false) end)
		pcall(function() Combat.SetAutoWin(false, true) end)
		pcall(function() Combat.SetKillPlayer(false) end)
		pcall(function() Combat.SetGloveTpSlap(false, true) end)
		pcall(function() UI.SetPlayerStatsESP(false, true) end)
		pcall(function() UI.SetItemESP(false, true) end)
		pcall(function() UI.SetAutoRejoin(false, true) end)
		pcall(function() UI.SetInfiniteJump(false, true) end)
		pcall(function() UI.SetNoclip(false, true) end)
		pcall(function() UI.SetAntiAfk(false, true) end)
		pcall(function() UI.SetHideUsername(false, true) end)
		pcall(function() UI.SetAutoEarlyBusJump(false, true) end)
		pcall(function() Farm.SetSlapFarm(false, true) end)
		pcall(function() Farm.SetAutoSlap(false, true) end)
		pcall(function() Farm.SetDummyFarm(false, true) end)
		pcall(function() Farm.SetPlayerFarm(false, true) end)
		pcall(function() Farm.SetAura(false, true) end)
		pcall(function() Speed.SetEnabled(false, true) end)
		pcall(function() Anti.SetStaffEnabled(false) end)
		pcall(function() Anti.SetAcidLava(false) end)
		pcall(function() Anti.SetHideUnderMap(false) end)
		pcall(function() Anti.SetAntiAcid(false, true) end)
		pcall(function() Anti.SetAntiLava(false, true) end)
		pcall(function() Anti.SetAntiCubeOfDeath(false, true) end)
		pcall(function() Anti.SetRemoveZoneEffect(false, true) end)
		pcall(function() Anti.SetDeleteAllSeats(false, true) end)
		pcall(function() Anti.SetZoneCenterPush(false, true) end)
		pcall(function() Teleport.ClearBusTopRidePlatform() end)
		pcall(clearUnderMapSafetyPlatform)
		pcall(Combat.RestoreGloveSize)
		pcall(function()
			if WindUIWindow and type(WindUIWindow.Destroy) == "function" then WindUIWindow:Destroy() end
		end)
	end
	sharedEnvironment.SVCLUTCHER_HUB = {
		Window = WindUIWindow, Notify = Notify, UI = UI, Main = Main, Items = Items,
		Teleport = Teleport, Combat = Combat, Anti = Anti, Farm = Farm, Speed = Speed,
		Net = Net, Preferences = Preferences, Game = Game,
	}
end
