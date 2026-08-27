-- The duty HUD.
--
-- Before this, a callout objective arrived as a notification that scrolled
-- away, and the only way to know what you were meant to be doing was to open
-- a menu and look. This keeps the four things an officer needs at a glance --
-- who they are, their status, the case they are on, and what is left to do --
-- on screen without taking focus or input.
--
-- It renders from a single pushed state and is only re-sent when something in
-- it actually changed, so a quiet shift costs nothing.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Const = Federal.Constants
local State = Federal.State
local Hud = {}
Federal.Hud = Hud

local current = { visible = false }
local callout = nil
local lastPayload = nil

local function settings()
    return (Config.Federal or {}).hud or {}
end

function Hud.Enabled()
    return settings().enabled ~= false
end

function Hud.Current()
    return current
end

-- The objective list, trimmed around the current stage: a ten-stage case would
-- otherwise fill the screen, and the stages already finished are the least
-- interesting rows on it.
local function objectives(active)
    local list = {}
    if not active or type(active.stages) ~= 'table' then return list end

    local window = tonumber(settings().objectives) or 4
    local stage = tonumber(active.stage) or 1
    local first = math.max(1, math.min(stage - 1, #active.stages - window + 1))

    for index = first, math.min(#active.stages, first + window - 1) do
        local entry = active.stages[index]
        local state = 'pending'
        if index < stage then
            state = 'done'
        elseif index == stage then
            state = 'current'
        end
        list[#list + 1] = { label = entry.label, state = state }
    end
    return list
end

Hud.Objectives = objectives

-- Builds the payload the UI renders. Pure, so a test can assert on what the
-- player would see without going near SendNUIMessage.
function Hud.Build()
    local membership = State.Membership()
    if not Hud.Enabled() or not membership then return { visible = false } end

    -- Off duty the HUD would just be clutter on a civilian's screen.
    if not membership.onDuty and settings().offDuty ~= true then return { visible = false } end

    local agency = State.Mine()
    local unit = membership.unit or {}
    local status = Const.UnitStatus[unit.status or 'available'] or Const.UnitStatus.available

    local payload = {
        visible = true,
        agency = agency and agency.short or 'FED',
        callsign = unit.callsign or '',
        rank = membership.rank or '',
        status = status.label,
        statusTone = status.tone,
        restrained = Federal.Actions.Restrained()
    }

    if callout then
        payload.callout = {
            number = callout.number,
            label = callout.label,
            objectives = objectives(callout)
        }
    end

    return payload
end

-- Cheap structural comparison, used only to decide whether a push is needed.
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end

    for key, value in pairs(a) do
        if not same(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

function Hud.Refresh()
    local payload = Hud.Build()
    current = payload

    -- Only when something changed: pushing an identical frame every second
    -- would be pure noise across the NUI boundary.
    if same(payload, lastPayload) then return false end

    lastPayload = payload
    SendNUIMessage({ action = 'hud', hud = payload })
    return true
end

function Hud.SetCallout(active)
    callout = active
    Hud.Refresh()
end

function Hud.ClearCallout(calloutId)
    if calloutId and callout and callout.id ~= calloutId then return end
    callout = nil
    Hud.Refresh()
end

State.OnChange(function() Hud.Refresh() end)

-- Restraint and unit status change outside the context push, so the HUD polls
-- slowly as a backstop. Everything else drives it by event.
CreateThread(function()
    while true do
        Wait(2000)
        Hud.Refresh()
    end
end)

return Hud
