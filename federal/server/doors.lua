-- Agency door locks.
--
-- Each door belongs to an agency, is gated by a minimum grade, and is
-- enforced on EVERY client through the game's door system - a locked FIB
-- gate is locked for civilians too, so the full list (definitions and lock
-- state) is broadcast to everyone. Only who may TOGGLE a door is private:
-- members of the owning agency at or above the door's grade, standing next
-- to it, verified against the position the server reads.
--
-- Doors are captured in game (aim at the door), stored in the resource's own
-- store, and managed from the /fedconfig panel.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local Doors = {}
Federal.Doors = Doors

local store = DAG.Repository.Create('federal_doors')

local function fail(message)
    return nil, message
end

local MAX_DOORS_PER_AGENCY = 64

local function record(agencyId)
    local stored = store.get(agencyId)
    return (stored and type(stored.doors) == 'table') and Util.Copy(stored.doors) or {}
end

function Doors.List(agencyId)
    return record(agencyId)
end

-- Everything every client must enforce: all agencies' doors with state.
function Doors.All()
    local all = {}
    for _, agency in ipairs(Core.Agencies()) do
        for _, door in ipairs(record(agency.id)) do
            door.agency = agency.id
            all[#all + 1] = door
        end
    end
    return all
end

local function broadcast()
    TriggerClientEvent(Federal.Net('doors:sync'), -1, Doors.All())
end

Doors.Broadcast = broadcast

local function persist(agencyId, doors)
    local saved, message = store.save(agencyId, { id = agencyId, doors = doors })
    if not saved then return fail(message or 'the doors could not be saved') end
    broadcast()
    return true
end

-- Captured by an editor aiming at a real door object; the payload carries the
-- object's model hash and position as the client read them. Authorization is
-- the editor's, and the door only ever locks that one object.
function Doors.Add(source, agencyId, payload)
    local agency, message = Federal.Editor.Editable(source, agencyId)
    if not agency then return fail(message) end

    payload = type(payload) == 'table' and payload or {}
    local model = tonumber(payload.model)
    local coords = Util.ToCoords(payload.coords)
    if not model or not coords then return fail('no door captured - aim at the door and try again') end

    local doors = record(agency.id)
    if #doors >= MAX_DOORS_PER_AGENCY then return fail('that agency already has the maximum number of doors') end

    local label = Util.Text(payload.label, 60, 'Door')
    local door = {
        id = ('door-%d-%d'):format(math.floor(model), math.floor((coords.x + 8192) * 10)),
        label = label,
        model = math.floor(model),
        coords = coords,
        -- Captured from the model's real size, so a wide gate prompts along
        -- its whole length rather than only at the hinge.
        radius = Util.Clamp(tonumber(payload.radius) or 4.0, 1.0, 12.0),
        minGrade = math.floor(Util.Clamp(tonumber(payload.minGrade) or 0, 0, 100)),
        locked = payload.locked ~= false
    }

    local _, index = Federal.Schema.FindById(doors, door.id)
    if index then
        doors[index] = door
    else
        doors[#doors + 1] = door
    end

    local ok, saveMessage = persist(agency.id, doors)
    if not ok then return fail(saveMessage) end
    return door
end

-- Panel edits: label, grade, the current lock state, and the prompt point -
-- where "press E" appears, for gates whose origin is nowhere near where a
-- player actually stands.
function Doors.Update(source, agencyId, payload)
    local agency, message = Federal.Editor.Editable(source, agencyId)
    if not agency then return fail(message) end

    payload = type(payload) == 'table' and payload or {}
    local doors = record(agency.id)
    local door, index = Federal.Schema.FindById(doors, payload.id)
    if not index then return fail('no such door') end

    if payload.label ~= nil then door.label = Util.Text(payload.label, 60, door.label) end
    if payload.minGrade ~= nil then door.minGrade = math.floor(Util.Clamp(tonumber(payload.minGrade) or 0, 0, 100)) end
    if payload.locked ~= nil then door.locked = payload.locked == true end
    if payload.radius ~= nil then
        -- How far away the prompt appears and the toggle reaches.
        door.radius = Util.Clamp(tonumber(payload.radius) or door.radius or 4.0, 1.0, 15.0)
    end
    if payload.prompt ~= nil then
        -- Valid coords place the prompt; blank fields clear it back to the
        -- door object itself.
        door.prompt = Util.ToCoords(payload.prompt)
    end
    doors[index] = door

    local ok, saveMessage = persist(agency.id, doors)
    if not ok then return fail(saveMessage) end
    return door
end

function Doors.Remove(source, agencyId, doorId)
    local agency, message = Federal.Editor.Editable(source, agencyId)
    if not agency then return fail(message) end

    local doors = record(agency.id)
    local door, index = Federal.Schema.FindById(doors, doorId)
    if not index then return fail('no such door') end

    table.remove(doors, index)
    local ok, saveMessage = persist(agency.id, doors)
    if not ok then return fail(saveMessage) end
    return door
end

-- The use path: a member at or above the door's grade, standing within reach
-- of the door the SERVER knows about. The client supplies only the door id.
function Doors.Toggle(source, agencyId, doorId)
    local membership = Core.Membership(source)
    if not membership or membership.agency.id ~= agencyId then
        if not Core.IsAdmin(source) then return fail('that door is not yours to control') end
        membership = { agency = { id = agencyId }, grade = math.huge }
    end

    local doors = record(agencyId)
    local door, index = Federal.Schema.FindById(doors, doorId)
    if not index then return fail('no such door') end
    if membership.grade < (door.minGrade or 0) then return fail('your grade does not control that door') end

    local position = Core.Coords(source)
    if not position then return fail('you are not at that door') end

    -- Standing at either the door object or its configured prompt point counts.
    local atDoor = false
    local distance = Util.Distance(position, door.coords)
    if distance and distance <= (door.radius or 4.0) + 5.0 then atDoor = true end
    if not atDoor and door.prompt then
        local promptDistance = Util.Distance(position, door.prompt)
        if promptDistance and promptDistance <= (door.radius or 4.0) + 5.0 then atDoor = true end
    end
    if not atDoor then return fail('you are not at that door') end

    door.locked = not door.locked
    doors[index] = door

    local saved, message = store.save(agencyId, { id = agencyId, doors = doors })
    if not saved then return fail(message) end
    broadcast()
    return door
end

-- Net wiring ------------------------------------------------------------------

RegisterNetEvent(Federal.Net('door:add'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local door, message = Doors.Add(playerSource, agencyId, payload)
    Bridge.Notify(playerSource,
        door and ('Registered door "%s" for the %s.'):format(door.label, agencyId:upper()) or message,
        door and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('door:update'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local door, message = Doors.Update(playerSource, agencyId, payload)
    Bridge.Notify(playerSource, door and ('Updated door "%s".'):format(door.label) or message, door and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('door:remove'), function(agencyId, doorId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(doorId) ~= 'string' then return end
    local door, message = Doors.Remove(playerSource, agencyId, doorId)
    Bridge.Notify(playerSource, door and ('Removed door "%s".'):format(door.label) or message, door and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('door:toggle'), function(agencyId, doorId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(doorId) ~= 'string' then return end
    local door, message = Doors.Toggle(playerSource, agencyId, doorId)
    if door then
        Bridge.Notify(playerSource, ('%s %s.'):format(door.label, door.locked and 'locked' or 'unlocked'), 'success')
    else
        Bridge.Notify(playerSource, message, 'error')
    end
end)

Bridge.RegisterCallback(Federal.Net('doors'), function(source, reply)
    reply(Doors.All())
end)

-- The stored lock state must come back on its own after any restart: push it
-- to everyone once the store is up, and to each player as they join. Without
-- this, a client whose initial fetch raced the boot would sit with every
-- door unlocked until the next edit happened to broadcast.
CreateThread(function()
    Wait(2000)
    broadcast()
end)

AddEventHandler('playerJoining', function()
    local playerSource = source
    SetTimeout(6000, function()
        TriggerClientEvent(Federal.Net('doors:sync'), playerSource, Doors.All())
    end)
end)

return Doors
