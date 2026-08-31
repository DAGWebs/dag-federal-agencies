-- Data feed for the /fedconfig GUI.
--
-- Access rule: the federal.admin ACE may configure any agency; everyone else
-- may open the panel only for the agency they work for, and only while
-- holding its HIGHEST rank. Every write the panel performs goes through the
-- existing editor/armory/uniform endpoints, which re-check authorization on
-- their own - this file only decides who gets the panel and what it shows.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local ConfigPanel = {}
Federal.ConfigPanel = ConfigPanel

local function fail(message)
    return nil, message
end

-- Which agency this player may open the panel for, or nil with the reason.
function ConfigPanel.CanOpen(source, agencyId)
    if Core.IsAdmin(source) then
        local agency = agencyId and Core.Agency(agencyId)
        if agency then return agency end
        local membership = Core.Membership(source)
        if membership then return membership.agency end
        if agencyId then return fail('no such agency') end
        return fail('name an agency: you are not a member of one')
    end

    local membership = Core.Membership(source)
    if not membership then return fail('you are not a member of a federal agency') end
    if agencyId and agencyId ~= membership.agency.id then
        return fail('you may only configure your own agency')
    end

    local top = Federal.Editor.TopGrade(membership.agency)
    if membership.grade < top then
        return fail(('only the highest rank (grade %d) may configure the agency'):format(top))
    end
    return membership.agency
end

-- Everything the panel renders, in one read. The agency record is the live
-- registry entry (config merged with stored edits); vehicles come from their
-- own store; the item catalog powers the armory tab's searchable field.
function ConfigPanel.Snapshot(source, agencyId)
    local agency, message = ConfigPanel.CanOpen(source, agencyId)
    if not agency then return fail(message) end

    local applications = Federal.Applications.GetForm(agency.id)
    applications.pending = Federal.Applications.PendingCount(agency.id)

    return {
        agency = Util.Copy(agency),
        vehicles = Federal.Armory.Vehicles(agency.id),
        doors = Federal.Doors.List(agency.id),
        applications = applications,
        topGrade = Federal.Editor.TopGrade(agency),
        itemCatalog = Federal.Armory.ItemCatalog(),
        licences = Bridge.LicenceCatalog and Bridge.LicenceCatalog() or {}
    }
end

Bridge.RegisterCallback(Federal.Net('config:get'), function(source, reply, agencyId)
    local snapshot, message = ConfigPanel.Snapshot(source, type(agencyId) == 'string' and agencyId or nil)
    if not snapshot then return reply(nil, message) end
    reply(snapshot)
end)

return ConfigPanel
