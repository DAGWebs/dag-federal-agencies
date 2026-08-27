-- The mobile data terminal.
--
-- The CAD as menu rows worked, but a CAD is the one screen an officer reads
-- rather than picks from: you want the caseload and the record side by side,
-- and you want to search it. This builds a single payload from the same server
-- callbacks the menus use and hands it to the NUI panel.
--
-- Handlers stay here. The panel sends back which action was pressed on which
-- record id; nothing executable crosses the boundary.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local MDT = {}
Federal.MDT = MDT

local open = false

local function stamp(seconds)
    if type(seconds) ~= 'number' then return '' end
    return os.date('%d %b %H:%M', seconds)
end

function MDT.IsOpen()
    return open
end

-- Row builders ----------------------------------------------------------------
--
-- One shape for every tab: id, title, meta, a pill, sections of fields and
-- notes, and the actions available on it.

local function incidentRow(incident)
    local narrative = {}
    for _, entry in ipairs(incident.narrative or {}) do
        narrative[#narrative + 1] = { meta = ('%s | %s'):format(entry.author, stamp(entry.at)), text = entry.text }
    end

    local fields = {
        { label = 'Number', value = incident.number },
        { label = 'Type', value = incident.type },
        { label = 'Status', value = incident.status },
        { label = 'Filed by', value = incident.createdBy },
        { label = 'Opened', value = stamp(incident.createdAt) },
        { label = 'Charges', value = table.concat(incident.charges or {}, ', ') }
    }

    local suspects = {}
    for _, suspect in ipairs(incident.suspects or {}) do
        suspects[#suspects + 1] = { label = suspect.name, value = suspect.identifier }
    end

    local actions = {}
    if State.Can('cad.write') and incident.status ~= 'closed' then
        actions[#actions + 1] = { id = 'narrative', label = 'Add narrative' }
        actions[#actions + 1] = { id = 'close', label = 'Close case' }
    end
    if State.Can('cad.expunge') then
        actions[#actions + 1] = { id = 'expunge', label = 'Expunge', tone = 'danger' }
    end

    return {
        id = incident.id,
        title = incident.title,
        meta = ('%s | %s'):format(incident.number, incident.type or ''),
        pill = incident.status,
        tone = incident.status == 'closed' and 'success' or 'accent',
        sections = {
            { label = 'Case', fields = fields },
            #suspects > 0 and { label = 'Suspects', fields = suspects } or nil,
            #narrative > 0 and { label = 'Narrative', notes = narrative } or nil
        },
        actions = actions
    }
end

local function warrantRow(warrant)
    local actions = {}
    if State.Can('cad.warrant') and warrant.status == 'active' then
        actions[#actions + 1] = { id = 'serve', label = 'Mark served' }
        actions[#actions + 1] = { id = 'void', label = 'Void', tone = 'danger' }
    end

    return {
        id = warrant.id,
        title = warrant.target and warrant.target.name or 'Unknown subject',
        meta = ('%s | %s'):format(warrant.number, warrant.reason or ''),
        pill = warrant.status,
        tone = warrant.status == 'active' and 'danger' or 'success',
        sections = {
            { label = 'Warrant', fields = {
                { label = 'Number', value = warrant.number },
                { label = 'Subject', value = warrant.target and warrant.target.identifier },
                { label = 'Reason', value = warrant.reason },
                { label = 'Charges', value = table.concat(warrant.charges or {}, ', ') },
                { label = 'Issued by', value = warrant.issuedBy },
                { label = 'Issued', value = stamp(warrant.createdAt) }
            } }
        },
        actions = actions
    }
end

local function boloRow(bolo)
    return {
        id = bolo.id,
        title = bolo.subject,
        meta = ('%s | %s'):format(bolo.number, bolo.kind),
        pill = bolo.plate or bolo.kind,
        tone = 'accent',
        sections = {
            { label = 'BOLO', fields = {
                { label = 'Number', value = bolo.number },
                { label = 'Kind', value = bolo.kind },
                { label = 'Plate', value = bolo.plate },
                { label = 'Description', value = bolo.description },
                { label = 'Created by', value = bolo.createdBy }
            } }
        },
        actions = State.Can('cad.write') and { { id = 'close', label = 'Close BOLO' } } or {}
    }
end

local function recordRow(record)
    local arrests, fines, notes = {}, {}, {}
    for _, arrest in ipairs(record.arrests or {}) do
        arrests[#arrests + 1] = {
            meta = ('%s | %s'):format(stamp(arrest.at), arrest.officer or 'unknown'),
            text = table.concat(arrest.charges or {}, ', ')
        }
    end
    for _, fine in ipairs(record.fines or {}) do
        fines[#fines + 1] = { meta = stamp(fine.at), text = ('$%d - %s'):format(fine.amount or 0, fine.reason or '') }
    end
    for _, note in ipairs(record.notes or {}) do
        notes[#notes + 1] = { meta = stamp(note.at), text = note.text }
    end

    return {
        id = record.identifier,
        title = record.name,
        meta = record.identifier,
        pill = ('%d arrest(s)'):format(#(record.arrests or {})),
        tone = #(record.arrests or {}) > 0 and 'danger' or nil,
        sections = {
            { label = 'Subject', fields = {
                { label = 'Name', value = record.name },
                { label = 'Identifier', value = record.identifier },
                { label = 'Fingerprints', value = record.printed and 'On file' or 'Not taken' }
            } },
            #arrests > 0 and { label = 'Arrests', notes = arrests } or nil,
            #fines > 0 and { label = 'Fines', notes = fines } or nil,
            #notes > 0 and { label = 'Notes', notes = notes } or nil
        },
        actions = {}
    }
end

local function evidenceRow(item)
    local chain = {}
    for _, entry in ipairs(item.chain or {}) do
        chain[#chain + 1] = { meta = stamp(entry.at), text = ('%s - %s'):format(entry.actor, entry.action) }
    end

    return {
        id = item.id,
        title = item.label,
        meta = ('%s | %s'):format(item.number, Const.EvidenceKinds[item.kind] and Const.EvidenceKinds[item.kind].label or item.kind),
        pill = item.analysed and 'Analysed' or 'Unprocessed',
        tone = item.analysed and 'success' or nil,
        sections = {
            { label = 'Item', fields = {
                { label = 'Number', value = item.number },
                { label = 'Collected by', value = item.collectedBy },
                { label = 'Collected', value = stamp(item.collectedAt) },
                { label = 'Result', value = item.result or 'Not yet analysed' },
                { label = 'Case', value = item.incidentId }
            } },
            #chain > 0 and { label = 'Chain of custody', notes = chain } or nil
        },
        -- Analysis is deliberately absent: the lab is a place, and the server
        -- refuses it from anywhere else.
        actions = {}
    }
end

local function leadRow(lead)
    local kind = Const.LeadKinds[lead.kind] or {}
    return {
        id = lead.id,
        title = kind.label or lead.kind,
        meta = lead.summary,
        pill = lead.status == 'open' and 'New' or 'Worked',
        tone = lead.status == 'open' and 'accent' or 'success',
        sections = {
            { label = 'Lead', fields = {
                { label = 'Number', value = lead.number },
                { label = 'Plate', value = lead.plate },
                { label = 'Keeper', value = lead.keeper },
                { label = 'Named', value = lead.name }
            } }
        },
        actions = lead.status == 'open' and { { id = 'follow', label = 'Follow lead' } } or {}
    }
end

local function reportRow(report)
    return {
        id = report.id,
        title = report.text,
        meta = ('From %s | %s'):format(report.caller, stamp(report.at)),
        pill = report.status == 'responding' and 'Responding' or 'New',
        tone = report.status == 'responding' and 'accent' or 'danger',
        sections = {
            { label = 'Report', fields = {
                { label = 'Caller', value = report.caller },
                { label = 'Received', value = stamp(report.at) },
                { label = 'Escalated', value = report.calloutId and 'Yes' or 'No' }
            } }
        },
        actions = {
            { id = 'waypoint', label = 'Set waypoint' },
            { id = 'respond', label = 'Respond' },
            { id = 'close', label = 'Close report', tone = 'danger' }
        }
    }
end

local function unitRow(unit)
    local status = Const.UnitStatus[unit.status] or {}
    return {
        id = tostring(unit.source or unit.identifier),
        title = ('%s %s'):format(unit.callsign or '?', unit.name or ''),
        meta = ('%s | %s'):format(unit.rank or 'Unranked', unit.station or 'no station'),
        pill = status.label or unit.status,
        tone = status.tone,
        sections = {
            { label = 'Unit', fields = {
                { label = 'Callsign', value = unit.callsign },
                { label = 'Rank', value = unit.rank },
                { label = 'Station', value = unit.station },
                { label = 'Status', value = status.label or unit.status }
            } }
        },
        actions = {}
    }
end

local function custodyRow(inmate)
    return {
        id = inmate.identifier,
        title = inmate.name,
        meta = ('%s | %d month(s)'):format(inmate.caseNumber or 'no case', inmate.months or 0),
        pill = Federal.Jail.Clock(inmate.remaining),
        tone = inmate.online and 'accent' or nil,
        sections = {
            { label = 'Inmate', fields = {
                { label = 'Name', value = inmate.name },
                { label = 'Case', value = inmate.caseNumber },
                { label = 'Sentence', value = ('%d month(s)'):format(inmate.months or 0) },
                { label = 'Remaining', value = Federal.Jail.Clock(inmate.remaining) },
                { label = 'Online', value = inmate.online and 'Yes' or 'No' }
            } }
        },
        actions = State.Can('actions.arrest') and { { id = 'release', label = 'Release', tone = 'danger' } } or {}
    }
end

MDT.Builders = {
    incidents = incidentRow,
    warrants = warrantRow,
    bolos = boloRow,
    records = recordRow,
    evidence = evidenceRow,
    leads = leadRow,
    reports = reportRow,
    units = unitRow,
    custody = custodyRow
}

local function build(key, list)
    local builder = MDT.Builders[key]
    local rows = {}
    for _, entry in ipairs(list or {}) do rows[#rows + 1] = builder(entry) end
    return rows
end

MDT.Build = build

-- Gathering -----------------------------------------------------------------------

-- Every tab is one callback. They are fired together and the panel opens once
-- the last one lands, so the terminal never renders half a caseload.
local SOURCES = {
    { key = 'incidents', callback = 'cad:incidents' },
    { key = 'warrants', callback = 'cad:warrants', args = { { status = 'active' } } },
    { key = 'bolos', callback = 'cad:bolos' },
    { key = 'evidence', callback = 'cad:evidence' },
    { key = 'leads', callback = 'leads' },
    { key = 'reports', callback = 'reports' },
    { key = 'custody', callback = 'jail:roster' }
}

function MDT.Open()
    if not State.Can('cad.view') then
        return Bridge.Notify('You are not authorized to use the terminal.', 'error')
    end

    local agency = State.Mine()
    local membership = State.Membership()
    local payload = {
        agency = agency and agency.short or 'FED',
        title = agency and agency.label or 'Mobile data terminal',
        subtitle = membership and ('%s | %s'):format(membership.rank, State.OnDuty() and 'On duty' or 'Off duty') or nil,
        status = 'Ready'
    }

    local pending = #SOURCES + 2
    local function settle()
        pending = pending - 1
        if pending > 0 then return end

        open = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'mdt:open', mdt = payload })
    end

    for _, source in ipairs(SOURCES) do
        Bridge.TriggerCallback(Federal.Net(source.callback), function(list)
            payload[source.key] = build(source.key, list)
            settle()
        end, table.unpack(source.args or {}))
    end

    -- Records need a search term, so the terminal opens with a blank list the
    -- officer fills by searching.
    payload.records = {}
    settle()

    Bridge.TriggerCallback(Federal.Net('cad:dashboard'), function(dashboard)
        payload.units = build('units', dashboard and dashboard.units or {})
        settle()
    end)
end

function MDT.Refresh()
    if not open then return end
    -- Rebuilt from scratch: the terminal reads live records, and holding a
    -- stale copy is how two officers end up seeing different cases.
    MDT.Open()
end

function MDT.Close()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'mdt:close' })
end

-- Actions ---------------------------------------------------------------------------

local function ask(name, callback, ...)
    Bridge.TriggerCallback(Federal.Net(name), function(result, err)
        if not result and err then Bridge.Notify(err, 'error') end
        if callback then callback(result) end
    end, ...)
end

local HANDLERS = {}

HANDLERS.incidents = function(id, action)
    if action == 'close' then return ask('cad:status', MDT.Refresh, id, 'closed') end
    if action == 'expunge' then return ask('cad:expunge', MDT.Refresh, id) end
    if action == 'narrative' then
        -- Input dialogs need the pointer, and the terminal is holding it.
        MDT.Close()
        DAG.Menu.Input('Narrative entry', { { name = 'text', label = 'What happened', required = true } },
            function(values)
                if not values then return end
                ask('cad:narrative', function() MDT.Open() end, id, values.text or values[1])
            end)
    end
end

HANDLERS.warrants = function(id, action)
    if action == 'serve' then return ask('cad:warrantStatus', MDT.Refresh, id, 'served') end
    if action == 'void' then return ask('cad:warrantStatus', MDT.Refresh, id, 'void') end
end

HANDLERS.bolos = function(id, action)
    if action == 'close' then return ask('cad:boloClose', MDT.Refresh, id) end
end

HANDLERS.leads = function(id, action)
    if action == 'follow' then
        return ask('leads:follow', function(lead)
            if lead then
                Bridge.Notify(lead.summary or 'Lead followed.', 'success', 8000)
                if lead.kind == 'address' then Federal.Leads.MarkAddress(lead) end
            end
            MDT.Refresh()
        end, id)
    end
end

HANDLERS.reports = function(id, action)
    if action == 'respond' then
        TriggerServerEvent(Federal.Net('report:ack'), id)
        Federal.Actions.SetStatus('enroute')
        return MDT.Refresh()
    end
    if action == 'close' then
        TriggerServerEvent(Federal.Net('report:close'), id)
        return SetTimeout(300, MDT.Refresh)
    end
    if action == 'waypoint' then
        MDT.Close()
        Bridge.TriggerCallback(Federal.Net('reports'), function(list)
            for _, report in ipairs(list or {}) do
                if report.id == id and report.location then
                    SetNewWaypoint(report.location.x, report.location.y)
                    Bridge.Notify('Waypoint set.', 'inform')
                end
            end
        end)
    end
end

HANDLERS.custody = function(id, action)
    if action == 'release' then
        TriggerServerEvent(Federal.Net('jail:release'), id)
        return SetTimeout(300, MDT.Refresh)
    end
end

function MDT.Act(tab, id, action)
    local handler = HANDLERS[tab]
    if handler then handler(id, action) end
end

RegisterNUICallback('mdtClose', function(_, reply)
    reply({})
    open = false
    SetNuiFocus(false, false)
end)

RegisterNUICallback('mdtAction', function(data, reply)
    reply({})
    if type(data) ~= 'table' or type(data.tab) ~= 'string' or type(data.action) ~= 'string' then return end
    MDT.Act(data.tab, data.id, data.action)
end)

-- Focus is a global input lock. Never leave it held across a restart.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and open then
        open = false
        SetNuiFocus(false, false)
    end
end)

return MDT
