-- Blips and world interactions built from whatever the registry currently
-- says. Everything here is rebuilt from scratch whenever the server pushes a
-- new context, which is what makes an edit in the in-game editor appear
-- immediately instead of on the next reconnect.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Const = Federal.Constants
local State = Federal.State
local Zones = {}
Federal.Zones = Zones

local blips, interactions = {}, {}

local function clearBlips()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    blips = {}
end

local function clearInteractions()
    for _, id in ipairs(interactions) do DAG.Interactions.Remove(id) end
    interactions = {}
end

local function addBlip(coords, label, spec)
    if type(spec) == 'table' and spec.enabled == false then return end
    spec = spec or {}

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, spec.sprite or 60)
    SetBlipColour(blip, spec.color or 26)
    SetBlipScale(blip, spec.scale or 0.8)
    SetBlipAsShortRange(blip, spec.shortRange ~= false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label)
    EndTextCommandSetBlipName(blip)

    blips[#blips + 1] = blip
    return blip
end

Zones.AddBlip = addBlip

-- Which menu a zone opens. A zone kind with no menu still registers so the
-- prompt appears; it just reports that nothing is wired to it yet.
local ZONE_MENUS = {
    duty = 'duty',
    locker = 'locker',
    armory = 'armory',
    evidence = 'evidence',
    boss = 'boss',
    cad = 'cad',
    cells = 'cells',
    garage = 'garage'
}

local function registerZone(agency, station, zone)
    local id = ('federal:%s:%s:%s'):format(agency.id, station.id, zone.id)
    local kind = Const.ZoneKinds[zone.kind]

    DAG.Interactions.Register({
        id = id,
        coords = vector3(zone.coords.x, zone.coords.y, zone.coords.z),
        distance = zone.radius or 2.0,
        label = ('Press ~INPUT_CONTEXT~ for %s'):format(zone.label or (kind and kind.label) or zone.kind),
        -- Re-evaluated every frame the player is near, so a promotion or a
        -- job change takes effect without re-registering anything.
        canInteract = function()
            local membership = State.Membership()
            if not membership or membership.agencyId ~= agency.id then return false end
            return State.Grade() >= (zone.minGrade or 0)
        end,
        onSelect = function()
            Federal.Menus.OpenZone(ZONE_MENUS[zone.kind] or zone.kind, agency, station, zone)
        end
    })

    interactions[#interactions + 1] = id
end

function Zones.Rebuild()
    clearBlips()
    clearInteractions()

    -- A disabled resource draws nothing at all. Without this the stations stay
    -- blipped on the map while every interaction refuses, which reads as a
    -- broken job rather than a switched-off one.
    if State.Context().enabled == false then return end

    local settings = Config.Federal or {}
    local membership = State.Membership()

    for _, agency in ipairs(State.Agencies()) do
        local mine = membership ~= nil and membership.agencyId == agency.id

        for _, station in ipairs(agency.stations or {}) do
            if settings.blips ~= false then
                addBlip(station.coords, ('%s - %s'):format(agency.short, station.label), station.blip or agency.blip)
            end
            -- Only your own agency's rooms are interactive; another agency's
            -- armory is not yours to open.
            if mine then
                for _, zone in ipairs(station.zones or {}) do registerZone(agency, station, zone) end
            end
        end
    end

    if Federal.Court and Federal.Court.RebuildZones then Federal.Court.RebuildZones() end
end

State.OnChange(function() Zones.Rebuild() end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearBlips() end
end)

return Zones
