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
-- so the locker only offers the ones that fit.
function Uniforms.Wearable(uniform, grade)
    if type(uniform) ~= 'table' then return false end
    if (grade or 0) < (uniform.minGrade or 0) then return false end
    return uniform.variant == 'any' or uniform.variant == Uniforms.Variant()
end

RegisterNetEvent(Federal.Net('wearUniform'), function(uniform)
    if Uniforms.Apply(uniform) then
        Bridge.Notify(('Changed into %s.'):format(uniform.label or 'uniform'), 'success')
    end
end)

return Uniforms
