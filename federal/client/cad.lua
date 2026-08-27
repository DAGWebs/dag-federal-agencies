-- The CAD terminal, rendered through the normalized menu system so it works
-- on ox_lib, qb-menu or the template's bundled NUI menu without change.
--
-- Every screen is built from a fresh server read: the client keeps no CAD
-- state of its own, so two officers never see different versions of a case.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local CAD = {}
Federal.CAD = CAD

local function id(name)
    return Federal.Menus.Id('cad:' .. name)
end

local function show(menuId, title, subtitle, options)
    if #options == 0 then
        options = { { title = 'Nothing to show', disabled = true } }
    end
    DAG.Menu.Register({ id = menuId, title = title, subtitle = subtitle, options = options })
    DAG.Menu.Open(menuId)
end

CAD.Show = show

local function ask(name, callback, ...)
    Bridge.TriggerCallback(Federal.Net('cad:' .. name), function(result, err)
        if result == nil and err then Bridge.Notify(err, 'error') end
        callback(result)
    end, ...)
end

CAD.Ask = ask

local function stamp(seconds)
    if type(seconds) ~= 'number' then return '' end
    return os.date('%d %b %H:%M', seconds)
end

-- Dashboard ------------------------------------------------------------------

function CAD.Open()
    ask('dashboard', function(dashboard)
        if not dashboard then return Bridge.Notify('The CAD is not available to you.', 'error') end
        local agency = State.Mine()
        local modules = agency and agency.cad and agency.cad.modules or {}

        local options = {
            { title = 'Caseload', header = true },
            {
                title = 'Incidents',
                description = 'Open and recent cases',
                icon = 'box',
                badge = tostring(dashboard.openIncidents),
                badgeTone = dashboard.openIncidents > 0 and 'accent' or nil,
                disabled = modules.incidents == false,
                onSelect = CAD.Incidents
            }
        }

        if modules.warrants ~= false then
            options[#options + 1] = {
                title = 'Warrants',
                description = 'Active warrants force-wide',
                icon = 'lock',
                badge = tostring(dashboard.activeWarrants),
                badgeTone = dashboard.activeWarrants > 0 and 'danger' or nil,
                onSelect = CAD.Warrants
            }
        end
        if modules.bolos ~= false then
            options[#options + 1] = {
                title = 'BOLOs',
                description = 'Be on the lookout',
                icon = 'info',
                badge = tostring(dashboard.activeBolos),
                onSelect = CAD.Bolos
            }
        end
        if modules.records ~= false then
            options[#options + 1] = { title = 'Citizen records', icon = 'user', onSelect = CAD.Records }
        end
        if modules.evidence ~= false then
            options[#options + 1] = { title = 'Evidence locker', icon = 'box', onSelect = CAD.Evidence }
        end
        if modules.units ~= false then
            options[#options + 1] = { title = 'Roster', header = true }
            options[#options + 1] = {
                title = 'Units on duty',
                icon = 'user',
                badge = tostring(#dashboard.units),
                onSelect = CAD.Units
            }
        end

        if State.Can('cad.write') then
            options[#options + 1] = { title = 'File', header = true }
            options[#options + 1] = { title = 'File a new incident', icon = 'check', onSelect = CAD.FileIncident }
        end
        if State.Can('cad.warrant') then
            options[#options + 1] = { title = 'Issue a warrant', icon = 'lock', onSelect = CAD.IssueWarrant }
        end
        if State.Can('cad.write') and modules.bolos ~= false then
            options[#options + 1] = { title = 'Create a BOLO', icon = 'info', onSelect = CAD.CreateBolo }
        end

        show(id('dashboard'), ('%s CAD'):format(dashboard.agency or 'Federal'),
            ('%d open case(s)'):format(dashboard.openIncidents), options)
    end)
end

-- Incidents -------------------------------------------------------------------

local PRIORITY = { [1] = 'Low', [2] = 'Normal', [3] = 'High' }

function CAD.Incidents()
    ask('incidents', function(list)
        local options = {}
        for _, incident in ipairs(list or {}) do
            options[#options + 1] = {
                title = incident.title,
                description = ('%s | %s | %s'):format(incident.number, incident.type, stamp(incident.createdAt)),
                icon = 'box',
                badge = incident.status,
                badgeTone = incident.status == 'closed' and 'success' or 'accent',
                onSelect = function() CAD.Incident(incident.id) end
            }
        end
        show(id('incidents'), 'Incidents', ('%d case(s)'):format(#(list or {})), options)
    end)
end

function CAD.Incident(incidentId)
    ask('incident', function(incident)
        if not incident then return Bridge.Notify('That case is not available to you.', 'error') end

        local options = {
            { title = incident.number, description = incident.title, disabled = true },
            {
                title = ('Status: %s'):format(incident.status),
                badge = PRIORITY[incident.priority] or 'Normal',
                disabled = true
            }
        }

        if #(incident.charges or {}) > 0 then
            options[#options + 1] = { title = 'Charges', header = true }
            for _, charge in ipairs(incident.charges) do
                options[#options + 1] = { title = charge, disabled = true }
            end
        end

        if #(incident.suspects or {}) > 0 then
            options[#options + 1] = { title = 'Suspects', header = true }
            for _, suspect in ipairs(incident.suspects) do
                options[#options + 1] = { title = suspect.name, description = suspect.identifier, disabled = true }
            end
        end

        if #(incident.narrative or {}) > 0 then
            options[#options + 1] = { title = 'Narrative', header = true }
            for _, entry in ipairs(incident.narrative) do
                options[#options + 1] = {
                    title = entry.author,
                    description = entry.text,
                    badge = stamp(entry.at),
                    disabled = true
                }
            end
        end

        if State.Can('cad.write') and incident.status ~= 'closed' then
            options[#options + 1] = { title = 'Actions', header = true }
            options[#options + 1] = {
                title = 'Add to the narrative',
                icon = 'check',
                onSelect = function() CAD.AddNarrative(incident.id) end
            }
            options[#options + 1] = {
                title = 'Attach a suspect',
                icon = 'user',
                onSelect = function() CAD.AttachSuspect(incident.id) end
            }
            options[#options + 1] = {
                title = 'Close the case',
                icon = 'lock',
                onSelect = function()
                    DAG.Menu.Confirm('Close this case?', incident.number, function(confirmed)
                        if not confirmed then return end
                        ask('status', function() CAD.Incidents() end, incident.id, 'closed')
                    end)
                end
            }
        end

        if State.Can('cad.expunge') then
            options[#options + 1] = {
                title = 'Expunge the record',
                icon = 'close',
                badgeTone = 'danger',
                onSelect = function()
                    DAG.Menu.Confirm('Expunge this case?', 'This cannot be undone.', function(confirmed)
                        if not confirmed then return end
                        ask('expunge', function() CAD.Incidents() end, incident.id)
                    end)
                end
            }
        end

        show(id('incident'), incident.number, incident.title, options)
    end, incidentId)
end

function CAD.FileIncident()
    DAG.Menu.Input('File an incident', {
        { name = 'title', label = 'Title', required = true },
        { name = 'type', label = 'Type', default = 'General' },
        { name = 'charges', label = 'Charges (comma separated)' },
        { name = 'narrative', label = 'Opening narrative' }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[3] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end

        ask('file', function(incident)
            if incident then
                Bridge.Notify(('Filed %s.'):format(incident.number), 'success')
                CAD.Incident(incident.id)
            end
        end, {
            title = values.title or values[1],
            type = values.type or values[2],
            charges = charges,
            narrative = values.narrative or values[4]
        })
    end)
end

function CAD.AddNarrative(incidentId)
    DAG.Menu.Input('Narrative entry', { { name = 'text', label = 'What happened', required = true } }, function(values)
        if not values then return end
        ask('narrative', function() CAD.Incident(incidentId) end, incidentId, values.text or values[1])
    end)
end

function CAD.AttachSuspect(incidentId)
    DAG.Menu.Input('Attach a suspect', {
        { name = 'identifier', label = 'Identifier', required = true },
        { name = 'name', label = 'Name' },
        { name = 'charges', label = 'Charges (comma separated)' }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[3] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end

        ask('suspect', function() CAD.Incident(incidentId) end, incidentId, {
            identifier = values.identifier or values[1],
            name = values.name or values[2],
            charges = charges
        })
    end)
end

-- Warrants ---------------------------------------------------------------------

function CAD.Warrants()
    ask('warrants', function(list)
        local options = {}
        for _, warrant in ipairs(list or {}) do
            options[#options + 1] = {
                title = warrant.target and warrant.target.name or 'Unknown subject',
                description = ('%s | %s'):format(warrant.number, warrant.reason),
                icon = 'lock',
                badge = warrant.status,
                badgeTone = warrant.status == 'active' and 'danger' or 'success',
                onSelect = function() CAD.Warrant(warrant) end
            }
        end
        show(id('warrants'), 'Warrants', ('%d on file'):format(#(list or {})), options)
    end, { status = 'active' })
end

function CAD.Warrant(warrant)
    local options = {
        { title = warrant.number, description = warrant.reason, disabled = true },
        { title = warrant.target and warrant.target.identifier or '', disabled = true },
        { title = ('Issued by %s'):format(warrant.issuedBy or 'unknown'), disabled = true }
    }

    for _, charge in ipairs(warrant.charges or {}) do
        options[#options + 1] = { title = charge, icon = 'info', disabled = true }
    end

    if State.Can('cad.warrant') and warrant.status == 'active' then
        options[#options + 1] = { title = 'Actions', header = true }
        options[#options + 1] = {
            title = 'Mark as served',
            icon = 'check',
            onSelect = function() ask('warrantStatus', function() CAD.Warrants() end, warrant.id, 'served') end
        }
        options[#options + 1] = {
            title = 'Void the warrant',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function() ask('warrantStatus', function() CAD.Warrants() end, warrant.id, 'void') end
        }
    end

    show(id('warrant'), warrant.number, warrant.target and warrant.target.name or nil, options)
end

function CAD.IssueWarrant()
    DAG.Menu.Input('Issue a warrant', {
        { name = 'identifier', label = 'Subject identifier', required = true },
        { name = 'name', label = 'Subject name' },
        { name = 'reason', label = 'Reason', required = true },
        { name = 'charges', label = 'Charges (comma separated)' }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[4] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end

        ask('warrant', function(warrant)
            if warrant then Bridge.Notify(('Warrant %s issued.'):format(warrant.number), 'success') end
            CAD.Warrants()
        end, {
            identifier = values.identifier or values[1],
            name = values.name or values[2],
            reason = values.reason or values[3],
            charges = charges
        })
    end)
end

-- BOLOs -------------------------------------------------------------------------

function CAD.Bolos()
    ask('bolos', function(list)
        local options = {}
        for _, bolo in ipairs(list or {}) do
            options[#options + 1] = {
                title = bolo.subject,
                description = ('%s | %s'):format(bolo.number, bolo.description),
                icon = bolo.kind == 'vehicle' and 'car' or 'user',
                badge = bolo.plate or bolo.kind,
                onSelect = function()
                    if not State.Can('cad.write') then return end
                    DAG.Menu.Confirm('Close this BOLO?', bolo.number, function(confirmed)
                        if confirmed then ask('boloClose', function() CAD.Bolos() end, bolo.id) end
                    end)
                end
            }
        end
        show(id('bolos'), 'BOLOs', ('%d active'):format(#(list or {})), options)
    end)
end

function CAD.CreateBolo()
    DAG.Menu.Input('Create a BOLO', {
        { name = 'kind', label = 'person or vehicle', required = true, default = 'person' },
        { name = 'subject', label = 'Subject', required = true },
        { name = 'plate', label = 'Plate (vehicles)' },
        { name = 'description', label = 'Description' }
    }, function(values)
        if not values then return end
        ask('bolo', function(bolo)
            if bolo then Bridge.Notify(('BOLO %s created.'):format(bolo.number), 'success') end
            CAD.Bolos()
        end, {
            kind = tostring(values.kind or values[1] or 'person'):lower(),
            subject = values.subject or values[2],
            plate = values.plate or values[3],
            description = values.description or values[4]
        })
    end)
end

-- Records -----------------------------------------------------------------------

function CAD.Records()
    DAG.Menu.Input('Search records', { { name = 'term', label = 'Name or identifier', required = true } }, function(values)
        if not values then return end
        ask('records', function(list)
            local options = {}
            for _, record in ipairs(list or {}) do
                options[#options + 1] = {
                    title = record.name,
                    description = record.identifier,
                    icon = 'user',
                    badge = ('%d arrest(s)'):format(#(record.arrests or {})),
                    onSelect = function() CAD.Record(record.identifier) end
                }
            end
            show(id('records'), 'Records', ('%d match(es)'):format(#(list or {})), options)
        end, values.term or values[1])
    end)
end

function CAD.Record(identifier)
    ask('record', function(record)
        if not record then return Bridge.Notify('No record on file.', 'error') end

        local options = {
            { title = record.name, description = record.identifier, disabled = true },
            { title = 'Fingerprints', badge = record.printed and 'On file' or 'Not taken', disabled = true }
        }

        if record.warrant then
            options[#options + 1] = {
                title = 'ACTIVE WARRANT',
                description = record.warrant.reason,
                badge = record.warrant.number,
                badgeTone = 'danger',
                disabled = true
            }
        end

        if #(record.arrests or {}) > 0 then
            options[#options + 1] = { title = 'Arrests', header = true }
            for _, arrest in ipairs(record.arrests) do
                options[#options + 1] = {
                    title = table.concat(arrest.charges or {}, ', '),
                    description = ('%s by %s'):format(stamp(arrest.at), arrest.officer or 'unknown'),
                    badge = tostring(arrest.agency or ''):upper(),
                    disabled = true
                }
            end
        end

        if #(record.fines or {}) > 0 then
            options[#options + 1] = { title = 'Fines', header = true }
            for _, fine in ipairs(record.fines) do
                options[#options + 1] = {
                    title = fine.reason,
                    description = stamp(fine.at),
                    badge = ('$%d'):format(fine.amount or 0),
                    disabled = true
                }
            end
        end

        if #(record.notes or {}) > 0 then
            options[#options + 1] = { title = 'Notes', header = true }
            for _, note in ipairs(record.notes) do
                options[#options + 1] = { title = note.text, description = stamp(note.at), disabled = true }
            end
        end

        show(id('record'), record.name, record.identifier, options)
    end, identifier)
end

-- Evidence ----------------------------------------------------------------------

function CAD.Evidence(incidentId)
    ask('evidence', function(list)
        local options = {}
        for _, item in ipairs(list or {}) do
            local kind = Const.EvidenceKinds[item.kind]
            options[#options + 1] = {
                title = item.label,
                description = ('%s | %s'):format(item.number, item.analysed and (item.result or 'Analysed') or 'Not analysed'),
                icon = 'box',
                badge = kind and kind.label or item.kind,
                badgeTone = item.analysed and 'success' or nil,
                onSelect = function() CAD.EvidenceItem(item) end
            }
        end
        show(id('evidence'), 'Evidence locker', ('%d item(s)'):format(#(list or {})), options)
    end, incidentId)
end

function CAD.EvidenceItem(item)
    local kind = Const.EvidenceKinds[item.kind] or {}
    local options = {
        { title = item.number, description = item.label, disabled = true },
        { title = ('Collected by %s'):format(item.collectedBy or 'unknown'), description = stamp(item.collectedAt), disabled = true },
        { title = 'Result', description = item.result or 'Not yet analysed', disabled = true }
    }

    options[#options + 1] = { title = 'Chain of custody', header = true }
    for _, entry in ipairs(item.chain or {}) do
        options[#options + 1] = { title = entry.action, description = ('%s | %s'):format(entry.actor, stamp(entry.at)), disabled = true }
    end

    if not item.analysed and kind.analysable and State.Can('actions.evidence') then
        options[#options + 1] = { title = 'Actions', header = true }
        options[#options + 1] = {
            title = 'Analyse at the lab',
            description = 'You must be standing in an evidence lab',
            icon = 'wrench',
            onSelect = function()
                ask('analyse', function(analysed)
                    if analysed then Bridge.Notify(analysed.result, 'success') end
                    CAD.Evidence()
                end, item.id)
            end
        }
    end

    if State.Can('cad.write') then
        options[#options + 1] = {
            title = 'Attach to a case',
            icon = 'box',
            onSelect = function()
                DAG.Menu.Input('Attach to case', { { name = 'incident', label = 'Incident id', required = true } },
                    function(values)
                        if not values then return end
                        ask('attach', function() CAD.Evidence() end, item.id, values.incident or values[1])
                    end)
            end
        }
    end

    show(id('evidenceItem'), item.number, item.label, options)
end

-- Roster --------------------------------------------------------------------------

function CAD.Units()
    ask('dashboard', function(dashboard)
        local options = {}
        for _, unit in ipairs(dashboard and dashboard.units or {}) do
            local status = Const.UnitStatus[unit.status] or { label = unit.status }
            options[#options + 1] = {
                title = ('%s - %s'):format(unit.callsign or '?', unit.name),
                description = ('%s | %s'):format(unit.rank or 'Unranked', unit.station or 'no station'),
                icon = 'user',
                badge = status.label,
                badgeTone = status.tone,
                disabled = true
            }
        end
        show(id('units'), 'Units on duty', nil, options)
    end)
end

-- Status board the officer sets on themselves.
function CAD.StatusMenu()
    local options = {}
    for _, status in ipairs(Const.UnitStatusOrder) do
        local detail = Const.UnitStatus[status]
        options[#options + 1] = {
            title = detail.label,
            icon = 'user',
            badgeTone = detail.tone,
            onSelect = function() Federal.Actions.SetStatus(status) end
        }
    end
    show(id('status'), 'Set your status', nil, options)
end

return CAD
