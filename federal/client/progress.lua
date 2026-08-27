-- Timed actions: a progress bar, an animation, and a cancel key.
--
-- Nothing in this resource should be instant. An action that resolves the
-- frame you press E reads as a menu click, not as work — and it also removes
-- every opportunity to interrupt somebody mid-search.
--
-- Three providers, in order: ox_lib's progress bar when it is running, the
-- bundled NUI bar otherwise, and a plain wait if a server has neither. The
-- caller never knows which one ran.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Progress = {}
Federal.Progress = Progress

local active = false

function Progress.Active()
    return active
end

-- Animations ------------------------------------------------------------------

-- Named so callers say what they are doing rather than remembering dictionary
-- strings. An unknown name simply plays nothing, which is better than an
-- action that refuses to run because a dictionary is missing.
Progress.Animations = {
    search      = { dict = 'anim@gangops@facility@servers@bodysearch@', clip = 'player_search', flag = 49 },
    frisk       = { dict = 'mp_arresting', clip = 'a_uncuff', flag = 49 },
    fingerprint = { dict = 'anim@heists@prison_heiststation@cop_reactions', clip = 'cop_a_idle', flag = 49 },
    swab        = { dict = 'amb@medic@standing@kneel@base', clip = 'base', flag = 1 },
    collect     = { dict = 'amb@medic@standing@kneel@base', clip = 'base', flag = 1 },
    analyse     = { dict = 'anim@amb@business@bgen@bgen_no_work@', clip = 'sit_phone_phoneputdown_idle_nowork', flag = 49 },
    equip       = { dict = 'anim@heists@narcotics@funding@gang_idle', clip = 'gang_chatting_idle01', flag = 49 },
    change      = { dict = 'clothingtie', clip = 'try_tie_negative_a', flag = 49 },
    write       = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
    deploy      = { dict = 'anim@narcotics@trash', clip = 'idle_a', flag = 1 }
}

local function startAnimation(name)
    local animation = Progress.Animations[name]
    if not animation then return nil end

    RequestAnimDict(animation.dict)
    local deadline = GetGameTimer() + 1500
    while not HasAnimDictLoaded(animation.dict) and GetGameTimer() < deadline do Wait(10) end
    -- A missing dictionary must not block the action itself.
    if not HasAnimDictLoaded(animation.dict) then return nil end

    TaskPlayAnim(PlayerPedId(), animation.dict, animation.clip, 4.0, -4.0, -1, animation.flag or 49, 0, false, false, false)
    return animation
end

local function stopAnimation(animation)
    if not animation then return end
    ClearPedTasks(PlayerPedId())
end

-- Providers ---------------------------------------------------------------------

local function oxAvailable()
    return GetResourceState('ox_lib') == 'started'
end

-- The bundled bar. Driven from Lua so it stays in step with the real elapsed
-- time rather than animating independently and finishing early.
local function bundledBar(label, duration, canCancel)
    SendNUIMessage({ action = 'progress:open', label = label, duration = duration, cancel = canCancel == true })

    local started = GetGameTimer()
    local cancelled = false

    while GetGameTimer() - started < duration do
        if canCancel and IsControlJustReleased(0, 202) then
            cancelled = true
            break
        end
        -- Moving does not cancel, but dying or being cuffed does: both mean
        -- the player is no longer in a position to be doing this.
        if IsEntityDead(PlayerPedId()) or Federal.Actions.Restrained() then
            cancelled = true
            break
        end
        Wait(0)
    end

    SendNUIMessage({ action = 'progress:close' })
    return not cancelled
end

-- Runs a timed action. Returns true when it completed, false when it was
-- cancelled or interrupted.
function Progress.Run(options)
    options = type(options) == 'table' and options or {}
    if active then
        Bridge.Notify('You are already doing something.', 'error')
        return false
    end

    local label = options.label or 'Working'
    local duration = math.max(tonumber(options.duration) or 3000, 250)
    local canCancel = options.cancel ~= false

    active = true
    local animation = startAnimation(options.animation)

    local function runBar()
        if oxAvailable() then
            return exports.ox_lib:progressBar({
                duration = duration,
                label = label,
                useWhileDead = false,
                canCancel = canCancel,
                disable = { move = options.freeze == true, car = true, combat = true }
            }) == true
        end
        return bundledBar(label, duration, canCancel)
    end

    -- The lock is released even if the bar throws. Leaking it would leave the
    -- player unable to perform any action for the rest of the session, and the
    -- error is re-raised rather than swallowed.
    local ok, completed = pcall(runBar)
    stopAnimation(animation)
    active = false
    if not ok then
        SendNUIMessage({ action = 'progress:close' })
        error(completed, 0)
    end

    if not completed and options.quiet ~= true then
        Bridge.Notify('Cancelled.', 'error')
    end
    return completed
end

-- Skill checks -------------------------------------------------------------------

-- Used where a mistake should be possible: picking a lock, lifting a print off
-- a poor surface. Falls back to succeeding when no provider can run one, so a
-- server without ox_lib is not blocked out of the content.
function Progress.SkillCheck(difficulty)
    if not oxAvailable() then return true end

    local levels = difficulty or { 'easy', 'easy', 'medium' }
    local ok = exports.ox_lib:skillCheck(levels)
    return ok == true
end

-- Convenience: a timed action followed by a skill check, which is the shape
-- most evidence work takes.
function Progress.Attempt(options)
    if not Progress.Run(options) then return false end
    if options.skill == nil then return true end

    if not Progress.SkillCheck(options.skill) then
        Bridge.Notify(options.failure or 'You fumbled it.', 'error')
        return false
    end
    return true
end

return Progress
