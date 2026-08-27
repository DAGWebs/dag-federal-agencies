-- Working leads: the screen where an analysed piece of evidence turns into
-- something to do next.
--
-- An address lead puts a waypoint and a search marker in the world, which is
-- the whole point of it: the case moves somewhere new because of what the lab
-- found, not because the template said so.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local Leads = {}
Federal.Leads = Leads

local markers = {}

local function id(name)
    return Federal.Menus.Id('leads:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

function Leads.ClearMarkers()
    for _, entry in ipairs(markers) do
        DAG.Interactions.Remove(entry.interaction)
        if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
    end
    markers = {}
end

-- Puts a followed address on the map and drops a search point there.
function Leads.MarkAddress(lead)
    if type(lead) ~= 'table' or type(lead.location) ~= 'table' then return nil end

    local blip = Federal.Zones.AddBlip(lead.location, ('Lead %s'):format(lead.number or ''), {
        sprite = 484, color = 5, scale = 0.8, shortRange = false
    })
    if blip then SetBlipRoute(blip, true) end

    local markerId = ('federal:lead:%s'):format(lead.id)
    DAG.Interactions.Register({
        id = markerId,
        coords = vector3(lead.location.x, lead.location.y, lead.location.z),
        distance = 3.0,
        marker = 21,
        label = 'Press ~INPUT_CONTEXT~ to search the address',
        onSelect = function()
            local timings = (Config.Federal or {}).timings or {}
            if not Federal.Progress.Run({
                label = 'Searching the address',
                duration = timings.search or 6000,
                animation = 'search'
            }) then return end

            DAG.Interactions.Remove(markerId)
            Bridge.TriggerCallback(Federal.Net('cad:collect'), function(record)
                if record then
                    Bridge.Notify(('Recovered %s at the address.'):format(record.number), 'success')
                end
            end, {
                kind = 'document',
                calloutId = lead.calloutId,
                location = lead.location,
                subject = lead.subject
            })
        end
    })

    markers[#markers + 1] = { interaction = markerId, blip = blip }
    return markerId
end

function Leads.Open(calloutId)
    Bridge.TriggerCallback(Federal.Net('leads'), function(list)
        local options = {}
        for _, lead in ipairs(list or {}) do
            local kind = Const.LeadKinds[lead.kind] or {}
            options[#options + 1] = {
                title = kind.label or lead.kind,
                description = lead.summary,
                icon = 'info',
                badge = lead.status == 'open' and 'New' or 'Worked',
                badgeTone = lead.status == 'open' and 'accent' or 'success',
                onSelect = function() Leads.Detail(lead) end
            }
        end

        options[#options + 1] = { title = 'Terminal', header = true }
        options[#options + 1] = {
            title = 'Run a plate',
            description = 'Check a partial against registered keepers',
            icon = 'car',
            onSelect = Leads.RunPlate
        }

        show(id('list'), 'Leads', ('%d on file'):format(#(list or {})), options)
    end, calloutId)
end

function Leads.Detail(lead)
    local kind = Const.LeadKinds[lead.kind] or {}
    local options = {
        { title = lead.number or '', description = lead.summary, disabled = true },
        { title = ('Kind: %s'):format(kind.label or lead.kind), disabled = true }
    }

    if lead.plate then
        options[#options + 1] = { title = ('Plate: %s'):format(lead.plate), icon = 'car', disabled = true }
    end
    if lead.keeper then
        options[#options + 1] = { title = ('Keeper: %s'):format(lead.keeper), icon = 'user', disabled = true }
    end
    if lead.name then
        options[#options + 1] = { title = ('Named: %s'):format(lead.name), icon = 'user', disabled = true }
    end

    if lead.status == 'open' then
        options[#options + 1] = { title = 'Actions', header = true }
        options[#options + 1] = {
            title = 'Follow this lead',
            description = 'Acts on what it points at',
            icon = 'check',
            onSelect = function() Leads.Follow(lead.id) end
        }
    end

    show(id('detail'), lead.number or 'Lead', kind.label, options)
end

function Leads.Follow(leadId)
    Bridge.TriggerCallback(Federal.Net('leads:follow'), function(lead, err)
        if not lead then return Bridge.Notify(err or 'That lead went nowhere.', 'error') end

        Bridge.Notify(lead.summary or 'Lead followed.', 'success', 8000)
        if lead.kind == 'address' then Leads.MarkAddress(lead) end
        Leads.Open(lead.calloutId)
    end, leadId)
end

function Leads.RunPlate()
    DAG.Menu.Input('Run a plate', { { name = 'plate', label = 'Plate', required = true } }, function(values)
        if not values then return end

        Bridge.TriggerCallback(Federal.Net('leads:plate'), function(lead, err)
            if not lead then return Bridge.Notify(err or 'The check failed.', 'error') end
            Bridge.Notify(lead.summary or ('Keeper: %s'):format(lead.keeper or 'unknown'),
                lead.status == 'cold' and 'inform' or 'success', 8000)
        end, values.plate or values[1])
    end)
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Leads.ClearMarkers() end
end)

return Leads
