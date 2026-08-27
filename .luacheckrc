std = 'lua54'
max_line_length = 160

-- Files are concatenated into one Lua state by the FiveM runtime, so the
-- template's own globals are shared on purpose.
globals = {
    'DAG',
    'Config',
    'exports',
}

read_globals = {
    -- CFX runtime
    'AddEventHandler', 'AddStateBagChangeHandler', 'CreateThread', 'Citizen',
    'GetCurrentResourceName', 'GetGameTimer', 'GetResourceState', 'LoadResourceFile',
    'RegisterCommand', 'RegisterNetEvent', 'RemoveStateBagChangeHandler',
    'SaveResourceFile', 'SetTimeout', 'TriggerClientEvent', 'TriggerEvent',
    'TriggerServerEvent', 'Wait', 'json', 'msgpack', 'promise', 'source',
    -- server
    'GetPlayerIdentifierByType', 'GetPlayerIdentifiers', 'GetPlayerName',
    'GetPlayers', 'IsPlayerAceAllowed', 'Player', 'DropPlayer',
    -- shared entity natives (server and client both have these)
    'DoesEntityExist', 'GetEntityCoords', 'GetEntityHeading', 'GetPlayerPed',
    'GetVehiclePedIsIn', 'NetworkGetEntityFromNetworkId',
    -- client
    'AddTextComponentSubstringPlayerName', 'BeginTextCommandDisplayHelp',
    'DrawMarker', 'EndTextCommandDisplayHelp',
    'RegisterNUICallback', 'SendNUIMessage', 'SetNuiFocus',
    'GetPlayerServerId', 'IsControlJustReleased', 'LocalPlayer', 'PlayerId',
    'PlayerPedId', 'vector3',
    -- client: blips
    'AddBlipForCoord', 'AddTextComponentString', 'BeginTextCommandSetBlipName',
    'DoesBlipExist', 'EndTextCommandSetBlipName', 'RemoveBlip',
    'SetBlipAsShortRange', 'SetBlipColour', 'SetBlipRoute', 'SetBlipScale',
    'SetBlipSprite',
    -- client: peds, models and animation
    'ClearPedProp', 'ClearPedTasks', 'CreatePed', 'DeleteEntity',
    'GetPedDrawableVariation', 'GetPedPaletteVariation', 'GetPedPropIndex',
    'GetPedPropTextureIndex', 'GetPedTextureVariation', 'HasAnimDictLoaded',
    'HasModelLoaded', 'IsEntityPlayingAnim', 'IsPedMale', 'RequestAnimDict',
    'RequestModel', 'SetBlockingOfNonTemporaryEvents', 'SetEntityAsMissionEntity',
    'SetModelAsNoLongerNeeded', 'SetPedArmour', 'SetPedComponentVariation',
    'SetPedDiesWhenInjured', 'SetPedFleeAttributes', 'SetPedPropIndex',
    'TaskPlayAnim', 'TaskStartScenarioInPlace',
    -- client: players, vehicles and controls
    'AttachEntityToEntity', 'CreateVehicle', 'DetachEntity',
    'DisableControlAction', 'GetActivePlayers', 'GetClosestVehicle',
    'GetHashKey', 'GetPlayerFromServerId', 'IsVehicleSeatFree',
    'NetworkGetNetworkIdFromEntity', 'PlaySoundFrontend', 'SetEnableHandcuffs',
    'SetPedIntoVehicle', 'SetVehicleNumberPlateText', 'IsEntityDead', 'SetNewWaypoint',
    -- client: suspect behaviour
    'GetEntitySpeed', 'GiveWeaponToPed', 'IsPedDeadOrDying', 'IsPlayerFreeAiming',
    'SetCurrentPedWeapon', 'SetPedAccuracy', 'SetPedHearingRange', 'SetPedKeepTask',
    'SetPedSeeingRange', 'TaskCombatPed', 'TaskHandsUp', 'TaskSmartFleePed',
}

exclude_files = { 'tests/lua/vendor/**' }

files['fxmanifest.lua'] = {
    globals = {
        'author', 'client_script', 'client_scripts', 'dependencies', 'dependency',
        'description', 'files', 'fx_version', 'game', 'lua54', 'provide',
        'server_script', 'server_scripts', 'shared_script', 'shared_scripts',
        'ui_page', 'version',
    },
}

files['tests/lua/**'] = {
    -- `math` is writable here on purpose: harness.fixRandom swaps math.random
    -- so dice-driven behaviour (NPC juror votes) is deterministic under test.
    globals = { 'harness', 'math' },
    read_globals = {
        'test',
        'assertDeepEq', 'assertEq', 'assertFalse', 'assertNil', 'assertThrows', 'assertTrue',
    },
}
