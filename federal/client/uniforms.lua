-- Capturing and applying uniforms.
--
-- The authoring flow a boss actually uses is "wear it, then save it": get
-- dressed however you want the uniform to look, open the boss menu and save
-- your current outfit. This file reads the ped component slots the uniform
-- schema owns and posts them to the server, and applies them coming back.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local Uniforms = {}
Federal.Uniforms = Uniforms

-- What the player is wearing right now, in the shape Schema.Uniform expects.
function Uniforms.Capture()
    local ped = PlayerPedId()
    local components, props = {}, {}

    for _, slot in ipairs(Const.UniformComponents) do
        components[#components + 1] = {
            slot = slot,
            drawable = GetPedDrawableVariation(ped, slot),
            texture = GetPedTextureVariation(ped, slot),
            palette = GetPedPaletteVariation(ped, slot)
        }
    end

    for _, slot in ipairs(Const.UniformProps) do
        local drawable = GetPedPropIndex(ped, slot)
        -- -1 means "nothing worn in this slot", which is worth storing: it is
        -- how a uniform says "take the hat off".
        props[#props + 1] = {
            slot = slot,
            drawable = drawable,
            texture = drawable >= 0 and GetPedPropTextureIndex(ped, slot) or 0
        }
    end

    return { components = components, props = props }
end

function Uniforms.Apply(uniform)
    if type(uniform) ~= 'table' then return false end
    local ped = PlayerPedId()

    for _, entry in ipairs(uniform.components or {}) do
        SetPedComponentVariation(ped, entry.slot, entry.drawable, entry.texture, entry.palette or 0)
    end

    for _, entry in ipairs(uniform.props or {}) do
        if (entry.drawable or -1) < 0 then
            ClearPedProp(ped, entry.slot)
        else
            SetPedPropIndex(ped, entry.slot, entry.drawable, entry.texture or 0, true)
        end
    end

    if (uniform.armour or 0) > 0 then SetPedArmour(ped, uniform.armour) end
    return true
end

function Uniforms.Variant()
    return IsPedMale(PlayerPedId()) and 'male' or 'female'
end

-- A uniform saved for one body type applied to the other produces nonsense,
-- so the locker only offers the ones that fit. Division-tied uniforms only
-- offer to members of that division; the server re-checks all of it.
function Uniforms.Wearable(uniform, grade, divisionId)
    if type(uniform) ~= 'table' then return false end
    if (grade or 0) < (uniform.minGrade or 0) then return false end
    if uniform.division and uniform.division ~= divisionId then return false end
    return uniform.variant == 'any' or uniform.variant == Uniforms.Variant()
end

-- What the player wore before their FIRST uniform of the session, so
-- "civilian clothes" can put it back even with no skin resource running.
local civilianOutfit = nil

RegisterNetEvent(Federal.Net('wearUniform'), function(uniform)
    if civilianOutfit == nil then civilianOutfit = Uniforms.Capture() end
    if Uniforms.Apply(uniform) then
        Bridge.Notify(('Changed into %s.'):format(uniform.label or 'uniform'), 'success')
    end
end)

-- Changing back: ask the server's skin resource for the saved appearance
-- (the authoritative copy), falling back to the outfit captured before the
-- first uniform went on. The event stays public so a custom skin stack can
-- add its own handler.
AddEventHandler(Federal.Net('restoreAppearance'), function()
    if GetResourceState('qb-clothing') == 'started' then
        TriggerServerEvent('qb-clothes:loadPlayerSkin')
        civilianOutfit = nil
        Bridge.Notify('Changed back into your own clothes.', 'success')
        return
    end

    if GetResourceState('illenium-appearance') == 'started' then
        TriggerEvent('illenium-appearance:client:reloadSkin')
        civilianOutfit = nil
        Bridge.Notify('Changed back into your own clothes.', 'success')
        return
    end

    if civilianOutfit then
        Uniforms.Apply(civilianOutfit)
        civilianOutfit = nil
        Bridge.Notify('Changed back into your own clothes.', 'success')
        return
    end

    Bridge.Notify('No saved appearance to change back into - use your clothing menu.', 'error')
end)

-- /feduniform round trip: the server command asks this client to read the
-- outfit it is wearing; authorization stays on the server.
RegisterNetEvent(Federal.Net('captureOutfit'), function(agencyId, label, minGrade)
    local captured = Uniforms.Capture()
    TriggerServerEvent(Federal.Net('uniform:adminSave'), agencyId, {
        label = label,
        minGrade = tonumber(minGrade) or 0,
        variant = Uniforms.Variant(),
        components = captured.components,
        props = captured.props
    })
end)

return Uniforms
