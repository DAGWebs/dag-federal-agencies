-- Standard LEO actions, authorized entirely on the server.
--
-- Every action re-reads both players' real positions and re-checks the
-- officer's rank. The client supplies only a target id: never a distance,
-- never an item list, never a "yes I am allowed" flag.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core
local CAD = Federal.CAD

local Actions = {}
Federal.Actions = Actions

-- Server-authoritative restraint state, keyed by player source.
local detained = {}
Actions.detained = detained

local function fail(message)
    return nil, message
end

local function settings()
    return Config.Federal or {}
end

function Actions.State(target)
    return detained[target] and Util.Copy(detained[target]) or nil
end

function Actions.IsCuffed(target)
    return detained[target] ~= nil and detained[target].cuffed == true
end

-- Resolves and range-checks the target of an action. `target` is the only
-- thing the client gets to choose, and it is validated here.
local function resolveTarget(source, target, permission)
    local membership = Core.Require(source, permission)
    if not membership then return nil end

    target = tonumber(target)
    if not target or target == source then
        Bridge.Notify(source, 'No valid subject selected.', 'error')
        return nil
    end

    local officer, subject = Core.Coords(source), Core.Coords(target)
    if not officer or not subject then
        Bridge.Notify(source, 'That subject is not available.', 'error')
        return nil
    end

    local limit = tonumber(settings().actionDistance) or 4.0
    local distance = Util.Distance(officer, subject)
    if not distance or distance > limit then
        Bridge.Notify(source, 'You are too far from that subject.', 'error')
        return nil
    end

    return membership, target
end

Actions.ResolveTarget = resolveTarget

local function subjectIdentity(target)
    return Bridge.GetIdentifier(target), Bridge.GetName(target)
end

-- Restraint ------------------------------------------------------------------

function Actions.Cuff(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.detain')
    if not membership then return fail('not authorized') end

    if Actions.IsCuffed(subject) then
        detained[subject] = nil
        TriggerClientEvent(Federal.Net('restraint'), subject, { cuffed = false })
        Bridge.Notify(subject, 'You have been uncuffed.', 'inform')
        Bridge.Notify(source, 'Subject uncuffed.', 'success')
        return { cuffed = false, target = subject }
    end

    local identifier, name = subjectIdentity(subject)
    detained[subject] = {
        cuffed = true,
        by = membership.identifier,
        agency = membership.agency.id,
        identifier = identifier,
        name = name,
        at = os.time()
    }

    TriggerClientEvent(Federal.Net('restraint'), subject, { cuffed = true })
    Bridge.Notify(subject, 'You have been placed in restraints.', 'inform')
    Bridge.Notify(source, 'Subject cuffed.', 'success')
    return { cuffed = true, target = subject }
end

-- Escorting only works on a cuffed subject, which is what stops it being used
-- to drag an uninvolved player around.
function Actions.Escort(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.detain')
    if not membership then return fail('not authorized') end
    if not Actions.IsCuffed(subject) then return fail('that subject is not restrained') end

    local state = detained[subject]
    if state.escortedBy == source then
        state.escortedBy = nil
        TriggerClientEvent(Federal.Net('escort'), subject, nil)
        return { escorting = false, target = subject }
    end

    state.escortedBy = source
    TriggerClientEvent(Federal.Net('escort'), subject, source)
    return { escorting = true, target = subject }
end

function Actions.Seat(source, target, netId)
    local membership, subject = resolveTarget(source, target, 'actions.detain')
    if not membership then return fail('not authorized') end
    if not Actions.IsCuffed(subject) then return fail('that subject is not restrained') end
    if not tonumber(netId) then return fail('no vehicle selected') end

    TriggerClientEvent(Federal.Net('seat'), subject, tonumber(netId))
    return { target = subject }
end

-- Searching --------------------------------------------------------------------

-- Item support is not universal. Rather than report an empty search on a
-- framework that cannot read inventories at all -- which reads as "clean" --
-- this refuses and says why.
local function inventoryReadable()
    if Bridge.InventoryProvider() == 'ox' then return true end
    return Bridge.Supports('getItemCount')
end

Actions.InventoryReadable = inventoryReadable

-- Sweeps the configured contraband list. Returns what was found and, when
-- `seizeOnSearch` is on, what was actually taken -- the two can differ if a
-- removal fails, and the report reflects what really happened.
function Actions.SearchSuspect(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.search')
    if not membership then return fail('not authorized') end

    if not inventoryReadable() then
        return fail('this framework cannot report inventories; extend the bridge adapter to enable searching')
    end

    local identifier, name = subjectIdentity(subject)
    local seize = settings().seizeOnSearch ~= false
    local found, seized = {}, {}

    for _, item in ipairs(settings().contraband or {}) do
        local count = Bridge.GetItemCount(subject, item)
        if count and count > 0 then
            found[#found + 1] = { item = item, count = count }
            if seize and Bridge.RemoveItem(subject, item, count) then
                seized[#seized + 1] = { item = item, count = count }
            end
        end
    end

    -- Seized contraband becomes evidence, tied to the subject it came from so
    -- the lab can match it back later.
    local logged = {}
    for _, entry in ipairs(seized) do
        local record = CAD.CollectEvidence(source, {
            kind = 'property',
            label = ('%s x%d seized from %s'):format(entry.item, entry.count, name or 'a subject'),
            subject = identifier,
            location = Core.Coords(source)
        })
        if record then logged[#logged + 1] = record.number end
    end

    if #found > 0 then
        Bridge.Notify(subject, 'You have been searched.', 'inform')
    end

    -- Lets a callout's "search the suspect" stage close on the search that
    -- actually happened instead of on the client reporting one.
    if Federal.Callouts and Federal.Callouts.OnSearch then
        Federal.Callouts.OnSearch(source, identifier)
    end

    return { target = subject, name = name, identifier = identifier, found = found, seized = seized, evidence = logged }
end

-- Vehicle occupants are resolved on the server from the vehicle each player's
-- ped is actually in, so a client cannot name someone who is not in the car.
local function occupantsOf(vehicle)
    local occupants = {}
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        local ped = playerSource and GetPlayerPed(playerSource)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped) == vehicle then
            occupants[#occupants + 1] = playerSource
        end
    end
    return occupants
end

function Actions.SearchVehicle(source, netId)
    local membership = Core.Require(source, 'actions.search')
    if not membership then return fail('not authorized') end

    local vehicle = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return fail('that vehicle is not there') end

    local officer = Core.Coords(source)
    local position = Util.ToCoords(GetEntityCoords(vehicle))
    local limit = tonumber(settings().actionDistance) or 4.0
    local distance = officer and position and Util.Distance(officer, position)
    if not distance or distance > limit + 2.0 then return fail('you are too far from that vehicle') end

    if not inventoryReadable() then
        return fail('this framework cannot report inventories; extend the bridge adapter to enable searching')
    end

    -- Searching a car searches who is in it. Trunk and glovebox contents are
    -- owned by the inventory resource, not by this one, so they are not
    -- invented here.
    local results = {}
    for _, occupant in ipairs(occupantsOf(vehicle)) do
        local report = Actions.SearchSuspect(source, occupant)
        if report then results[#results + 1] = report end
    end

    return { netId = tonumber(netId), occupants = results }
end

-- Identification ------------------------------------------------------------------

function Actions.Identify(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.search')
    if not membership then return fail('not authorized') end

    local identifier, name = subjectIdentity(subject)
    local record = CAD.LookupRecord(source, identifier)

    return {
        target = subject,
        identifier = identifier,
        name = name,
        record = record,
        warrant = CAD.ActiveWarrantFor(identifier)
    }
end

-- Fingerprinting puts a subject on file, which is what later lets an
-- identifying evidence analysis match them.
function Actions.Fingerprint(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.evidence')
    if not membership then return fail('not authorized') end

    local identifier, name = subjectIdentity(subject)
    local record = CAD.Record(identifier, name)
    if not record then return fail('that subject cannot be identified') end

    record.printed = true
    CAD.records.save(identifier, record)
    CAD.Note(identifier, name, ('Fingerprinted by %s (%s)'):format(membership.name, membership.agency.short))

    return { identifier = identifier, name = name, record = CAD.records.get(identifier) }
end

function Actions.SwabSubject(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.evidence')
    if not membership then return fail('not authorized') end

    local identifier, name = subjectIdentity(subject)
    local record = CAD.CollectEvidence(source, {
        kind = 'dna',
        label = ('DNA swab from %s'):format(name or 'a subject'),
        subject = identifier,
        location = Core.Coords(source)
    })
    if not record then return fail('the swab could not be logged') end
    return record
end

-- Booking ---------------------------------------------------------------------

-- An arrest requires the subject to be restrained first. Serving an
-- outstanding warrant is automatic: it is the one thing an officer should
-- never have to remember to do by hand.
function Actions.Arrest(source, target, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership, subject = resolveTarget(source, target, 'actions.arrest')
    if not membership then return fail('not authorized') end
    if not Actions.IsCuffed(subject) and not Core.IsAdmin(source) then return fail('restrain the subject first') end

    local identifier, name = subjectIdentity(subject)
    local charges = payload.charges

    local warrant = CAD.ActiveWarrantFor(identifier)
    if warrant then
        CAD.SetWarrantStatus(source, warrant.id, 'served')
        if (not charges or #charges == 0) and warrant.charges then charges = warrant.charges end
    end

    local record = CAD.LogArrest(source, {
        identifier = identifier,
        name = name,
        charges = charges,
        incidentId = payload.incidentId
    })
    if not record then return fail('the arrest could not be filed') end

    detained[subject] = detained[subject] or {}
    detained[subject].cuffed = true
    detained[subject].arrested = true
    detained[subject].identifier = identifier
    detained[subject].name = name

    local booking = {
        target = subject,
        identifier = identifier,
        name = name,
        charges = charges or {},
        agency = membership.agency.id,
        officer = membership.name,
        warrant = warrant and warrant.number or nil,
        incidentId = payload.incidentId
    }

    if Federal.Callouts and Federal.Callouts.OnArrest then
        Federal.Callouts.OnArrest(identifier)
    end

    -- Court is optional: an arrest still books cleanly on a server that has
    -- the court process switched off.
    if Federal.Court and Federal.Court.OnArrest then
        local case = Federal.Court.OnArrest(source, booking)
        booking.caseNumber = case and case.number or nil
    end

    TriggerClientEvent(Federal.Net('restraint'), subject, { cuffed = true, arrested = true })
    Bridge.Notify(subject, ('You have been arrested by the %s.'):format(membership.agency.short), 'error')
    TriggerEvent(Federal.Net('arrested'), booking)
    return booking
end

function Actions.Release(source, target)
    local membership, subject = resolveTarget(source, target, 'actions.arrest')
    if not membership then return fail('not authorized') end

    detained[subject] = nil
    TriggerClientEvent(Federal.Net('restraint'), subject, { cuffed = false })
    Bridge.Notify(subject, 'You have been released.', 'success')
    return { target = subject }
end

function Actions.Fine(source, target, amount, reason)
    local membership, subject = resolveTarget(source, target, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local fines = settings().fines or {}
    local value = Util.Money(amount)
    if not value or value < (fines.minimum or 1) or value > (fines.maximum or 50000) then
        return fail(('a fine must be between %d and %d'):format(fines.minimum or 1, fines.maximum or 50000))
    end

    local account = fines.account or 'bank'
    if not Bridge.RemoveMoney(subject, account, value, 'federal-fine') then
        return fail('the subject cannot pay that fine')
    end

    local identifier, name = subjectIdentity(subject)
    CAD.LogFine(source, identifier, name, value, reason)
    Bridge.Notify(subject, ('You were fined $%d.'):format(value), 'error')
    return { target = subject, amount = value }
end

AddEventHandler('playerDropped', function()
    detained[source] = nil
end)

-- Net wiring. Each handler validates its own argument types before the module
-- functions get a chance to see them.
local function numeric(value)
    local parsed = tonumber(value)
    return parsed and math.floor(parsed) or nil
end

RegisterNetEvent(Federal.Net('action:cuff'), function(target)
    local playerSource = source
    if not numeric(target) then return end
    local result, message = Actions.Cuff(playerSource, numeric(target))
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

RegisterNetEvent(Federal.Net('action:escort'), function(target)
    local playerSource = source
    if not numeric(target) then return end
    local result, message = Actions.Escort(playerSource, numeric(target))
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

RegisterNetEvent(Federal.Net('action:seat'), function(target, netId)
    local playerSource = source
    if not numeric(target) or not numeric(netId) then return end
    local result, message = Actions.Seat(playerSource, numeric(target), numeric(netId))
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

RegisterNetEvent(Federal.Net('action:release'), function(target)
    local playerSource = source
    if not numeric(target) then return end
    local result, message = Actions.Release(playerSource, numeric(target))
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

RegisterNetEvent(Federal.Net('action:fine'), function(target, amount, reason)
    local playerSource = source
    if not numeric(target) then return end
    local result, message = Actions.Fine(playerSource, numeric(target), tonumber(amount), reason)
    Bridge.Notify(playerSource, result and ('Fine of $%d issued.'):format(result.amount) or message,
        result and 'success' or 'error')
end)

Bridge.RegisterCallback(Federal.Net('action:search'), function(source, reply, target)
    local result, message = Actions.SearchSuspect(source, tonumber(target))
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('action:searchVehicle'), function(source, reply, netId)
    local result, message = Actions.SearchVehicle(source, tonumber(netId))
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('action:identify'), function(source, reply, target)
    local result, message = Actions.Identify(source, tonumber(target))
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('action:fingerprint'), function(source, reply, target)
    local result, message = Actions.Fingerprint(source, tonumber(target))
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('action:swab'), function(source, reply, target)
    local result, message = Actions.SwabSubject(source, tonumber(target))
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('action:arrest'), function(source, reply, target, payload)
    local result, message = Actions.Arrest(source, tonumber(target), payload)
    reply(result, message)
end)

return Actions
