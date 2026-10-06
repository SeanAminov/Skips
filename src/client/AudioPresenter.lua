--!strict
--[[
	Small, non-positional sound palette. Sounds live in SoundService so the rope remains equally
	audible at every camera angle; pitch variation adds life without introducing an audio clock.
]]

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local AudioPresenter = {}
AudioPresenter.__index = AudioPresenter

type SoundSpec = { id: string, volume: number, speed: number }

local SPECS: { [string]: SoundSpec } = {
	JUMP = { id = "rbxassetid://2772396665", volume = 0.20, speed = 1.12 },
	SWEEP = { id = "rbxassetid://9114375469", volume = 0.17, speed = 1.08 },
	CLEAR = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.27, speed = 1.38 },
	UPGRADE = { id = "rbxassetid://127488139302452", volume = 0.32, speed = 1.05 },
	CARD = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.25, speed = 1.65 },
	-- Bundled with Roblox rather than permission-gated catalog audio: the comic vocal stumble is
	-- reliably available in every place and reads as a soft cartoon loss, not a hard collision.
	MISS = { id = "rbxasset://sounds/uuhhh.mp3", volume = 0.48, speed = 1.15 },
	TICK = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.12, speed = 0.72 },
	REVIVE = { id = "rbxassetid://127488139302452", volume = 0.36, speed = 1.32 },
}

-- Full volume for the whole palette; the Sound setting scales it (SettingsClient).
local BASE_VOLUME = 0.85

export type AudioPresenter = typeof(setmetatable(
	{} :: { folder: Folder, group: SoundGroup, lastCountdown: number },
	{} :: { __index: typeof(AudioPresenter) }
))

function AudioPresenter.new(): AudioPresenter
	local old = SoundService:FindFirstChild("SkipsAudio")
	if old then old:Destroy() end
	local oldGroup = SoundService:FindFirstChild("SkipsSFX")
	if oldGroup then oldGroup:Destroy() end

	local group = Instance.new("SoundGroup")
	group.Name = "SkipsSFX"
	group.Volume = BASE_VOLUME
	group.Parent = SoundService
	local folder = Instance.new("Folder")
	folder.Name = "SkipsAudio"
	folder.Parent = SoundService
	return setmetatable({ folder = folder, group = group, lastCountdown = -1 }, AudioPresenter) :: any
end

-- The Sound setting: 0 is silent, 1 is full. Presentation only, like every setting.
function AudioPresenter.setVolume(self: AudioPresenter, level: number)
	self.group.Volume = BASE_VOLUME * math.clamp(level, 0, 1)
end

function AudioPresenter.play(self: AudioPresenter, name: string, pitchOffset: number?)
	local spec = SPECS[name]
	if not spec then return end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = spec.id
	sound.Volume = spec.volume
	sound.PlaybackSpeed = math.clamp(spec.speed + (pitchOffset or 0), 0.5, 2)
	sound.SoundGroup = self.group
	sound.Parent = self.folder
	sound:Play()
	Debris:AddItem(sound, 4)
end

function AudioPresenter.playCountdown(self: AudioPresenter, seconds: number)
	local whole = math.max(0, math.ceil(seconds))
	if whole ~= self.lastCountdown then
		self.lastCountdown = whole
		if whole > 0 and whole <= 5 then self:play("TICK", (5 - whole) * 0.06) end
	end
end

function AudioPresenter.resetCountdown(self: AudioPresenter)
	self.lastCountdown = -1
end

function AudioPresenter.destroy(self: AudioPresenter)
	self.folder:Destroy()
	self.group:Destroy()
end

return AudioPresenter
