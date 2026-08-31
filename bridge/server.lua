local Bridge = DAG.Framework
local adapters, registeredCallbacks = {}, {}
local warned = {}

-- Methods a framework adapter may implement. An adapter that omits one is
-- reported as not supporting it; the bridge never substitutes a made-up value.
local METHODS = {
    'getPlayer', 'getIdentifier', 'getName', 'getJob', 'getMoney', 'addMoney',
    'removeMoney', 'getItemCount', 'addItem', 'removeItem', 'hasPermission',
    'setDuty', 'setJob', 'createUseableItem', 'registerCallback'
}

local function finiteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function positiveAmount(value)
    return finiteNumber(value) and value > 0
end

local function positiveInteger(value)
    return positiveAmount(value) and value % 1 == 0
end

function Bridge.RegisterAdapter(name, adapter)
    assert(type(name) == 'string' and type(adapter) == 'table', 'Invalid framework adapter')
    for method in pairs(adapter) do
        assert(type(adapter[method]) == 'function', ('Adapter "%s" method "%s" must be a function'):format(name, method))
    end
    adapters[name] = adapter
end

-- Merges extra methods into an already-registered adapter. This is the
-- supported way to teach the bridge about a fork's APIs (vRP especially)
-- from your own resource, without editing the bundled adapter files.
function Bridge.ExtendAdapter(name, methods)
    assert(type(name) == 'string' and type(methods) == 'table', 'Invalid adapter extension')
    local target = adapters[name]
    assert(target, ('No adapter registered for "%s"'):format(name))
    for method, fn in pairs(methods) do
        assert(type(fn) == 'function', ('Adapter "%s" method "%s" must be a function'):format(name, method))
        target[method] = fn
    end
    return target
end

local function adapter()
    local name = Bridge.Detect()
    return adapters[name], name
end

function Bridge.Supports(method)
    local active = adapter()
    return active ~= nil and type(active[method]) == 'function'
end

-- Returns the adapter methods the active framework does NOT implement, so a
-- resource can fail loudly at startup instead of mid-transaction.
function Bridge.MissingCapabilities()
    local missing = {}
    for _, method in ipairs(METHODS) do
        if not Bridge.Supports(method) then missing[#missing + 1] = method end
    end
    return missing
end

-- Calls an adapter method, or returns nil (once-per-method warning) when the
-- active framework has no implementation for it.
local function call(method, ...)
    local active, name = adapter()
    local fn = active and active[method]
    if type(fn) ~= 'function' then
        local key = name .. ':' .. method
        if not warned[key] then
            warned[key] = true
            Bridge.Print("framework '%s' has no '%s' implementation; callers receive nil/false", name, method)
        end
        return nil
    end
    return fn(...)
end

function Bridge.GetPlayer(source) return call('getPlayer', source) end

-- Identity always resolves: the engine provides a usable fallback on every
-- framework, so these two are the only methods with a built-in default.
function Bridge.GetIdentifier(source)
    return call('getIdentifier', source)
        or GetPlayerIdentifierByType(source, 'license')
        or GetPlayerIdentifiers(source)[1]
end

function Bridge.GetName(source)
    return call('getName', source) or GetPlayerName(source)
end

-- Returns nil when the framework cannot report jobs. Callers gating on a job
-- must treat nil as "deny", not as "unemployed".
function Bridge.GetJob(source)
    return Bridge.NormalizeJob(call('getJob', source))
end

-- Returns nil when the framework has no money implementation.
function Bridge.GetMoney(source, account)
    local balance = call('getMoney', source, account or 'cash')
    return finiteNumber(balance) and balance or nil
end

function Bridge.AddMoney(source, account, amount, reason)
    if not positiveAmount(amount) then return false end
    return call('addMoney', source, account or 'cash', amount, reason) == true
end

function Bridge.RemoveMoney(source, account, amount, reason)
    account = account or 'cash'
    if not positiveAmount(amount) then return false end
    local balance = Bridge.GetMoney(source, account)
    if not balance or balance < amount then return false end
    return call('removeMoney', source, account, amount, reason) == true
end

-- Best-effort framework transfer with compensation. This is convenient for
-- ordinary gameplay, but it is not a substitute for a database transaction:
-- the refund itself can fail, which is why it is logged rather than swallowed.
function Bridge.TransferMoney(fromSource, toSource, account, amount, reason)
    if fromSource == toSource then return false, 'same_player' end
    if not Bridge.RemoveMoney(fromSource, account, amount, reason) then return false, 'insufficient_funds' end
    if Bridge.AddMoney(toSource, account, amount, reason) then return true end

    if not Bridge.AddMoney(fromSource, account, amount, ('rollback:%s'):format(reason or 'transfer')) then
        Bridge.Print('CRITICAL: failed to refund %s %s to %s after a failed transfer', amount, account, tostring(fromSource))
        return false, 'refund_failed'
    end
    return false, 'recipient_failed'
end

local function useOxInventory()
    return Config.Inventory ~= 'framework' and GetResourceState('ox_inventory') == 'started'
end

-- 'ox' when item calls are routed to ox_inventory directly, otherwise
-- 'framework'. Note that on Qbox and Ox Core the framework-native inventory
-- IS ox_inventory, so both values behave identically there.
function Bridge.InventoryProvider()
    return useOxInventory() and 'ox' or 'framework'
end

function Bridge.GetItemCount(source, item, metadata)
    if type(item) ~= 'string' then return 0 end
    if useOxInventory() then return exports.ox_inventory:Search(source, 'count', item, metadata) or 0 end
    local count = call('getItemCount', source, item, metadata)
    return finiteNumber(count) and count or 0
end

function Bridge.HasItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    return Bridge.GetItemCount(source, item, metadata) >= amount
end

function Bridge.AddItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    if useOxInventory() then return exports.ox_inventory:AddItem(source, item, amount, metadata) == true end
    return call('addItem', source, item, amount, metadata) == true
end

function Bridge.RemoveItem(source, item, amount, metadata)
    amount = amount or 1
    if type(item) ~= 'string' or not positiveInteger(amount) then return false end
    -- Single count lookup shared by the guard and the ox path below.
    if Bridge.GetItemCount(source, item, metadata) < amount then return false end
    if useOxInventory() then return exports.ox_inventory:RemoveItem(source, item, amount, metadata) == true end
    return call('removeItem', source, item, amount, metadata) == true
end

-- Citizen and vehicle lookups ------------------------------------------------
--
-- The CAD's Lookup console reads the framework's OWN database (via oxmysql)
-- so officers can find civilians and registered vehicles, not only people
-- who already have a criminal record. Everything here is best-effort: no
-- oxmysql, an unknown schema, or a failed query returns {} and the lookup
-- degrades to criminal records plus online players.

local function dbQuery(query, params)
    if GetResourceState('oxmysql') ~= 'started' then return nil end
    local waiting = promise.new()
    local ok = pcall(function()
        exports.oxmysql:query(query, params, function(rows) waiting:resolve(rows or {}) end)
    end)
    if not ok then return nil end
    return Citizen.Await(waiting)
end

local function charinfoName(raw)
    local ok, info = pcall(json.decode, raw or '')
    if not ok or type(info) ~= 'table' then return nil end
    local name = ('%s %s'):format(info.firstname or '', info.lastname or '')
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    return name ~= '' and name or nil
end

function Bridge.SearchCitizens(term)
    term = tostring(term or '')
    if term == '' then return {} end
    local results = {}

    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        -- charinfo is a JSON blob; matching each word of the term against it
        -- lowercased finds "John Smith" across the two separate JSON keys.
        local where, params = {}, {}
        for word in term:lower():gmatch('%S+') do
            where[#where + 1] = 'LOWER(charinfo) LIKE ?'
            params[#params + 1] = '%' .. word .. '%'
        end
        params[#params + 1] = term
        local rows = dbQuery(('SELECT citizenid, charinfo FROM players WHERE (%s) OR citizenid = ? LIMIT 20')
            :format(table.concat(where, ' AND ')), params)
        for _, row in ipairs(rows or {}) do
            results[#results + 1] = {
                identifier = row.citizenid,
                name = charinfoName(row.charinfo) or row.citizenid
            }
        end
    elseif GetResourceState('es_extended') == 'started' then
        local rows = dbQuery(
            "SELECT identifier, firstname, lastname FROM users WHERE LOWER(CONCAT(firstname, ' ', lastname)) LIKE ? OR identifier = ? LIMIT 20",
            { '%' .. term:lower() .. '%', term })
        for _, row in ipairs(rows or {}) do
            results[#results + 1] = {
                identifier = row.identifier,
                name = ('%s %s'):format(row.firstname or '', row.lastname or '')
            }
        end
    end

    -- Whatever the database said, online players are always searchable.
    if #results == 0 then
        local needle = term:lower()
        for _, playerId in ipairs(GetPlayers()) do
            local playerSource = tonumber(playerId)
            local name = playerSource and Bridge.GetName(playerSource)
            if name and name:lower():find(needle, 1, true) then
                results[#results + 1] = { identifier = Bridge.GetIdentifier(playerSource), name = name }
            end
        end
    end

    return results
end

-- Everything registered to one person, for the CAD's person profile.
function Bridge.VehiclesByOwner(identifier)
    identifier = tostring(identifier or '')
    if identifier == '' then return {} end
    local results = {}

    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        local rows = dbQuery(
            'SELECT plate, vehicle, garage FROM player_vehicles WHERE citizenid = ? LIMIT 20', { identifier })
        for _, row in ipairs(rows or {}) do
            results[#results + 1] = { plate = row.plate, model = tostring(row.vehicle or ''), garage = row.garage }
        end
    elseif GetResourceState('es_extended') == 'started' then
        local rows = dbQuery(
            'SELECT plate, vehicle FROM owned_vehicles WHERE owner = ? LIMIT 20', { identifier })
        for _, row in ipairs(rows or {}) do
            local model = row.vehicle
            local ok, data = pcall(json.decode, row.vehicle or '')
            if ok and type(data) == 'table' and data.model then model = data.model end
            results[#results + 1] = { plate = row.plate, model = tostring(model or '') }
        end
    end
    return results
end

-- What the framework knows about the person themselves: their vitals from
-- charinfo and the licences on their metadata. Best-effort like the rest.
function Bridge.CitizenInfo(identifier)
    identifier = tostring(identifier or '')
    if identifier == '' then return nil end

    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        local rows = dbQuery(
            'SELECT charinfo, metadata, job FROM players WHERE citizenid = ? LIMIT 1', { identifier })
        local row = rows and rows[1]
        if not row then return nil end

        local info = {}
        local ok, charinfo = pcall(json.decode, row.charinfo or '')
        if ok and type(charinfo) == 'table' then
            info.firstname = charinfo.firstname
            info.lastname = charinfo.lastname
            info.birthdate = charinfo.birthdate
            info.gender = charinfo.gender == 1 and 'Female' or charinfo.gender == 0 and 'Male' or tostring(charinfo.gender or '')
            info.nationality = charinfo.nationality
            info.phone = charinfo.phone
        end
        local jobOk, job = pcall(json.decode, row.job or '')
        if jobOk and type(job) == 'table' then
            info.job = job.label or job.name
            if type(job.grade) == 'table' then info.jobPosition = job.grade.name end
            info.jobBoss = job.isboss == true
        end
        local metaOk, metadata = pcall(json.decode, row.metadata or '')
        if metaOk and type(metadata) == 'table' and type(metadata.licences) == 'table' then
            local licences = {}
            for name, held in pairs(metadata.licences) do
                if held == true then licences[#licences + 1] = name end
            end
            table.sort(licences)
            info.licences = licences
        end
        return info
    elseif GetResourceState('es_extended') == 'started' then
        local rows = dbQuery(
            'SELECT firstname, lastname, dateofbirth, sex, job FROM users WHERE identifier = ? LIMIT 1', { identifier })
        local row = rows and rows[1]
        if not row then return nil end
        return {
            firstname = row.firstname,
            lastname = row.lastname,
            birthdate = row.dateofbirth,
            gender = row.sex == 'f' and 'Female' or 'Male',
            job = row.job
        }
    end
    return nil
end

-- The licence names this framework knows about, for the certification
-- prerequisite picker. Framework defaults plus the common addon licences;
-- unknown ones can still be typed by hand in the panel.
function Bridge.LicenceCatalog()
    local names, seen = {}, {}
    local function add(name)
        if type(name) == 'string' and name ~= '' and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    if GetResourceState('qb-core') == 'started' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        local defaults = ok and core and core.Config and core.Config.Player and core.Config.Player.PlayerDefaults
        local licences = defaults and defaults.metadata
            and (defaults.metadata.licences or defaults.metadata.licenses) or nil
        if type(licences) == 'table' then
            for name in pairs(licences) do add(name) end
        end
    end

    for _, name in ipairs({
        'driver', 'weapon', 'business', 'hunting', 'fishing', 'pilot', 'boating',
        'theory_plane', 'practical_plane', 'theory_heli', 'practical_heli'
    }) do add(name) end

    table.sort(names)
    return names
end

-- The licences one player currently holds, as a name -> true map. Live
-- framework data first, the database copy as fallback.
function Bridge.PlayerLicences(source)
    if GetResourceState('qb-core') == 'started' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        local player = ok and core and core.Functions.GetPlayer(source) or nil
        local metadata = player and player.PlayerData and player.PlayerData.metadata
        local licences = metadata and (metadata.licences or metadata.licenses)
        if type(licences) == 'table' then return licences end
    end

    local info = Bridge.CitizenInfo and Bridge.CitizenInfo(Bridge.GetIdentifier(source)) or nil
    local map = {}
    for _, name in ipairs(info and info.licences or {}) do map[name] = true end
    return map
end

function Bridge.LookupVehicles(term)
    term = tostring(term or '')
    if term == '' then return {} end
    local plate = '%' .. term:upper():gsub('%s', '') .. '%'
    local owner = '%' .. term:lower() .. '%'
    local results = {}

    if GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        local rows = dbQuery(
            "SELECT pv.plate, pv.vehicle, p.charinfo FROM player_vehicles pv"
            .. " LEFT JOIN players p ON p.citizenid = pv.citizenid"
            .. " WHERE REPLACE(UPPER(pv.plate), ' ', '') LIKE ? OR LOWER(p.charinfo) LIKE ? LIMIT 20",
            { plate, owner })
        for _, row in ipairs(rows or {}) do
            results[#results + 1] = {
                plate = row.plate,
                model = tostring(row.vehicle or ''),
                owner = charinfoName(row.charinfo)
            }
        end
    elseif GetResourceState('es_extended') == 'started' then
        local rows = dbQuery(
            "SELECT ov.plate, ov.vehicle, u.firstname, u.lastname FROM owned_vehicles ov"
            .. " LEFT JOIN users u ON u.identifier = ov.owner"
            .. " WHERE REPLACE(UPPER(ov.plate), ' ', '') LIKE ? OR LOWER(CONCAT(u.firstname, ' ', u.lastname)) LIKE ? LIMIT 20",
            { plate, owner })
        for _, row in ipairs(rows or {}) do
            local model = row.vehicle
            local ok, data = pcall(json.decode, row.vehicle or '')
            if ok and type(data) == 'table' and data.model then model = data.model end
            results[#results + 1] = {
                plate = row.plate,
                model = tostring(model or ''),
                owner = ('%s %s'):format(row.firstname or '', row.lastname or '')
            }
        end
    end

    return results
end

function Bridge.Notify(source, message, kind, duration)
    TriggerClientEvent(Bridge.Event('client:notify'), source, message, kind, duration)
end

function Bridge.HasPermission(source, permission)
    permission = permission or 'dag.admin'
    if source == 0 then return true end
    if IsPlayerAceAllowed(source, permission) then return true end
    return call('hasPermission', source, permission) == true
end

function Bridge.SetDuty(source, onDuty)
    if type(onDuty) ~= 'boolean' then return false end
    return call('setDuty', source, onDuty) == true
end

-- Changes the player's framework job. This is the one bridge write that hands
-- out authority rather than money or items, so it verifies rather than trusts:
-- the adapter's report is confirmed by re-reading the job, and a framework
-- that cannot report jobs cannot set them either.
function Bridge.SetJob(source, jobName, grade)
    if type(jobName) ~= 'string' or jobName == '' then return false end
    grade = tonumber(grade) or 0
    if not finiteNumber(grade) or grade < 0 or grade % 1 ~= 0 then return false end

    if call('setJob', source, jobName, grade) ~= true then return false end

    -- An adapter that returned true without the job actually changing would
    -- leave a boss believing they promoted someone who was never promoted.
    local job = Bridge.GetJob(source)
    if not job then return false end
    return job.name == jobName and job.grade == grade
end

function Bridge.CreateUseableItem(item, callback)
    assert(type(item) == 'string' and type(callback) == 'function', 'Invalid useable item')
    return call('createUseableItem', item, callback) == true
end

function Bridge.RegisterCallback(name, callback)
    assert(type(name) == 'string' and type(callback) == 'function', 'Invalid callback registration')
    if Bridge.Supports('registerCallback') then return call('registerCallback', name, callback) end
    registeredCallbacks[name] = callback
end

-- Per-source token bucket for the built-in callback transport. Without this a
-- single client can drive unbounded server work by spamming one net event.
local buckets = {}
local function rateLimited(playerSource)
    local limit = Config.CallbackRateLimit
    if not limit or not positiveInteger(limit.max) then return false end

    local now = GetGameTimer()
    local bucket = buckets[playerSource]
    if not bucket or now - bucket.start >= limit.window then
        buckets[playerSource] = { start = now, count = 1 }
        return false
    end

    bucket.count = bucket.count + 1
    if bucket.count <= limit.max then return false end
    if bucket.count == limit.max + 1 then
        Bridge.Debug('rate limited callback flood from %s', tostring(playerSource))
    end
    return true
end

AddEventHandler('playerDropped', function()
    buckets[source] = nil
end)

RegisterNetEvent(Bridge.Event('server:callback'), function(id, name, ...)
    local playerSource = source
    -- Everything below the transport is client-controlled and must be validated.
    if type(id) ~= 'number' or type(name) ~= 'string' then return end
    if rateLimited(playerSource) then return end

    local callback = registeredCallbacks[name]
    if not callback then
        return TriggerClientEvent(Bridge.Event('client:callback'), playerSource, id, nil, 'unknown_callback')
    end

    local answered = false
    local function reply(...)
        if answered then return end
        answered = true
        TriggerClientEvent(Bridge.Event('client:callback'), playerSource, id, ...)
    end

    local ok, err = pcall(callback, playerSource, reply, ...)
    if not ok then
        Bridge.Print("callback '%s' errored: %s", name, tostring(err))
        reply(nil, 'error')
    end
end)

exports('GetFrameworkBridge', function() return Bridge end)
