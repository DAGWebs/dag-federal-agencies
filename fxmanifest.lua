fx_version 'cerulean'
game 'gta5'

author 'DAG'
description 'Framework-agnostic federal agencies job, CAD, investigations and court process'
version '2.0.0'

lua54 'yes'

shared_scripts {
    'config.lua',
    'bridge/shared.lua',
    -- Vocabulary and validators, then the default catalogs that use them.
    'federal/shared/constants.lua',
    'federal/shared/util.lua',
    'federal/shared/schema.lua',
    'federal/config/agencies.lua',
    'federal/config/callouts.lua',
    'federal/config/court.lua'
}

client_scripts {
    'bridge/client.lua',
    'bridge/client/*.lua',
    'modules/menu/client.lua',
    'modules/menu/nui.lua',
    'modules/interactions/client.lua',
    -- Federal client. Listed in dependency order rather than globbed: state
    -- must exist before the modules that read it, and bootstrap must be last
    -- because it wires the others together.
    'federal/client/state.lua',
    'federal/client/progress.lua',
    'federal/client/uniforms.lua',
    'federal/client/actions.lua',
    'federal/client/suspects.lua',
    'federal/client/cad.lua',
    'federal/client/armory.lua',
    'federal/client/units.lua',
    'federal/client/reports.lua',
    'federal/client/leads.lua',
    'federal/client/callouts.lua',
    'federal/client/court.lua',
    'federal/client/jail.lua',
    'federal/client/personnel.lua',
    'federal/client/editor.lua',
    'federal/client/hud.lua',
    'federal/client/menus.lua',
    'federal/client/zones.lua',
    'federal/client/bootstrap.lua',
    'client/main.lua'
}

ui_page 'ui/index.html'

files {
    'ui/index.html',
    'ui/style.css',
    'ui/app.js'
}

server_scripts {
    'bridge/server.lua',
    'bridge/server/*.lua',
    'modules/storage/server.lua',
    'modules/commands/server.lua',
    'modules/access/server.lua',
    'modules/repository/server.lua',
    -- Federal server. Core owns the registry and the permission gates, so it
    -- loads before everything that authorizes through it.
    'federal/server/core.lua',
    'federal/server/cad.lua',
    'federal/server/personnel.lua',
    'federal/server/uniforms.lua',
    'federal/server/armory.lua',
    'federal/server/actions.lua',
    'federal/server/editor.lua',
    'federal/server/reports.lua',
    'federal/server/leads.lua',
    'federal/server/callouts.lua',
    'federal/server/court.lua',
    'federal/server/jail.lua',
    'federal/server/commands.lua',
    'server/main.lua'
}
