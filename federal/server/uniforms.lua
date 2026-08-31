-- Uniform management. Uniforms belong to an agency and are edited by its boss
-- (or anyone the rank ladder grants `uniform.manage`), standing in a boss
-- office at one of that agency's stations.
--
-- The intended authoring flow is "wear it, then save it": the client captures
-- the ped components the boss is actually wearing and posts them here. Typing
-- drawable indexes into a config file is supported but is not the happy path.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Schema = Federal.Schema
local Core = Federal.Core

local Uniforms = {}
Federal.Uniforms = Uniforms

local function fail(message)
    return nil, message
end

-- Boss actions happen in the boss office, not from anywhere on the map.
local function requireBoss(source, permission)
    local membership = Core.Require(source, permission)
    if not membership then return nil end

    local allowed = Core.RequireZone(source, membership, 'boss')
    if not allowed then return nil end
    return membership
end

Uniforms.RequireBoss = requireBoss

-- Persists a whole agency after one of its lists has been edited. Agencies are
-- stored as complete records, so every editor write is read-modify-save.
function Uniforms.PersistAgency(agency)
    local normalized, message = Schema.Agency(agency)
    if not normalized then return fail(message) end

    local saved, saveMessage = Core.agencies.save(normalized.id, normalized)
    if not saved then return fail(saveMessage or 'the agency could not be saved') end

    Core.Sync()
    return normalized
end

-- Whether this member is issued a uniform: grade, and division when the
-- uniform is tied to one. Admins bypass the division tie for testing.
local function issued(source, membership, uniform)
    if membership.grade < (uniform.minGrade or 0) then return false, 'your grade does not have that uniform issued' end
    if uniform.division and not Core.IsAdmin(source) then
        local mine = membership.division and membership.division.id
        if mine ~= uniform.division then
            local division = Schema.FindById(membership.agency.divisions or {}, uniform.division)
            return false, ('that uniform is issued to %s only'):format(division and division.label or 'another division')
        end
    end
    return true
end

Uniforms.Issued = issued

function Uniforms.List(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local available = {}
    for _, uniform in ipairs(membership.agency.uniforms or {}) do
        if issued(source, membership, uniform) then
            available[#available + 1] = uniform
        end
    end
    return available
end

function Uniforms.Save(source, payload)
    local membership = requireBoss(source, 'uniform.manage')
    if not membership then return fail('not authorized') end

    local uniform, message = Schema.Uniform(payload)
    if not uniform then return fail(message) end

    local agency = membership.agency
    agency.uniforms = agency.uniforms or {}

    local _, index = Schema.FindById(agency.uniforms, uniform.id)
    if index then
        agency.uniforms[index] = uniform
    else
        agency.uniforms[#agency.uniforms + 1] = uniform
    end

    local saved, saveMessage = Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return uniform
end

function Uniforms.Delete(source, uniformId)
    local membership = requireBoss(source, 'uniform.manage')
    if not membership then return fail('not authorized') end

    local agency = membership.agency
    local uniform, index = Schema.FindById(agency.uniforms or {}, uniformId)
    if not index then return fail('that uniform no longer exists') end

    table.remove(agency.uniforms, index)
    local saved, saveMessage = Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return uniform
end

-- Admin/editor variants for the config commands (/feduniform and friends).
-- The boss-menu path requires standing in the command office; these require
-- federal.admin or editor.manage and work anywhere.
function Uniforms.AdminSave(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'uniform.manage')
    if not agency then return fail(message) end

    local uniform, uniformMessage = Schema.Uniform(payload)
    if not uniform then return fail(uniformMessage) end

    agency.uniforms = agency.uniforms or {}
    local _, index = Schema.FindById(agency.uniforms, uniform.id)
    if index then
        agency.uniforms[index] = uniform
    else
        agency.uniforms[#agency.uniforms + 1] = uniform
    end

    local saved, saveMessage = Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return uniform
end

function Uniforms.AdminDelete(source, agencyId, uniformId)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'uniform.manage')
    if not agency then return fail(message) end

    local uniform, index = Schema.FindById(agency.uniforms or {}, uniformId)
    if not index then return fail('that uniform no longer exists') end

    table.remove(agency.uniforms, index)
    local saved, saveMessage = Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return uniform
end

-- Wearing a uniform happens in a locker room and is gated by grade, so a
-- probationary agent cannot put on the raid kit.
function Uniforms.Wear(source, uniformId)
    local membership = Core.Require(source, 'armory.use', { duty = false })
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'locker')
    if not allowed then return fail('not at a locker room') end

    local uniform = Schema.FindById(membership.agency.uniforms or {}, uniformId)
    if not uniform then return fail('that uniform no longer exists') end

    local ok, reason = issued(source, membership, uniform)
    if not ok then return fail(reason) end

    -- Onto the unit's checkout log, which the CAD roster reads.
    if Federal.Armory and Federal.Armory.LogUniform then
        Federal.Armory.LogUniform(membership.identifier, uniform.label)
    end

    TriggerClientEvent(Federal.Net('wearUniform'), source, uniform)
    return uniform
end

RegisterNetEvent(Federal.Net('uniform:save'), function(payload)
    local playerSource = source
    local uniform, message = Uniforms.Save(playerSource, payload)
    Bridge.Notify(playerSource, uniform and ('Saved uniform "%s".'):format(uniform.label) or message, uniform and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('uniform:delete'), function(uniformId)
    local playerSource = source
    if type(uniformId) ~= 'string' then return end
    local uniform, message = Uniforms.Delete(playerSource, uniformId)
    Bridge.Notify(playerSource, uniform and ('Deleted uniform "%s".'):format(uniform.label) or message, uniform and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('uniform:wear'), function(uniformId)
    local playerSource = source
    if type(uniformId) ~= 'string' then return end
    local uniform, message = Uniforms.Wear(playerSource, uniformId)
    if not uniform then Bridge.Notify(playerSource, message, 'error') end
end)

-- The capture round trip for /feduniform: the command asks the client to read
-- the outfit it is wearing, and the client posts the capture back here.
RegisterNetEvent(Federal.Net('uniform:adminSave'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local uniform, message = Uniforms.AdminSave(playerSource, agencyId, payload)
    Bridge.Notify(playerSource,
        uniform and ('Saved uniform "%s" to %s.'):format(uniform.label, agencyId:upper()) or message,
        uniform and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('uniform:adminDelete'), function(agencyId, uniformId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(uniformId) ~= 'string' then return end
    local uniform, message = Uniforms.AdminDelete(playerSource, agencyId, uniformId)
    Bridge.Notify(playerSource,
        uniform and ('Deleted uniform "%s".'):format(uniform.label) or message,
        uniform and 'success' or 'error')
end)

Bridge.RegisterCallback(Federal.Net('uniforms'), function(source, reply)
    reply(Uniforms.List(source))
end)

return Uniforms
