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
    return Federal.Util.Stamp(seconds)
end

-- Auto-filed incidents from other resources sometimes ship a location of
-- (0,0): that is "no scene", not a scene in the ocean off the pier.
local function realLocation(location)
    if type(location) ~= 'table' then return nil end
    local x, y = tonumber(location.x) or 0, tonumber(location.y) or 0
    if math.abs(x) < 1.0 and math.abs(y) < 1.0 then return nil end
    return location
end

function MDT.IsOpen()
    return open
end

-- A borrowed session: this client is working a stolen terminal on somebody
-- else's login. The server hands it over and owns the real expiry; this
-- local copy just keeps the client honest.
local borrowed = nil

local function activeBorrow()
    if borrowed and borrowed.expires > GetGameTimer() then return borrowed end
    borrowed = nil
    return nil
end

-- Writing rights: your own rank's, or the stolen session's (the server
-- grants a borrowed login read/write as the original owner - never expunge,
-- never warrants).
local function canWrite()
    return State.Can('cad.write') or activeBorrow() ~= nil
end

-- The letterhead every document carries: the viewing agency's identity, so
-- an IAA warrant and an FIB warrant read as two different agencies' paper.
local function letterhead()
    local agency = State.Mine()
    if agency then
        return agency.label, agency.cad and agency.cad.logo or nil
    end
    local borrow = activeBorrow()
    if borrow and borrow.brand then
        return borrow.brand.label or 'Federal Agency', borrow.brand.logo
    end
    return 'Federal Agency', nil
end

-- Row builders ----------------------------------------------------------------
--
-- One shape for every tab: id, title, meta, a pill, sections of fields and
-- notes, and the actions available on it.

-- The overview: the screen a real terminal lands on - live caseload numbers
-- and who is on the street right now.
local function overviewRow(dash)
    dash = type(dash) == 'table' and dash or {}
    local units = dash.units or {}

    local notes = {}
    for _, unit in ipairs(units) do
        notes[#notes + 1] = {
            meta = ('%s | %s'):format(unit.callsign or '?', unit.status or 'available'),
            text = unit.name .. (unit.division and (' - ' .. unit.division) or '')
        }
    end

    return {
        id = 'overview',
        title = 'Agency status',
        meta = 'Live caseload and street strength',
        pill = dash.agency or 'FED',
        tone = 'accent',
        sections = {
            { label = 'Caseload', fields = {
                { label = 'Open cases', value = dash.openIncidents or 0 },
                { label = 'Active warrants', value = dash.activeWarrants or 0 },
                { label = 'Active BOLOs', value = dash.activeBolos or 0 },
                { label = 'Units on duty', value = #units }
            } },
            #notes > 0 and { label = 'On the street', notes = notes } or nil
        },
        actions = {}
    }
end

local function incidentRow(incident)
    local narrative = {}
    for _, entry in ipairs(incident.narrative or {}) do
        narrative[#narrative + 1] = { meta = ('%s | %s'):format(entry.author, stamp(entry.at)), text = entry.text }
    end

    local officers = {}
    for _, officer in ipairs(incident.officers or {}) do
        officers[#officers + 1] = officer.name
    end

    -- Only what the letterhead does not already say; blanks are omitted, not
    -- rendered as empty rows.
    local fields = {
        { label = 'Status', value = incident.status },
        { label = 'Priority', value = ({ 'High', 'Medium', 'Low' })[incident.priority or 2] },
        { label = 'Last updated', value = stamp(incident.updatedAt) },
        { label = 'Officers on the case', value = #officers > 0 and table.concat(officers, ', ') or nil },
        { label = 'Charges', value = #(incident.charges or {}) > 0 and table.concat(incident.charges, ', ') or nil }
    }

    local scene = realLocation(incident.location)
    if scene then
        fields[#fields + 1] = {
            label = 'Scene',
            value = ('X %d | Y %d'):format(math.floor(scene.x), math.floor(scene.y))
        }
    end

    local suspects = {}
    for _, suspect in ipairs(incident.suspects or {}) do
        suspects[#suspects + 1] = {
            label = suspect.name,
            value = suspect.identifier,
            link = suspect.identifier and { lookup = suspect.identifier } or nil
        }
    end

    local witnesses = {}
    for _, witness in ipairs(incident.witnesses or {}) do
        witnesses[#witnesses + 1] = { label = witness.name, value = witness.statement or witness.identifier or '' }
    end

    -- Related cases: the thread this case belongs to, each one a click away.
    local linked = {}
    for _, link in ipairs(incident.linked or {}) do
        linked[#linked + 1] = {
            label = link.number,
            value = ('%s (%s)'):format(link.title, link.status),
            link = { tab = 'incidents', id = link.id }
        }
    end

    local photos = {}
    for _, photo in ipairs(incident.photos or {}) do
        photos[#photos + 1] = { url = photo.url, caption = photo.caption }
    end

    local actions = {}
    if scene then
        actions[#actions + 1] = { id = 'waypoint', label = 'Route to scene' }
    end
    if canWrite() then
        if incident.status ~= 'closed' then
            actions[#actions + 1] = { id = 'narrative', label = 'Add narrative' }
            actions[#actions + 1] = { id = 'photo', label = 'Attach photo' }
            actions[#actions + 1] = { id = 'charge', label = 'Add charge' }
            actions[#actions + 1] = { id = 'suspect', label = 'Add suspect' }
            actions[#actions + 1] = { id = 'witness', label = 'Add witness' }
            actions[#actions + 1] = { id = 'assign', label = 'Attach me' }
            actions[#actions + 1] = { id = 'scene', label = scene and 'Move scene marker' or 'Mark scene on map' }
            actions[#actions + 1] = { id = 'link', label = 'Link incidents' }
            if #linked > 0 then
                actions[#actions + 1] = { id = 'unlink', label = 'Unlink' }
            end
            actions[#actions + 1] = { id = 'case', label = 'Add to case file' }
            actions[#actions + 1] = { id = 'close', label = 'Close case' }
        else
            actions[#actions + 1] = { id = 'reopen', label = 'Reopen case' }
        end
    end
    if State.Can('cad.expunge') then
        actions[#actions + 1] = { id = 'expunge', label = 'Expunge', tone = 'danger' }
    end

    -- Built incrementally: a conditional nil inside a table constructor
    -- punches a hole that stops ipairs dead at the missing section.
    local sections = { { label = 'Case', fields = fields } }
    if #suspects > 0 then sections[#sections + 1] = { label = 'Suspects', fields = suspects } end
    if #witnesses > 0 then sections[#sections + 1] = { label = 'Witnesses', fields = witnesses } end
    if #linked > 0 then sections[#sections + 1] = { label = 'Linked cases', fields = linked } end
    if #narrative > 0 then sections[#sections + 1] = { label = 'Narrative', notes = narrative } end

    local agencyLabel, logo = letterhead()
    local opening = incident.narrative and incident.narrative[1]
    return {
        id = incident.id,
        title = incident.title,
        meta = ('%s | %s'):format(incident.number, incident.type or ''),
        pill = incident.status,
        tone = incident.status == 'closed' and 'success'
            or ((incident.priority or 2) == 1 and 'danger' or 'accent'),
        -- The report header: an incident reads like paper, with the working
        -- fields and full narrative following underneath.
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'INCIDENT REPORT',
            number = incident.number,
            status = incident.status == 'closed' and 'closed' or 'active',
            subject = incident.title,
            subjectId = incident.type,
            body = opening and opening.text
                or 'No narrative has been filed yet. Add the first entry below.',
            charges = incident.charges or {},
            issuedBy = incident.createdBy or 'Unknown',
            issuedAt = stamp(incident.createdAt)
        },
        photos = photos,
        sections = sections,
        actions = actions
    }
end

local WARRANT_HEADINGS = {
    arrest = 'WARRANT FOR ARREST',
    search = 'SEARCH WARRANT',
    bench = 'BENCH WARRANT'
}

local WARRANT_BODIES = {
    arrest = 'By the authority vested in this agency, any federal officer is commanded to arrest the above-named subject and bring them before the court without unnecessary delay. Grounds: %s.',
    search = 'By the authority vested in this agency, any federal officer is authorized to enter and search the premises and property of the above-named subject and to seize evidence therein. Grounds: %s.',
    bench = 'By order of the court, any federal officer is commanded to take the above-named subject into custody and produce them before the bench forthwith. Grounds: %s.'
}

local function warrantRow(warrant)
    local actions = {}
    if State.Can('cad.warrant') and warrant.status == 'active' then
        actions[#actions + 1] = { id = 'serve', label = 'Mark served' }
        actions[#actions + 1] = { id = 'void', label = 'Void', tone = 'danger' }
    end

    local agencyLabel, logo = letterhead()
    local kind = warrant.kind or 'arrest'
    return {
        id = warrant.id,
        title = warrant.target and warrant.target.name or 'Unknown subject',
        meta = ('%s | %s | %s'):format(warrant.number, (WARRANT_HEADINGS[kind] or 'WARRANT'):lower(), warrant.reason or ''),
        pill = warrant.status,
        tone = warrant.status == 'active' and 'danger' or 'success',
        -- Rendered as a government document, not a form: letterhead, subject
        -- block, enumerated charges, issuing officer and seal line.
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = WARRANT_HEADINGS[kind] or 'WARRANT',
            number = warrant.number,
            status = warrant.status,
            subject = warrant.target and warrant.target.name or 'Unknown subject',
            subjectId = warrant.target and warrant.target.identifier or '',
            body = (WARRANT_BODIES[kind] or WARRANT_BODIES.arrest):format(warrant.reason or 'as stated on file'),
            charges = warrant.charges or {},
            issuedBy = warrant.issuedBy or 'Unknown',
            issuedAt = stamp(warrant.createdAt)
        },
        sections = (function()
            -- Built incrementally: conditional nils in a constructor punch
            -- holes that stop iteration dead.
            local refs = {}
            if warrant.target and warrant.target.identifier then
                refs[#refs + 1] = {
                    label = 'Subject record',
                    value = warrant.target.name or warrant.target.identifier,
                    link = { lookup = warrant.target.identifier }
                }
            end
            if warrant.incidentId then
                refs[#refs + 1] = {
                    label = 'Originating case',
                    value = warrant.incidentId,
                    link = { tab = 'incidents', id = warrant.incidentId }
                }
            end
            return #refs > 0 and { { label = 'Cross-references', fields = refs } } or {}
        end)(),
        actions = actions
    }
end

local caseCache = {}

local function caseRow(board)
    caseCache[board.id] = board
    -- Every pin is a doorway: clicking it opens the record it references.
    local PIN_TABS = { incident = 'incidents', warrant = 'warrants', bolo = 'bolos', evidence = 'evidence' }
    local pinsByKind = {}
    for index, pin in ipairs(board.pins or {}) do
        local kind = pin.kind or 'record'
        pinsByKind[kind] = pinsByKind[kind] or {}
        local link = nil
        if PIN_TABS[kind] then
            link = { tab = PIN_TABS[kind], id = pin.refId }
        elseif kind == 'record' then
            link = { lookup = pin.refId }
        end
        pinsByKind[kind][#pinsByKind[kind] + 1] = {
            label = ('#%d'):format(index),
            value = pin.label,
            link = link
        }
    end

    local boardFields = {
        { label = 'Number', value = board.number },
        { label = 'Status', value = board.status },
        { label = 'Classification', value = board.classification },
        { label = 'Lead agent', value = board.createdBy },
        { label = 'Agents', value = table.concat(board.agents or {}, ', ') },
        { label = 'Opened', value = stamp(board.createdAt) },
        { label = 'Updated', value = stamp(board.updatedAt) },
        { label = 'Pins', value = #(board.pins or {}) }
    }
    local sections = { { label = 'Case file', fields = boardFields } }
    if board.summary then
        sections[#sections + 1] = { label = 'Summary', notes = { { text = board.summary } } }
    end

    local KIND_LABELS = {
        incident = 'Pinned incidents', warrant = 'Pinned warrants', bolo = 'Pinned BOLOs',
        evidence = 'Pinned evidence', record = 'Pinned citizen records'
    }
    for kind, fields in pairs(pinsByKind) do
        sections[#sections + 1] = { label = KIND_LABELS[kind] or kind, fields = fields }
    end

    local notes = {}
    for _, entry in ipairs(board.notes or {}) do
        notes[#notes + 1] = { meta = ('%s | %s'):format(entry.author, stamp(entry.at)), text = entry.text }
    end
    if #notes > 0 then sections[#sections + 1] = { label = 'Notes', notes = notes } end

    -- Photo pins render as an image wall; the rest as draggable chips.
    local photos, chips = {}, {}
    for index, pin in ipairs(board.pins or {}) do
        if pin.kind == 'photo' then
            photos[#photos + 1] = { url = pin.refId, caption = pin.label }
        end
        chips[#chips + 1] = { index = index, kind = pin.kind, label = pin.label }
    end

    local actions = {}
    if canWrite() then
        if board.status ~= 'closed' then
            actions[#actions + 1] = { id = 'pin', label = 'Pin a record' }
            actions[#actions + 1] = { id = 'photo', label = 'Pin a photo' }
            actions[#actions + 1] = { id = 'note', label = 'Add note' }
            actions[#actions + 1] = { id = 'agent', label = 'Add agent' }
            if #(board.pins or {}) > 0 then
                actions[#actions + 1] = { id = 'unpin', label = 'Unpin' }
            end
            actions[#actions + 1] = { id = 'close', label = 'Close case file' }
        else
            actions[#actions + 1] = { id = 'reopen', label = 'Reopen' }
        end
    end
    if State.Can('cad.expunge') then
        actions[#actions + 1] = { id = 'delete', label = 'Delete', tone = 'danger' }
    end

    local agencyLabel, logo = letterhead()
    return {
        id = board.id,
        title = board.title,
        meta = ('%s | %d pin(s)'):format(board.number, #(board.pins or {})),
        pill = board.status,
        tone = board.status == 'closed' and 'success' or 'accent',
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = ('CASE FILE%s'):format(board.classification and (' - ' .. board.classification:upper()) or ''),
            number = board.number,
            status = board.status == 'closed' and 'closed' or 'active',
            subject = board.title,
            subjectId = ('%d record(s) on the board'):format(#(board.pins or {})),
            body = board.summary or 'No opening summary on file.',
            charges = {},
            issuedBy = board.createdBy or 'Unknown',
            issuedAt = stamp(board.createdAt)
        },
        photos = photos,
        pinChips = board.status ~= 'closed' and chips or nil,
        sections = sections,
        actions = actions
    }
end

local function boloRow(bolo)
    local agencyLabel, logo = letterhead()
    return {
        id = bolo.id,
        title = bolo.subject,
        meta = ('%s | %s'):format(bolo.number, bolo.kind),
        pill = bolo.plate or bolo.kind,
        tone = 'accent',
        -- The face they are looking for, when the subject's record has one.
        photos = bolo.photo and { { url = bolo.photo, caption = bolo.subject } } or nil,
        -- A BOLO reads as a broadcast notice, not a form.
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'BE ON THE LOOKOUT',
            number = bolo.number,
            status = bolo.status or 'active',
            subject = bolo.subject or 'Unknown subject',
            subjectId = bolo.plate and ('Plate %s'):format(bolo.plate) or bolo.kind,
            body = bolo.description or 'All units: locate and report. Approach per agency policy.',
            charges = {},
            issuedBy = bolo.createdBy or 'Dispatch',
            issuedAt = stamp(bolo.createdAt)
        },
        sections = {},
        actions = canWrite() and { { id = 'close', label = 'Close BOLO' } } or {}
    }
end

local function recordRow(record)
    local arrests, fines, notes = {}, {}, {}
    for _, arrest in ipairs(record.arrests or {}) do
        -- Each booking links straight to its arrest report on the Custody
        -- tab: a record is a table of contents, not a dead end.
        arrests[#arrests + 1] = {
            label = ('%s | %s'):format(stamp(arrest.at), arrest.officer or 'unknown'),
            value = table.concat(arrest.charges or {}, ', '),
            link = { tab = 'custody', id = ('arr:%s:%s'):format(record.identifier or '?', tostring(arrest.at or 0)) }
        }
    end
    for _, fine in ipairs(record.fines or {}) do
        fines[#fines + 1] = { meta = stamp(fine.at), text = ('$%d - %s'):format(fine.amount or 0, fine.reason or '') }
    end
    for _, note in ipairs(record.notes or {}) do
        notes[#notes + 1] = { meta = stamp(note.at), text = note.text }
    end

    local sections = {
        { label = 'Subject', fields = {
            { label = 'Name', value = record.name },
            { label = 'Identifier', value = record.identifier },
            { label = 'Fingerprints', value = record.printed and 'On file' or 'Not taken' }
        } }
    }
    if #arrests > 0 then sections[#sections + 1] = { label = 'Criminal record - arrests', fields = arrests } end
    if #fines > 0 then sections[#sections + 1] = { label = 'Civil record - fines', notes = fines } end
    if #notes > 0 then sections[#sections + 1] = { label = 'Agency notes', notes = notes } end

    local actions = {}
    if canWrite() then
        actions[#actions + 1] = { id = 'photo', label = 'Add photograph' }
    end

    -- The file is classified by what is actually IN it: a person whose
    -- record exists only because somebody photographed or fingerprinted
    -- them is a civilian, not a criminal.
    local arrestTotal = #(record.arrests or {})
    local criminal = arrestTotal > 0

    local agencyLabel, logo = letterhead()
    return {
        id = record.identifier,
        -- Selecting the row pulls the FULL profile (vehicles, licences,
        -- court history) on demand; this marks it as profile-capable.
        profileId = record.identifier,
        title = record.name,
        meta = record.identifier,
        pill = criminal and ('%d arrest(s)'):format(arrestTotal) or 'Civilian',
        tone = criminal and 'danger' or nil,
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = criminal and 'CRIMINAL RECORD' or 'CIVILIAN RECORD',
            number = record.identifier,
            status = 'active',
            subject = record.name,
            subjectId = record.printed and 'prints on file' or 'no prints taken',
            body = criminal
                and ('%d arrest(s) and %d fine(s) on file with this agency. Subject has a documented history; review the entries below.')
                    :format(arrestTotal, #(record.fines or {}))
                or ('No custodial history. The subject is on file%s.'):format(
                    #(record.fines or {}) > 0 and (' with %d civil fine(s)'):format(#(record.fines or {}))
                        or ' for administrative reasons only'),
            charges = {},
            issuedBy = 'Records Division',
            issuedAt = 'LIVE FILE'
        },
        photos = record.photo and { { url = record.photo, caption = record.name } } or nil,
        sections = sections,
        actions = actions
    }
end

local function evidenceRow(item)
    local chain = {}
    for _, entry in ipairs(item.chain or {}) do
        chain[#chain + 1] = { meta = stamp(entry.at), text = ('%s - %s'):format(entry.actor, entry.action) }
    end

    local kindLabel = Const.EvidenceKinds[item.kind] and Const.EvidenceKinds[item.kind].label or item.kind
    local agencyLabel, logo = letterhead()

    local sections = {}
    if item.incidentId then
        sections[#sections + 1] = { label = 'Filed against', fields = {
            { label = 'Case', value = item.incidentId, link = { tab = 'incidents', id = item.incidentId } }
        } }
    end
    if item.description then
        sections[#sections + 1] = { label = 'Notes', notes = { { text = item.description } } }
    end
    if #chain > 0 then sections[#sections + 1] = { label = 'Chain of custody', notes = chain } end

    return {
        id = item.id,
        title = item.label,
        meta = ('%s | %s'):format(item.number, kindLabel),
        pill = item.analysed and 'Analysed' or (item.custody == 'field' and 'In the field' or 'Unprocessed'),
        tone = item.analysed and 'success' or (item.custody == 'field' and 'accent' or nil),
        -- Rendered as an evidence report, not a list of fields.
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'EVIDENCE REPORT',
            number = item.number,
            status = item.analysed and 'processed' or 'active',
            subject = item.label or kindLabel,
            subjectId = kindLabel,
            body = ('%s%s%s'):format(
                item.result or 'Awaiting laboratory analysis.',
                item.fieldTest and (' Field test: ' .. item.fieldTest .. '.') or '',
                item.incidentId and (' Filed against case ' .. item.incidentId .. '.') or ''),
            charges = {},
            issuedBy = item.collectedBy or 'Unknown',
            issuedAt = stamp(item.collectedAt)
        },
        sections = sections,
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
                { label = 'Source', value = lead.origin },
                { label = 'Entered by', value = lead.enteredBy },
                { label = 'Subject', value = lead.subject },
                { label = 'Plate', value = lead.plate },
                { label = 'Keeper', value = lead.keeper },
                { label = 'Named', value = lead.name }
            } },
            { label = 'Details', notes = { { text = lead.summary or '' } } }
        },
        actions = lead.status == 'open' and { { id = 'follow', label = 'Follow lead' } } or {}
    }
end

-- A dispatch ticket: the 911/tip side of an automatic callout, so the
-- Reports tab reads as the intake channel the calls came in through.
local function ticketRow(callout)
    local stage = callout.stages and callout.stages[callout.stage]
    local agencyLabel, logo = letterhead()
    return {
        id = 'tick:' .. tostring(callout.id),
        title = callout.label or 'Dispatch ticket',
        meta = ('%s | Priority %d'):format(callout.number or 'CALL', callout.priority or 2),
        pill = #(callout.assigned or {}) > 0 and 'Units responding' or 'Awaiting response',
        tone = #(callout.assigned or {}) > 0 and 'accent' or 'danger',
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'DISPATCH TICKET',
            number = callout.number,
            status = 'active',
            subject = callout.label or 'Dispatch ticket',
            subjectId = ('Priority %d'):format(callout.priority or 2),
            body = callout.description or callout.brief
                or 'Received via the anonymous tip line / 911. Details develop at the scene.',
            charges = {},
            issuedBy = 'Dispatch',
            issuedAt = stamp(callout.createdAt)
        },
        sections = {
            { label = 'Response', fields = {
                { label = 'Units assigned', value = #(callout.assigned or {}) },
                { label = 'Current objective', value = stage and stage.label or nil }
            } }
        },
        actions = {}
    }
end

-- One booking as its own arrest report, on the Custody tab beside the
-- live inmates.
local function arrestRow(entry)
    return {
        id = ('arr:%s:%s'):format(entry.identifier or '?', tostring(entry.at or 0)),
        title = ('Arrest report - %s'):format(entry.name or 'Unknown'),
        meta = ('%s | %s'):format(stamp(entry.at), entry.officer or 'unknown officer'),
        pill = entry.caseNumber or 'Booked',
        sections = {
            { label = 'Arrest report', fields = {
                { label = 'Subject', value = entry.name },
                { label = 'Identifier', value = entry.identifier },
                { label = 'Arresting officer', value = entry.officer },
                { label = 'Booked', value = stamp(entry.at) },
                { label = 'Court case', value = entry.caseNumber },
                { label = 'Charges', value = table.concat(entry.charges or {}, ', ') }
            } }
        },
        actions = {}
    }
end

local function reportRow(report)
    local agencyLabel, logo = letterhead()
    return {
        id = report.id,
        title = report.text,
        meta = ('From %s | %s'):format(report.caller, stamp(report.at)),
        pill = report.status == 'responding' and 'Responding' or 'New',
        tone = report.status == 'responding' and 'accent' or 'danger',
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = '911 CALL REPORT',
            number = '911',
            status = report.status == 'responding' and 'active' or 'active',
            subject = report.caller or 'Anonymous caller',
            subjectId = stamp(report.at),
            body = report.text or 'No statement taken.',
            charges = {},
            issuedBy = 'Emergency call taker',
            issuedAt = stamp(report.at)
        },
        sections = {
            { label = 'Call handling', fields = {
                { label = 'Units responding', value = report.status == 'responding' and 'Yes' or 'Not yet' },
                { label = 'Escalated to a callout', value = report.calloutId and 'Yes' or 'No' }
            } }
        },
        actions = {
            { id = 'waypoint', label = 'Set waypoint' },
            { id = 'respond', label = 'Respond' },
            { id = 'close', label = 'Close report', tone = 'danger' }
        }
    }
end

-- Station ids read like slugs; the roster shows the station's actual name.
local function stationLabel(stationId)
    local agency = State.Mine()
    if not agency or not stationId then return nil end
    for _, station in ipairs(agency.stations or {}) do
        if station.id == stationId then return station.label end
    end
    return stationId
end

local function unitRow(unit)
    local status = Const.UnitStatus[unit.status] or {}
    local me = GetPlayerServerId(PlayerId())
    local isSelf = tonumber(unit.source) == me

    local onAir = nil
    if unit.since then
        local minutes = math.max(0, math.floor((GetCloudTimeAsInt and GetCloudTimeAsInt() or 0) > 0
            and ((GetCloudTimeAsInt() - unit.since) / 60) or 0))
        if minutes > 0 then onAir = ('%d minute(s)'):format(minutes) end
    end

    local actions = {}
    if isSelf or State.Can('roster.manage') then
        actions[#actions + 1] = { id = 'status', label = isSelf and 'Set my status' or 'Set their status' }
    end
    if State.Can('roster.manage') then
        actions[#actions + 1] = { id = 'certs', label = 'Manage certifications' }
    end

    -- The identity block ships structured: the terminal renders it as a
    -- personnel header (portrait, name, the callsign large, a status chip)
    -- instead of eight anonymous cells.
    local unitCard = {
        name = unit.name,
        rank = unit.rank,
        callsign = unit.callsign,
        status = (status.label or tostring(unit.status or 'available')):upper(),
        statusTone = status.tone,
        division = unit.division,
        divisionRank = unit.divisionRank,
        station = stationLabel(unit.station),
        onAir = onAir,
        photo = unit.photo
    }

    local sections = {}

    -- What the unit currently has out of the agency's stores: their motor
    -- pool vehicle (on their callsign plate), armory draws, uniform. Capped
    -- to a handful of lines so the card never becomes a scroll.
    -- Equipment out of the stores, shipped structured so the terminal can
    -- render it as a manifest - item pictures, a plate chip, drawn times -
    -- instead of rows of text.
    local kit = nil
    local checkout = unit.checkout
    if checkout and (checkout.vehicle or checkout.uniform or #(checkout.items or {}) > 0) then
        kit = { items = {} }
        if checkout.vehicle then
            kit.vehicle = {
                label = checkout.vehicle.label or checkout.vehicle.model,
                model = checkout.vehicle.model,
                plate = checkout.vehicle.plate,
                at = stamp(checkout.vehicle.at)
            }
        end
        if checkout.uniform then
            -- Older entries were a bare label; newer ones carry when it was
            -- put on.
            local uniform = type(checkout.uniform) == 'table' and checkout.uniform
                or { label = checkout.uniform }
            kit.uniform = { label = uniform.label, at = uniform.at and stamp(uniform.at) or nil }
        end
        local lines = checkout.items or {}
        local shown = math.min(#lines, 8)
        for index = #lines - shown + 1, #lines do
            local line = lines[index]
            kit.items[#kit.items + 1] = {
                item = line.item,
                label = line.label or line.item,
                count = line.count or 1,
                at = line.at and stamp(line.at) or nil
            }
        end
        if #lines > shown then kit.more = #lines - shown end

        if isSelf or State.Can('roster.manage') then
            actions[#actions + 1] = { id = 'kit', label = 'Clear checkout log' }
        end
    end

    -- Certifications ship structured too: the terminal renders them as
    -- signed award badges rather than a list.
    local certBadges = nil
    if #(unit.certs or {}) > 0 then
        certBadges = {}
        for _, cert in ipairs(unit.certs) do
            certBadges[#certBadges + 1] = {
                label = cert.label,
                by = cert.by,
                at = cert.at and stamp(cert.at) or nil
            }
        end
    end

    -- Service history: the work behind the badge, every entry a doorway.
    local service = unit.service
    if service and ((service.arrestCount or 0) + (service.caseCount or 0)) > 0 then
        local fields = {
            { label = 'Arrests made', value = service.arrestCount },
            { label = 'Cases worked', value = service.caseCount }
        }
        for _, arrestee in ipairs(service.arrestees or {}) do
            fields[#fields + 1] = {
                label = ('Arrested %s'):format(stamp(arrestee.at)),
                value = arrestee.name,
                link = { tab = 'custody', id = ('arr:%s:%s'):format(arrestee.identifier or '?', tostring(arrestee.at or 0)) }
            }
        end
        for _, case in ipairs(service.cases or {}) do
            fields[#fields + 1] = {
                label = case.number,
                value = case.title,
                link = { tab = 'incidents', id = case.id }
            }
        end
        sections[#sections + 1] = { label = 'Service history', fields = fields }
    end

    -- Chain of command: supervisor, partner, and whoever works under them.
    local org = unit.org
    if org then
        local fields = {}
        if org.supervisor then fields[#fields + 1] = { label = 'Reports to', value = org.supervisor } end
        if org.partner then fields[#fields + 1] = { label = 'Partner', value = org.partner } end
        if #(org.reports or {}) > 0 then
            fields[#fields + 1] = { label = 'Direct reports', value = table.concat(org.reports, ', ') }
        end
        if #fields > 0 then sections[#sections + 1] = { label = 'Chain of command', fields = fields } end
    end

    local agencyLabel, logo = letterhead()
    return {
        id = tostring(unit.source or unit.identifier),
        -- Raw award list rides along so the manage menu knows what is held.
        certs = unit.certs,
        certBadges = certBadges,
        kit = kit,
        unitCard = unitCard,
        title = ('%s %s'):format(unit.callsign or '?', unit.name or ''),
        meta = ('%s | %s'):format(unit.rank or 'Unranked', stationLabel(unit.station) or 'No station'),
        pill = (status.label or tostring(unit.status or 'available')):upper(),
        tone = status.tone,
        -- A roster entry reads like a personnel file, not a menu row.
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'PERSONNEL FILE',
            number = unit.callsign,
            status = 'active',
            subject = unit.name,
            subjectId = unit.rank,
            body = ('%s holds the rank of %s%s and is posted to %s. Current status: %s.'):format(
                unit.name or 'The member',
                unit.rank or 'Unranked',
                unit.division and (' in the %s division'):format(unit.division) or '',
                stationLabel(unit.station) or 'no station',
                (status.label or tostring(unit.status or 'available')):upper()),
            charges = {},
            issuedBy = 'Personnel Division',
            issuedAt = 'ACTIVE ROSTER'
        },
        sections = sections,
        actions = actions
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
    overview = overviewRow,
    incidents = incidentRow,
    cases = caseRow,
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
    { key = 'cases', callback = 'cad:cases' },
    -- Every warrant, not only active ones: the terminal filters by status.
    { key = 'warrants', callback = 'cad:warrants' },
    { key = 'bolos', callback = 'cad:bolos' },
    { key = 'evidence', callback = 'cad:evidence' },
    { key = 'leads', callback = 'leads' },
    { key = 'reports', callback = 'reports' },
    { key = 'custody', callback = 'jail:roster' }
}

-- Each Open gets a generation stamp so a slow callback from a previous open
-- (or an already-closed terminal) can never repaint the current one.
local generation = 0
local lastPayload = nil

-- The raw feeds behind the dispatch board, kept at module scope so the
-- 10-second live refresh and the action handlers can reach them.
local rawCallouts, rawReports, rawIncidents = nil, nil, nil

-- Live map state. Unit positions ride the same broadcast the minimap blips
-- use; while the terminal is open every update is forwarded to it, which is
-- what makes the map live rather than a snapshot.
local mapUnits = {}

-- The position broadcast deliberately excludes yourself (no self-blip on the
-- minimap), so the big map adds you back from your own live position.
local function withSelf(list)
    local units = {}
    for _, unit in ipairs(type(list) == 'table' and list or {}) do units[#units + 1] = unit end

    local membership = State.Membership()
    if membership then
        local coords = GetEntityCoords(PlayerPedId())
        local unit = membership.unit
        units[#units + 1] = {
            source = GetPlayerServerId(PlayerId()),
            callsign = unit and unit.callsign or 'YOU',
            name = unit and unit.name or nil,
            status = membership.onDuty
                and ((lastPayload and lastPayload.myStatus) or (unit and unit.status) or 'available')
                or 'offduty',
            division = membership.division,
            rank = membership.rank,
            coords = { x = coords.x, y = coords.y, z = coords.z }
        }
    end
    return units
end

RegisterNetEvent(Federal.Net('units'), function(list)
    if type(list) ~= 'table' then return end
    mapUnits = list
    if open then
        SendNUIMessage({ action = 'mdt:map', units = withSelf(list) })
    end
end)

-- Assigned entries are server ids; the unit broadcast turns them into
-- callsigns wherever it can.
local function unitLabel(src)
    for _, unit in ipairs(mapUnits or {}) do
        if tonumber(unit.source) == tonumber(src) then
            return ('%s %s'):format(unit.callsign or '?', unit.name or '')
        end
    end
    return 'Unit #' .. tostring(src)
end

-- Active callouts, 911 reports and located open incidents collapse into one
-- "calls" layer: everything with a place in the world an officer can drive
-- to shows on the dispatch board and the live map.
local function mapCalls(callouts, reports, incidentList)
    local calls = {}
    -- Incidents opened FROM a live callout must not double-list: the
    -- callout row already represents that call on the board.
    local liveCallouts = {}
    for _, callout in ipairs(callouts or {}) do
        liveCallouts[callout.id] = true
    end
    for _, callout in ipairs(callouts or {}) do
        if type(callout.location) == 'table' then
            local stage = callout.stages and callout.stages[callout.stage]
            local parties = {}
            if callout.suspect then
                parties[#parties + 1] = ('Suspect: %s'):format(callout.suspect.name or 'Unidentified subject')
            end
            for _, entry in ipairs(callout.assigned or {}) do
                local src = type(entry) == 'table' and (entry.source or entry.id) or entry
                parties[#parties + 1] = ('Assigned: %s'):format(unitLabel(src))
            end
            calls[#calls + 1] = {
                id = callout.id,
                kind = 'callout',
                label = callout.label or 'Callout',
                number = callout.number,
                priority = callout.priority or 2,
                coords = callout.location,
                assigned = #(callout.assigned or {}),
                desc = callout.description or callout.brief
                    or (stage and ('Current objective: %s'):format(stage.label) or nil),
                stage = stage and stage.label or nil,
                parties = parties
            }
        end
    end
    for _, report in ipairs(reports or {}) do
        if type(report.location) == 'table' then
            calls[#calls + 1] = {
                id = report.id,
                kind = 'report',
                label = report.text and ('%s'):format(report.text:sub(1, 48)) or '911 report',
                number = '911',
                priority = 3,
                coords = report.location,
                assigned = 0,
                desc = report.text,
                parties = { ('Caller: %s'):format(report.caller or 'Anonymous') }
            }
        end
    end
    -- Open incidents with a scene location: the marker an investigator set
    -- so the case points somewhere on the map.
    for _, incident in ipairs(incidentList or {}) do
        if incident.status ~= 'closed' and realLocation(incident.location)
            and not (incident.calloutId and liveCallouts[incident.calloutId]) then
            local parties = {}
            for _, officer in ipairs(incident.officers or {}) do
                parties[#parties + 1] = ('Officer: %s'):format(officer.name or '')
            end
            for _, suspect in ipairs(incident.suspects or {}) do
                parties[#parties + 1] = ('Suspect: %s'):format(suspect.name or '')
            end
            calls[#calls + 1] = {
                id = incident.id,
                kind = 'incident',
                label = incident.title or 'Incident',
                number = incident.number,
                priority = incident.priority or 2,
                coords = incident.location,
                assigned = #(incident.officers or {}),
                desc = ('%s | filed by %s | %s'):format(
                    incident.type or 'Incident', incident.createdBy or 'unknown', stamp(incident.createdAt)),
                parties = parties
            }
        end
    end
    return calls
end

-- The call this officer is assigned to right now, for the My Call screen.
local function findMyCall(callouts)
    local me = GetPlayerServerId(PlayerId())
    for _, callout in ipairs(callouts or {}) do
        for _, assigned in ipairs(callout.assigned or {}) do
            local src = type(assigned) == 'table' and (assigned.source or assigned.id) or assigned
            if tonumber(src) == me then
                local names = {}
                for _, entry in ipairs(callout.assigned) do
                    local entrySrc = type(entry) == 'table' and (entry.source or entry.id) or entry
                    names[#names + 1] = unitLabel(entrySrc)
                end
                local stage = callout.stages and callout.stages[callout.stage]
                return {
                    id = callout.id,
                    number = callout.number,
                    label = callout.label,
                    priority = callout.priority or 2,
                    status = callout.status or 'active',
                    location = callout.location,
                    description = callout.description or callout.brief
                        or (stage and ('Current objective: %s'):format(stage.label) or nil),
                    units = names
                }
            end
        end
    end
    return nil
end

function MDT.Open()
    local borrow = activeBorrow()
    if not State.Can('cad.view') and not borrow then
        return Bridge.Notify('You are not authorized to use the terminal.', 'error')
    end
    if not borrow and not State.OnDuty() and not State.Context().admin then
        return Bridge.Notify('Clock on at a sign-in desk first.', 'error')
    end

    local agency = State.Mine()
    local membership = State.Membership()
    local payload = {
        agency = agency and agency.short or 'FED',
        title = agency and agency.label or 'Mobile data terminal',
        subtitle = membership and ('%s | %s'):format(membership.rank, State.OnDuty() and 'On duty' or 'Off duty') or nil,
        status = 'Loading...',
        -- Terminal branding: the agency's own identity, so two agencies'
        -- CADs read as two different systems. The logo is a config-panel
        -- https link; the accent is the agency colour.
        brand = {
            label = agency and agency.label or 'Federal Agency',
            short = agency and agency.short or 'FED',
            color = agency and agency.color or nil,
            logo = agency and agency.cad and agency.cad.logo or nil
        },
        myStatus = membership and membership.unit and membership.unit.status or 'available',
        officer = membership and {
            name = membership.name,
            rank = membership.rank,
            callsign = membership.unit and membership.unit.callsign or nil,
            division = membership.division,
            station = membership.unit and stationLabel(membership.unit.station) or nil
        } or nil
    }

    -- A stolen terminal wears the owner's identity and the owning agency's
    -- letterhead, whatever the person holding it is.
    if borrow then
        local brand = borrow.brand or {}
        payload.agency = brand.short or 'FED'
        payload.title = brand.label or 'Mobile data terminal'
        payload.subtitle = ('Signed in as %s | TERMINAL SESSION'):format(borrow.owner or 'unknown')
        payload.brand = {
            label = brand.label or 'Federal Agency',
            short = brand.short or 'FED',
            color = brand.color,
            logo = brand.logo
        }
        payload.officer = { name = borrow.owner, rank = 'Terminal session' }
    end

    -- Records need a search term, so that tab always starts blank. The map
    -- opens instantly with the latest unit broadcast; its calls layer fills
    -- as the callout and report feeds land.
    payload.records = {}
    payload.itemImages = (Config.Federal or {}).itemImages
    payload.map = {
        units = withSelf(mapUnits),
        calls = {},
        self = GetPlayerServerId(PlayerId())
    }

    -- A refresh keeps the stale caseload on screen while fresh feeds stream
    -- in, so the tab the officer is standing on never vanishes mid-action.
    if open and lastPayload then
        for _, source in ipairs(SOURCES) do payload[source.key] = lastPayload[source.key] end
        payload.units = lastPayload.units
        payload.map.calls = lastPayload.map and lastPayload.map.calls or {}
        -- The last known status, not the cached context: a refresh right
        -- after a status click must not flash back to the stale value while
        -- the roster feed is still in flight.
        payload.myStatus = lastPayload.myStatus or payload.myStatus
    end
    lastPayload = payload

    generation = generation + 1
    local mine = generation

    -- The terminal opens IMMEDIATELY and each tab streams in as its callback
    -- lands, instead of the whole screen waiting on the slowest of eight
    -- round trips. The payload accumulates, so every push repaints the panel
    -- with everything that has arrived so far.
    open = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'mdt:open', mdt = payload })

    local pending = #SOURCES + 3
    -- Kept apart from the payload so a repaint never re-merges merged rows.
    local baseReports, baseCustody, arrestRows = {}, {}, {}
    local function push()
        pending = pending - 1
        if not open or generation ~= mine then return end
        if rawCallouts or rawReports or rawIncidents then
            payload.map.calls = mapCalls(rawCallouts, rawReports, rawIncidents)
        end
        payload.map.units = withSelf(mapUnits)
        payload.myCall = findMyCall(rawCallouts)

        -- The Reports tab is the intake channel: player 911 reports plus a
        -- dispatch ticket for every live callout, since that is where those
        -- calls notionally came from.
        local reportRows = {}
        for _, row in ipairs(baseReports) do reportRows[#reportRows + 1] = row end
        for _, callout in ipairs(rawCallouts or {}) do reportRows[#reportRows + 1] = ticketRow(callout) end
        payload.reports = reportRows

        -- Custody shows the live inmates AND the arrest reports behind them.
        local custodyRows = {}
        for _, row in ipairs(baseCustody) do custodyRows[#custodyRows + 1] = row end
        for _, row in ipairs(arrestRows) do custodyRows[#custodyRows + 1] = row end
        payload.custody = custodyRows

        payload.status = pending > 0 and ('Loading %d feed(s)...'):format(pending) or 'Ready'
        SendNUIMessage({ action = 'mdt:open', mdt = payload })
    end

    for _, source in ipairs(SOURCES) do
        Bridge.TriggerCallback(Federal.Net(source.callback), function(list)
            if source.key == 'reports' then rawReports = list end
            if source.key == 'incidents' then rawIncidents = list end
            local rows = build(source.key, list)
            if source.key == 'reports' then
                baseReports = rows
            elseif source.key == 'custody' then
                baseCustody = rows
            else
                payload[source.key] = rows
            end
            push()
        end, table.unpack(source.args or {}))
    end

    Bridge.TriggerCallback(Federal.Net('cad:arrests'), function(list)
        for _, entry in ipairs(list or {}) do arrestRows[#arrestRows + 1] = arrestRow(entry) end
        push()
    end)

    Bridge.TriggerCallback(Federal.Net('cad:dashboard'), function(dashboard)
        payload.units = build('units', dashboard and dashboard.units or {})
        payload.overview = build('overview', { dashboard or {} })
        -- The roster is the authority on MY status too: the cached context
        -- lags a status change, and a strip that snaps back reads as broken.
        local me = GetPlayerServerId(PlayerId())
        for _, unit in ipairs(dashboard and dashboard.units or {}) do
            if tonumber(unit.source) == me and unit.status then
                payload.myStatus = unit.status
            end
        end
        push()
    end)

    -- The calls layer of the live map.
    Bridge.TriggerCallback(Federal.Net('callouts'), function(list)
        rawCallouts = list
        push()
    end)
end

function MDT.Refresh()
    if not open then return end
    -- Rebuilt from scratch: the terminal reads live records, and holding a
    -- stale copy is how two officers end up seeing different cases.
    MDT.Open()
end

-- The dispatch board stays live: while the terminal is open the call feeds
-- re-poll every ten seconds, so a callout that lands AFTER the terminal
-- opened still shows up as an active call without reopening anything.
CreateThread(function()
    while true do
        Wait(10000)
        if open and lastPayload then
            local mine = generation
            Bridge.TriggerCallback(Federal.Net('callouts'), function(list)
                if not open or generation ~= mine then return end
                rawCallouts = list
                Bridge.TriggerCallback(Federal.Net('reports'), function(reportList)
                    if not open or generation ~= mine then return end
                    rawReports = reportList
                    local reportRows = build('reports', reportList)
                    for _, callout in ipairs(rawCallouts or {}) do
                        reportRows[#reportRows + 1] = ticketRow(callout)
                    end
                    lastPayload.reports = reportRows
                    lastPayload.map.calls = mapCalls(rawCallouts, rawReports, rawIncidents)
                    lastPayload.map.units = withSelf(mapUnits)
                    lastPayload.myCall = findMyCall(rawCallouts)
                    SendNUIMessage({ action = 'mdt:open', mdt = lastPayload })
                end)
            end)
        end
    end
end)

function MDT.Close()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'mdt:close' })
end

-- Access away from a terminal: the tablet item (server-side use) and the
-- terminal built into any vehicle drawn from the agency motor pool. The
-- server may hand a borrowed session along - a stolen tablet or vehicle is
-- still signed in as its owner.
RegisterNetEvent(Federal.Net('openMdt'), function(session)
    if type(session) == 'table' then
        borrowed = {
            owner = session.owner,
            brand = session.brand,
            expires = GetGameTimer() + 600000
        }
    end
    MDT.Open()
end)

RegisterCommand('fedmdt', function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if State.Can('cad.view') and (State.OnDuty() or State.Context().admin) then
        if vehicle == 0 then
            return Bridge.Notify('Use a CAD terminal, an agency vehicle, or your tablet.', 'error')
        end
        if not Entity(vehicle).state or not Entity(vehicle).state.fedVehicle then
            return Bridge.Notify('This vehicle has no terminal - draw one from the motor pool.', 'error')
        end
        return MDT.Open()
    end

    -- No usable credentials of your own (a civilian, or an agent off the
    -- clock): a flagged vehicle's terminal is still signed in as whoever
    -- drew it. Ask the server for that session.
    if vehicle ~= 0 and Entity(vehicle).state and Entity(vehicle).state.fedTerminal then
        TriggerServerEvent(Federal.Net('terminal:borrow'), NetworkGetNetworkIdFromEntity(vehicle))
    end
end, false)

RegisterKeyMapping('fedmdt', 'Federal: open the vehicle MDT', 'keyboard', 'F7')

-- qb-radialmenu integration: members whose rank can read the CAD get a
-- "Federal CAD" slice on the radial. Added and removed as membership and
-- permissions change, so a civilian's radial never advertises it.
local radialId = nil

local function syncRadial()
    if GetResourceState('qb-radialmenu') ~= 'started' then return end

    local eligible = State.Membership() ~= nil and State.Can('cad.view')
    if eligible and not radialId then
        local ok, result = pcall(function()
            return exports['qb-radialmenu']:AddOption({
                id = 'fedcad',
                title = 'Federal CAD',
                icon = 'laptop',
                type = 'client',
                event = Federal.Net('openMdt'),
                shouldClose = true
            }, 'fedcad')
        end)
        radialId = ok and (result or 'fedcad') or nil
    elseif not eligible and radialId then
        pcall(function() exports['qb-radialmenu']:RemoveOption(radialId) end)
        radialId = nil
    end
end

State.OnChange(syncRadial)
CreateThread(function()
    Wait(3000)
    syncRadial()
end)

-- Actions ---------------------------------------------------------------------------

local function ask(name, callback, ...)
    Bridge.TriggerCallback(Federal.Net(name), function(result, err)
        if not result and err then Bridge.Notify(err, 'error') end
        if callback then callback(result) end
    end, ...)
end

local HANDLERS = {}

-- Input dialogs render in the same NUI page, so they open ON TOP of the
-- terminal instead of replacing it: cancel and you are exactly where you
-- were. The dialog releases NUI focus when it closes, so the terminal takes
-- the pointer back before anything else happens.
local function withInput(title, fields, handler)
    DAG.Menu.Input(title, fields, function(values)
        if MDT.IsOpen() then SetNuiFocus(true, true) end
        if not values then return end
        handler(values)
    end)
end

-- Flows that open a pick-menu still have to put the terminal away first (the
-- side menu is its own surface); with the terminal remembering its workspace
-- the reopen lands back where the officer was.
local function withMenu(menuId, title, subtitle, options)
    MDT.Close()
    Federal.CAD.Show(Federal.Menus.Id(menuId), title, subtitle, options)
end

-- Getting a photograph into the CAD. With screenshot-basic running the
-- officer can shoot one with the in-game camera: it uploads to the endpoint
-- in Config.Federal.mediaUpload when one is configured, and otherwise the
-- image itself is embedded into the record (compressed, size-capped), so
-- the camera works out of the box. A pasted https link always works too.
local function askCaption(url, callback)
    DAG.Menu.Input('Caption', {
        { name = 'caption', label = 'Caption', type = 'textarea', rows = 3 }
    }, function(values)
        callback(url, values and values.caption or nil)
    end)
end

-- Shrinking a camera shot: the terminal's own page owns a canvas, so the
-- full-resolution capture downscales to a ~1280px report photo - a tenth
-- the size - before it ever crosses the network.
local shrinkPending = {}
local shrinkSequence = 0

local function shrinkPhoto(data, cb)
    shrinkSequence = shrinkSequence + 1
    local id = tostring(shrinkSequence)
    shrinkPending[id] = cb
    SendNUIMessage({ action = 'photo:shrink', id = id, data = data, maxWidth = 1280, quality = 0.72 })
end

RegisterNUICallback('photoShrunk', function(payload, reply)
    reply({})
    if type(payload) ~= 'table' then return end
    local cb = shrinkPending[tostring(payload.id)]
    shrinkPending[tostring(payload.id)] = nil
    if cb then cb(type(payload.data) == 'string' and payload.data or nil) end
end)

-- Even a shrunk photo is too big for one net event, so it ships to the
-- server in ~60KB chunks and the record is filed with the upload token.
local PHOTO_CHUNK = 60000
local uploadSequence = 0

local function shipPhoto(data, cb)
    CreateThread(function()
        uploadSequence = uploadSequence + 1
        local id = ('p%d'):format(uploadSequence)
        local total = math.ceil(#data / PHOTO_CHUNK)
        for index = 1, total do
            TriggerServerEvent(Federal.Net('photo:chunk'), id, index,
                data:sub((index - 1) * PHOTO_CHUNK + 1, index * PHOTO_CHUNK), total)
            if index % 4 == 0 then Wait(0) end
        end
        cb('upload:' .. id)
    end)
end

-- One shutter press: uploads to the configured endpoint when there is one,
-- otherwise shrinks and ships the image into the record itself.
local function capturePhoto(onDone)
    local upload = (Config.Federal or {}).mediaUpload or {}
    if upload.url and upload.url ~= '' then
        exports['screenshot-basic']:requestScreenshotUpload(upload.url, upload.field or 'files[]',
            function(data)
                local ok, response = pcall(json.decode, data or '')
                local url = ok and type(response) == 'table' and (
                    response.url
                    or (response.files and response.files[1] and response.files[1].url)
                    or (response.attachments and response.attachments[1] and response.attachments[1].url)
                ) or nil
                onDone(url, url == nil and 'The upload endpoint did not return a link.' or nil)
            end)
    else
        exports['screenshot-basic']:requestScreenshot({ encoding = 'jpg', quality = 0.9 },
            function(data)
                if type(data) ~= 'string' or not data:find('^data:image/') then
                    return onDone(nil, 'The camera produced no image.')
                end
                shrinkPhoto(data, function(smaller)
                    shipPhoto(smaller or data, function(token) onDone(token) end)
                end)
            end)
    end
end

-- Photo mode: a free camera the officer actually operates. Mouse orbits
-- around them, the wheel zooms, and the shutter fires when THEY are ready -
-- not the instant they clicked the menu.
local function drawPhotoHelp()
    SetTextFont(4)
    SetTextScale(0.32, 0.32)
    SetTextColour(255, 255, 255, 210)
    SetTextCentre(true)
    SetTextDropShadow()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName('Mouse orbit  |  Scroll zoom  |  ENTER / CLICK capture  |  BACKSPACE cancel')
    EndTextCommandDisplayText(0.5, 0.93)
end

local function photoMode(callback)
    MDT.Close()
    CreateThread(function()
        local angle = math.rad(GetEntityHeading(PlayerPedId()) + 180.0)
        local pitch = 0.15
        local radius = 3.5

        local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        RenderScriptCams(true, true, 400, true, true)

        local snapping = false
        while true do
            Wait(0)
            DisableAllControlActions(0)

            -- Orbit with the mouse, zoom with the wheel.
            angle = angle - GetDisabledControlNormal(0, 1) * 3.0
            pitch = math.max(-1.3, math.min(1.3, pitch + GetDisabledControlNormal(0, 2) * 2.0))
            if IsDisabledControlJustPressed(0, 241) or IsDisabledControlJustPressed(0, 96) then
                radius = math.max(1.2, radius - 0.5)
            end
            if IsDisabledControlJustPressed(0, 242) or IsDisabledControlJustPressed(0, 97) then
                radius = math.min(12.0, radius + 0.5)
            end

            local focus = GetEntityCoords(PlayerPedId())
            local flat = radius * math.cos(pitch)
            SetCamCoord(cam,
                focus.x + math.cos(angle) * flat,
                focus.y + math.sin(angle) * flat,
                focus.z + 0.4 + math.sin(pitch) * radius)
            PointCamAtCoord(cam, focus.x, focus.y, focus.z + 0.4)

            if IsDisabledControlJustPressed(0, 176) or IsDisabledControlJustPressed(0, 24)
                or IsDisabledControlJustPressed(0, 191) then
                snapping = true
                break
            end
            if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) then
                break
            end

            drawPhotoHelp()
        end

        if not snapping then
            RenderScriptCams(false, true, 400, true, true)
            DestroyCam(cam, false)
            Bridge.Notify('Photo cancelled.', 'inform')
            return MDT.Open()
        end

        -- Two clean frames so the help text is not in the shot.
        Wait(0)
        Wait(0)
        capturePhoto(function(url, err)
            RenderScriptCams(false, true, 400, true, true)
            DestroyCam(cam, false)
            if not url then
                Bridge.Notify(err or 'No photo.', 'error')
                return MDT.Open()
            end
            askCaption(url, callback)
        end)
    end)
end

local function withPhoto(title, callback)
    local hasCamera = GetResourceState('screenshot-basic') == 'started'

    if not hasCamera then
        return withInput(title, {
            { name = 'url', label = 'Image link (https)', required = true },
            { name = 'caption', label = 'Caption', type = 'textarea', rows = 3 }
        }, function(values)
            callback(values.url, values.caption)
        end)
    end

    withMenu('mdt:photo', title, nil, {
        {
            title = 'Take a photo now',
            description = 'Free camera: orbit, zoom, then press ENTER to capture',
            icon = 'info',
            onSelect = function() photoMode(callback) end
        },
        {
            title = 'Paste an image link',
            icon = 'info',
            onSelect = function()
                DAG.Menu.Input(title, {
                    { name = 'url', label = 'Image link (https)', required = true },
                    { name = 'caption', label = 'Caption', type = 'textarea', rows = 3 }
                }, function(values)
                    if not values then return MDT.Open() end
                    callback(values.url, values.caption)
                end)
            end
        }
    })
end

local function splitList(text)
    local values = {}
    for value in tostring(text or ''):gmatch('[^,]+') do
        local trimmed = value:gsub('^%s+', ''):gsub('%s+$', '')
        if trimmed ~= '' then values[#values + 1] = trimmed end
    end
    return values
end

HANDLERS.incidents = function(id, action)
    if action == 'file' then
        return withInput('File a new case', {
            { name = 'title', label = 'Case title', required = true },
            { name = 'type', label = 'Case type (e.g. Firearms, Fraud)' },
            {
                name = 'priority', label = 'Priority', type = 'select', default = '2',
                options = {
                    { value = '1', label = 'High' },
                    { value = '2', label = 'Medium' },
                    { value = '3', label = 'Low' }
                }
            },
            { name = 'narrative', label = 'Opening narrative', type = 'textarea', rows = 8 }
        }, function(values)
            ask('cad:file', function() MDT.Open() end, {
                title = values.title,
                type = values.type,
                priority = tonumber(values.priority) or 2,
                narrative = values.narrative
            })
        end)
    end
    if action == 'close' then return ask('cad:status', MDT.Refresh, id, 'closed') end
    if action == 'reopen' then return ask('cad:status', MDT.Refresh, id, 'open') end
    if action == 'expunge' then return ask('cad:expunge', MDT.Refresh, id) end
    if action == 'assign' then return ask('cad:assign', MDT.Refresh, id, GetPlayerServerId(PlayerId())) end

    if action == 'narrative' then
        return withInput('Narrative entry', {
            { name = 'text', label = 'What happened', type = 'textarea', rows = 8, required = true }
        }, function(values)
            ask('cad:narrative', function() MDT.Open() end, id, values.text or values[1])
        end)
    end

    if action == 'photo' then
        return withPhoto('Attach a photo', function(url, caption)
            ask('cad:photo', function() MDT.Open() end, id, url, caption)
        end)
    end

    if action == 'charge' then
        -- The charge catalog as a searchable pick, not a free-typing slot.
        local options = {}
        for _, charge in ipairs((Config.Federal or {}).charges or {}) do
            options[#options + 1] = { value = charge, label = charge }
        end
        return withInput('Add a charge', {
            {
                name = 'charge', label = 'Charge', type = 'select', required = true,
                options = options, allowCustom = true
            }
        }, function(values)
            ask('cad:charge', function() MDT.Open() end, id, values.charge or values[1])
        end)
    end

    -- Suspects and witnesses come off a record search: type a name, pick the
    -- person, done. Manual entry stays as the fallback for a John Doe.
    local function attachPerson(kind, callbackName)
        return withInput(('Search for a %s'):format(kind), {
            { name = 'term', label = 'Name or identifier', required = true }
        }, function(values)
            Bridge.TriggerCallback(Federal.Net('cad:lookup'), function(result)
                local options = {}
                for _, person in ipairs(result and result.people or {}) do
                    options[#options + 1] = {
                        title = person.name or person.identifier,
                        description = person.identifier,
                        icon = 'user',
                        badge = person.civilian and 'Civilian' or 'On file',
                        badgeTone = person.civilian and nil or 'accent',
                        onSelect = function()
                            ask(callbackName, function() MDT.Open() end, id, {
                                name = person.name, identifier = person.identifier
                            })
                        end
                    }
                end
                options[#options + 1] = {
                    title = 'Enter manually',
                    description = 'Unknown subject / John Doe',
                    icon = 'wrench',
                    onSelect = function()
                        DAG.Menu.Input(('Add a %s'):format(kind), {
                            { name = 'name', label = 'Name', required = true },
                            { name = 'identifier', label = 'Identifier (optional)' }
                        }, function(manual)
                            if not manual then return MDT.Open() end
                            ask(callbackName, function() MDT.Open() end, id, {
                                name = manual.name, identifier = manual.identifier
                            })
                        end)
                    end
                }
                withMenu('mdt:person', ('Attach %s'):format(kind),
                    ('%d match(es)'):format(#(result and result.people or {})), options)
            end, values.term or values[1])
        end)
    end

    if action == 'suspect' then return attachPerson('suspect', 'cad:suspect') end
    if action == 'witness' then return attachPerson('witness', 'cad:witness') end

    if action == 'link' then
        -- Search for the incident to link instead of typing its number from
        -- memory; picking one links it and offers the next straight away.
        return withInput('Link incidents', {
            { name = 'term', label = 'Search incidents (title or number)', required = true }
        }, function(values)
            Bridge.TriggerCallback(Federal.Net('cad:caseSearch'), function(results)
                local options = {}
                for _, match in ipairs(results or {}) do
                    if match.kind == 'incident' and match.refId ~= id then
                        local number = tostring(match.label):match('^%S+')
                        options[#options + 1] = {
                            title = match.label,
                            description = match.meta,
                            icon = 'info',
                            onSelect = function()
                                ask('cad:link', function()
                                    Bridge.Notify('Linked. Search again to chain more.', 'success')
                                    MDT.Open()
                                end, id, number)
                            end
                        }
                    end
                end
                if #options == 0 then
                    Bridge.Notify('No incidents match that search.', 'error')
                    return MDT.Open()
                end
                withMenu('mdt:link', 'Link an incident', ('%d match(es)'):format(#options), options)
            end, values.term or values[1])
        end)
    end

    if action == 'unlink' then
        return withInput('Unlink a case', {
            { name = 'number', label = 'Linked case number', required = true }
        }, function(values)
            ask('cad:unlink', function() MDT.Open() end, id, values.number or values[1])
        end)
    end

    if action == 'case' then
        -- Put this incident (and everything linked to it) on a case file:
        -- pick an existing board or name a new one on the spot.
        return Bridge.TriggerCallback(Federal.Net('cad:cases'), function(cases)
            local options = {}
            for _, board in ipairs(cases or {}) do
                if board.status ~= 'closed' then
                    options[#options + 1] = {
                        title = board.title,
                        description = ('%s | %d pin(s)'):format(board.number, #(board.pins or {})),
                        icon = 'info',
                        onSelect = function()
                            ask('cad:caseAttach', function(result)
                                if result then
                                    Bridge.Notify(('%d incident(s) added to %s.'):format(result.pinned, result.number), 'success')
                                end
                                MDT.Open()
                            end, board.id, id, true)
                        end
                    }
                end
            end
            options[#options + 1] = {
                title = 'New case file...',
                description = 'Create a board and file this chain onto it',
                icon = 'check',
                badgeTone = 'accent',
                onSelect = function()
                    DAG.Menu.Input('New case file', {
                        { name = 'title', label = 'Case title', required = true }
                    }, function(values)
                        if not values then return MDT.Open() end
                        ask('cad:caseAttach', function(result)
                            if result then
                                Bridge.Notify(('%s opened with %d incident(s).'):format(result.number, result.pinned), 'success')
                            end
                            MDT.Open()
                        end, values.title or values[1], id, true)
                    end)
                end
            }
            withMenu('mdt:case', 'Add to case file', nil, options)
        end)
    end

    if action == 'scene' then
        local coords = GetEntityCoords(PlayerPedId())
        return ask('cad:scene', function(record)
            if record then Bridge.Notify('Scene marked at your position - it now shows on the live map.', 'success') end
            MDT.Refresh()
        end, id, { x = coords.x, y = coords.y, z = coords.z })
    end

    if action == 'waypoint' then
        for _, incident in ipairs(rawIncidents or {}) do
            local scene = incident.id == id and realLocation(incident.location) or nil
            if scene then
                SetNewWaypoint(scene.x, scene.y)
                return Bridge.Notify('Waypoint set to the scene.', 'inform')
            end
        end
        return Bridge.Notify('That case has no scene marked - use "Mark scene on map" while standing there.', 'error')
    end
end

HANDLERS.cases = function(id, action, data)
    if action == 'create' then
        -- The creation modal reads like an actual case-opening form.
        return withInput('Open a case file', {
            { name = 'title', label = 'Case title (e.g. Operation Nightfall)', required = true },
            {
                name = 'classification', label = 'Classification', type = 'select', default = 'General',
                options = {
                    { value = 'General', label = 'General' },
                    { value = 'Organized crime', label = 'Organized crime' },
                    { value = 'Financial', label = 'Financial' },
                    { value = 'Narcotics', label = 'Narcotics' },
                    { value = 'Counter-terrorism', label = 'Counter-terrorism' },
                    { value = 'Protective intelligence', label = 'Protective intelligence' },
                    { value = 'Internal affairs', label = 'Internal affairs' }
                }
            },
            { name = 'summary', label = 'Opening summary', type = 'textarea', rows = 6 }
        }, function(values)
            ask('cad:caseCreate', function() MDT.Open() end, {
                title = values.title,
                classification = values.classification,
                summary = values.summary
            })
        end)
    end

    if action == 'agent' then
        -- Add a colleague to the case: pick from who is on the air, or type
        -- a name for someone off duty.
        local options = {}
        for _, unit in ipairs((lastPayload and lastPayload.map and lastPayload.map.units) or {}) do
            if unit.name then
                options[#options + 1] = {
                    title = ('%s %s'):format(unit.callsign or '?', unit.name),
                    icon = 'user',
                    onSelect = function()
                        ask('cad:caseAgent', function() MDT.Open() end, id, unit.name)
                    end
                }
            end
        end
        options[#options + 1] = {
            title = 'Type a name',
            description = 'An agent who is not on the air right now',
            icon = 'wrench',
            onSelect = function()
                DAG.Menu.Input('Add agent', { { name = 'name', label = 'Agent name', required = true } },
                    function(values)
                        if not values then return MDT.Open() end
                        ask('cad:caseAgent', function() MDT.Open() end, id, values.name or values[1])
                    end)
            end
        }
        return withMenu('mdt:agent', 'Add an agent', nil, options)
    end

    if action == 'close' then return ask('cad:caseStatus', MDT.Refresh, id, 'closed') end
    if action == 'reopen' then return ask('cad:caseStatus', MDT.Refresh, id, 'open') end
    if action == 'delete' then return ask('cad:caseDelete', MDT.Refresh, id) end

    if action == 'note' then
        return withInput('Board note', {
            { name = 'text', label = 'Note', type = 'textarea', rows = 6, required = true }
        }, function(values)
            ask('cad:caseNote', function() MDT.Open() end, id, values.text or values[1])
        end)
    end

    if action == 'photo' then
        return withPhoto('Pin a photo', function(url, caption)
            local link = tostring(url or '')
            if not link:find('^https://') and not link:find('^data:image/') and not link:find('^upload:') then
                Bridge.Notify('Photos are https image links or camera shots.', 'error')
                return MDT.Open()
            end
            ask('cad:casePin', function() MDT.Open() end, id, {
                kind = 'photo', refId = url, label = caption or 'Photo'
            })
        end)
    end

    if action == 'reorder' then
        local board = caseCache[id]
        if board and type(data) == 'table' and type(data.order) == 'table' then
            ask('cad:caseReorder', MDT.Refresh, id, data.order)
        end
        return
    end

    if action == 'pin' then
        -- Live search, then pick from the matches: the evidence-board flow.
        return withInput('Pin a record', {
            { name = 'term', label = 'Search cases, warrants, BOLOs, people, evidence', required = true }
        }, function(values)
            Bridge.TriggerCallback(Federal.Net('cad:caseSearch'), function(results)
                if not results or #results == 0 then
                    Bridge.Notify('Nothing matches that search.', 'error')
                    return MDT.Open()
                end

                local options = {}
                for _, match in ipairs(results) do
                    options[#options + 1] = {
                        title = match.label,
                        description = match.meta,
                        icon = 'info',
                        badge = match.kind,
                        onSelect = function()
                            ask('cad:casePin', function() MDT.Open() end, id, {
                                kind = match.kind, refId = match.refId, label = match.label
                            })
                        end
                    }
                end
                Federal.CAD.Show(Federal.Menus.Id('mdt:pin'), 'Pin to the board', ('%d match(es)'):format(#results), options)
            end, values.term or values[1])
        end)
    end

    if action == 'unpin' then
        local board = caseCache[id]
        if not board then return end
        local options = {}
        for index, pin in ipairs(board.pins or {}) do
            options[#options + 1] = {
                title = pin.label,
                description = pin.kind,
                icon = 'close',
                onSelect = function()
                    ask('cad:caseUnpin', function() MDT.Open() end, id, index)
                end
            }
        end
        MDT.Close()
        Federal.CAD.Show(Federal.Menus.Id('mdt:unpin'), 'Unpin from the board', board.title, options)
    end
end

HANDLERS.warrants = function(id, action)
    if action == 'issue' then
        -- A warrant application: find the subject on record first, then the
        -- form - warrant type, grounds, charges from the catalog.
        return withInput('Warrant application', {
            { name = 'term', label = 'Search for the subject', required = true }
        }, function(values)
            Bridge.TriggerCallback(Federal.Net('cad:lookup'), function(result)
                local options = {}
                for _, person in ipairs(result and result.people or {}) do
                    options[#options + 1] = {
                        title = person.name or person.identifier,
                        description = person.identifier,
                        icon = 'user',
                        badge = person.civilian and 'Civilian' or 'On file',
                        onSelect = function()
                            local chargeOptions = {}
                            for _, charge in ipairs((Config.Federal or {}).charges or {}) do
                                chargeOptions[#chargeOptions + 1] = { value = charge, label = charge }
                            end
                            DAG.Menu.Input(('Warrant: %s'):format(person.name or person.identifier), {
                                {
                                    name = 'kind', label = 'Warrant type', type = 'select',
                                    default = 'arrest', required = true,
                                    options = {
                                        { value = 'arrest', label = 'Arrest warrant' },
                                        { value = 'search', label = 'Search warrant' },
                                        { value = 'bench', label = 'Bench warrant' }
                                    }
                                },
                                { name = 'reason', label = 'Grounds', type = 'textarea', rows = 5, required = true },
                                {
                                    name = 'charge', label = 'Primary charge', type = 'select',
                                    options = chargeOptions, allowCustom = true
                                },
                                { name = 'charges', label = 'Further charges (comma separated)' }
                            }, function(form)
                                if not form then return MDT.Open() end
                                local list = splitList(form.charges)
                                if form.charge and form.charge ~= '' then table.insert(list, 1, form.charge) end
                                ask('cad:warrant', function() MDT.Open() end, {
                                    name = person.name,
                                    identifier = person.identifier,
                                    kind = form.kind,
                                    reason = form.reason,
                                    charges = list
                                })
                            end)
                        end
                    }
                end
                if #options == 0 then
                    Bridge.Notify('Nobody matches that search.', 'error')
                    return MDT.Open()
                end
                withMenu('mdt:warrant', 'Warrant subject', ('%d match(es)'):format(#options), options)
            end, values.term or values[1])
        end)
    end
    if action == 'serve' then return ask('cad:warrantStatus', MDT.Refresh, id, 'served') end
    if action == 'void' then return ask('cad:warrantStatus', MDT.Refresh, id, 'void') end
end

HANDLERS.bolos = function(id, action)
    if action == 'new' then
        return withInput('New BOLO', {
            {
                name = 'kind', label = 'Kind', type = 'select', default = 'person',
                options = {
                    { value = 'person', label = 'Person' },
                    { value = 'vehicle', label = 'Vehicle' }
                }
            },
            { name = 'subject', label = 'Subject (name or vehicle)', required = true },
            { name = 'plate', label = 'Plate (vehicles)' },
            { name = 'description', label = 'Description', type = 'textarea', rows = 5 }
        }, function(values)
            ask('cad:bolo', function() MDT.Open() end, {
                kind = values.kind,
                subject = values.subject,
                plate = values.plate,
                description = values.description
            })
        end)
    end
    if action == 'close' then return ask('cad:boloClose', MDT.Refresh, id) end
end

-- Logging evidence straight from the terminal: kind from the catalog, a
-- label, optionally filed against a case. (Physical bagging in the field
-- still goes through evidence bags; this is the paperwork path.)
HANDLERS.evidence = function(_, action)
    if action == 'log' then
        local kinds = {}
        for _, key in ipairs(Const.EvidenceKindOrder) do
            kinds[#kinds + 1] = { value = key, label = Const.EvidenceKinds[key].label }
        end
        return withInput('Evidence report', {
            { name = 'kind', label = 'Kind', type = 'select', required = true, options = kinds },
            { name = 'label', label = 'What is it?', required = true },
            { name = 'incident', label = 'File against incident id (optional)' }
        }, function(values)
            ask('cad:collect', function(record)
                if record then Bridge.Notify(('Logged as %s.'):format(record.number), 'success') end
                MDT.Open()
            end, { kind = values.kind, label = values.label, incidentId = values.incident })
        end)
    end
end

-- Setting a unit's status off the roster: your own freely, others with
-- roster.manage (the server enforces both).
HANDLERS.units = function(id, action)
    if action == 'status' then
        local statuses = {}
        for _, key in ipairs({ 'available', 'enroute', 'onscene', 'busy', 'offsite', 'panic' }) do
            local meta = Const.UnitStatus[key]
            if meta then statuses[#statuses + 1] = { value = key, label = meta.label } end
        end
        return withInput('Set status', {
            { name = 'status', label = 'Status', type = 'select', required = true, options = statuses }
        }, function(values)
            TriggerServerEvent(Federal.Net('unit:status'), tonumber(id), values.status)
            SetTimeout(400, MDT.Refresh)
        end)
    end
    if action == 'kit' then
        TriggerServerEvent(Federal.Net('checkout:clear'), tonumber(id))
        return SetTimeout(400, MDT.Refresh)
    end
    if action == 'certs' then
        -- Award / revoke straight off the personnel file: the agency's
        -- catalog with the member's current awards marked.
        local agency = State.Mine()
        local catalog = agency and agency.certifications or {}
        if #catalog == 0 then
            return Bridge.Notify('Define certifications in /fedconfig first (Certifications tab).', 'error')
        end

        local held = {}
        for _, row in ipairs((lastPayload and lastPayload.units) or {}) do
            if row.id == id then
                for _, cert in ipairs(row.certs or {}) do held[cert.id] = true end
                break
            end
        end

        local picks = {}
        for _, cert in ipairs(catalog) do
            local requires = #(cert.licences or {}) > 0
                and ('Requires: %s'):format(table.concat(cert.licences, ', ')) or nil
            picks[#picks + 1] = {
                title = cert.label,
                description = requires or cert.description
                    or (held[cert.id] and 'Click to revoke' or 'Click to award'),
                icon = held[cert.id] and 'check' or 'lock',
                badge = held[cert.id] and 'Awarded' or nil,
                badgeTone = held[cert.id] and 'success' or nil,
                onSelect = function()
                    TriggerServerEvent(Federal.Net('personnel:certToggle'), tonumber(id), cert.id)
                    SetTimeout(400, MDT.Open)
                end
            }
        end
        return withMenu('mdt:certs', 'Certifications', nil, picks)
    end
end

-- Photographs on a person's file, from the Lookup console.
HANDLERS.lookup = function(id, action)
    if action == 'photo' then
        local name = nil
        for _, row in ipairs((lastPayload and lastPayload.records) or {}) do
            if row.id == id then name = row.title break end
        end
        return withPhoto('Photograph on file', function(url)
            ask('cad:recordPhoto', function(record)
                if record and lastPayload then
                    for index, row in ipairs(lastPayload.records or {}) do
                        if row.id == id or row.profileId == id then
                            lastPayload.records[index] = MDT.Builders.records(record)
                            break
                        end
                    end
                    -- The photo flow closed the terminal (camera mode); a
                    -- push to a closed panel shows nothing, so reopen it
                    -- properly around the fresh row.
                    open = true
                    SetNuiFocus(true, true)
                    SendNUIMessage({ action = 'mdt:open', mdt = lastPayload })
                    Bridge.Notify('Photograph filed.', 'success')
                elseif not record then
                    MDT.Open()
                end
            end, id, url, name)
        end)
    end
end

HANDLERS.leads = function(id, action)
    if action == 'new' then
        local kinds = {}
        for key, meta in pairs(Const.LeadKinds) do
            kinds[#kinds + 1] = { value = key, label = meta.label or key }
        end
        table.sort(kinds, function(a, b) return a.label < b.label end)
        return withInput('New lead', {
            { name = 'kind', label = 'Kind of lead', type = 'select', required = true, options = kinds },
            { name = 'origin', label = 'Source (informant, patrol, tip line...)' },
            { name = 'subject', label = 'Subject identifier (optional)' },
            { name = 'summary', label = 'What the lead says', type = 'textarea', rows = 5, required = true }
        }, function(values)
            Bridge.TriggerCallback(Federal.Net('leads:create'), function(lead, err)
                if not lead then Bridge.Notify(err or 'Refused.', 'error') end
                MDT.Open()
            end, {
                kind = values.kind, origin = values.origin,
                subject = values.subject, summary = values.summary
            })
        end)
    end
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

-- The status strip on the terminal's top bar: pressing a state posts it the
-- same way the field menu does. The strip repaints OPTIMISTICALLY - the
-- context push can lag the click by a second, and a button that does not
-- light up reads as broken.
HANDLERS.status = function(_, action)
    if not Const.UnitStatus[action] then return end
    Federal.Actions.SetStatus(action)
    if lastPayload then
        lastPayload.myStatus = action
        SendNUIMessage({ action = 'mdt:open', mdt = lastPayload })
    end
    SetTimeout(800, MDT.Refresh)
end

-- My Call screen actions.
HANDLERS.mycall = function(_, action)
    local call = lastPayload and lastPayload.myCall
    if not call then return end
    if action == 'waypoint' and call.location then
        SetNewWaypoint(call.location.x, call.location.y)
        Bridge.Notify('Waypoint set to your call.', 'inform')
    end
end

-- Dispatch board actions: acting on a call straight off the board.
HANDLERS.dispatch = function(id, action)
    local call = nil
    for _, entry in ipairs((lastPayload and lastPayload.map and lastPayload.map.calls) or {}) do
        if entry.id == id then call = entry break end
    end
    if not call then return end

    if action == 'waypoint' and call.coords then
        SetNewWaypoint(call.coords.x, call.coords.y)
        return Bridge.Notify('Waypoint set.', 'inform')
    end

    if action == 'respond' then
        if call.kind == 'callout' then
            return Bridge.TriggerCallback(Federal.Net('callout:attach'), function(result, err)
                if not result then
                    Bridge.Notify(err or 'Refused.', 'error')
                else
                    Federal.Callouts.Track(result)
                    Bridge.Notify(('Assigned to %s.'):format(call.number or 'the call'), 'success')
                end
                MDT.Refresh()
            end, id)
        end
        if call.kind == 'report' then
            TriggerServerEvent(Federal.Net('report:ack'), id)
            Federal.Actions.SetStatus('enroute')
            return MDT.Refresh()
        end
        return
    end

    if action == 'incident' then
        -- Paper the call: an incident pre-filled from the dispatch entry,
        -- carrying the call's location as its scene.
        return withInput('Open an incident from this call', {
            { name = 'title', label = 'Case title', default = call.label, required = true },
            { name = 'narrative', label = 'Opening narrative', type = 'textarea', rows = 6,
                default = ('Opened from dispatch entry %s.'):format(call.number or '') }
        }, function(values)
            ask('cad:file', function(record)
                if record then
                    Bridge.Notify(('%s filed.'):format(record.number), 'success')
                    -- A converted 911 ticket is paper now: close the report
                    -- so the board does not show the same call twice.
                    if call.kind == 'report' then
                        TriggerServerEvent(Federal.Net('report:close'), call.id)
                    end
                end
                MDT.Open()
            end, {
                title = values.title,
                type = call.kind == 'report' and '911 report' or 'Callout',
                -- The incident keeps the CALL's priority, not the default.
                priority = call.priority,
                narrative = values.narrative,
                calloutId = call.kind == 'callout' and call.id or nil,
                location = call.coords
            })
        end)
    end
end

function MDT.Act(tab, id, action, data)
    local handler = HANDLERS[tab]
    if handler then handler(id, action, data) end
end

RegisterNUICallback('mdtClose', function(_, reply)
    reply({})
    open = false
    SetNuiFocus(false, false)
end)

RegisterNUICallback('mdtAction', function(data, reply)
    reply({})
    if type(data) ~= 'table' or type(data.tab) ~= 'string' or type(data.action) ~= 'string' then return end
    MDT.Act(data.tab, data.id, data.action, data.data)
end)

-- The Lookup console. One server round trip returns everything the term
-- touches - people (records AND framework civilians), registered vehicles
-- cross-checked against BOLO plates, warrants, BOLOs, incidents, case files
-- - and it all renders as rows with the same document detail.
-- A citizen with no criminal record still gets a file, just a clean one.
local function civilianRow(identifier, name)
    local agencyLabel, logo = letterhead()
    return {
        id = identifier,
        profileId = identifier,
        title = name,
        meta = identifier,
        pill = 'Civilian',
        document = {
            agency = agencyLabel,
            logo = logo,
            heading = 'CITIZEN FILE',
            number = identifier,
            status = 'active',
            subject = name,
            subjectId = 'no criminal record',
            body = 'No criminal history is on file with this agency. Framework records follow below where available.',
            charges = {},
            issuedBy = 'Records Division',
            issuedAt = 'LIVE FILE'
        },
        sections = {},
        actions = canWrite() and { { id = 'photo', label = 'Add photograph' } } or {}
    }
end

local function lookupRows(result)
    local rows = {}
    local agencyLabel, logo = letterhead()

    for _, person in ipairs(result.people or {}) do
        if person.civilian then
            rows[#rows + 1] = civilianRow(person.identifier, person.name)
        else
            rows[#rows + 1] = MDT.Builders.records(person)
        end
    end

    for _, vehicle in ipairs(result.vehicles or {}) do
        rows[#rows + 1] = {
            id = 'veh:' .. tostring(vehicle.plate),
            title = tostring(vehicle.plate or ''),
            meta = ('%s%s'):format(vehicle.model or 'Unknown model',
                vehicle.owner and (' | ' .. vehicle.owner) or ''),
            pill = vehicle.bolo and ('BOLO ' .. vehicle.bolo) or 'Registered',
            tone = vehicle.bolo and 'danger' or nil,
            document = {
                agency = agencyLabel,
                logo = logo,
                heading = 'VEHICLE REGISTRATION',
                number = tostring(vehicle.plate or ''),
                status = 'active',
                subject = vehicle.model or 'Unknown model',
                subjectId = ('plate %s'):format(vehicle.plate or '?'),
                body = ('Registered keeper: %s.%s'):format(
                    vehicle.owner or 'no keeper on file',
                    vehicle.bolo and (' ACTIVE BOLO %s IS FLYING ON THIS PLATE - approach per agency policy.'):format(vehicle.bolo) or ''),
                charges = {},
                issuedBy = 'Vehicle Records',
                issuedAt = 'LIVE FILE'
            },
            sections = {
                { label = 'Registration', fields = {
                    { label = 'Garage', value = vehicle.garage },
                    { label = 'Flags', value = vehicle.bolo and ('Active BOLO %s'):format(vehicle.bolo) or 'None' }
                } }
            },
            actions = {}
        }
    end

    for _, hit in ipairs(result.hits or {}) do
        rows[#rows + 1] = {
            id = 'hit:' .. tostring(hit.label),
            title = hit.label,
            meta = hit.meta,
            pill = hit.kind,
            tone = (hit.kind == 'warrant' or hit.kind == 'bolo') and 'danger' or 'accent',
            document = {
                agency = agencyLabel,
                logo = logo,
                heading = hit.kind:upper() .. ' INDEX ENTRY',
                number = tostring(hit.label):match('^%S+') or '',
                status = 'active',
                subject = hit.label,
                subjectId = hit.meta,
                body = 'This is an index card, not the full file: open the Records workspace to read and work the complete document.',
                charges = {},
                issuedBy = 'Records Division',
                issuedAt = 'INDEX'
            },
            sections = {},
            actions = {}
        }
    end

    return rows
end

-- The full profile behind a person: fetched lazily when their row is
-- selected, so a 40-row search does not fire 40 database queries.
local function profileRow(profile)
    local base
    if profile.record then
        base = MDT.Builders.records(profile.record)
    else
        local citizen = profile.citizen or {}
        local name = citizen.firstname
            and ('%s %s'):format(citizen.firstname, citizen.lastname or '')
            or profile.identifier
        local agencyLabel, logo = letterhead()
        base = {
            id = profile.identifier,
            title = name,
            meta = profile.identifier,
            pill = 'Civilian',
            document = {
                agency = agencyLabel,
                logo = logo,
                heading = 'CITIZEN FILE',
                number = profile.identifier,
                status = 'active',
                subject = name,
                subjectId = 'no criminal record',
                body = 'No criminal history is on file with this agency. Framework records follow below.',
                charges = {},
                issuedBy = 'Records Division',
                issuedAt = 'LIVE FILE'
            },
            sections = {},
            actions = canWrite() and { { id = 'photo', label = 'Add photograph' } } or {}
        }
    end
    base.profileId = profile.identifier
    base.profileLoaded = true

    local sections = {}

    local citizen = profile.citizen
    if citizen then
        sections[#sections + 1] = { label = 'Civil record', fields = {
            { label = 'Date of birth', value = citizen.birthdate },
            { label = 'Gender', value = citizen.gender },
            { label = 'Nationality', value = citizen.nationality },
            { label = 'Phone', value = citizen.phone }
        } }
        if citizen.job then
            sections[#sections + 1] = { label = 'Business & employment records', fields = {
                { label = 'Employer', value = citizen.job },
                { label = 'Position', value = citizen.jobPosition },
                { label = 'Owner / management', value = citizen.jobBoss and 'Yes - holds signing authority' or 'No' }
            } }
        end
        -- Each licence renders as an actual ID card, not a name in a list.
        if citizen.licences and #citizen.licences > 0 then
            local cards = {}
            for _, licence in ipairs(citizen.licences) do
                cards[#cards + 1] = {
                    kind = (licence:gsub('_', ' '):upper()) .. ' LICENSE',
                    name = base.title,
                    identifier = profile.identifier,
                    dob = citizen.birthdate,
                    gender = citizen.gender,
                    photo = profile.record and profile.record.photo or nil
                }
            end
            base.idcards = cards
        end
    end

    if #(profile.vehicles or {}) > 0 then
        local fields = {}
        for _, vehicle in ipairs(profile.vehicles) do
            fields[#fields + 1] = {
                label = vehicle.plate,
                value = ('%s%s'):format(vehicle.model or '', vehicle.garage and (' | ' .. vehicle.garage) or ''),
                -- Clicking the plate pulls the vehicle's own registration file.
                link = { lookup = vehicle.plate }
            }
        end
        sections[#sections + 1] = { label = 'Registered vehicles', fields = fields }
    end

    if #(profile.warrants or {}) > 0 then
        local fields = {}
        for _, warrant in ipairs(profile.warrants) do
            fields[#fields + 1] = {
                label = warrant.number,
                value = ('%s | %s'):format(warrant.status, warrant.reason or ''),
                -- Clicking the number opens the warrant itself.
                link = warrant.id and { tab = 'warrants', id = warrant.id } or nil
            }
        end
        sections[#sections + 1] = { label = 'Warrants', fields = fields }
    end

    if #(profile.court or {}) > 0 then
        local fields = {}
        for _, case in ipairs(profile.court) do
            fields[#fields + 1] = {
                label = case.number,
                value = ('%s%s'):format(case.stage or '', case.verdict and (' | ' .. case.verdict) or '')
            }
        end
        sections[#sections + 1] = { label = 'Court history', fields = fields }
    end

    -- Profile detail leads; the criminal record's own sections follow it.
    for _, section in ipairs(base.sections or {}) do sections[#sections + 1] = section end
    base.sections = sections
    return base
end

RegisterNUICallback('mdtProfile', function(data, reply)
    reply({})
    if not open or type(data) ~= 'table' then return end
    local identifier = tostring(data.identifier or '')
    if identifier == '' then return end

    Bridge.TriggerCallback(Federal.Net('cad:profile'), function(profile)
        if not open or not lastPayload or type(profile) ~= 'table' then return end
        local row = profileRow(profile)
        for index, existing in ipairs(lastPayload.records or {}) do
            if existing.profileId == identifier or existing.id == identifier then
                lastPayload.records[index] = row
                SendNUIMessage({ action = 'mdt:open', mdt = lastPayload })
                return
            end
        end
    end, identifier)
end)

RegisterNUICallback('mdtLookup', function(data, reply)
    reply({})
    if not open or type(data) ~= 'table' then return end
    local term = tostring(data.term or '')

    Bridge.TriggerCallback(Federal.Net('cad:lookup'), function(result)
        if not open or not lastPayload then return end
        result = type(result) == 'table' and result or { people = {}, vehicles = {}, hits = {} }
        lastPayload.records = lookupRows(result)
        lastPayload.recordsSearched = term ~= '' and term or nil
        SendNUIMessage({ action = 'mdt:open', mdt = lastPayload })
    end, term)
end)

-- Focus is a global input lock. Never leave it held across a restart.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and open then
        open = false
        SetNuiFocus(false, false)
    end
end)

return MDT
