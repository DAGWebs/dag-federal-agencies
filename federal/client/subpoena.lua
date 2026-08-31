-- Financial subpoenas: officer commands and the records view.
--
-- Filing, signing and pulling all go through server callbacks; this file is
-- just the officer's console for them. The records themselves are shown in an
-- ox_lib dialog when they come back.

DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework

local function fmtMoney(n)
    if n == nil then return 'unknown' end
    local sign = n < 0 and '-' or ''
    local whole = string.format('%.2f', math.abs(n))
    local intPart, frac = whole:match('^(%d+)%.(%d+)$')
    intPart = (intPart or whole):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return sign .. '$' .. intPart .. '.' .. (frac or '00')
end

-- Renders the pulled profile as a markdown dialog.
local function showRecords(profile)
    local lines = {}
    lines[#lines + 1] = ('## Financial records — %s'):format(profile.name or profile.identifier or 'Unknown')
    if profile.subpoena then
        lines[#lines + 1] = ('**Subpoena %s** · %s'):format(profile.subpoena.number, profile.subpoena.reason or '')
    end
    lines[#lines + 1] = profile.online and '_Citizen is online (live balances)._' or '_Citizen is offline._'
    if profile.creditScore then lines[#lines + 1] = ('Credit score: **%d**'):format(profile.creditScore) end

    lines[#lines + 1] = '\n### Accounts'
    lines[#lines + 1] = '| Account | Type | Balance |'
    lines[#lines + 1] = '| --- | --- | --- |'
    for _, acct in ipairs(profile.accounts or {}) do
        lines[#lines + 1] = ('| %s (%s) | %s | %s |'):format(
            acct.label or '?', acct.number or '', acct.type or '', fmtMoney(acct.balance))
    end

    lines[#lines + 1] = '\n### Recent transactions'
    lines[#lines + 1] = '| When | Account | Detail | Amount |'
    lines[#lines + 1] = '| --- | --- | --- | --- |'
    local shown = 0
    for _, tx in ipairs(profile.transactions or {}) do
        if shown >= 40 then break end
        shown = shown + 1
        lines[#lines + 1] = ('| %s | %s | %s | %s |'):format(
            DAG.Federal.Util.Stamp(tx.at),
            (tx.accountLabel or ''),
            (tx.description or tx.kind or ''):gsub('|', '/'),
            fmtMoney(tx.amount))
    end
    if #(profile.transactions or {}) == 0 then
        lines[#lines + 1] = '| — | — | No transactions on file | — |'
    end

    if GetResourceState('ox_lib') == 'started' then
        exports.ox_lib:alertDialog({
            header = 'FIB Financial Records',
            content = table.concat(lines, '\n'),
            centered = true,
            size = 'lg'
        })
    else
        Bridge.Notify('Records returned. Install ox_lib to view them.', 'inform')
    end
end

-- /subpoena <playerId|citizenid> <reason...>
RegisterCommand('subpoena', function(_, args)
    local target = args[1]
    if not target then return Bridge.Notify('Usage: /subpoena <playerId or citizenid> <reason>', 'error') end
    local reason = table.concat(args, ' ', 2)

    Bridge.TriggerCallback(Federal.Net('subpoena:file'), function(record, err)
        if not record then return Bridge.Notify(err or 'The request was refused.', 'error') end
        if record.status == 'granted' then
            Bridge.Notify(('Subpoena %s granted. /subpoena-records %s'):format(record.number, record.number), 'success')
        else
            Bridge.Notify(('Subpoena %s filed (%s). %s'):format(record.number, record.status, record.note or ''), 'inform')
        end
    end, target, reason)
end, false)

-- /subpoenas — list your agency's subpoenas
RegisterCommand('subpoenas', function()
    Bridge.TriggerCallback(Federal.Net('subpoena:list'), function(list)
        if not list or #list == 0 then return Bridge.Notify('No subpoenas on file.', 'inform') end

        if GetResourceState('ox_lib') == 'started' then
            local options = {}
            for _, s in ipairs(list) do
                options[#options + 1] = {
                    title = ('%s — %s'):format(s.number, (s.target and s.target.name) or (s.target and s.target.identifier) or '?'),
                    description = ('%s · %d incidents · %s'):format(s.status, s.evidence or 0, s.reason or ''),
                    icon = s.status == 'granted' and 'folder-open' or 'hourglass',
                    onSelect = function()
                        if s.status == 'granted' then
                            Bridge.TriggerCallback(Federal.Net('subpoena:pull'), function(profile, err)
                                if not profile then return Bridge.Notify(err or 'No records.', 'error') end
                                showRecords(profile)
                            end, s.number)
                        else
                            Bridge.Notify(('%s is %s. %s'):format(s.number, s.status, s.note or ''), 'inform')
                        end
                    end
                }
            end
            exports.ox_lib:registerContext({ id = 'fib_subpoenas', title = 'Subpoenas', options = options })
            exports.ox_lib:showContext('fib_subpoenas')
        else
            for _, s in ipairs(list) do
                Bridge.Notify(('%s · %s · %s'):format(s.number, s.status, (s.target and s.target.name) or '?'), 'inform')
            end
        end
    end)
end, false)

-- /subpoena-sign <number> — judges only
RegisterCommand('subpoena-sign', function(_, args)
    local ref = args[1]
    if not ref then return Bridge.Notify('Usage: /subpoena-sign <subpoena number>', 'error') end
    Bridge.TriggerCallback(Federal.Net('subpoena:sign'), function(record, err)
        if not record then return Bridge.Notify(err or 'Could not sign that.', 'error') end
        Bridge.Notify(('Signed subpoena %s.'):format(record.number), 'success')
    end, ref)
end, false)

-- /subpoena-records <number> — pull and view the records
RegisterCommand('subpoena-records', function(_, args)
    local ref = args[1]
    if not ref then return Bridge.Notify('Usage: /subpoena-records <subpoena number>', 'error') end
    Bridge.TriggerCallback(Federal.Net('subpoena:pull'), function(profile, err)
        if not profile then return Bridge.Notify(err or 'No records were returned.', 'error') end
        showRecords(profile)
    end, ref)
end, false)
