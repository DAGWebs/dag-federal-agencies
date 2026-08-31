local Menu = DAG.Menu
local focused = false

-- The bundled NUI menu. Self-contained: no external CDN, no ox_lib, no
-- qb-menu. It is what Config.Menu = 'auto' falls back to, and what
-- Config.Menu = 'nui' selects unconditionally.

local function theme()
    local configured = Config.MenuTheme or {}
    return {
        accent = configured.accent or '#4c8dff',
        width = configured.width or 384,
        position = configured.position or 'right'
    }
end

local function setFocus(enabled)
    if focused == enabled then return end
    focused = enabled
    SetNuiFocus(enabled, enabled)
end

-- Only the fields the front-end reads are sent. Handlers (onSelect, args,
-- event names) stay in Lua: nothing executable crosses into the browser, and
-- selections come back as an index.
local function serialize(options)
    local payload = {}
    for index, option in ipairs(options) do
        payload[index] = {
            title = option.title,
            description = option.description,
            icon = option.icon,
            badge = option.badge,
            badgeTone = option.badgeTone,
            progress = option.progress,
            disabled = option.disabled == true,
            header = option.header == true,
            submenu = option.menu ~= nil
        }
    end
    return payload
end

Menu.RegisterProvider('nui', {
    open = function(view)
        setFocus(true)
        SendNUIMessage({
            action = 'open',
            theme = theme(),
            menu = {
                title = view.title,
                subtitle = view.subtitle,
                breadcrumb = view.breadcrumb,
                canGoBack = view.canGoBack,
                options = serialize(view.options)
            }
        })
    end,
    close = function()
        setFocus(false)
        SendNUIMessage({ action = 'close' })
    end
})

-- Equipment grid -----------------------------------------------------------
--
-- A card-grid storefront (armory shelves, locker rails) rendered by the
-- bundled UI. Only display fields cross into the browser; the select handler
-- stays in Lua and receives the chosen item id.

local gridHandler = nil

function Menu.Grid(view, onSelect)
    gridHandler = onSelect
    setFocus(true)
    SendNUIMessage({
        action = 'grid:open',
        theme = theme(),
        grid = {
            title = view.title,
            subtitle = view.subtitle,
            hint = view.hint,
            imageBase = view.imageBase,
            sections = view.sections
        }
    })
end

function Menu.GridClose()
    gridHandler = nil
    setFocus(false)
    SendNUIMessage({ action = 'grid:close' })
end

RegisterNUICallback('gridSelect', function(data, reply)
    reply({})
    if gridHandler and type(data) == 'table' then gridHandler(tostring(data.id)) end
end)

RegisterNUICallback('gridClose', function(_, reply)
    reply({})
    gridHandler = nil
    setFocus(false)
end)

-- Input dialog -------------------------------------------------------------
--
-- The bundled dialog renders the same normalized field list Menu.Input takes,
-- so a server with no ox_lib and no qb-input still has a way to type. One
-- dialog at a time: opening a second cancels the first.

local pendingInput = nil

function Menu.OpenInput(title, fields, callback)
    if pendingInput then
        local cancelled = pendingInput
        pendingInput = nil
        cancelled(nil)
    end

    local payload = {}
    for index, field in ipairs(fields) do
        -- The front-end dialog understands text, number, textarea (with the
        -- formatting toolbar) and select (a searchable dropdown over
        -- `options`). Anything else degrades to text.
        local kind = field.type
        if kind ~= 'number' and kind ~= 'textarea' and kind ~= 'select' then kind = 'text' end
        payload[index] = {
            name = field.name or tostring(index),
            label = field.label or field.name or ('Field %d'):format(index),
            type = kind,
            required = field.required == true,
            default = field.default,
            placeholder = field.placeholder,
            rows = field.rows,
            options = kind == 'select' and field.options or nil,
            allowCustom = field.allowCustom == true
        }
    end

    pendingInput = callback
    setFocus(true)
    SendNUIMessage({
        action = 'input:open',
        theme = theme(),
        input = { title = title or 'Input', fields = payload }
    })
end

RegisterNUICallback('inputResult', function(data, reply)
    reply({})
    setFocus(false)

    local callback = pendingInput
    pendingInput = nil
    if not callback then return end

    if type(data) ~= 'table' or data.cancelled or type(data.values) ~= 'table' then
        return callback(nil)
    end
    callback(data.values)
end)

RegisterNUICallback('select', function(data, reply)
    reply({})
    Menu.Select(data and data.index)
end)

RegisterNUICallback('back', function(_, reply)
    reply({})
    Menu.Back()
end)

-- The player dismissed the menu from the UI, so the panel is already hidden;
-- releasing focus and clearing Lua state is all that is left.
RegisterNUICallback('close', function(_, reply)
    reply({})
    setFocus(false)
    Menu.Close()
end)

-- Focus is a global input lock. Never leave it held across a resource restart.
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then setFocus(false) end
end)
