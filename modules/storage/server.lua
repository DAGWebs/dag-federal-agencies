DAG.Storage = DAG.Storage or {}
local Storage = DAG.Storage
local Bridge = DAG.Framework
local fileName = Config.Storage.file
local collections, dirty = {}, false

-- MySQL driver ---------------------------------------------------------------
--
-- When oxmysql is running (or Config.Storage.driver = 'mysql'), the database
-- is the boot source of truth and every write is mirrored to it row by row.
-- The in-memory cache keeps every read synchronous exactly as before, and the
-- JSON file keeps being written as a live backup - so switching drivers in
-- either direction never loses data:
--
--   * First start with MySQL and an empty table: the existing storage.json
--     is imported automatically. Nothing to run by hand.
--   * Later starts: the table wins; the JSON file mirrors it.
--
-- The table itself is created automatically (or run sql/storage.sql).

local mysql = {
    enabled = false,
    ready = false,
    table = nil,
    queue = {}
}

local function mysqlDriver()
    local driver = (Config.Storage and Config.Storage.driver) or 'auto'
    if driver == 'json' then return false end
    if driver == 'mysql' then return true end
    return GetResourceState('oxmysql') == 'started'
end

local function mysqlQuery(sql, params)
    local ok, result = pcall(function()
        local p = promise.new()
        exports.oxmysql:query(sql, params or {}, function(rows) p:resolve(rows or false) end)
        return Citizen.Await(p)
    end)
    if not ok then
        Bridge.Print('mysql query failed (%s); storage falls back to JSON only', tostring(result))
        mysql.enabled = false
        return nil
    end
    return result
end

-- Waits (briefly) for the boot load, so a read that races the database still
-- sees stored edits rather than an empty store.
local function awaitMysql()
    if not mysql.enabled or mysql.ready then return end
    local deadline = GetGameTimer() + 10000
    while mysql.enabled and not mysql.ready and GetGameTimer() < deadline do Wait(50) end
    if not mysql.ready then
        Bridge.Print('storage database did not load within 10s; continuing with the JSON file')
        mysql.enabled = false
    end
end

local function mysqlPush(op, name, id, record)
    if not mysql.enabled then return end
    mysql.queue[#mysql.queue + 1] = { op = op, name = name, id = id, record = record }
end

local function mysqlFlush()
    if not mysql.enabled or not mysql.ready or #mysql.queue == 0 then return end
    local batch = mysql.queue
    mysql.queue = {}

    for _, entry in ipairs(batch) do
        if entry.op == 'set' then
            local ok, encoded = pcall(json.encode, entry.record)
            if ok and type(encoded) == 'string' then
                mysqlQuery(
                    ('INSERT INTO `%s` (collection, record_id, data) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)'):format(mysql.table),
                    { entry.name, entry.id, encoded })
            else
                Bridge.Print('could not encode %s/%s for the database; kept in memory and JSON', entry.name, entry.id)
            end
        else
            mysqlQuery(('DELETE FROM `%s` WHERE collection = ? AND record_id = ?'):format(mysql.table), { entry.name, entry.id })
        end
        if not mysql.enabled then return end
    end
end

local function mysqlBoot()
    mysql.table = (Config.Storage and Config.Storage.table)
        or (GetCurrentResourceName():gsub('[^%w]', '_') .. '_storage')

    mysqlQuery(([[CREATE TABLE IF NOT EXISTS `%s` (
        `collection` VARCHAR(64) NOT NULL,
        `record_id` VARCHAR(128) NOT NULL,
        `data` LONGTEXT NOT NULL,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`collection`, `record_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(mysql.table))
    if not mysql.enabled then return end

    local rows = mysqlQuery(('SELECT collection, record_id, data FROM `%s`'):format(mysql.table))
    if not mysql.enabled then return end

    if type(rows) == 'table' and #rows > 0 then
        -- The database is the authority; the JSON file becomes its mirror.
        local loaded = {}
        for _, row in ipairs(rows) do
            local ok, decoded = pcall(json.decode, row.data)
            if ok and type(decoded) == 'table' then
                loaded[row.collection] = loaded[row.collection] or {}
                loaded[row.collection][row.record_id] = decoded
            else
                Bridge.Print('ignoring corrupt database row %s/%s', tostring(row.collection), tostring(row.record_id))
            end
        end
        collections = loaded
        dirty = true -- rewrite the JSON mirror from what the database holds
        Bridge.Print('storage loaded from MySQL table %s (%d rows)', mysql.table, #rows)
    else
        -- Empty table, existing JSON: this is the migration. Every record the
        -- file holds is queued into the database; the file stays as backup.
        local imported = 0
        for name, records in pairs(collections) do
            for id, record in pairs(records) do
                mysqlPush('set', name, tostring(id), record)
                imported = imported + 1
            end
        end
        if imported > 0 then
            Bridge.Print('migrating %d record(s) from %s into MySQL table %s', imported, fileName, mysql.table)
        else
            Bridge.Print('storage using MySQL table %s (new install)', mysql.table)
        end
    end

    mysql.ready = true
    mysqlFlush()
end

-- Native deep copy. The previous json.encode/json.decode round trip cost two
-- full serializations per read and collapsed empty tables into arrays.
local function clone(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for key, inner in pairs(value) do copy[key] = clone(inner, seen) end
    return copy
end

Storage.Clone = clone

local raw = LoadResourceFile(GetCurrentResourceName(), fileName)
if raw and raw ~= '' then
    local success, decoded = pcall(json.decode, raw)
    if success and type(decoded) == 'table' then
        collections = decoded
    else
        Bridge.Print('ignoring invalid storage JSON in %s; starting empty', fileName)
    end
end

local function collection(name)
    assert(type(name) == 'string' and name ~= '', 'Invalid storage collection')
    collections[name] = collections[name] or {}
    return collections[name]
end

function Storage.Get(name, id)
    awaitMysql()
    return clone(collection(name)[tostring(id)])
end

function Storage.All(name)
    awaitMysql()
    return clone(collection(name))
end

function Storage.Set(name, id, value)
    assert(id ~= nil and type(value) == 'table', 'Invalid storage record')
    awaitMysql()
    local stored = clone(value)
    collection(name)[tostring(id)] = stored
    dirty = true
    mysqlPush('set', name, tostring(id), stored)
    TriggerEvent(Bridge.Event('recordUpdated'), name, tostring(id), clone(stored))
    return clone(stored)
end

function Storage.Update(name, id, changes)
    assert(type(changes) == 'table', 'Invalid storage changes')
    local record = Storage.Get(name, id) or {}
    for key, value in pairs(changes) do record[key] = value end
    return Storage.Set(name, id, record)
end

function Storage.Delete(name, id)
    awaitMysql()
    local records, key = collection(name), tostring(id)
    if records[key] == nil then return false end
    records[key] = nil
    dirty = true
    mysqlPush('delete', name, key)
    TriggerEvent(Bridge.Event('recordDeleted'), name, key)
    return true
end

function Storage.Find(name, predicate)
    assert(type(predicate) == 'function', 'Invalid storage predicate')
    awaitMysql()
    local results = {}
    for id, value in pairs(collection(name)) do
        local candidate = clone(value)
        if predicate(candidate, id) then results[#results + 1] = candidate end
    end
    return results
end

function Storage.Save(force)
    if not dirty and not force then return true end

    -- A record holding a function, cycle, or userdata would otherwise throw
    -- inside the save thread and silently stop every future write.
    local encoded, err = nil, nil
    local ok, result = pcall(json.encode, collections)
    if ok then encoded = result else err = result end

    if type(encoded) ~= 'string' then
        Bridge.Print('failed to encode storage (%s); write skipped, data kept in memory', tostring(err))
        return false
    end

    local success = SaveResourceFile(GetCurrentResourceName(), fileName, encoded, -1)
    if success then
        dirty = false
    else
        Bridge.Print('failed to write %s; retrying on the next interval', fileName)
    end
    return success == true
end

local interval = tonumber(Config.Storage.saveInterval) or 5000
if interval < 1000 then
    Bridge.Print('Config.Storage.saveInterval raised to 1000ms (was %s)', tostring(Config.Storage.saveInterval))
    interval = 1000
end

CreateThread(function()
    while true do
        Wait(interval)
        Storage.Save()
        mysqlFlush()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Storage.Save()
    mysqlFlush()
end)

-- Boot the database driver once the server is up. Everything above works
-- from the JSON-loaded cache until the load completes.
if mysqlDriver() then
    mysql.enabled = true
    CreateThread(mysqlBoot)
end

exports('GetStorage', function() return Storage end)
