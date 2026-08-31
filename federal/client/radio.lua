-- Radio traffic.
--
-- The officer SAYS the call over their voice radio; this makes the world
-- match it. One press of the radio key opens the traffic menu - each entry
-- phrased the way it would be spoken, on the unit's phonetic callsign - and
-- selecting one squelches, raises the hand-radio animation, sets the CAD
-- status, and broadcasts the call to every unit on the air.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State

local Radio = {}
Federal.Radio = Radio

-- APCO phonetic letters, the way patrol actually reads a callsign:
-- 1F-36 -> "1-Frank-36".
local PHONETIC = {
    A = 'Adam', B = 'Boy', C = 'Charles', D = 'David', E = 'Edward', F = 'Frank',
    G = 'George', H = 'Henry', I = 'Ida', J = 'John', K = 'King', L = 'Lincoln',
    M = 'Mary', N = 'Nora', O = 'Ocean', P = 'Paul', Q = 'Queen', R = 'Robert',
    S = 'Sam', T = 'Tom', U = 'Union', V = 'Victor', W = 'William',
    X = 'X-ray', Y = 'Young', Z = 'Zebra'
}

function Radio.Phonetic(callsign)
    local parts = {}
    for character in tostring(callsign or ''):gmatch('%w') do
        parts[#parts + 1] = PHONETIC[character:upper()] or character
    end
    return #parts > 0 and table.concat(parts, '-') or tostring(callsign or 'unit')
end

local function squelch()
    PlaySoundFrontend(-1, 'Start_Squelch', 'CB_RADIO_SFX', true)
end

-- A short hand-to-ear radio animation while the call goes out.
local function radioAnimation()
    CreateThread(function()
        local ped = PlayerPedId()
        RequestAnimDict('random@arrests')
        local deadline = GetGameTimer() + 1000
        while not HasAnimDictLoaded('random@arrests') and GetGameTimer() < deadline do Wait(10) end
        if HasAnimDictLoaded('random@arrests') then
            TaskPlayAnim(ped, 'random@arrests', 'generic_radio_chatter', 8.0, -8.0, 2500, 49, 0, false, false, false)
        end
    end)
end

local function sendCall(status, phrase)
    squelch()
    radioAnimation()
    TriggerServerEvent(Federal.Net('radio:call'), status, phrase)
end

function Radio.Open()
    local membership = State.Membership()
    if not membership then return end
    if not State.OnDuty() and not State.Context().admin then
        return Bridge.Notify('Your radio is at the station - clock on first.', 'error')
    end

    local callsign = (membership.unit and membership.unit.callsign) or '?'
    local phonetic = Radio.Phonetic(callsign)

    -- Each entry reads the way it is spoken on the air.
    local CALLS = {
        { status = 'enroute', phrase = 'show me en route', label = 'Show me en route' },
        { status = 'onscene', phrase = 'show me on scene', label = 'Show me on scene' },
        { status = 'busy', phrase = 'show me code 6, out for investigation', label = 'Code 6 - out for investigation' },
        { status = 'available', phrase = 'show me back in service', label = 'Back in service' },
        { status = 'panic', phrase = 'officer needs assistance, send everything', label = 'PANIC - officer needs assistance', tone = 'danger' }
    }

    local options = {
        { title = ('%s (%s)'):format(phonetic, callsign), description = 'Key the radio', disabled = true }
    }
    for _, call in ipairs(CALLS) do
        options[#options + 1] = {
            title = call.label,
            description = ('"%s, %s"'):format(phonetic, call.phrase),
            icon = 'info',
            badgeTone = call.tone,
            onSelect = function() sendCall(call.status, call.phrase) end
        }
    end

    DAG.Menu.Register({
        id = Federal.Menus.Id('radio'),
        title = 'Radio traffic',
        subtitle = phonetic,
        options = options
    })
    DAG.Menu.Open(Federal.Menus.Id('radio'))
end

RegisterCommand('fedradio', function()
    Radio.Open()
end, false)

RegisterKeyMapping('fedradio', 'Federal: key the radio', 'keyboard',
    ((Config.Federal or {}).radio and Config.Federal.radio.defaultKey) or 'LMENU')

-- Incoming traffic from other units: the squelch plays here too, so a call
-- SOUNDS like radio and not like a system message.
RegisterNetEvent(Federal.Net('radio:traffic'), function(text)
    squelch()
    Bridge.Notify(text, 'inform', 9000)
end)

return Radio
