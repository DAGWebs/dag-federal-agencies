DAG.Interactions = DAG.Interactions or {}
local Interactions = DAG.Interactions
local entries = {}

local function coords(value)
    if type(value) == 'vector3' then return value end
    assert(type(value) == 'table', 'Interaction coords must be a vector3 or table')
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    assert(x and y and z, 'Interaction coords require x, y and z')
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function select(entry)
    if entry.menu then return DAG.Menu.Open(entry.menu) end
    if entry.onSelect then return entry.onSelect(entry.args) end
    if entry.event then return TriggerEvent(entry.event, entry.args) end
    if entry.serverEvent then return TriggerServerEvent(entry.serverEvent, entry.args) end
end

function Interactions.Register(entry)
    assert(type(entry) == 'table' and type(entry.id) == 'string' and entry.coords, 'Invalid interaction')
    entry.coords = coords(entry.coords)
    entries[entry.id] = entry
    return entry.id
end

-- Where an entry actually is right now. A `follow` entity overrides the
-- registered coordinates while it exists, so an interaction can track a ped
-- or vehicle that moves; when the entity is gone the registered position is
-- used again rather than the entry silently disappearing.
local function positionOf(entry)
    if entry.follow and DoesEntityExist(entry.follow) then
        local at = GetEntityCoords(entry.follow)
        return vector3(at.x, at.y, at.z)
    end
    return entry.coords
end

Interactions.PositionOf = positionOf

function Interactions.Remove(id)
    entries[id] = nil
end

function Interactions.Clear()
    entries = {}
end

function Interactions.Get(id)
    return entries[id]
end

CreateThread(function()
    while true do
        local sleep, playerCoords = 500, GetEntityCoords(PlayerPedId())
        -- Only the closest eligible entry gets the help prompt: drawing several
        -- overlapping prompts meant whichever entry pairs() happened to yield
        -- last silently won the keypress.
        local closest, closestDistance

        for _, entry in pairs(entries) do
            local at = positionOf(entry)
            local distance = #(playerCoords - at)
            if distance <= (entry.drawDistance or Config.InteractionDrawDistance) then
                -- An entry the player cannot use right now draws nothing at
                -- all: an off-duty officer's armory shows no arrow, not an
                -- arrow that refuses. Same check that gates the keypress.
                if not entry.canInteract or entry.canInteract(entry) == true then
                    sleep = 0
                    DrawMarker(entry.marker or 2, at.x, at.y, at.z,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.2, 0.2,
                        80, 160, 255, 180, false, true, 2, false, nil, nil, false)

                    if distance <= (entry.distance or Config.InteractionDistance)
                        and (not closestDistance or distance < closestDistance) then
                        closest, closestDistance = entry, distance
                    end
                end
            end
        end

        if closest then
            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(closest.label or 'Press ~INPUT_CONTEXT~ to interact')
            EndTextCommandDisplayHelp(0, false, true, -1)
            if IsControlJustReleased(0, closest.key or Config.InteractionKey) then select(closest) end
        end

        Wait(sleep)
    end
end)

exports('GetInteractions', function() return Interactions end)
