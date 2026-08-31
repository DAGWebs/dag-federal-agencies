/* NUI front-end for DAG.Menu.

   Protocol (client -> UI), via SendNUIMessage:
     { action: 'open',  menu: { title, subtitle, breadcrumb, canGoBack, options: [...] } }
     { action: 'close' }
     { action: 'theme', theme: { accent, width, position } }

   Protocol (UI -> client), via fetch to the resource's NUI callbacks:
     select { index }   back {}   close {} */

(function () {
    'use strict';

    var ICONS = {
        chevron: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>',
        back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
        check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>',
        close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6L6 18M6 6l12 12"/></svg>',
        lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>',
        user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 00-4-4H8a4 4 0 00-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
        car: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12.4l1.8-4.5A2.5 2.5 0 017.1 6.3h9.8a2.5 2.5 0 012.3 1.6l1.8 4.5"/><path d="M3 12.4h18v4.2a1 1 0 01-1 1H4a1 1 0 01-1-1z"/><circle cx="7.4" cy="17.6" r="1.3"/><circle cx="16.6" cy="17.6" r="1.3"/></svg>',
        box: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8l-9-5-9 5v8l9 5 9-5z"/><path d="M3.3 7.5L12 12l8.7-4.5M12 12v9"/></svg>',
        cash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/></svg>',
        wrench: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.77-3.77a6 6 0 01-7.94 7.94l-6.91 6.91a2.12 2.12 0 01-3-3l6.91-6.91a6 6 0 017.94-7.94l-3.76 3.76z"/></svg>',
        info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/></svg>'
    };

    var root = document.getElementById('root');
    var titleEl = document.getElementById('title');
    var subtitleEl = document.getElementById('subtitle');
    var breadcrumbEl = document.getElementById('breadcrumb');
    var optionsEl = document.getElementById('options');
    var hintBack = document.getElementById('hintBack');

    var state = { menu: null, active: -1, open: false };

    function post(name, payload) {
        var resource = (typeof GetParentResourceName === 'function')
            ? GetParentResourceName()
            : 'dag-template';

        return fetch('https://' + resource + '/' + name, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {})
        }).catch(function () { /* standalone preview has no NUI host */ });
    }

    function icon(name) {
        if (!name) return '';
        if (ICONS[name]) return ICONS[name];
        // Anything not in the built-in set renders as text, so emoji work.
        return escapeHtml(name);
    }

    function escapeHtml(value) {
        return String(value).replace(/[&<>"']/g, function (char) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char];
        });
    }

    /* Rows that cannot be chosen: separators and disabled entries. */
    function isSelectable(option) {
        return !option.header && !option.disabled;
    }

    function firstSelectable(from, direction) {
        var options = state.menu.options;
        for (var step = 0; step < options.length; step += 1) {
            var index = (from + direction * step + options.length * 2) % options.length;
            if (isSelectable(options[index])) return index;
        }
        return -1;
    }

    function render() {
        var menu = state.menu;
        optionsEl.innerHTML = '';

        titleEl.textContent = menu.title || 'Menu';
        subtitleEl.textContent = menu.subtitle || '';
        subtitleEl.hidden = !menu.subtitle;
        breadcrumbEl.textContent = menu.breadcrumb || '';
        breadcrumbEl.hidden = !menu.breadcrumb;
        hintBack.hidden = !menu.canGoBack;

        if (!menu.options.length) {
            var empty = document.createElement('li');
            empty.className = 'menu__empty';
            empty.textContent = 'Nothing available.';
            optionsEl.appendChild(empty);
            return;
        }

        menu.options.forEach(function (option, index) {
            optionsEl.appendChild(renderOption(option, index));
        });

        scrollActiveIntoView();
    }

    function renderOption(option, index) {
        var item = document.createElement('li');
        item.className = 'option';
        item.dataset.index = String(index);
        item.setAttribute('role', 'menuitem');

        if (option.header) {
            item.classList.add('option--header');
            item.innerHTML = '<div class="option__text"><div class="option__title">'
                + escapeHtml(option.title || '') + '</div></div>';
            return item;
        }

        if (option.disabled) {
            item.classList.add('option--disabled');
            item.setAttribute('aria-disabled', 'true');
        }
        if (index === state.active) item.classList.add('option--active');

        var html = '<div class="option__icon">' + icon(option.icon || 'info') + '</div>';

        html += '<div class="option__text"><div class="option__title">'
            + escapeHtml(option.title || '') + '</div>';
        if (option.description) {
            html += '<div class="option__description">' + escapeHtml(option.description) + '</div>';
        }
        html += '</div>';

        html += '<div class="option__aside">';
        if (option.badge) {
            var tone = option.badgeTone ? ' option__badge--' + escapeHtml(option.badgeTone) : '';
            html += '<span class="option__badge' + tone + '">' + escapeHtml(option.badge) + '</span>';
        }
        if (option.submenu) {
            html += '<span class="option__chevron">' + ICONS.chevron + '</span>';
        }
        html += '</div>';

        if (typeof option.progress === 'number') {
            var pct = Math.max(0, Math.min(100, option.progress));
            html += '<div class="option__meter"><span style="width:' + pct + '%"></span></div>';
        }

        item.innerHTML = html;
        return item;
    }

    function setActive(index) {
        if (index === state.active) return;
        state.active = index;

        Array.prototype.forEach.call(optionsEl.children, function (child) {
            child.classList.toggle('option--active', Number(child.dataset.index) === index);
        });
        scrollActiveIntoView();
    }

    function scrollActiveIntoView() {
        var el = optionsEl.querySelector('.option--active');
        if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
    }

    function move(direction) {
        if (!state.menu || !state.menu.options.length) return;
        var next = firstSelectable(state.active + direction, direction);
        if (next !== -1) setActive(next);
    }

    function choose(index) {
        if (!state.menu) return;
        var option = state.menu.options[index];
        if (!option || !isSelectable(option)) return;
        setActive(index);
        post('select', { index: index + 1 });
    }

    function open(menu) {
        state.menu = {
            title: menu.title,
            subtitle: menu.subtitle,
            breadcrumb: menu.breadcrumb,
            canGoBack: !!menu.canGoBack,
            options: Array.isArray(menu.options) ? menu.options : []
        };
        state.active = -1;
        state.open = true;

        root.hidden = false;
        render();

        var first = firstSelectable(0, 1);
        if (first !== -1) setActive(first);

        // Next frame, so the entry transition actually runs.
        requestAnimationFrame(function () { root.dataset.open = 'true'; });
    }

    function close(notify) {
        if (!state.open) return;
        state.open = false;
        root.dataset.open = 'false';

        window.setTimeout(function () {
            if (!state.open) root.hidden = true;
        }, 160);

        if (notify !== false) post('close', {});
    }

    function applyTheme(theme) {
        if (!theme) return;
        if (theme.accent) {
            root.style.setProperty('--menu-accent', theme.accent);
            root.style.setProperty('--menu-accent-soft', hexToSoft(theme.accent));
        }
        if (theme.width) root.style.setProperty('--menu-width', theme.width + 'px');
        if (theme.position) root.dataset.position = theme.position;
    }

    function hexToSoft(hex) {
        var match = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
        if (!match) return 'rgba(76, 141, 255, 0.16)';
        return 'rgba(' + parseInt(match[1], 16) + ', ' + parseInt(match[2], 16)
            + ', ' + parseInt(match[3], 16) + ', 0.16)';
    }

    optionsEl.addEventListener('click', function (event) {
        var item = event.target.closest('.option');
        if (item) choose(Number(item.dataset.index));
    });

    optionsEl.addEventListener('mousemove', function (event) {
        var item = event.target.closest('.option');
        if (!item) return;
        var index = Number(item.dataset.index);
        if (isSelectable(state.menu.options[index])) setActive(index);
    });

    document.addEventListener('keydown', function (event) {
        if (!state.open) return;

        switch (event.key) {
            case 'ArrowUp':    event.preventDefault(); move(-1); break;
            case 'ArrowDown':  event.preventDefault(); move(1); break;
            case 'Enter':      event.preventDefault(); choose(state.active); break;
            case 'Backspace':
                event.preventDefault();
                if (state.menu.canGoBack) post('back', {}); else close();
                break;
            case 'Escape':     event.preventDefault(); close(); break;
            default: break;
        }
    });

    /* Timed-action bar. Independent of the menu: it renders while the menu is
       closed and never takes focus, because it is display only. */
    var progressEl = document.getElementById('progress');
    var progressLabel = document.getElementById('progressLabel');
    var progressFill = document.getElementById('progressFill');
    var progressHint = document.getElementById('progressHint');
    var progressTimer = null;

    function progressOpen(data) {
        window.clearTimeout(progressTimer);
        progressLabel.textContent = data.label || 'Working';
        progressHint.hidden = !data.cancel;

        progressEl.hidden = false;
        progressFill.style.transition = 'none';
        progressFill.style.width = '0%';

        /* Two frames: one to apply the reset with no transition, one to start
           the real one. Collapsing these makes the bar jump straight to full. */
        requestAnimationFrame(function () {
            progressEl.dataset.open = 'true';
            requestAnimationFrame(function () {
                progressFill.style.transition = 'width ' + (data.duration || 3000) + 'ms linear';
                progressFill.style.width = '100%';
            });
        });
    }

    function progressClose() {
        progressEl.dataset.open = 'false';
        progressTimer = window.setTimeout(function () {
            progressEl.hidden = true;
            progressFill.style.transition = 'none';
            progressFill.style.width = '0%';
        }, 140);
    }

    /* Duty HUD. Renders from a single state push; the client sends a new one
       whenever anything in it changes rather than on a timer. */
    var hudEl = document.getElementById('hud');
    var hudAgency = document.getElementById('hudAgency');
    var hudCallsign = document.getElementById('hudCallsign');
    var hudStatus = document.getElementById('hudStatus');
    var hudRank = document.getElementById('hudRank');
    var hudCallout = document.getElementById('hudCallout');
    var hudCalloutNumber = document.getElementById('hudCalloutNumber');
    var hudCalloutLabel = document.getElementById('hudCalloutLabel');
    var hudObjectives = document.getElementById('hudObjectives');
    var hudRestrained = document.getElementById('hudRestrained');

    function hudRender(data) {
        if (!data || !data.visible) {
            hudEl.dataset.open = 'false';
            hudEl.hidden = true;
            return;
        }

        hudEl.hidden = false;
        requestAnimationFrame(function () { hudEl.dataset.open = 'true'; });

        hudAgency.textContent = data.agency || 'FED';
        hudCallsign.textContent = data.callsign || '';
        hudStatus.textContent = data.status || '';
        hudStatus.dataset.tone = data.statusTone || 'success';
        hudRank.textContent = data.rank || '';
        hudRestrained.hidden = !data.restrained;

        var callout = data.callout;
        hudCallout.hidden = !callout;
        if (!callout) return;

        hudCalloutNumber.textContent = callout.number || '';
        hudCalloutLabel.textContent = callout.label || '';
        hudObjectives.innerHTML = '';

        (callout.objectives || []).forEach(function (objective) {
            var item = document.createElement('li');
            item.className = 'hud__objective';
            item.dataset.state = objective.state || 'pending';
            item.textContent = objective.label || '';
            hudObjectives.appendChild(item);
        });
    }

    /* Mobile data terminal. Unlike the HUD and the progress bar this one takes
       focus and input: it is the screen an officer reads rather than picks
       from. All content is escaped -- every string in it was typed by a
       player. */
    var mdtEl = document.getElementById('mdt');
    var mdtAgency = document.getElementById('mdtAgency');
    var mdtLogo = document.getElementById('mdtLogo');
    var mdtTitle = document.getElementById('mdtTitle');
    var mdtSubtitle = document.getElementById('mdtSubtitle');
    var mdtNavEl = document.getElementById('mdtNav');
    var mdtCrumbEl = document.getElementById('mdtCrumb');
    var mdtStatusStripEl = document.getElementById('mdtStatusStrip');
    var mdtClockEl = document.getElementById('mdtClock');
    var mdtOfficerEl = document.getElementById('mdtOfficer');
    var mdtTreeEl = document.getElementById('mdtTree');
    var mdtListEl = document.getElementById('mdtList');
    var mdtDetailEl = document.getElementById('mdtDetail');
    var mdtToolbar = document.getElementById('mdtToolbar');
    var mdtSearch = document.getElementById('mdtSearch');
    var mdtStatus = document.getElementById('mdtStatus');
    var mdtDispatchEl = document.getElementById('mdtDispatch');
    var mdtLookupViewEl = document.getElementById('mdtLookupView');
    var mdtRecordsViewEl = document.getElementById('mdtRecordsView');
    var mdtMyCallViewEl = document.getElementById('mdtMyCallView');
    var mdtLookupListEl = document.getElementById('mdtLookupList');
    var mdtLookupDetailEl = document.getElementById('mdtLookupDetail');
    var mdtLookupTermEl = document.getElementById('mdtLookupTerm');

    var MDT_PAGE = 25;
    var mdt = {
        open: false, data: {}, view: 'dispatch', tab: 'incidents',
        selected: null, query: '', filter: null, page: 1, lookupSelected: null
    };

    /* The CAD is workspaces, not tabs: DISPATCH is the live board it lands
       on, LOOKUP is the record search console, RECORDS is the filing room
       (its file tree below), MY CALL is the assigned-call viewer. */
    var MDT_VIEWS = [
        { key: 'dispatch', label: 'DISPATCH', icon: '⌘' },
        { key: 'lookup', label: 'LOOKUP', icon: '🔍' },
        { key: 'records', label: 'RECORDS', icon: '📁' },
        { key: 'mycall', label: 'MY CALL', icon: '📟' }
    ];

    /* The filing room's tree: what each node reads and the filing actions
       its toolbar offers. Status filter chips build themselves from
       whatever pills the rows carry. */
    var MDT_NODES = [
        { key: 'overview', label: 'Overview', icon: '⌂' },
        { key: 'incidents', label: 'Incidents', icon: '📋', search: true, actions: [{ id: 'file', label: '+ New case' }] },
        { key: 'cases', label: 'Case Files', icon: '📌', search: true, actions: [{ id: 'create', label: '+ New case file' }] },
        { key: 'warrants', label: 'Warrants', icon: '📜', search: true, actions: [{ id: 'issue', label: '+ Issue warrant' }] },
        { key: 'bolos', label: 'BOLOs', icon: '🚨', search: true, actions: [{ id: 'new', label: '+ New BOLO' }] },
        { key: 'evidence', label: 'Evidence', icon: '📦', search: true, actions: [{ id: 'log', label: '+ Log evidence' }] },
        { key: 'leads', label: 'Leads', icon: '🧭', search: true, actions: [{ id: 'new', label: '+ New lead' }] },
        { key: 'reports', label: '911 Reports', icon: '📞', search: true },
        { key: 'units', label: 'Units', icon: '👥', search: true },
        { key: 'custody', label: 'Custody', icon: '🔒', search: true }
    ];

    var MDT_STATUSES = [
        { key: 'available', label: 'AVAILABLE' },
        { key: 'enroute', label: 'EN ROUTE' },
        { key: 'onscene', label: 'ON SCENE' },
        { key: 'busy', label: 'BUSY' },
        { key: 'panic', label: 'PANIC', danger: true }
    ];

    function mdtRows(key) {
        var rows = mdt.data[key];
        return Array.isArray(rows) ? rows : [];
    }

    /* Pills that mean "this record is done": hidden by default so the
       working view never silts up, reachable through the Closed toggle or
       an explicit status chip. */
    var MDT_DONE_PILLS = { closed: true, void: true, served: true, worked: true };

    function mdtRowDone(row) {
        return MDT_DONE_PILLS[String(row.pill || '').toLowerCase()] === true;
    }

    function mdtVisibleRows(key) {
        var rows = mdtRows(key);

        if (mdt.filter) {
            rows = rows.filter(function (row) { return String(row.pill || '') === mdt.filter; });
        } else if (!mdt.showClosed) {
            rows = rows.filter(function (row) { return !mdtRowDone(row); });
        }

        if (mdt.query) {
            var needle = mdt.query.toLowerCase();
            rows = rows.filter(function (row) {
                return [row.title, row.meta, row.pill].some(function (field) {
                    return field && String(field).toLowerCase().indexOf(needle) !== -1;
                });
            });
        }

        return rows;
    }

    /* The slice of visible rows the current page shows; selection indexes
       into this slice, so a click always resolves the row it landed on. */
    function mdtPage(key) {
        var rows = mdtVisibleRows(key);
        var pages = Math.max(1, Math.ceil(rows.length / MDT_PAGE));
        if (mdt.page > pages) mdt.page = pages;
        var start = (mdt.page - 1) * MDT_PAGE;
        return { rows: rows.slice(start, start + MDT_PAGE), total: rows.length, pages: pages };
    }

    function mdtRenderNav() {
        mdtNavEl.innerHTML = '';
        MDT_VIEWS.forEach(function (view) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mdt__navBtn';
            button.dataset.view = view.key;
            button.setAttribute('aria-selected', String(view.key === mdt.view));
            var badge = '';
            if (view.key === 'mycall' && mdt.data.myCall) badge = '<span class="mdt__navDot"></span>';
            button.innerHTML = '<span class="mdt__navIcon">' + view.icon + '</span>'
                + '<span>' + escapeHtml(view.label) + '</span>' + badge;
            mdtNavEl.appendChild(button);
        });
    }

    function mdtRenderTree() {
        mdtTreeEl.innerHTML = '';
        MDT_NODES.forEach(function (node) {
            if (!mdt.data[node.key]) return;
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mdt__treeNode';
            button.dataset.tab = node.key;
            button.setAttribute('aria-selected', String(node.key === mdt.tab));
            var isList = Array.isArray(mdt.data[node.key]) && node.key !== 'overview';
            button.innerHTML = '<span class="mdt__treeIcon">' + node.icon + '</span>'
                + '<span class="mdt__treeLabel">' + escapeHtml(node.label) + '</span>'
                + (isList ? '<span class="mdt__tabCount">' + mdtRows(node.key).length + '</span>' : '');
            mdtTreeEl.appendChild(button);
        });
    }

    function mdtRenderStatusStrip() {
        mdtStatusStripEl.innerHTML = '';
        MDT_STATUSES.forEach(function (status) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mdt__statusBtn' + (status.danger ? ' mdt__statusBtn--danger' : '');
            button.dataset.status = status.key;
            button.setAttribute('aria-pressed', String(mdt.data.myStatus === status.key));
            button.textContent = status.label;
            mdtStatusStripEl.appendChild(button);
        });
    }

    function mdtRenderBrand() {
        var brand = mdt.data.brand || {};
        mdtAgency.textContent = brand.short || mdt.data.agency || 'FED';
        mdtTitle.textContent = (brand.label || mdt.data.title || 'Computer Aided Dispatch');
        var officer = mdt.data.officer || {};
        mdtSubtitle.textContent = [mdt.data.subtitle, officer.division, officer.station]
            .filter(Boolean).join(' | ');

        if (brand.logo && /^https:\/\//.test(brand.logo)) {
            mdtLogo.src = brand.logo;
            mdtLogo.hidden = false;
            mdtLogo.onerror = function () { mdtLogo.hidden = true; };
        } else {
            mdtLogo.hidden = true;
        }

        /* The agency colour becomes the terminal's accent, so each agency's
           CAD reads as its own system. Soft variant = same hue, low alpha. */
        if (/^#[0-9a-fA-F]{6}$/.test(brand.color || '')) {
            mdtEl.style.setProperty('--menu-accent', brand.color);
            mdtEl.style.setProperty('--menu-accent-soft', brand.color + '2b');
        } else {
            mdtEl.style.removeProperty('--menu-accent');
            mdtEl.style.removeProperty('--menu-accent-soft');
        }

        var officer = mdt.data.officer;
        mdtOfficerEl.textContent = officer
            ? ((officer.callsign ? officer.callsign + ' · ' : '') + (officer.name || '') + (officer.rank ? ' · ' + officer.rank : ''))
            : '';
    }

    /* DISPATCH board: active calls and active units as tables beside the
       live map, the way a dispatch seat actually reads. */
    var MDT_PRIORITY_LABELS = { 1: 'HIGH', 2: 'MED', 3: 'LOW' };

    function mdtRenderDispatch() {
        var map = mdt.data.map || {};
        var calls = map.calls || [];
        var units = (map.units || []).filter(function (unit) { return unit.coords; });

        document.getElementById('mdtCallCount').textContent = calls.length;
        document.getElementById('mdtUnitCount').textContent = units.length;

        var callsBody = document.getElementById('mdtCallsBody');
        callsBody.innerHTML = '';
        if (!calls.length) {
            callsBody.innerHTML = '<tr class="mdt__trEmpty"><td colspan="4">No active calls</td></tr>';
        }
        calls.forEach(function (call, index) {
            var tr = document.createElement('tr');
            tr.dataset.call = String(index);
            tr.innerHTML = '<td class="mdt__tdMono">' + escapeHtml(call.number || 'CALL') + '</td>'
                + '<td>' + escapeHtml(call.label || '') + '</td>'
                + '<td><span class="mdt__prio mdt__prio--' + (call.priority || 2) + '">'
                + (MDT_PRIORITY_LABELS[call.priority] || 'MED') + '</span></td>'
                + '<td>' + (call.assigned > 0 ? call.assigned : '<span class="mdt__tdWarn">UNASSIGNED</span>') + '</td>';
            callsBody.appendChild(tr);
        });

        var unitsBody = document.getElementById('mdtUnitsBody');
        unitsBody.innerHTML = '';
        if (!units.length) {
            unitsBody.innerHTML = '<tr class="mdt__trEmpty"><td colspan="4">Nobody on the street</td></tr>';
        }
        units.forEach(function (unit, index) {
            var isSelf = map.self && Number(unit.source) === Number(map.self);
            var tr = document.createElement('tr');
            tr.dataset.unit = String(index);
            if (isSelf) tr.className = 'mdt__trSelf';
            tr.innerHTML = '<td class="mdt__tdMono">' + escapeHtml(unit.callsign || '?') + '</td>'
                + '<td>' + escapeHtml(unit.name || '') + (isSelf ? ' <span class="mdt__you">YOU</span>' : '') + '</td>'
                + '<td>' + escapeHtml(unit.division || '-') + '</td>'
                + '<td><span class="mdt__unitDot" style="background:' + (MAP_STATUS_COLORS[unit.status] || '#4ade80') + '"></span>'
                + escapeHtml(String(unit.status || 'available').toUpperCase()) + '</td>';
            unitsBody.appendChild(tr);
        });
    }

    /* MY CALL: the assigned call rendered as a call viewer, cards not rows. */
    function mdtRenderMyCall() {
        var call = mdt.data.myCall;
        if (!call) {
            mdtMyCallViewEl.innerHTML = '<div class="mdt__noCall">'
                + '<div class="mdt__noCallIcon">📟</div>'
                + '<div class="mdt__noCallTitle">No active call</div>'
                + '<div class="mdt__noCallSub">When dispatch assigns you to a callout it appears here.</div></div>';
            return;
        }

        var unitLines = (call.units || []).map(function (unit) {
            return '<div class="mdt__cvUnit">🚔 ' + escapeHtml(unit) + '</div>';
        }).join('') || '<div class="mdt__cvUnit">-</div>';

        var grid = call.location
            ? ('X ' + Math.round(call.location.x) + ' &middot; Y ' + Math.round(call.location.y))
            : '-';

        mdtMyCallViewEl.innerHTML =
            '<div class="mdt__cvHead">'
            + '<div><div class="mdt__cvTitle">CALL VIEWER</div>'
            + '<div class="mdt__cvPills"><span class="mdt__pill mdt__pill--accent">' + escapeHtml(String(call.status || 'active').toUpperCase()) + '</span>'
            + '<span class="mdt__prio mdt__prio--' + (call.priority || 2) + '">PRIORITY ' + (call.priority || 2) + '</span></div></div>'
            + '<button type="button" class="mdt__go" data-mycall="waypoint">SET WAYPOINT ➤</button>'
            + '</div>'
            + '<div class="mdt__cvGrid">'
            + '<div class="mdt__cvCard"><div class="mdt__cvCardHead">☎ CALL</div>'
            + '<div class="mdt__cvBig">' + escapeHtml(call.number || '') + '</div>'
            + '<div class="mdt__cvLine">' + escapeHtml(call.label || '') + '</div></div>'
            + '<div class="mdt__cvCard"><div class="mdt__cvCardHead">📍 LOCATION</div>'
            + '<div class="mdt__cvBig">' + grid + '</div>'
            + '<div class="mdt__cvLine">Use the waypoint button to route</div></div>'
            + '<div class="mdt__cvCard"><div class="mdt__cvCardHead">👥 UNITS ASSIGNED</div>' + unitLines + '</div>'
            + '<div class="mdt__cvCard mdt__cvCard--wide"><div class="mdt__cvCardHead">📄 CALL DESCRIPTION</div>'
            + '<div class="mdt__cvLine">' + escapeHtml(call.description || 'Details develop at the scene.') + '</div></div>'
            + '</div>';
    }

    /* Live map ----------------------------------------------------------- */
    /* A stylised tactical chart of San Andreas drawn in world coordinates
       (SVG y is flipped), with the agency's units and active calls plotted
       live. Unit positions stream in over 'mdt:map' pushes while open. */

    var mdtMapEl = document.getElementById('mdtMap');
    var mapBuilt = false;
    var mapUnitsLayer = null;
    var mapCallsLayer = null;
    var mapStatusEl = null;
    var mapCardEl = null;
    var mapPanMoved = false;
    /* Fraction of the full map the viewport currently shows: markers and
       their labels multiply by this so they stay screen-sized as you zoom. */
    var mapZoom = 1;
    var mapFocusFn = null;

    function mapShowCard(lines) {
        if (!mapCardEl) return;
        delete mapCardEl.dataset.callId;
        mapCardEl.innerHTML = lines.map(function (line, index) {
            return '<div class="' + (index === 0 ? 'mdt__mapCardTitle' : 'mdt__mapCardLine') + '">'
                + escapeHtml(line) + '</div>';
        }).join('');
        mapCardEl.hidden = false;
    }

    /* A call's card carries its dispatch actions: respond, route, paper it.
       Incident-scene markers only route (they already ARE the paper). */
    function mapShowCallCard(call) {
        if (!mapCardEl) return;
        mapCardEl.dataset.callId = String(call.id);
        var kindLine = call.kind === 'report' ? '911 report'
            : call.kind === 'incident' ? 'Incident scene' : 'Callout';

        var html =
            '<div class="mdt__mapCardTitle">' + escapeHtml((call.number || 'CALL') + ' - ' + (call.label || '')) + '</div>'
            + '<div class="mdt__mapCardLine">Priority ' + (call.priority || 2) + ' | ' + kindLine + '</div>';
        if (call.desc) html += '<div class="mdt__mapCardLine mdt__mapCardDesc">' + escapeHtml(call.desc) + '</div>';
        (call.parties || []).forEach(function (party) {
            html += '<div class="mdt__mapCardLine">' + escapeHtml(party) + '</div>';
        });
        html += '<div class="mdt__mapCardLine">' + (call.assigned > 0 ? call.assigned + ' unit(s) assigned' : 'Unassigned') + '</div>'
            + '<div class="mdt__mapCardActions">'
            + (call.kind !== 'incident' ? '<button type="button" class="mdt__cardBtn" data-dispatch="respond">RESPOND</button>' : '')
            + '<button type="button" class="mdt__cardBtn" data-dispatch="waypoint">WAYPOINT</button>'
            + (call.kind !== 'incident' ? '<button type="button" class="mdt__cardBtn" data-dispatch="incident">OPEN INCIDENT</button>' : '')
            + '</div>';
        mapCardEl.innerHTML = html;
        mapCardEl.hidden = false;
    }

    /* The shipped ui/map.jpg is the standard square 8192px full-map render;
       these bounds are the world extent it covers (derived from the classic
       phone-GPS Leaflet transform 0.02072/117.3, -0.0205/172.8). If markers
       ever sit visibly offset from where units really stand, nudge these. */
    var MAP_IMAGE_BOUNDS = { minX: -5661.6, maxX: 6694.0, minY: -4059.1, maxY: 8429.9 };

    var MAP_LAND = [
        [-1950, -3100], [-1500, -3250], [-1000, -3450], [-450, -3570], [150, -3620],
        [550, -3480], [850, -3300], [1150, -3050], [1400, -2850], [1700, -2600],
        [2100, -2100], [2450, -1700], [2750, -1150], [2950, -650], [3100, 0],
        [3200, 700], [3400, 1300], [3550, 1750], [3400, 2350], [3300, 2850],
        [3550, 3350], [3850, 3950], [3700, 4500], [3500, 5050], [3350, 5550],
        [3150, 5900], [2800, 6250], [2400, 6500], [1950, 6700], [1500, 6850],
        [1000, 7100], [500, 7350], [50, 7400], [-450, 7380], [-950, 7280],
        [-1400, 7050], [-1800, 6800], [-2200, 6400], [-2550, 5950], [-2850, 5350],
        [-3100, 4850], [-3350, 4250], [-3500, 3650], [-3550, 3100], [-3400, 2500],
        [-3300, 2050], [-3500, 1500], [-3550, 1000], [-3350, 500], [-3150, 50],
        [-2950, -450], [-2650, -950], [-2350, -1350], [-2100, -1750], [-2000, -2400]
    ];

    /* Major arteries, drawn faint: the LS ring, the Senora freeway north, and
       Route 68 east-west. Approximate on purpose - they orient, not navigate. */
    var MAP_ROADS = [
        [[-1600, -900], [-900, -1500], [-200, -1900], [600, -1900], [1150, -1500], [1200, -700], [800, -200], [0, 100], [-900, -100], [-1500, -450], [-1600, -900]],
        [[1200, -700], [1400, 300], [1600, 1300], [2000, 2400], [2200, 3300], [1900, 4200], [1700, 5100], [1200, 6100], [400, 6800]],
        [[-2900, 1400], [-2000, 1900], [-1000, 2300], [0, 2650], [1100, 2850], [2200, 3300]]
    ];

    var MAP_STATUS_COLORS = {
        available: '#4ade80', enroute: '#4c8dff', onscene: '#8ab4ff',
        busy: '#fbbf24', panic: '#ff6b6b', offduty: '#8b93a1'
    };

    var MAP_PRIORITY_COLORS = { 1: '#ff6b6b', 2: '#fbbf24', 3: '#4c8dff' };

    function svgEl(name, attrs) {
        var el = document.createElementNS('http://www.w3.org/2000/svg', name);
        Object.keys(attrs || {}).forEach(function (key) { el.setAttribute(key, attrs[key]); });
        return el;
    }

    function mapBuild() {
        if (mapBuilt) return;
        mapBuilt = true;

        /* Framed to the full extent of the shipped map render. */
        var svg = svgEl('svg', {
            viewBox: MAP_IMAGE_BOUNDS.minX + ' ' + (-MAP_IMAGE_BOUNDS.maxY) + ' '
                + (MAP_IMAGE_BOUNDS.maxX - MAP_IMAGE_BOUNDS.minX) + ' '
                + (MAP_IMAGE_BOUNDS.maxY - MAP_IMAGE_BOUNDS.minY),
            preserveAspectRatio: 'xMidYMid meet',
            class: 'mdt__mapSvg'
        });

        svg.appendChild(svgEl('rect', {
            x: MAP_IMAGE_BOUNDS.minX, y: -MAP_IMAGE_BOUNDS.maxY,
            width: MAP_IMAGE_BOUNDS.maxX - MAP_IMAGE_BOUNDS.minX,
            height: MAP_IMAGE_BOUNDS.maxY - MAP_IMAGE_BOUNDS.minY,
            fill: '#0a111b'
        }));

        var points = MAP_LAND.map(function (p) { return p[0] + ',' + (-p[1]); }).join(' ');
        svg.appendChild(svgEl('polygon', {
            points: points, fill: '#161f2a', stroke: '#2b3a4a', 'stroke-width': 30
        }));

        /* Alamo Sea and the Zancudo river mouth */
        svg.appendChild(svgEl('ellipse', {
            cx: 1350, cy: -4050, rx: 950, ry: 480, fill: '#0a111b', stroke: '#2b3a4a', 'stroke-width': 20
        }));
        svg.appendChild(svgEl('ellipse', {
            cx: -2100, cy: -2900, rx: 380, ry: 220, fill: '#0a111b', stroke: '#2b3a4a', 'stroke-width': 16
        }));

        /* Roads */
        var roads = svgEl('g', {
            stroke: 'rgba(255,255,255,0.07)', 'stroke-width': 55, fill: 'none', 'stroke-linecap': 'round'
        });
        MAP_ROADS.forEach(function (road) {
            roads.appendChild(svgEl('polyline', {
                points: road.map(function (p) { return p[0] + ',' + (-p[1]); }).join(' ')
            }));
        });
        svg.appendChild(roads);

        /* Grid */
        var grid = svgEl('g', { stroke: 'rgba(255,255,255,0.04)', 'stroke-width': 8 });
        for (var gx = -4000; gx <= 4500; gx += 1000) {
            grid.appendChild(svgEl('line', { x1: gx, y1: -8300, x2: gx, y2: 4400 }));
        }
        for (var gy = -4000; gy <= 8000; gy += 1000) {
            grid.appendChild(svgEl('line', { x1: -4300, y1: -gy, x2: 4700, y2: -gy }));
        }
        svg.appendChild(grid);

        /* The real map render: covers the vector chart entirely on load and
           falls back to it silently if the image cannot load. */
        var satellite = svgEl('image', {
            x: MAP_IMAGE_BOUNDS.minX,
            y: -MAP_IMAGE_BOUNDS.maxY,
            width: MAP_IMAGE_BOUNDS.maxX - MAP_IMAGE_BOUNDS.minX,
            height: MAP_IMAGE_BOUNDS.maxY - MAP_IMAGE_BOUNDS.minY,
            href: 'map.jpg',
            preserveAspectRatio: 'none'
        });
        satellite.addEventListener('error', function () { satellite.remove(); });
        svg.appendChild(satellite);

        mapCallsLayer = svgEl('g', {});
        mapUnitsLayer = svgEl('g', {});
        svg.appendChild(mapCallsLayer);
        svg.appendChild(mapUnitsLayer);
        mdtMapEl.appendChild(svg);

        mapStatusEl = document.createElement('div');
        mapStatusEl.className = 'mdt__mapStatus';
        mdtMapEl.appendChild(mapStatusEl);

        mapCardEl = document.createElement('div');
        mapCardEl.className = 'mdt__mapCard';
        mapCardEl.hidden = true;
        mdtMapEl.appendChild(mapCardEl);

        /* A call card's action buttons go to the Lua dispatch handler. */
        mapCardEl.addEventListener('click', function (event) {
            var button = event.target.closest('.mdt__cardBtn');
            if (!button || !mapCardEl.dataset.callId) return;
            post('mdtAction', { tab: 'dispatch', id: mapCardEl.dataset.callId, action: button.dataset.dispatch });
        });

        /* Clicking water/land dismisses the detail card - but not at the end
           of a pan drag. */
        svg.addEventListener('click', function (event) {
            if (mapPanMoved) { mapPanMoved = false; return; }
            if (event.target === svg || event.target.tagName === 'polygon'
                || event.target.tagName === 'rect' || event.target.tagName === 'image') {
                mapCardEl.hidden = true;
            }
        });

        /* Zoom to the cursor with the wheel, drag to pan, double-click to
           reset. Everything is viewBox math clamped to the map's extent. */
        var base = {
            x: MAP_IMAGE_BOUNDS.minX, y: -MAP_IMAGE_BOUNDS.maxY,
            w: MAP_IMAGE_BOUNDS.maxX - MAP_IMAGE_BOUNDS.minX,
            h: MAP_IMAGE_BOUNDS.maxY - MAP_IMAGE_BOUNDS.minY
        };
        var view = { x: base.x, y: base.y, w: base.w, h: base.h };
        var applyView = function () {
            svg.setAttribute('viewBox', view.x + ' ' + view.y + ' ' + view.w + ' ' + view.h);
            var zoom = view.w / base.w;
            if (Math.abs(zoom - mapZoom) > 0.001) {
                mapZoom = zoom;
                /* Redraw markers at the new scale so they stay readable
                   instead of ballooning as the world shrinks. */
                var data = mdt.data.map || {};
                mapRenderCalls(data.calls);
                mapRenderUnits(data.units, data.self);
            }
        };

        /* Jump-zoom to a point: what a dispatch row click uses. */
        mapFocusFn = function (coords) {
            if (!coords) return;
            var w = base.w / 10;
            var h = w * (base.h / base.w);
            view.w = w;
            view.h = h;
            view.x = Math.min(Math.max((Number(coords.x) || 0) - w / 2, base.x), base.x + base.w - w);
            view.y = Math.min(Math.max((-(Number(coords.y) || 0)) - h / 2, base.y), base.y + base.h - h);
            applyView();
        };

        svg.addEventListener('wheel', function (event) {
            event.preventDefault();
            event.stopPropagation();
            var rect = svg.getBoundingClientRect();
            var px = (event.clientX - rect.left) / rect.width;
            var py = (event.clientY - rect.top) / rect.height;
            var factor = event.deltaY > 0 ? 1.25 : 0.8;
            var w = Math.min(base.w, Math.max(base.w / 24, view.w * factor));
            var h = w * (base.h / base.w);
            view.x = Math.min(Math.max(view.x + (view.w - w) * px, base.x), base.x + base.w - w);
            view.y = Math.min(Math.max(view.y + (view.h - h) * py, base.y), base.y + base.h - h);
            view.w = w;
            view.h = h;
            applyView();
        }, { passive: false });

        var panning = null;
        svg.addEventListener('mousedown', function (event) {
            panning = { x: event.clientX, y: event.clientY, vx: view.x, vy: view.y };
        });
        window.addEventListener('mousemove', function (event) {
            if (!panning) return;
            var rect = svg.getBoundingClientRect();
            var dx = (event.clientX - panning.x) * (view.w / rect.width);
            var dy = (event.clientY - panning.y) * (view.h / rect.height);
            if (Math.abs(event.clientX - panning.x) + Math.abs(event.clientY - panning.y) > 4) mapPanMoved = true;
            view.x = Math.min(Math.max(panning.vx - dx, base.x), base.x + base.w - view.w);
            view.y = Math.min(Math.max(panning.vy - dy, base.y), base.y + base.h - view.h);
            applyView();
        });
        window.addEventListener('mouseup', function () { panning = null; });
        svg.addEventListener('dblclick', function () {
            view = { x: base.x, y: base.y, w: base.w, h: base.h };
            applyView();
        });

        var legend = document.createElement('div');
        legend.className = 'mdt__mapLegend';
        legend.innerHTML =
            '<span><i style="background:#4ade80"></i>Available</span>'
            + '<span><i style="background:#4c8dff"></i>En route / on scene</span>'
            + '<span><i style="background:#fbbf24"></i>Busy</span>'
            + '<span><i style="background:#ff6b6b"></i>Panic / priority call</span>';
        mdtMapEl.appendChild(legend);
    }

    function mapRenderCalls(calls) {
        if (!mapCallsLayer) return;
        mapCallsLayer.innerHTML = '';
        var s = mapZoom;
        (calls || []).forEach(function (call) {
            if (!call.coords) return;
            var x = Number(call.coords.x) || 0;
            var y = -(Number(call.coords.y) || 0);
            var color = call.kind === 'incident' ? '#8ab4ff' : (MAP_PRIORITY_COLORS[call.priority] || '#4c8dff');

            var group = svgEl('g', { class: 'mdt__mapCall' });
            group.appendChild(svgEl('circle', { cx: x, cy: y, r: 220 * s, fill: 'none', stroke: color, 'stroke-width': 18 * s, class: 'mdt__mapPulse' }));
            group.appendChild(svgEl('rect', {
                x: x - 90 * s, y: y - 90 * s, width: 180 * s, height: 180 * s,
                fill: color, transform: 'rotate(45 ' + x + ' ' + y + ')'
            }));
            var label = svgEl('text', {
                x: x, y: y + 360 * s, 'text-anchor': 'middle',
                fill: color, 'font-size': 190 * s, 'font-weight': 700
            });
            label.textContent = call.number || 'CALL';
            group.appendChild(label);
            group.addEventListener('click', function () { mapShowCallCard(call); });
            mapCallsLayer.appendChild(group);
        });
    }

    function mapRenderUnits(units, selfId) {
        if (!mapUnitsLayer) return;
        mapUnitsLayer.innerHTML = '';
        var count = 0;
        var s = mapZoom;
        (units || []).forEach(function (unit) {
            if (!unit.coords) return;
            count += 1;
            var x = Number(unit.coords.x) || 0;
            var y = -(Number(unit.coords.y) || 0);
            var color = MAP_STATUS_COLORS[unit.status] || '#4ade80';
            var isSelf = selfId && Number(unit.source) === Number(selfId);

            var group = svgEl('g', {});
            if (isSelf) {
                group.appendChild(svgEl('circle', { cx: x, cy: y, r: 200 * s, fill: 'none', stroke: '#ffffff', 'stroke-width': 22 * s, opacity: 0.7 }));
            }
            if (unit.status === 'panic') {
                group.appendChild(svgEl('circle', { cx: x, cy: y, r: 260 * s, fill: 'none', stroke: color, 'stroke-width': 20 * s, class: 'mdt__mapPulse' }));
            }
            group.appendChild(svgEl('circle', { cx: x, cy: y, r: 110 * s, fill: color, stroke: '#0a111b', 'stroke-width': 25 * s }));
            var label = svgEl('text', {
                x: x, y: y - 190 * s, 'text-anchor': 'middle',
                fill: '#e8edf4', 'font-size': 200 * s, 'font-weight': 600
            });
            label.textContent = unit.callsign || unit.name || ('#' + unit.source);
            group.appendChild(label);
            group.addEventListener('click', function () {
                mapShowCard([
                    (unit.callsign || '?') + ' - ' + (unit.name || 'Unknown'),
                    'Status: ' + (unit.status || 'available'),
                    unit.division ? ('Division: ' + unit.division) : 'No division',
                    unit.rank ? ('Rank: ' + unit.rank) : '',
                    isSelf ? 'This is you' : ''
                ].filter(function (line) { return line !== ''; }));
            });
            mapUnitsLayer.appendChild(group);
        });

        if (mapStatusEl) {
            var callCount = ((mdt.data.map || {}).calls || []).length;
            mapStatusEl.innerHTML = '<span class="mdt__mapLive"></span>LIVE - '
                + count + ' unit(s) on the street, ' + callCount + ' active call(s)';
        }
    }

    function mapRender() {
        mapBuild();
        var data = mdt.data.map || {};
        mapRenderCalls(data.calls);
        mapRenderUnits(data.units, data.self);
    }

    var mdtFiltersEl = document.getElementById('mdtFilters');
    var mdtPagerEl = document.getElementById('mdtPager');
    var mdtPageInfoEl = document.getElementById('mdtPageInfo');
    var mdtTabActionsEl = document.getElementById('mdtTabActions');

    function mdtRenderFilters() {
        /* Chips build themselves from the statuses actually present, so any
           tab whose rows carry two or more distinct pills gets a filter row
           for free. */
        var pills = {};
        var order = [];
        var hasDone = false;
        mdtRows(mdt.tab).forEach(function (row) {
            var pill = String(row.pill || '');
            if (pill && !pills[pill]) { pills[pill] = true; order.push(pill); }
            if (mdtRowDone(row)) hasDone = true;
        });

        if (order.length < 2 && !hasDone) {
            mdtFiltersEl.hidden = true;
            mdtFiltersEl.innerHTML = '';
            if (mdt.filter) mdt.filter = null;
            return;
        }

        mdtFiltersEl.hidden = false;
        mdtFiltersEl.innerHTML = '';

        var all = document.createElement('button');
        all.type = 'button';
        all.className = 'mdt__chip';
        all.textContent = 'All';
        all.setAttribute('aria-pressed', String(mdt.filter === null));
        all.dataset.filter = '';
        mdtFiltersEl.appendChild(all);

        order.forEach(function (pill) {
            var chip = document.createElement('button');
            chip.type = 'button';
            chip.className = 'mdt__chip';
            chip.textContent = pill;
            chip.dataset.filter = pill;
            chip.setAttribute('aria-pressed', String(mdt.filter === pill));
            mdtFiltersEl.appendChild(chip);
        });

        /* Done records (closed, void, served...) hide by default; this chip
           lets them back in without picking each status one by one. */
        if (hasDone) {
            var toggle = document.createElement('button');
            toggle.type = 'button';
            toggle.className = 'mdt__chip mdt__chip--toggle';
            toggle.textContent = mdt.showClosed ? 'Hiding nothing' : 'Closed hidden';
            toggle.dataset.toggleClosed = 'true';
            toggle.setAttribute('aria-pressed', String(!!mdt.showClosed));
            mdtFiltersEl.appendChild(toggle);
        }
    }

    function mdtRenderList() {
        var definition = MDT_NODES.filter(function (tab) { return tab.key === mdt.tab; })[0] || {};
        var tabActions = definition.actions || [];
        mdtToolbar.hidden = !definition.search && !tabActions.length;
        mdtSearch.hidden = !definition.search;

        mdtTabActionsEl.innerHTML = '';
        tabActions.forEach(function (action) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mdt__tabAction';
            button.textContent = action.label;
            button.dataset.action = action.id;
            mdtTabActionsEl.appendChild(button);
        });

        mdtRenderFilters();

        var page = mdtPage(mdt.tab);
        mdtListEl.innerHTML = '';

        if (!page.rows.length) {
            var empty = document.createElement('li');
            empty.className = 'mdt__empty';
            empty.textContent = (mdt.query || mdt.filter) ? 'Nothing matches.' : 'Nothing on file.';
            mdtListEl.appendChild(empty);
        }

        page.rows.forEach(function (row, index) {
            var item = document.createElement('li');
            item.className = 'mdt__row';
            item.dataset.index = String(index);
            item.setAttribute('aria-selected', String(index === mdt.selected));

            var pill = row.pill
                ? '<span class="mdt__pill' + (row.tone ? ' mdt__pill--' + escapeHtml(row.tone) : '') + '">'
                    + escapeHtml(row.pill) + '</span>'
                : '';

            item.innerHTML = '<div class="mdt__rowTitle"><span>' + escapeHtml(row.title || '') + '</span>'
                + pill + '</div>'
                + (row.meta ? '<div class="mdt__rowMeta">' + escapeHtml(row.meta) + '</div>' : '');
            mdtListEl.appendChild(item);
        });

        mdtPagerEl.hidden = page.pages <= 1;
        if (page.pages > 1) {
            mdtPageInfoEl.textContent = 'Page ' + mdt.page + ' / ' + page.pages + ' - ' + page.total + ' entries';
            document.getElementById('mdtPrev').disabled = mdt.page <= 1;
            document.getElementById('mdtNext').disabled = mdt.page >= page.pages;
        }
    }

    /* Markdown-lite for narratives and notes: **bold**, *italic*, "- " lists
       and line breaks - enough to write a structured report, nothing more.
       Escapes first, so markup is styling and never HTML injection. */
    function richText(text) {
        var safe = escapeHtml(String(text || ''));
        safe = safe.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
        safe = safe.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');
        var lines = safe.split('\n').map(function (line) {
            if (/^\s*-\s+/.test(line)) return '<div class="mdt__bullet">' + line.replace(/^\s*-\s+/, '') + '</div>';
            return line;
        });
        return lines.join('<br>').replace(/<\/div><br>/g, '</div>');
    }

    /* One detail renderer for every workspace: the records room and the
       lookup console both hand it a row and get the same document back.
       When the row carries a document, its sections render INSIDE the paper
       as parts of the report; otherwise they render as data cards. */
    function mdtSectionsHtml(row) {
        var html = '';

        /* Personnel header: portrait, name and rank, the callsign large,
           the status as a chip - a file cover, not a grid of cells. */
        if (row.unitCard) {
            var card = row.unitCard;
            var portrait = (card.photo && (/^https:\/\//.test(card.photo) || /^data:image\//.test(card.photo)))
                ? '<img class="mdt__unitPhoto" src="' + escapeHtml(card.photo) + '" onerror="this.remove()">'
                : '<div class="mdt__unitPhoto mdt__unitPhoto--empty">NO<br>PHOTO</div>';
            var lines = '';
            [['POSTING', card.station], ['DIVISION', card.division],
                ['DIVISION RANK', card.divisionRank], ['ON THE AIR', card.onAir]].forEach(function (pair) {
                if (pair[1]) {
                    lines += '<div class="mdt__unitLine"><span>' + pair[0] + '</span>' + escapeHtml(pair[1]) + '</div>';
                }
            });
            html += '<div class="mdt__unitHead">'
                + portrait
                + '<div class="mdt__unitId">'
                + '<div class="mdt__unitName">' + escapeHtml(card.name || '') + '</div>'
                + '<div class="mdt__unitRank">' + escapeHtml(card.rank || '') + '</div>'
                + lines
                + '</div>'
                + '<div class="mdt__unitSide">'
                + '<div class="mdt__unitCallsign">' + escapeHtml(card.callsign || '?') + '</div>'
                + '<div class="mdt__unitStatus mdt__unitStatus--' + escapeHtml(card.statusTone || 'plain') + '">'
                + escapeHtml(card.status || '') + '</div>'
                + '</div></div>';
        }

        (row.sections || []).forEach(function (section) {
            /* Empty values do not render as blank rows. */
            var fields = (section.fields || []).filter(function (field) {
                return field.value !== undefined && field.value !== null && String(field.value) !== '';
            });
            var notes = section.notes || [];
            if (!fields.length && !notes.length) return;

            html += '<div class="mdt__secCard">'
                + (section.label ? '<div class="mdt__section">' + escapeHtml(section.label) + '</div>' : '');
            if (fields.length) {
                html += '<div class="mdt__fieldGrid">';
                fields.forEach(function (field) {
                    /* A field that references another record renders as a
                       live link: click it and the CAD opens that record. */
                    var value;
                    if (field.link && field.link.tab && field.link.id) {
                        value = '<button type="button" class="mdt__fieldLink" data-jump-tab="'
                            + escapeHtml(field.link.tab) + '" data-jump-id="' + escapeHtml(field.link.id) + '">'
                            + escapeHtml(field.value) + ' &#8599;</button>';
                    } else if (field.link && field.link.lookup) {
                        value = '<button type="button" class="mdt__fieldLink" data-jump-lookup="'
                            + escapeHtml(field.link.lookup) + '">'
                            + escapeHtml(field.value) + ' &#8599;</button>';
                    } else {
                        value = escapeHtml(field.value);
                    }
                    html += '<div class="mdt__field"><span class="mdt__fieldLabel">'
                        + escapeHtml(field.label || '') + '</span><span class="mdt__fieldValue">'
                        + value + '</span></div>';
                });
                html += '</div>';
            }
            notes.forEach(function (note) {
                html += '<div class="mdt__note">'
                    + (note.meta ? '<div class="mdt__noteMeta">' + escapeHtml(note.meta) + '</div>' : '')
                    + richText(note.text) + '</div>';
            });
            html += '</div>';
        });

        /* The equipment manifest: what the unit has out of the stores, with
           the inventory's own item pictures, a plate chip for the vehicle,
           and drawn times. */
        if (row.kit) {
            var kit = row.kit;
            var kitHtml = '';
            if (kit.vehicle) {
                kitHtml += '<div class="mdt__kitRow">'
                    + '<span class="mdt__kitIcon">🚔</span>'
                    + '<span class="mdt__kitInfo"><span class="mdt__kitName">' + escapeHtml(kit.vehicle.label || '') + '</span>'
                    + '<span class="mdt__kitMeta">' + escapeHtml((kit.vehicle.model || '') + (kit.vehicle.at ? ' · drawn ' + kit.vehicle.at : '')) + '</span></span>'
                    + (kit.vehicle.plate ? '<span class="mdt__plate">' + escapeHtml(kit.vehicle.plate) + '</span>' : '')
                    + '</div>';
            }
            if (kit.uniform) {
                kitHtml += '<div class="mdt__kitRow">'
                    + '<span class="mdt__kitIcon">👕</span>'
                    + '<span class="mdt__kitInfo"><span class="mdt__kitName">' + escapeHtml(kit.uniform.label || '') + '</span>'
                    + '<span class="mdt__kitMeta">' + escapeHtml(kit.uniform.at ? 'Worn since ' + kit.uniform.at : 'Current uniform') + '</span></span>'
                    + '</div>';
            }
            (kit.items || []).forEach(function (line) {
                var picture = '<span class="mdt__kitIcon">📦</span>';
                if (mdt.data.itemImages && line.item) {
                    picture = '<span class="mdt__kitIcon" hidden>📦</span>'
                        + '<img class="mdt__kitImg" src="' + escapeHtml(mdt.data.itemImages + line.item + '.png') + '"'
                        + ' onerror="this.previousElementSibling.hidden=false;this.remove()">';
                }
                kitHtml += '<div class="mdt__kitRow">'
                    + picture
                    + '<span class="mdt__kitInfo"><span class="mdt__kitName">' + escapeHtml(line.label || '') + '</span>'
                    + '<span class="mdt__kitMeta">' + escapeHtml(line.at ? 'Last drawn ' + line.at : 'Issued') + '</span></span>'
                    + (line.count > 1 ? '<span class="mdt__kitCount">x' + line.count + '</span>' : '')
                    + '</div>';
            });
            if (kit.more) {
                kitHtml += '<div class="mdt__kitMore">+' + kit.more + ' earlier draw(s) on the log</div>';
            }
            html += '<div class="mdt__secCard"><div class="mdt__section">Equipment checked out</div>'
                + '<div class="mdt__kit">' + kitHtml + '</div></div>';
        }

        /* Certifications as signed award badges. */
        if ((row.certBadges || []).length) {
            html += '<div class="mdt__secCard"><div class="mdt__section">Certifications</div><div class="mdt__certs">';
            row.certBadges.forEach(function (cert) {
                html += '<div class="mdt__cert">'
                    + '<div class="mdt__certMedal">★</div>'
                    + '<div class="mdt__certName">' + escapeHtml(cert.label || '') + '</div>'
                    + (cert.by ? '<div class="mdt__certMeta">Signed by ' + escapeHtml(cert.by) + '</div>' : '')
                    + (cert.at ? '<div class="mdt__certMeta">' + escapeHtml(cert.at) + '</div>' : '')
                    + '</div>';
            });
            html += '</div></div>';
        }

        /* Licences render as the cards themselves: a copy of the document,
           not a comma-separated list of their names. */
        if ((row.idcards || []).length) {
            html += '<div class="mdt__secCard"><div class="mdt__section">Licences held</div>'
                + '<div class="mdt__idCards">';
            row.idcards.forEach(function (card) {
                var portrait = (card.photo && (/^https:\/\//.test(card.photo) || /^data:image\//.test(card.photo)))
                    ? '<img class="mdt__idPhoto" src="' + escapeHtml(card.photo) + '" onerror="this.remove()">'
                    : '<div class="mdt__idPhoto mdt__idPhoto--empty">NO PHOTO</div>';
                html += '<div class="mdt__idCard">'
                    + '<div class="mdt__idHead">SAN ANDREAS &middot; ' + escapeHtml(card.kind || 'LICENSE') + '</div>'
                    + '<div class="mdt__idBody">' + portrait + '<div class="mdt__idInfo">'
                    + '<div class="mdt__idName">' + escapeHtml(card.name || '') + '</div>'
                    + (card.dob ? '<div class="mdt__idLine">DOB &nbsp;' + escapeHtml(card.dob) + '</div>' : '')
                    + (card.gender ? '<div class="mdt__idLine">SEX &nbsp;' + escapeHtml(card.gender) + '</div>' : '')
                    + '<div class="mdt__idLine mdt__idSerial">' + escapeHtml(card.identifier || '') + '</div>'
                    + '</div></div>'
                    + '<div class="mdt__idFoot">VALID &mdash; STATE ISSUED</div>'
                    + '</div>';
            });
            html += '</div></div>';
        }

        /* Photographs: hosted links or embedded in-game camera shots. */
        if ((row.photos || []).length) {
            var photos = '';
            row.photos.forEach(function (photo) {
                if (/^https:\/\//.test(photo.url || '') || /^data:image\//.test(photo.url || '')) {
                    photos += '<img class="mdt__photo" src="' + escapeHtml(photo.url) + '"'
                        + (photo.caption ? ' title="' + escapeHtml(photo.caption) + '"' : '')
                        + ' onerror="this.remove()">';
                }
            });
            if (photos) {
                html += '<div class="mdt__secCard"><div class="mdt__section">Photographs</div>'
                    + '<div class="mdt__photos">' + photos + '</div></div>';
            }
        }
        return html;
    }

    function mdtDetailHtml(row) {
        var html = '';
        var inner = mdtSectionsHtml(row);

        if (row.document) {
            var doc = row.document;
            var chargeLines = '';
            (doc.charges || []).forEach(function (charge, index) {
                chargeLines += '<li>Count ' + (index + 1) + ' &mdash; ' + escapeHtml(charge) + '</li>';
            });
            var seal = (doc.logo && /^https:\/\//.test(doc.logo))
                ? '<img class="mdt__docLogo" src="' + escapeHtml(doc.logo) + '" onerror="this.outerHTML=\'<div class=&quot;mdt__docSeal&quot;>&#9733;</div>\'">'
                : '<div class="mdt__docSeal">&#9733;</div>';
            html += '<div class="mdt__doc' + (doc.status !== 'active' ? ' mdt__doc--closed' : '') + '">'
                + '<div class="mdt__docHead">'
                + seal
                + '<div><div class="mdt__docAgency">' + escapeHtml(doc.agency || '') + '</div>'
                + '<div class="mdt__docSub">United States Federal Justice System</div></div>'
                + '<div class="mdt__docNumber">' + escapeHtml(doc.number || '') + '</div>'
                + '</div>'
                + '<div class="mdt__docTitle">' + escapeHtml(doc.heading || 'WARRANT') + '</div>'
                + '<div class="mdt__docSubject">In the matter of: <strong>' + escapeHtml(doc.subject || '') + '</strong>'
                + (doc.subjectId ? ' <span class="mdt__docId">(' + escapeHtml(doc.subjectId) + ')</span>' : '') + '</div>'
                + '<p class="mdt__docBody">' + escapeHtml(doc.body || '') + '</p>'
                + (chargeLines ? '<ol class="mdt__docCharges">' + chargeLines + '</ol>' : '')
                /* The rest of the report lives ON the paper, not under it. */
                + (inner ? '<div class="mdt__docSections">' + inner + '</div>' : '')
                + '<div class="mdt__docFoot">'
                + '<div><div class="mdt__docSig">' + escapeHtml(doc.issuedBy || '') + '</div>'
                + '<div class="mdt__docSigLabel">Issuing officer</div></div>'
                + '<div><div class="mdt__docSig">' + escapeHtml(doc.issuedAt || '') + '</div>'
                + '<div class="mdt__docSigLabel">Date of issue</div></div>'
                + '</div>'
                + (doc.status !== 'active' ? '<div class="mdt__docStamp">' + escapeHtml(String(doc.status).toUpperCase()) + '</div>' : '')
                + '</div>';
        } else {
            html += '<h2 class="mdt__h">' + escapeHtml(row.title || '') + '</h2>';
            if (row.meta) html += '<p class="mdt__sub">' + escapeHtml(row.meta) + '</p>';
            html += inner;
        }

        /* Case board chips: drag one onto another to reorder the board. */
        if ((row.pinChips || []).length) {
            html += '<div class="mdt__section">Board (drag to reorder)</div><div class="mdt__pins" id="mdtPins">';
            row.pinChips.forEach(function (chip) {
                html += '<span class="mdt__pinChip" draggable="true" data-pin="' + chip.index + '">'
                    + '<span class="mdt__pinKind">' + escapeHtml(chip.kind || '') + '</span>'
                    + escapeHtml(chip.label || '') + '</span>';
            });
            html += '</div>';
        }

        if ((row.actions || []).length) {
            html += '<div class="mdt__actions">';
            row.actions.forEach(function (action, index) {
                html += '<button type="button" class="mdt__action'
                    + (action.tone === 'danger' ? ' mdt__action--danger' : '')
                    + '" data-action="' + index + '">' + escapeHtml(action.label || '') + '</button>';
            });
            html += '</div>';
        }

        return html;
    }

    function mdtRenderDetail() {
        var rows = mdtPage(mdt.tab).rows;
        var row = rows[mdt.selected];

        if (!row) {
            mdtDetailEl.innerHTML = '<div class="mdt__empty">Select an entry.</div>';
            return;
        }

        mdtDetailEl.innerHTML = mdtDetailHtml(row);

        var pinsEl = mdtDetailEl.querySelector('.mdt__pins');
        if (pinsEl) {
            var dragged = null;
            pinsEl.addEventListener('dragstart', function (event) {
                var chip = event.target.closest('.mdt__pinChip');
                if (chip) dragged = chip;
            });
            pinsEl.addEventListener('dragover', function (event) {
                var chip = event.target.closest('.mdt__pinChip');
                if (chip && dragged && chip !== dragged) {
                    event.preventDefault();
                    chip.classList.add('mdt__pinChip--dragover');
                }
            });
            pinsEl.addEventListener('dragleave', function (event) {
                var chip = event.target.closest('.mdt__pinChip');
                if (chip) chip.classList.remove('mdt__pinChip--dragover');
            });
            pinsEl.addEventListener('drop', function (event) {
                var target = event.target.closest('.mdt__pinChip');
                if (!target || !dragged || target === dragged) return;
                event.preventDefault();
                target.classList.remove('mdt__pinChip--dragover');
                pinsEl.insertBefore(dragged, target);
                dragged = null;

                var order = [];
                pinsEl.querySelectorAll('.mdt__pinChip').forEach(function (chip) {
                    order.push(Number(chip.dataset.pin));
                });
                post('mdtAction', { tab: mdt.tab, id: row.id, action: 'reorder', data: { order: order } });
            });
        }
    }

    /* LOOKUP console: search results as rows, same document detail. */
    function mdtRenderLookup() {
        var rows = mdtRows('records');
        var ul = document.createElement('ul');
        ul.className = 'mdt__list';

        if (!rows.length) {
            var empty = document.createElement('li');
            empty.className = 'mdt__empty';
            empty.textContent = mdt.data.recordsSearched
                ? 'No records match "' + mdt.data.recordsSearched + '".'
                : 'Run a search to pull records on file.';
            ul.appendChild(empty);
        }

        rows.forEach(function (row, index) {
            var item = document.createElement('li');
            item.className = 'mdt__row';
            item.dataset.index = String(index);
            item.setAttribute('aria-selected', String(index === mdt.lookupSelected));
            var pill = row.pill
                ? '<span class="mdt__pill' + (row.tone ? ' mdt__pill--' + escapeHtml(row.tone) : '') + '">'
                    + escapeHtml(row.pill) + '</span>'
                : '';
            item.innerHTML = '<div class="mdt__rowTitle"><span>' + escapeHtml(row.title || '') + '</span>'
                + pill + '</div>'
                + (row.meta ? '<div class="mdt__rowMeta">' + escapeHtml(row.meta) + '</div>' : '');
            ul.appendChild(item);
        });

        mdtLookupListEl.innerHTML = '';
        mdtLookupListEl.appendChild(ul);

        var selected = rows[mdt.lookupSelected];
        mdtLookupDetailEl.innerHTML = selected
            ? mdtDetailHtml(selected)
            : '<div class="mdt__empty">Select a record.</div>';
    }

    var MDT_VIEW_LABELS = { dispatch: 'DISPATCH', lookup: 'LOOKUP', records: 'RECORDS', mycall: 'MY CALL' };

    function mdtRender() {
        mdtRenderBrand();
        mdtRenderNav();
        mdtRenderStatusStrip();
        mdtStatus.textContent = mdt.data.status || 'Ready';

        var node = MDT_NODES.filter(function (n) { return n.key === mdt.tab; })[0];
        mdtCrumbEl.textContent = MDT_VIEW_LABELS[mdt.view]
            + (mdt.view === 'records' && node ? ' / ' + node.label.toUpperCase() : '');

        mdtDispatchEl.hidden = mdt.view !== 'dispatch';
        mdtLookupViewEl.hidden = mdt.view !== 'lookup';
        mdtRecordsViewEl.hidden = mdt.view !== 'records';
        mdtMyCallViewEl.hidden = mdt.view !== 'mycall';

        if (mdt.view === 'dispatch') {
            mdtRenderDispatch();
            mapRender();
        } else if (mdt.view === 'lookup') {
            /* First visit auto-populates: everyone on file plus the active
               warrants and BOLOs, before a single key is typed. */
            if (!mdt.lookupAuto && !mdtRows('records').length && !mdt.data.recordsSearched) {
                mdt.lookupAuto = true;
                post('mdtLookup', { term: '' });
            }
            mdtRenderLookup();
        } else if (mdt.view === 'records') {
            mdtRenderTree();
            mdtRenderList();
            mdtRenderDetail();
        } else if (mdt.view === 'mycall') {
            mdtRenderMyCall();
        }
    }

    /* The terminal clock, ticking while the CAD is open. */
    var mdtClockTimer = null;
    function mdtTickClock() {
        var now = new Date();
        var pad = function (n) { return String(n).padStart(2, '0'); };
        mdtClockEl.textContent = pad(now.getHours()) + ':' + pad(now.getMinutes()) + ':' + pad(now.getSeconds());
    }

    function mdtOpen(data) {
        /* The terminal REMEMBERS its workspace across close/open: acting on
           a record round-trips through a pick menu without throwing the
           officer back to Dispatch. Only search state resets per session. */
        if (!mdt.open) {
            mdt.lookupAuto = false;
            /* Every session starts with the done records tucked away. */
            mdt.showClosed = false;
            /* The duty HUD would sit on top of the terminal otherwise. */
            var hudEl = document.getElementById('hud');
            if (hudEl) hudEl.style.visibility = 'hidden';
        }

        mdt.data = data || {};
        mdt.open = true;

        if (!mdtClockTimer) {
            mdtTickClock();
            mdtClockTimer = window.setInterval(mdtTickClock, 1000);
        }

        mdtEl.hidden = false;
        requestAnimationFrame(function () { mdtEl.dataset.open = 'true'; });
        mdtRender();
    }

    function mdtClose(notify) {
        if (!mdt.open) return;
        mdt.open = false;
        mdtEl.dataset.open = 'false';
        if (mdtClockTimer) { window.clearInterval(mdtClockTimer); mdtClockTimer = null; }
        var hudEl = document.getElementById('hud');
        if (hudEl) hudEl.style.visibility = '';
        window.setTimeout(function () { if (!mdt.open) mdtEl.hidden = true; }, 140);
        if (notify !== false) post('mdtClose', {});
    }

    /* Top nav: switching workspaces. */
    mdtNavEl.addEventListener('click', function (event) {
        var button = event.target.closest('.mdt__navBtn');
        if (!button) return;
        mdt.view = button.dataset.view;
        mdtRender();
    });

    /* The filing room's tree. */
    mdtTreeEl.addEventListener('click', function (event) {
        var node = event.target.closest('.mdt__treeNode');
        if (!node) return;
        mdt.tab = node.dataset.tab;
        mdt.selected = null;
        mdt.query = '';
        mdt.filter = null;
        mdt.page = 1;
        mdtSearch.value = '';
        mdtRender();
    });

    /* The status strip posts the pressed state to the same handler the field
       menu uses; the server broadcast repaints the strip. */
    mdtStatusStripEl.addEventListener('click', function (event) {
        var button = event.target.closest('.mdt__statusBtn');
        if (!button) return;
        post('mdtAction', { tab: 'status', id: '', action: button.dataset.status });
    });

    /* Lookup: the search posts to Lua, which queries the server and pushes
       the results back into the payload. */
    function mdtDoLookup() {
        var term = (mdtLookupTermEl.value || '').trim();
        if (!term) return;
        mdt.lookupSelected = null;
        post('mdtLookup', { term: term });
    }
    document.getElementById('mdtLookupGo').addEventListener('click', mdtDoLookup);
    mdtLookupTermEl.addEventListener('keydown', function (event) {
        if (event.key === 'Enter') { event.preventDefault(); mdtDoLookup(); }
    });

    mdtLookupListEl.addEventListener('click', function (event) {
        var row = event.target.closest('.mdt__row');
        if (!row) return;
        mdt.lookupSelected = Number(row.dataset.index);
        mdtRenderLookup();

        /* People rows load their FULL profile (vehicles, licences, court
           history) lazily the first time they are opened. */
        var selected = mdtRows('records')[mdt.lookupSelected];
        if (selected && selected.profileId && !selected.profileLoaded) {
            post('mdtProfile', { identifier: selected.profileId });
        }
    });

    /* Actions on a lookup record (add photograph, ...) post like any other
       detail action, under the 'lookup' tab. */
    mdtLookupDetailEl.addEventListener('click', function (event) {
        if (mdtHandleJumpClick(event)) return;
        var button = event.target.closest('.mdt__action');
        if (!button) return;
        var row = mdtRows('records')[mdt.lookupSelected];
        var action = row && (row.actions || [])[Number(button.dataset.action)];
        if (!action) return;
        post('mdtAction', { tab: 'lookup', id: row.id, action: action.id });
    });

    /* My Call actions (waypoint). */
    mdtMyCallViewEl.addEventListener('click', function (event) {
        var button = event.target.closest('[data-mycall]');
        if (!button) return;
        post('mdtAction', { tab: 'mycall', id: '', action: button.dataset.mycall });
    });

    /* Dispatch board rows focus the matching marker's card on the map. */
    mdtDispatchEl.addEventListener('click', function (event) {
        var callRow = event.target.closest('tr[data-call]');
        var unitRow = event.target.closest('tr[data-unit]');
        var map = mdt.data.map || {};
        if (callRow) {
            var call = (map.calls || [])[Number(callRow.dataset.call)];
            if (call) {
                mapShowCallCard(call);
                /* Fly the map to the call so the card has its context. */
                if (mapFocusFn && call.coords) mapFocusFn(call.coords);
            }
        } else if (unitRow) {
            var units = (map.units || []).filter(function (unit) { return unit.coords; });
            var unit = units[Number(unitRow.dataset.unit)];
            if (unit) {
                mapShowCard([
                    (unit.callsign || '?') + ' - ' + (unit.name || 'Unknown'),
                    'Status: ' + (unit.status || 'available'),
                    unit.division ? ('Division: ' + unit.division) : 'No division'
                ].filter(Boolean));
            }
        }
    });

    mdtListEl.addEventListener('click', function (event) {
        var row = event.target.closest('.mdt__row');
        if (!row) return;
        mdt.selected = Number(row.dataset.index);
        mdtRenderList();
        mdtRenderDetail();
    });

    /* Jumping between records: any linked field lands on the record it
       references - workspace, tab, page and selection all follow. */
    function mdtJump(tab, id) {
        mdt.view = 'records';
        mdt.tab = tab;
        mdt.filter = null;
        mdt.query = '';
        mdtSearch.value = '';
        /* The target may itself be closed, served or void. */
        mdt.showClosed = true;
        var rows = mdtVisibleRows(tab);
        var index = -1;
        rows.forEach(function (row, i) { if (String(row.id) === String(id)) index = i; });
        if (index === -1) {
            mdt.page = 1;
            mdt.selected = null;
        } else {
            mdt.page = Math.floor(index / MDT_PAGE) + 1;
            mdt.selected = index - (mdt.page - 1) * MDT_PAGE;
        }
        mdtRender();
    }

    function mdtJumpLookup(term) {
        mdt.view = 'lookup';
        mdt.lookupSelected = 0;
        if (mdtLookupTermEl) mdtLookupTermEl.value = term;
        post('mdtLookup', { term: term });
        mdtRender();
    }

    function mdtHandleJumpClick(event) {
        var link = event.target.closest('.mdt__fieldLink');
        if (!link) return false;
        if (link.dataset.jumpTab) { mdtJump(link.dataset.jumpTab, link.dataset.jumpId); return true; }
        if (link.dataset.jumpLookup) { mdtJumpLookup(link.dataset.jumpLookup); return true; }
        return false;
    }

    mdtDetailEl.addEventListener('click', function (event) {
        if (mdtHandleJumpClick(event)) return;
        var button = event.target.closest('.mdt__action');
        if (!button) return;

        var row = mdtPage(mdt.tab).rows[mdt.selected];
        var action = row && (row.actions || [])[Number(button.dataset.action)];
        if (!action) return;

        /* Handlers stay in Lua: the UI sends what was pressed and on which
           record, never anything executable. */
        post('mdtAction', { tab: mdt.tab, id: row.id, action: action.id });
    });

    mdtFiltersEl.addEventListener('click', function (event) {
        var chip = event.target.closest('.mdt__chip');
        if (!chip) return;
        if (chip.dataset.toggleClosed) {
            mdt.showClosed = !mdt.showClosed;
        } else {
            mdt.filter = chip.dataset.filter === '' ? null : chip.dataset.filter;
        }
        mdt.page = 1;
        mdt.selected = null;
        mdtRenderList();
        mdtRenderDetail();
    });

    mdtPagerEl.addEventListener('click', function (event) {
        var button = event.target.closest('.mdt__pageBtn');
        if (!button || button.disabled) return;
        mdt.page = mdt.page + (button.id === 'mdtNext' ? 1 : -1);
        mdt.selected = null;
        mdtRenderList();
        mdtRenderDetail();
    });

    mdtTabActionsEl.addEventListener('click', function (event) {
        var button = event.target.closest('.mdt__tabAction');
        if (!button) return;
        post('mdtAction', { tab: mdt.tab, action: button.dataset.action });
    });

    mdtSearch.addEventListener('input', function () {
        mdt.query = mdtSearch.value || '';
        mdt.page = 1;
        mdt.selected = null;
        mdtRenderList();
        mdtRenderDetail();
    });

    document.getElementById('mdtClose').addEventListener('click', function () { mdtClose(); });

    document.addEventListener('keydown', function (event) {
        /* A dialog stacked over the terminal owns Escape. */
        if (!mdt.open || dialogState.open) return;
        if (event.key === 'Escape') { event.preventDefault(); mdtClose(); }
    });

    /* Studio orbit camera relay. While a studio menu is open the game runs a
       scripted camera, but this page holds keyboard focus - so numpad 4/6
       (rotate), 8/2 (raise/lower) and the scroll wheel (zoom) are forwarded
       back to Lua from here. */
    var cameraMode = false;

    var CAMERA_KEYS = {
        Numpad4: 'left', Numpad6: 'right', Numpad8: 'up', Numpad2: 'down'
    };

    document.addEventListener('keydown', function (event) {
        if (!cameraMode) return;
        var op = CAMERA_KEYS[event.code];
        if (!op) return;
        event.preventDefault();
        post('studioCam', { op: op });
    });

    window.addEventListener('wheel', function (event) {
        if (!cameraMode) return;
        post('studioCam', { op: event.deltaY > 0 ? 'zoomout' : 'zoomin' });
    }, { passive: true });

    /* Bottom-right toast notifications. */
    var toastsEl = document.getElementById('toasts');

    function toast(data) {
        var el = document.createElement('div');
        el.className = 'toast' + (data.kind === 'success' ? ' toast--success' : data.kind === 'error' ? ' toast--error' : '');
        el.textContent = data.text || '';
        toastsEl.appendChild(el);
        requestAnimationFrame(function () { el.dataset.open = 'true'; });

        var life = Math.max(1500, Number(data.duration) || 5000);
        window.setTimeout(function () {
            el.dataset.open = 'false';
            window.setTimeout(function () { el.remove(); }, 220);
        }, life);

        /* Never let a backlog pile past the screen. */
        while (toastsEl.children.length > 6) toastsEl.removeChild(toastsEl.firstChild);
    }

    /* Equipment grid: the armory / locker storefront. Cards only carry
       display fields; a click posts the item id back to Lua. */
    var gridEl = document.getElementById('grid');
    var gridBodyEl = document.getElementById('gridBody');
    var gridState = { open: false };

    function gridOpen(data) {
        data = data || {};
        gridState.open = true;

        document.getElementById('gridTitle').textContent = data.title || 'Equipment';
        document.getElementById('gridSubtitle').textContent = data.subtitle || '';
        document.getElementById('gridHint').textContent = data.hint || 'Click an item';

        gridBodyEl.innerHTML = '';
        (data.sections || []).forEach(function (section) {
            if (section.label) {
                var head = document.createElement('div');
                head.className = 'grid__section';
                head.textContent = section.label;
                gridBodyEl.appendChild(head);
            }

            var wrap = document.createElement('div');
            wrap.className = 'grid__items';
            (section.items || []).forEach(function (item) {
                var card = document.createElement('div');
                card.className = 'grid__card' + (item.locked ? ' grid__card--locked' : '');
                card.dataset.id = String(item.id);
                if (item.locked) card.dataset.locked = 'true';

                var badge = item.badge
                    ? '<span class="grid__badge' + (item.badgeTone ? ' grid__badge--' + escapeHtml(item.badgeTone) : '')
                        + '">' + escapeHtml(item.badge) + '</span>'
                    : '';

                card.innerHTML = badge
                    + (item.tag ? '<span class="grid__tag">' + escapeHtml(item.tag) + '</span>' : '')
                    + '<span class="grid__icon">' + escapeHtml(item.icon || '📦') + '</span>'
                    + '<span class="grid__label">' + escapeHtml(item.label || '') + '</span>'
                    + (item.sub ? '<span class="grid__sub">' + escapeHtml(item.sub) + '</span>' : '');

                /* The inventory's own item picture, when the server hands us
                   an image base (nui://<inventory>/...). Tries .png then
                   .webp; on failure the emoji glyph simply stays visible. */
                if (data.imageBase && item.image) {
                    var icon = card.querySelector('.grid__icon');
                    var img = document.createElement('img');
                    img.className = 'grid__img';
                    var sources = [
                        data.imageBase + item.image + '.png',
                        data.imageBase + item.image + '.webp',
                        data.imageBase + String(item.image).toUpperCase() + '.png'
                    ];
                    var attempt = 0;
                    img.onerror = function () {
                        attempt += 1;
                        if (attempt < sources.length) { img.src = sources[attempt]; }
                        else { img.remove(); }
                    };
                    /* The emoji glyph is the fallback ONLY: once the real
                       item picture is in, it goes away entirely. (hidden
                       alone loses to the icon's display rule.) */
                    img.onload = function () { if (icon) { icon.remove(); icon = null; } };
                    img.src = sources[0];
                    card.insertBefore(img, icon);
                }
                wrap.appendChild(card);
            });
            gridBodyEl.appendChild(wrap);
        });

        gridEl.hidden = false;
        requestAnimationFrame(function () { gridEl.dataset.open = 'true'; });
    }

    function gridClose(notify) {
        if (!gridState.open) return;
        gridState.open = false;
        gridEl.dataset.open = 'false';
        window.setTimeout(function () { if (!gridState.open) gridEl.hidden = true; }, 150);
        if (notify !== false) post('gridClose', {});
    }

    gridBodyEl.addEventListener('click', function (event) {
        var card = event.target.closest('.grid__card');
        if (!card || card.dataset.locked === 'true') return;
        post('gridSelect', { id: card.dataset.id });
    });

    document.getElementById('gridClose').addEventListener('click', function () { gridClose(); });

    document.addEventListener('keydown', function (event) {
        if (!gridState.open || dialogState.open) return;
        if (event.key === 'Escape') { event.preventDefault(); gridClose(); }
    });

    /* Door prompt chip: shown while standing at a controllable door. */
    var doorPromptEl = document.getElementById('doorPrompt');
    var doorPromptLabel = document.getElementById('doorPromptLabel');
    var doorPromptHint = document.getElementById('doorPromptHint');
    var doorPromptState = document.getElementById('doorPromptState');
    var doorPromptTimer = null;

    function doorPrompt(data) {
        window.clearTimeout(doorPromptTimer);
        if (!data.show) {
            doorPromptEl.dataset.open = 'false';
            doorPromptTimer = window.setTimeout(function () { doorPromptEl.hidden = true; }, 150);
            return;
        }

        doorPromptLabel.textContent = data.label || 'Door';
        doorPromptHint.textContent = data.locked ? 'Press to unlock' : 'Press to lock';
        doorPromptState.textContent = data.locked ? 'Locked' : 'Unlocked';
        doorPromptState.dataset.locked = String(data.locked === true);
        doorPromptEl.hidden = false;
        requestAnimationFrame(function () { doorPromptEl.dataset.open = 'true'; });
    }

    /* Agency configuration panel (/fedconfig). A tabbed list-and-form GUI
       over the live agency record. Every Save posts one operation to Lua;
       the server validates and persists it, then pushes a fresh snapshot
       back, so the panel always renders what is actually stored. */
    var cfgEl = document.getElementById('cfg');
    var cfgTabsEl = document.getElementById('cfgTabs');
    var cfgListEl = document.getElementById('cfgList');
    var cfgFormEl = document.getElementById('cfgForm');
    var cfgItemsEl = document.getElementById('cfgItems');

    var cfg = { open: false, data: null, tab: 'agency', sel: null };

    var CFG_TABS = [
        { key: 'agency', label: 'Agency' },
        { key: 'stations', label: 'Stations' },
        { key: 'ranks', label: 'Ranks' },
        { key: 'divisions', label: 'Divisions' },
        { key: 'certifications', label: 'Certifications' },
        { key: 'investigations', label: 'Investigation' },
        { key: 'uniforms', label: 'Uniforms' },
        { key: 'armory', label: 'Armory' },
        { key: 'vehicles', label: 'Vehicles' },
        { key: 'doors', label: 'Doors' },
        { key: 'applications', label: 'Applications' }
    ];

    function cfgAgency() { return (cfg.data && cfg.data.agency) || {}; }

    function cfgCount(key) {
        var agency = cfgAgency();
        if (key === 'agency') return null;
        if (key === 'stations') return (agency.stations || []).length;
        if (key === 'vehicles') return ((cfg.data && cfg.data.vehicles) || []).length;
        if (key === 'doors') return ((cfg.data && cfg.data.doors) || []).length;
        if (key === 'applications') return ((cfg.data && cfg.data.applications) || {}).pending || 0;
        return (agency[key] || []).length;
    }

    function cfgApps() {
        var apps = (cfg.data && cfg.data.applications) || {};
        apps.form = apps.form || {};
        apps.form.questions = apps.form.questions || [];
        apps.places = apps.places || [];
        return apps;
    }

    function rankSelectOptions() {
        var options = [];
        (cfgAgency().ranks || []).forEach(function (rank) {
            options.push({ value: String(rank.grade), label: 'Grade ' + rank.grade + ' - ' + rank.label });
        });
        if (!options.length) options.push({ value: '0', label: 'Grade 0' });
        return options;
    }

    function cfgPost(op, data) {
        post('cfgAction', { op: op, data: data || {} });
    }

    /* Field helpers ------------------------------------------------------ */

    function fInput(key, label, value, type, extra) {
        return '<div class="cfg__field"><label class="cfg__label">' + escapeHtml(label) + '</label>'
            + '<input class="cfg__input" data-key="' + key + '" type="' + (type || 'text') + '" '
            + 'autocomplete="off" spellcheck="false" value="'
            + escapeHtml(value === undefined || value === null ? '' : String(value)) + '"'
            + (extra || '') + '></div>';
    }

    function fTextarea(key, label, value) {
        return '<div class="cfg__field"><label class="cfg__label">' + escapeHtml(label) + '</label>'
            + '<textarea class="cfg__input cfg__textarea" data-key="' + key + '" rows="6" '
            + 'autocomplete="off" spellcheck="false">'
            + escapeHtml(value === undefined || value === null ? '' : String(value))
            + '</textarea></div>';
    }

    function fSelect(key, label, value, options) {
        var html = '<div class="cfg__field"><label class="cfg__label">' + escapeHtml(label)
            + '</label><select class="cfg__select" data-key="' + key + '">';
        options.forEach(function (option) {
            var v = option.value === undefined ? option : option.value;
            var text = option.label === undefined ? v : option.label;
            html += '<option value="' + escapeHtml(String(v)) + '"'
                + (String(v) === String(value) ? ' selected' : '') + '>'
                + escapeHtml(String(text)) + '</option>';
        });
        return html + '</select></div>';
    }

    /* Coordinates: three inputs plus the button that fills them from the
       player's live position (fetched from Lua when pressed). */
    function fCoords(coords) {
        coords = coords || {};
        function part(axis) {
            return '<div><label class="cfg__label">' + axis.toUpperCase() + '</label>'
                + '<input class="cfg__input" data-key="coord-' + axis + '" type="number" step="0.01" value="'
                + escapeHtml(String(coords[axis] === undefined ? '' : coords[axis])) + '"></div>';
        }
        return '<div class="cfg__field"><div class="cfg__coords">'
            + part('x') + part('y') + part('z')
            + '<button type="button" class="cfg__button" id="cfgUseCoords">Use my position</button>'
            + '</div></div>';
    }

    function fChecks(names, checked, title) {
        var html = '<label class="cfg__label">' + escapeHtml(title || 'Permissions') + '</label><div class="cfg__checks">';
        names.forEach(function (name) {
            html += '<label class="cfg__check"><input type="checkbox" data-perm="'
                + escapeHtml(name) + '"' + (checked && checked[name] ? ' checked' : '') + '>'
                + escapeHtml(name) + '</label>';
        });
        return html + '</div>';
    }

    function fCheckbox(key, label, checked) {
        return '<div class="cfg__field"><label class="cfg__check"><input type="checkbox" data-key="'
            + key + '"' + (checked ? ' checked' : '') + '>' + escapeHtml(label) + '</label></div>';
    }

    function fActions(saveLabel, canDelete) {
        return '<div class="cfg__actions">'
            + '<button type="button" class="cfg__button cfg__button--primary" id="cfgSave">'
            + escapeHtml(saveLabel || 'Save') + '</button>'
            + (canDelete ? '<button type="button" class="cfg__button cfg__button--danger" id="cfgDelete">Delete</button>' : '')
            + '</div>';
    }

    function readForm() {
        var values = {};
        Array.prototype.forEach.call(cfgFormEl.querySelectorAll('[data-key]'), function (input) {
            var key = input.dataset.key;
            if (input.type === 'checkbox') values[key] = input.checked;
            else if (input.type === 'number') values[key] = input.value === '' ? null : Number(input.value);
            else values[key] = input.value;
        });
        var perms = cfgFormEl.querySelectorAll('[data-perm]');
        if (perms.length) {
            values.permissions = {};
            Array.prototype.forEach.call(perms, function (box) {
                if (box.checked) values.permissions[box.dataset.perm] = true;
            });
        }
        if (values['coord-x'] !== undefined) {
            values.coords = { x: values['coord-x'], y: values['coord-y'], z: values['coord-z'] };
        }
        return values;
    }

    /* List + form rendering ---------------------------------------------- */

    function cfgFind(list, id) {
        for (var i = 0; i < (list || []).length; i += 1) {
            if (list[i].id === id) return list[i];
        }
        return null;
    }

    function divisionSelectOptions() {
        var options = [{ value: '', label: 'Any division' }];
        (cfgAgency().divisions || []).forEach(function (division) {
            options.push({ value: division.id, label: division.label });
        });
        return options;
    }

    /* Map icons. A curated set of blip sprites that suit agencies, plus a
       free "custom id" field for anything from the full game list. */
    var BLIP_SPRITES = [
        { value: '', label: 'Agency default' },
        { value: '60', label: 'Police shield' },
        { value: '487', label: 'Agency crest' },
        { value: '110', label: 'Firearms' },
        { value: '43', label: 'Officer' },
        { value: '40', label: 'House' },
        { value: '66', label: 'Dollar sign' },
        { value: '1', label: 'Plain circle' }
    ];

    var BLIP_COLORS = [
        { value: '', label: 'Agency default' },
        { value: '0', label: 'White' },
        { value: '1', label: 'Red' },
        { value: '2', label: 'Green' },
        { value: '3', label: 'Light blue' },
        { value: '5', label: 'Yellow' },
        { value: '17', label: 'Orange' },
        { value: '26', label: 'Federal blue' },
        { value: '27', label: 'Purple' },
        { value: '29', label: 'Navy' },
        { value: '47', label: 'Amber' }
    ];

    function blipFields(blip) {
        blip = blip || {};
        var sprite = blip.sprite === undefined || blip.sprite === null ? '' : String(blip.sprite);
        var known = BLIP_SPRITES.some(function (option) { return option.value === sprite; });

        return '<div class="cfg__grid">'
            + fSelect('blipSprite', 'Map icon', known ? sprite : '', BLIP_SPRITES)
            + fInput('blipCustom', 'Custom icon id (overrides)', known ? '' : sprite, 'number')
            + '</div>'
            + fSelect('blipColor', 'Icon colour', blip.color === undefined || blip.color === null ? '' : String(blip.color), BLIP_COLORS)
            + '<div class="cfg__note">Custom ids come from the game\'s blip sprite list (docs.fivem.net &rarr; Blips).</div>';
    }

    function cfgRenderTabs() {
        cfgTabsEl.innerHTML = '';
        CFG_TABS.forEach(function (tab) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'cfg__tab';
            button.dataset.tab = tab.key;
            button.setAttribute('role', 'tab');
            button.setAttribute('aria-selected', String(tab.key === cfg.tab));
            var count = cfgCount(tab.key);
            button.innerHTML = '<span>' + escapeHtml(tab.label) + '</span>'
                + (count === null ? '' : '<span class="cfg__tabCount">' + count + '</span>');
            cfgTabsEl.appendChild(button);
        });
    }

    function row(label, meta, sel, options) {
        options = options || {};
        var item = document.createElement('li');
        item.className = 'cfg__row' + (options.sub ? ' cfg__row--sub' : '') + (options.action ? ' cfg__row--action' : '');
        item.innerHTML = escapeHtml(label) + (meta ? '<div class="cfg__rowMeta">' + escapeHtml(meta) + '</div>' : '');
        if (sel) {
            item.dataset.sel = JSON.stringify(sel);
            item.setAttribute('aria-selected', String(JSON.stringify(cfg.sel) === JSON.stringify(sel)));
        }
        cfgListEl.appendChild(item);
        return item;
    }

    function emptyRow(text) {
        var item = document.createElement('li');
        item.className = 'cfg__row cfg__row--empty';
        item.textContent = text;
        cfgListEl.appendChild(item);
    }

    function cfgRenderList() {
        var agency = cfgAgency();
        cfgListEl.innerHTML = '';

        if (cfg.tab === 'agency') {
            row('Agency details', agency.label, { type: 'agency' });
        } else if (cfg.tab === 'stations') {
            (agency.stations || []).forEach(function (station) {
                row(station.label, 'station ' + station.id, { type: 'station', id: station.id });
                (station.zones || []).forEach(function (zone) {
                    row(zone.label, zone.kind, { type: 'zone', stationId: station.id, id: zone.id }, { sub: true });
                });
                row('+ Add a room here', null, { type: 'new-zone', stationId: station.id }, { sub: true, action: true });
            });
            row('+ New station', null, { type: 'new-station' }, { action: true });
        } else if (cfg.tab === 'ranks') {
            (agency.ranks || []).forEach(function (rank) {
                row(rank.label, 'grade ' + rank.grade, { type: 'rank', id: rank.id });
            });
            row('+ New rank', null, { type: 'new-rank' }, { action: true });
        } else if (cfg.tab === 'divisions') {
            (agency.divisions || []).forEach(function (division) {
                row(division.label, division.minGrade > 0 ? ('grade ' + division.minGrade + '+') : null,
                    { type: 'division', id: division.id });
                (division.ranks || []).forEach(function (rank) {
                    row(rank.label, 'division grade ' + rank.grade,
                        { type: 'division-rank', divisionId: division.id, id: rank.id }, { sub: true });
                });
                row('+ Add a rank to ' + division.label, null,
                    { type: 'new-division-rank', divisionId: division.id }, { sub: true, action: true });
            });
            if (!(agency.divisions || []).length) emptyRow('No divisions yet.');
            row('+ New division', null, { type: 'new-division' }, { action: true });
        } else if (cfg.tab === 'uniforms') {
            (agency.uniforms || []).forEach(function (uniform) {
                row(uniform.label, 'grade ' + (uniform.minGrade || 0) + '+ | ' + (uniform.variant || 'any'),
                    { type: 'uniform', id: uniform.id });
            });
            row('+ New uniform from my current outfit', null, { type: 'new-uniform' }, { action: true });
        } else if (cfg.tab === 'armory') {
            (agency.armory || []).forEach(function (entry) {
                row(entry.label, entry.item + ' | grade ' + (entry.minGrade || 0) + '+',
                    { type: 'armory', id: entry.id });
            });
            row('+ Stock an item', null, { type: 'new-armory' }, { action: true });
        } else if (cfg.tab === 'certifications') {
            (agency.certifications || []).forEach(function (cert) {
                var sub = (cert.licences && cert.licences.length)
                    ? 'Requires: ' + cert.licences.join(', ')
                    : (cert.description || 'Awarded from Personnel');
                row(cert.label, sub, { type: 'cert', id: cert.id });
            });
            row('+ Add a certification', null, { type: 'new-cert' }, { action: true });
        } else if (cfg.tab === 'investigations') {
            (agency.investigations || []).forEach(function (flow) {
                row('Matches "' + flow.match + '"',
                    (flow.statements || []).length + ' statement(s), ' + (flow.leads || []).length + ' lead(s)',
                    { type: 'inv', id: flow.id });
            });
            row('+ Add an investigation flow', null, { type: 'new-inv' }, { action: true });
        } else if (cfg.tab === 'vehicles') {
            ((cfg.data && cfg.data.vehicles) || []).forEach(function (vehicle) {
                row(vehicle.label, vehicle.model + ' | grade ' + (vehicle.minGrade || 0) + '+'
                    + (vehicle.hasProps ? ' | saved mods' : ''), { type: 'vehicle', id: vehicle.id });
            });
            row('+ Spawn & customize in the studio', null, { type: 'vehicle-studio' }, { action: true });
            row('+ Add the vehicle I am sitting in', null, { type: 'new-vehicle' }, { action: true });
        } else if (cfg.tab === 'doors') {
            ((cfg.data && cfg.data.doors) || []).forEach(function (door) {
                row(door.label, 'grade ' + (door.minGrade || 0) + '+ | ' + (door.locked ? 'locked' : 'unlocked'),
                    { type: 'door', id: door.id });
            });
            if (!((cfg.data && cfg.data.doors) || []).length) emptyRow('No doors registered yet.');
            row('+ Capture the door I am aiming at', null, { type: 'new-door' }, { action: true });
        } else if (cfg.tab === 'applications') {
            var apps = cfgApps();
            row('Form settings',
                (apps.form.enabled ? 'Open for applications' : 'Closed')
                + (apps.pending ? ' | ' + apps.pending + ' pending' : ''),
                { type: 'app-form' });

            apps.form.questions.forEach(function (question) {
                row(question.label, question.required ? 'required' : 'optional',
                    { type: 'app-question', id: question.id }, { sub: true });
            });
            row('+ Add a question', null, { type: 'new-app-question' }, { sub: true, action: true });

            apps.places.forEach(function (place) {
                row(place.label, 'application desk', { type: 'app-place', id: place.id });
            });
            row('+ Add an application desk', null, { type: 'new-app-place' }, { action: true });
        }
    }

    function cfgRenderForm() {
        var agency = cfgAgency();
        var meta = (cfg.data && cfg.data.meta) || {};
        var sel = cfg.sel;
        var html = '';

        if (!sel) {
            cfgFormEl.innerHTML = '<div class="cfg__note">Select an entry on the left, or one of the + actions.</div>';
            return;
        }

        if (sel.type === 'agency') {
            html = '<h2 class="cfg__h">Agency</h2><p class="cfg__sub">Identity and membership.</p>'
                + fInput('label', 'Name', agency.label)
                + '<div class="cfg__grid">'
                + fInput('short', 'Short code', agency.short)
                + fInput('bossGrade', 'Boss grade', agency.bossGrade, 'number')
                + '</div>'
                + fInput('jobs', 'Framework jobs (comma separated)', (agency.jobs || []).join(', '))
                + fInput('color', 'Colour (hex)', agency.color)
                + fInput('callsignPrefix', 'Callsign prefix (e.g. 1F-) - every callsign is forced onto it; blank uses the short code',
                    agency.callsignPrefix || '')
                + fInput('cadLogo', 'CAD logo (https image link, shown on the terminal)',
                    (agency.cad && agency.cad.logo) || '')
                + blipFields(agency.blip)
                + '<label class="cfg__label">NPC callouts</label>'
                + fCheckbox('npcEnabled', 'Dispatch NPC callouts automatically',
                    !agency.npcCallouts || agency.npcCallouts.enabled !== false)
                + fInput('npcCivilianLimit',
                    'Only while fewer than this many non-members are online (0 = always)',
                    agency.npcCallouts ? agency.npcCallouts.civilianLimit : 0, 'number')
                + fInput('npcMaxActive',
                    'Max simultaneous callouts (0 = default; never exceeds one per officer on duty)',
                    agency.npcCallouts ? agency.npcCallouts.maxActive : 0, 'number')
                + '<div class="cfg__note">Members can always force a callout from the callouts menu, whatever this gate says.</div>'
                + fActions('Save agency');
        } else if (sel.type === 'station' || sel.type === 'new-station') {
            var station = sel.id ? cfgFind(agency.stations, sel.id) : null;
            html = '<h2 class="cfg__h">' + (station ? escapeHtml(station.label) : 'New station') + '</h2>'
                + '<p class="cfg__sub">Moving a station keeps its rooms; rooms are placed individually.</p>'
                + fInput('label', 'Name', station && station.label)
                + fSelect('kind', 'Type', station ? station.kind : 'field', [
                    { value: 'hq', label: 'Headquarters' },
                    { value: 'field', label: 'Field office' }
                ])
                + fCheckbox('publicBlip', 'Show the map icon to people outside the agency',
                    station ? station.publicBlip !== false : true)
                + blipFields(station && station.blip)
                + fCoords(station && station.coords)
                + fActions(station ? 'Save station' : 'Create station', !!station);
        } else if (sel.type === 'zone' || sel.type === 'new-zone') {
            var zoneStation = cfgFind(agency.stations, sel.stationId) || {};
            var zone = sel.id ? cfgFind(zoneStation.zones, sel.id) : null;
            html = '<h2 class="cfg__h">' + (zone ? escapeHtml(zone.label) : 'New room') + '</h2>'
                + '<p class="cfg__sub">In ' + escapeHtml(zoneStation.label || '') + '.</p>'
                + fSelect('kind', 'Room type', zone && zone.kind, meta.zoneKinds || [])
                + fInput('label', 'Label (optional)', zone && zone.label)
                + '<div class="cfg__grid">'
                + fInput('radius', 'Radius', zone ? zone.radius : 1.5, 'number', ' step="0.5"')
                + fInput('minGrade', 'Minimum grade', zone ? zone.minGrade : 0, 'number')
                + '</div>'
                + fCoords(zone && zone.coords)
                + fActions(zone ? 'Save room' : 'Place room', !!zone);
        } else if (sel.type === 'rank' || sel.type === 'new-rank') {
            var rank = sel.id ? cfgFind(agency.ranks, sel.id) : null;
            html = '<h2 class="cfg__h">' + (rank ? escapeHtml(rank.label) : 'New rank') + '</h2>'
                + '<p class="cfg__sub">The grade ties to the framework job grade.</p>'
                + '<div class="cfg__grid">'
                + fInput('label', 'Rank name', rank && rank.label)
                + fInput('grade', 'Grade', rank ? rank.grade : '', 'number')
                + '</div>'
                + fChecks(meta.permissions || [], rank && rank.permissions)
                + fActions(rank ? 'Save rank' : 'Create rank', !!rank);
        } else if (sel.type === 'division' || sel.type === 'new-division') {
            var division = sel.id ? cfgFind(agency.divisions, sel.id) : null;
            html = '<h2 class="cfg__h">' + (division ? escapeHtml(division.label) : 'New division') + '</h2>'
                + '<p class="cfg__sub">Assign members and their division rank from Personnel. Its ranks are the indented rows on the left.</p>'
                + '<div class="cfg__grid">'
                + fInput('label', 'Division name', division && division.label)
                + fInput('minGrade', 'Joinable from grade', division ? division.minGrade : 0, 'number')
                + '</div>'
                + fInput('callsignPrefix', 'Callsign prefix override (blank = use the agency prefix)',
                    (division && division.callsignPrefix) || '')
                + fActions(division ? 'Save division' : 'Create division', !!division);
        } else if (sel.type === 'division-rank' || sel.type === 'new-division-rank') {
            var rankDivision = cfgFind(agency.divisions, sel.divisionId) || {};
            var divisionRank = sel.id ? cfgFind(rankDivision.ranks, sel.id) : null;
            html = '<h2 class="cfg__h">' + (divisionRank ? escapeHtml(divisionRank.label) : 'New division rank') + '</h2>'
                + '<p class="cfg__sub">A rank on ' + escapeHtml(rankDivision.label || 'the division') + '\'s own ladder - grade 0 is its entry rank.</p>'
                + '<div class="cfg__grid">'
                + fInput('label', 'Rank name', divisionRank && divisionRank.label)
                + fInput('grade', 'Division grade', divisionRank ? divisionRank.grade : ((rankDivision.ranks || []).length), 'number')
                + '</div>'
                + fActions(divisionRank ? 'Save rank' : 'Create rank', !!divisionRank);
        } else if (sel.type === 'uniform' || sel.type === 'new-uniform') {
            var uniform = sel.id ? cfgFind(agency.uniforms, sel.id) : null;
            html = '<h2 class="cfg__h">' + (uniform ? escapeHtml(uniform.label) : 'New uniform') + '</h2>'
                + '<p class="cfg__sub">Wear the outfit you want, then save with capture ticked.</p>'
                + fInput('label', 'Uniform name', uniform && uniform.label)
                + '<div class="cfg__grid">'
                + fInput('minGrade', 'Minimum grade', uniform ? uniform.minGrade : 0, 'number')
                + fSelect('variant', 'Fits', uniform ? uniform.variant : 'any', meta.variants || ['any', 'male', 'female'])
                + '</div>'
                + fSelect('division', 'Restrict to division', (uniform && uniform.division) || '', divisionSelectOptions())
                + fCheckbox('capture', 'Capture the clothes I am wearing right now', !uniform)
                + fActions(uniform ? 'Save uniform' : 'Create uniform', !!uniform)
                + (uniform
                    ? '<div class="cfg__actions">'
                        + '<button type="button" class="cfg__button" id="cfgStudioBtn">Edit the clothing (live studio)</button>'
                        + '<button type="button" class="cfg__button" id="cfgDuplicateBtn">Duplicate</button>'
                        + '</div>'
                        + '<div class="cfg__note">The studio closes this panel, dresses you in the uniform, and lets you cycle every piece live before saving it back. Duplicate creates a copy to start a new uniform from.</div>'
                    : '');
        } else if (sel.type === 'armory' || sel.type === 'new-armory') {
            var armoryEntry = sel.id ? cfgFind(agency.armory, sel.id) : null;
            html = '<h2 class="cfg__h">' + (armoryEntry ? escapeHtml(armoryEntry.label) : 'Stock an item') + '</h2>'
                + '<p class="cfg__sub">Start typing in the item field to search your server\'s catalog.</p>'
                + fInput('item', 'Item', armoryEntry && armoryEntry.item, 'text', ' list="cfgItems"')
                + fInput('label', 'Display name', armoryEntry && armoryEntry.label)
                + '<div class="cfg__grid3">'
                + fInput('count', 'Per draw', armoryEntry ? armoryEntry.count : 1, 'number')
                + fInput('minGrade', 'Minimum grade', armoryEntry ? armoryEntry.minGrade : 0, 'number')
                + fInput('price', 'Price', armoryEntry ? armoryEntry.price : 0, 'number')
                + '</div>'
                + fInput('category', 'Category', armoryEntry && armoryEntry.category)
                + fSelect('division', 'Restrict to division', (armoryEntry && armoryEntry.division) || '', divisionSelectOptions())
                + fActions(armoryEntry ? 'Save item' : 'Stock item', !!armoryEntry);
        } else if (sel.type === 'cert' || sel.type === 'new-cert') {
            var cert = sel.id ? cfgFind(agency.certifications, sel.id) : null;
            var certLicences = {};
            ((cert && cert.licences) || []).forEach(function (name) { certLicences[name] = true; });
            html = '<h2 class="cfg__h">' + (cert ? escapeHtml(cert.label) : 'New certification') + '</h2>'
                + '<p class="cfg__sub">A qualification the agency can award. Roster managers award and revoke it '
                + 'per member from the Personnel menu; it shows on the personnel file with who signed it and when. '
                + 'Ticked licences are PREREQUISITES: the award is refused until the member holds every one.</p>'
                + fInput('label', 'Name (e.g. Field Training, SWAT, Firearms)', cert && cert.label)
                + fInput('description', 'Description (optional)', cert && cert.description)
                + fChecks(meta.licences || [], certLicences, 'Required licences (prerequisites)')
                + fActions(cert ? 'Save certification' : 'Create certification', !!cert);
        } else if (sel.type === 'inv' || sel.type === 'new-inv') {
            var flow = sel.id ? cfgFind(agency.investigations, sel.id) : null;
            html = '<h2 class="cfg__h">' + (flow ? 'Flow: ' + escapeHtml(flow.match) : 'New investigation flow') + '</h2>'
                + '<p class="cfg__sub">When officers interview NPCs at a scene whose case type contains the match '
                + 'keyword, witnesses answer with THESE statements. One per line; %s becomes the suspect '
                + 'description. Lead lines are what pressing a witness shakes loose - plain text, or '
                + '"ledger: ...", "name: ...", "contact: ..." to pick the lead kind.</p>'
                + fInput('match', 'Match keyword (e.g. fraud, theft, espionage)', flow && flow.match)
                + fTextarea('statements', 'Witness statements (one per line)',
                    ((flow && flow.statements) || []).join('\n'))
                + fTextarea('leads', 'Pressable details / leads (one per line)',
                    ((flow && flow.leads) || []).map(function (lead) {
                        return (lead.kind && lead.kind !== 'contact' ? lead.kind + ': ' : '') + lead.text;
                    }).join('\n'))
                + fActions(flow ? 'Save flow' : 'Create flow', !!flow);
        } else if (sel.type === 'vehicle-studio') {
            html = '<h2 class="cfg__h">Vehicle studio</h2>'
                + '<p class="cfg__sub">Type a spawn code, spawn into the vehicle, customize it live with the '
                + 'orbit camera (numpad 4/6/8/2, scroll to zoom), then save it - exactly like the uniform studio. '
                + 'The panel closes while the studio runs.</p>'
                + '<div class="cfg__actions cfg__actions--top"><button type="button" '
                + 'class="cfg__button cfg__button--primary" id="cfgVehicleStudioBtn">'
                + '&#128663; Launch the vehicle studio</button></div>';
        } else if (sel.type === 'vehicle' || sel.type === 'new-vehicle') {
            var vehicle = sel.id ? cfgFind((cfg.data && cfg.data.vehicles) || [], sel.id) : null;
            html = '<h2 class="cfg__h">' + (vehicle ? escapeHtml(vehicle.label) : 'Add a vehicle') + '</h2>'
                + '<p class="cfg__sub">'
                + (vehicle ? 'Model: ' + escapeHtml(vehicle.model)
                    : 'Sit in the vehicle and tick capture, or use /fedaddcar on foot for the spawn-and-customize studio.')
                + '</p>'
                + (vehicle
                    ? '<div class="cfg__actions cfg__actions--top"><button type="button" '
                        + 'class="cfg__button cfg__button--primary" id="cfgVehicleEditBtn">'
                        + '&#128663; Spawn &amp; edit in the studio</button></div>'
                    : '')
                + fInput('label', 'Display name', vehicle && vehicle.label)
                + fInput('minGrade', 'Minimum grade', vehicle ? vehicle.minGrade : 0, 'number')
                + fSelect('division', 'Restrict to division', (vehicle && vehicle.division) || '', divisionSelectOptions())
                + fCheckbox('capture', 'Capture the vehicle I am sitting in (model, mods, liveries)', !vehicle)
                + fActions(vehicle ? 'Save vehicle' : 'Add vehicle', !!vehicle);
        } else if (sel.type === 'door' || sel.type === 'new-door') {
            var door = sel.id ? cfgFind((cfg.data && cfg.data.doors) || [], sel.id) : null;
            html = '<h2 class="cfg__h">' + (door ? escapeHtml(door.label) : 'Register a door') + '</h2>'
                + '<p class="cfg__sub">'
                + (door ? 'Locked doors are enforced for everyone; members at the grade below can toggle them at the door.'
                    : 'Fill this in, press Capture, and you get 4 seconds to aim at the door or gate.')
                + '</p>'
                + fInput('label', 'Door name', door && door.label)
                + '<div class="cfg__grid">'
                + fInput('minGrade', 'Controlled from grade', door ? door.minGrade : 0, 'number')
                + fInput('radius', 'Prompt radius (metres)', door ? (door.radius || 4.0) : 4.0, 'number', ' step="0.5"')
                + '</div>'
                + (door ? fCheckbox('locked', 'Locked right now', door.locked) : '')
                + (door
                    ? '<label class="cfg__label">Prompt point (where "press E" appears; blank = at the door)</label>'
                        + fCoords(door.prompt)
                    : '')
                + fActions(door ? 'Save door' : 'Capture the door I am aiming at', !!door);
        } else if (sel.type === 'app-form') {
            var appForm = cfgApps().form;
            html = '<h2 class="cfg__h">Application form</h2>'
                + '<p class="cfg__sub">Anyone at a desk fills this in; approving hires them at the rank and division below automatically.</p>'
                + fCheckbox('enabled', 'Open for applications', appForm.enabled === true)
                + fInput('title', 'Form title', appForm.title || 'Application')
                + fSelect('rank', 'Rank granted on approval', String(appForm.rank || 0), rankSelectOptions())
                + fSelect('division', 'Division assigned on approval', appForm.division || '', divisionSelectOptions())
                + '<div class="cfg__note">Questions and desks are the rows on the left. Pending applications are reviewed from the boss menu.</div>'
                + fActions('Save form settings');
        } else if (sel.type === 'app-question' || sel.type === 'new-app-question') {
            var question = sel.id ? cfgFind(cfgApps().form.questions, sel.id) : null;
            html = '<h2 class="cfg__h">' + (question ? 'Edit question' : 'New question') + '</h2>'
                + fInput('label', 'Question', question && question.label)
                + fCheckbox('required', 'An answer is required', question ? question.required : true)
                + fActions(question ? 'Save question' : 'Add question', !!question);
        } else if (sel.type === 'app-place' || sel.type === 'new-app-place') {
            var place = sel.id ? cfgFind(cfgApps().places, sel.id) : null;
            html = '<h2 class="cfg__h">' + (place ? escapeHtml(place.label) : 'New application desk') + '</h2>'
                + '<p class="cfg__sub">Anyone can walk up to this point and apply - it shows on the map for everyone.</p>'
                + fInput('label', 'Desk name', place && place.label)
                + fCoords(place && place.coords)
                + fActions(place ? 'Save desk' : 'Place desk', !!place);
        }

        cfgFormEl.innerHTML = html;

        var useCoords = document.getElementById('cfgUseCoords');
        if (useCoords) {
            useCoords.addEventListener('click', function () {
                post('cfgCoords', {}).then(function (resp) {
                    return resp && resp.json ? resp.json() : null;
                }).then(function (coords) {
                    if (!coords) return;
                    ['x', 'y', 'z'].forEach(function (axis) {
                        var input = cfgFormEl.querySelector('[data-key="coord-' + axis + '"]');
                        if (input && typeof coords[axis] === 'number') input.value = coords[axis].toFixed(2);
                    });
                }).catch(function () {});
            });
        }

        var saveButton = document.getElementById('cfgSave');
        if (saveButton) saveButton.addEventListener('click', cfgSave);

        var studioButton = document.getElementById('cfgStudioBtn');
        if (studioButton) {
            studioButton.addEventListener('click', function () {
                // The Lua side closes the panel and opens the studio.
                cfgPost('uniformStudio', { id: cfg.sel && cfg.sel.id });
            });
        }

        var vehicleStudioButton = document.getElementById('cfgVehicleStudioBtn');
        if (vehicleStudioButton) {
            vehicleStudioButton.addEventListener('click', function () {
                cfgPost('vehicleStudio', {});
            });
        }

        var vehicleEditButton = document.getElementById('cfgVehicleEditBtn');
        if (vehicleEditButton) {
            vehicleEditButton.addEventListener('click', function () {
                cfgPost('vehicleEdit', { id: cfg.sel && cfg.sel.id });
            });
        }

        var duplicateButton = document.getElementById('cfgDuplicateBtn');
        if (duplicateButton) {
            duplicateButton.addEventListener('click', function () {
                cfgPost('uniformDuplicate', { id: cfg.sel && cfg.sel.id });
            });
        }

        var deleteButton = document.getElementById('cfgDelete');
        if (deleteButton) {
            deleteButton.addEventListener('click', function () {
                if (deleteButton.dataset.armed !== 'true') {
                    deleteButton.dataset.armed = 'true';
                    deleteButton.textContent = 'Click again to delete';
                    return;
                }
                cfgDelete();
            });
        }
    }

    function cfgSave() {
        var sel = cfg.sel;
        if (!sel) return;
        var values = readForm();

        if (sel.type === 'agency') cfgPost('agencySave', values);
        else if (sel.type === 'station' || sel.type === 'new-station') {
            cfgPost('stationSave', {
                id: sel.id, label: values.label, coords: values.coords,
                kind: values.kind, publicBlip: values.publicBlip !== false,
                blipSprite: values.blipSprite, blipCustom: values.blipCustom, blipColor: values.blipColor
            });
        } else if (sel.type === 'zone' || sel.type === 'new-zone') {
            cfgPost('zoneSave', {
                stationId: sel.stationId, id: sel.id, kind: values.kind, label: values.label,
                radius: values.radius, minGrade: values.minGrade, coords: values.coords
            });
        } else if (sel.type === 'rank' || sel.type === 'new-rank') {
            cfgPost('rankSave', { label: values.label, grade: values.grade, permissions: values.permissions || {} });
        } else if (sel.type === 'division' || sel.type === 'new-division') {
            cfgPost('divisionSave', {
                id: sel.id, label: values.label, minGrade: values.minGrade,
                callsignPrefix: values.callsignPrefix || ''
            });
        } else if (sel.type === 'division-rank' || sel.type === 'new-division-rank') {
            cfgPost('divisionRankSave', { divisionId: sel.divisionId, grade: values.grade, label: values.label });
        } else if (sel.type === 'cert' || sel.type === 'new-cert') {
            cfgPost('certSave', {
                id: sel.id, label: values.label, description: values.description || '',
                licences: Object.keys(values.permissions || {})
            });
        } else if (sel.type === 'inv' || sel.type === 'new-inv') {
            var splitLines = function (text) {
                return String(text || '').split('\n').map(function (line) { return line.trim(); })
                    .filter(function (line) { return line !== ''; });
            };
            cfgPost('invSave', {
                id: sel.id, match: values.match,
                statements: splitLines(values.statements),
                leads: splitLines(values.leads)
            });
        } else if (sel.type === 'uniform' || sel.type === 'new-uniform') {
            cfgPost('uniformSave', {
                id: sel.id, label: values.label, minGrade: values.minGrade,
                variant: values.variant, division: values.division, capture: values.capture === true
            });
        } else if (sel.type === 'armory' || sel.type === 'new-armory') {
            cfgPost('armorySave', {
                id: sel.id, item: values.item, label: values.label, count: values.count,
                minGrade: values.minGrade, price: values.price, category: values.category,
                division: values.division
            });
        } else if (sel.type === 'vehicle' || sel.type === 'new-vehicle') {
            cfgPost('vehicleSave', {
                id: sel.id, label: values.label, minGrade: values.minGrade,
                division: values.division, capture: values.capture === true
            });
        } else if (sel.type === 'door') {
            cfgPost('doorSave', {
                id: sel.id, label: values.label, minGrade: values.minGrade,
                radius: values.radius, locked: values.locked === true, prompt: values.coords
            });
        } else if (sel.type === 'new-door') {
            cfgPost('doorCapture', { label: values.label, minGrade: values.minGrade });
        } else if (sel.type === 'app-form') {
            cfgPost('appFormSave', {
                enabled: values.enabled === true, title: values.title,
                rank: values.rank, division: values.division
            });
        } else if (sel.type === 'app-question' || sel.type === 'new-app-question') {
            cfgPost('appQuestionSave', { id: sel.id, label: values.label, required: values.required === true });
        } else if (sel.type === 'app-place' || sel.type === 'new-app-place') {
            cfgPost('appPlaceSave', { id: sel.id, label: values.label, coords: values.coords });
        }
    }

    function cfgDelete() {
        var sel = cfg.sel;
        if (!sel || !sel.id) return;
        if (sel.type === 'station') cfgPost('stationDelete', { id: sel.id });
        else if (sel.type === 'zone') cfgPost('zoneDelete', { stationId: sel.stationId, id: sel.id });
        else if (sel.type === 'rank') {
            var rank = cfgFind(cfgAgency().ranks, sel.id);
            if (rank) cfgPost('rankDelete', { grade: rank.grade });
        } else if (sel.type === 'division') cfgPost('divisionDelete', { id: sel.id });
        else if (sel.type === 'division-rank') {
            var rankRow = cfgFind((cfgFind(cfgAgency().divisions, sel.divisionId) || {}).ranks, sel.id);
            if (rankRow) cfgPost('divisionRankDelete', { divisionId: sel.divisionId, grade: rankRow.grade });
        }
        else if (sel.type === 'cert') cfgPost('certDelete', { id: sel.id });
        else if (sel.type === 'inv') cfgPost('invDelete', { id: sel.id });
        else if (sel.type === 'uniform') cfgPost('uniformDelete', { id: sel.id });
        else if (sel.type === 'armory') cfgPost('armoryDelete', { id: sel.id });
        else if (sel.type === 'vehicle') cfgPost('vehicleDelete', { id: sel.id });
        else if (sel.type === 'door') cfgPost('doorDelete', { id: sel.id });
        else if (sel.type === 'app-question') cfgPost('appQuestionDelete', { id: sel.id });
        else if (sel.type === 'app-place') cfgPost('appPlaceDelete', { id: sel.id });
        cfg.sel = null;
        cfgRenderList();
        cfgRenderForm();
    }

    function cfgRender() {
        var agency = cfgAgency();
        document.getElementById('cfgAgency').textContent = agency.short || 'FED';
        document.getElementById('cfgTitle').textContent = agency.label || 'Agency configuration';
        document.getElementById('cfgSubtitle').textContent = 'Live configuration';

        cfgItemsEl.innerHTML = '';
        (((cfg.data || {}).meta || {}).items || []).forEach(function (item) {
            var option = document.createElement('option');
            option.value = item.value;
            option.label = item.label;
            cfgItemsEl.appendChild(option);
        });

        cfgRenderTabs();
        cfgRenderList();
        cfgRenderForm();
    }

    function cfgOpen(data) {
        cfg.data = data || {};
        cfg.open = true;
        if (!cfg.sel) cfg.sel = { type: 'agency' };
        cfgEl.hidden = false;
        requestAnimationFrame(function () { cfgEl.dataset.open = 'true'; });
        cfgRender();
    }

    function cfgUpdate(data) {
        if (!cfg.open) return;
        cfg.data = data || cfg.data;
        cfgRender();
    }

    function cfgClose(notify) {
        if (!cfg.open) return;
        cfg.open = false;
        cfg.sel = null;
        cfgEl.dataset.open = 'false';
        window.setTimeout(function () { if (!cfg.open) cfgEl.hidden = true; }, 140);
        if (notify !== false) post('cfgClose', {});
    }

    cfgTabsEl.addEventListener('click', function (event) {
        var tab = event.target.closest('.cfg__tab');
        if (!tab) return;
        cfg.tab = tab.dataset.tab;
        cfg.sel = cfg.tab === 'agency' ? { type: 'agency' } : null;
        cfgRender();
    });

    cfgListEl.addEventListener('click', function (event) {
        var item = event.target.closest('.cfg__row');
        if (!item || !item.dataset.sel) return;
        cfg.sel = JSON.parse(item.dataset.sel);
        cfgRenderList();
        cfgRenderForm();
    });

    document.getElementById('cfgCloseBtn').addEventListener('click', function () { cfgClose(); });

    document.addEventListener('keydown', function (event) {
        if (!cfg.open || dialogState.open) return;
        if (event.key === 'Escape') { event.preventDefault(); cfgClose(); }
    });

    /* Input dialog. Fields are typed by the player, submitted whole, and the
       result goes back to Lua as { values } or { cancelled: true }. */
    var dialogEl = document.getElementById('dialog');
    var dialogForm = document.getElementById('dialogForm');
    var dialogTitle = document.getElementById('dialogTitle');
    var dialogFields = document.getElementById('dialogFields');
    var dialogState = { open: false, fields: [] };

    function dialogOpen(data) {
        data = data || {};
        dialogState.open = true;
        dialogState.fields = Array.isArray(data.fields) ? data.fields : [];

        dialogTitle.textContent = data.title || 'Input';
        dialogFields.innerHTML = '';

        dialogState.fields.forEach(function (field, index) {
            var wrap = document.createElement('div');
            var label = document.createElement('label');
            label.className = 'dialog__label';
            label.textContent = (field.label || field.name || 'Field') + (field.required ? ' *' : '');
            label.setAttribute('for', 'dialogField' + index);

            var input;
            if (field.type === 'textarea') {
                /* Long-form entry: reports and narratives are written, not
                   typed into a slot. Enter makes a new line here. */
                input = document.createElement('textarea');
                input.className = 'dialog__input dialog__textarea';
                input.rows = field.rows || 6;
            } else {
                input = document.createElement('input');
                input.className = 'dialog__input';
                input.type = field.type === 'number' ? 'number' : 'text';
            }
            input.id = 'dialogField' + index;
            input.autocomplete = 'off';
            input.spellcheck = false;
            if (field.default !== undefined && field.default !== null) input.value = String(field.default);
            if (field.placeholder) input.placeholder = field.placeholder;

            wrap.appendChild(label);
            wrap.appendChild(input);

            /* Long-form fields get a formatting bar: bold, italic, bullets.
               The buttons insert the same markdown-lite the report renderer
               understands, wrapped around whatever is selected. */
            if (field.type === 'textarea') {
                var tools = document.createElement('div');
                tools.className = 'dialog__tools';
                [['B', '**', '**'], ['I', '*', '*'], ['• List', '\n- ', '']].forEach(function (tool) {
                    var btn = document.createElement('button');
                    btn.type = 'button';
                    btn.className = 'dialog__tool';
                    btn.textContent = tool[0];
                    btn.addEventListener('click', function () {
                        var start = input.selectionStart || 0;
                        var end = input.selectionEnd || 0;
                        var value = input.value;
                        input.value = value.slice(0, start) + tool[1] + value.slice(start, end) + tool[2] + value.slice(end);
                        input.focus();
                        input.selectionStart = start + tool[1].length;
                        input.selectionEnd = end + tool[1].length;
                    });
                    tools.appendChild(btn);
                });
                var hint = document.createElement('span');
                hint.className = 'dialog__toolHint';
                hint.textContent = 'renders formatted in the report';
                tools.appendChild(hint);
                wrap.insertBefore(tools, input);
            }

            /* A select field is a search box over a provided option list:
               type to filter, click or Enter to pick. The chosen VALUE (the
               spawn code) is kept on the input's dataset; the visible text
               shows the friendly label. allowCustom lets unlisted values
               through for addon content the list does not know about. */
            if (field.type === 'select' && Array.isArray(field.options)) {
                var listEl = document.createElement('div');
                listEl.className = 'dialog__options';
                listEl.hidden = true;
                wrap.appendChild(listEl);
                wrap.className = 'dialog__selectWrap';

                var renderList = function () {
                    var needle = (input.value || '').toLowerCase();
                    var matches = [];
                    for (var i = 0; i < field.options.length && matches.length < 30; i += 1) {
                        var option = field.options[i];
                        var value = String(option.value === undefined ? option : option.value);
                        var text = String(option.label === undefined ? value : option.label);
                        if (!needle || text.toLowerCase().indexOf(needle) !== -1
                            || value.toLowerCase().indexOf(needle) !== -1) {
                            matches.push({ value: value, label: text });
                        }
                    }

                    listEl.innerHTML = '';
                    matches.forEach(function (match) {
                        var row = document.createElement('button');
                        row.type = 'button';
                        row.className = 'dialog__option';
                        row.innerHTML = escapeHtml(match.label)
                            + (match.value !== match.label
                                ? ' <span class="dialog__optionValue">' + escapeHtml(match.value) + '</span>' : '');
                        row.addEventListener('click', function () {
                            input.value = match.label;
                            input.dataset.value = match.value;
                            listEl.hidden = true;
                        });
                        listEl.appendChild(row);
                    });
                    listEl.hidden = matches.length === 0;
                };

                input.addEventListener('input', function () {
                    delete input.dataset.value;
                    renderList();
                });
                input.addEventListener('focus', renderList);
                /* Enter with the list open picks the top match instead of
                   submitting a half-typed value. */
                input.addEventListener('keydown', function (event) {
                    if (event.key !== 'Enter' || listEl.hidden) return;
                    var first = listEl.querySelector('.dialog__option');
                    if (first && !input.dataset.value) {
                        event.preventDefault();
                        first.click();
                    }
                });
            }

            dialogFields.appendChild(wrap);
        });

        dialogEl.hidden = false;
        requestAnimationFrame(function () {
            dialogEl.dataset.open = 'true';
            var first = dialogFields.querySelector('input');
            if (first) first.focus();
        });
    }

    function dialogClose(notifyResult) {
        if (!dialogState.open) return;
        dialogState.open = false;
        dialogEl.dataset.open = 'false';
        window.setTimeout(function () { if (!dialogState.open) dialogEl.hidden = true; }, 140);
        if (notifyResult) post('inputResult', notifyResult);
    }

    dialogForm.addEventListener('submit', function (event) {
        event.preventDefault();
        if (!dialogState.open) return;

        var values = {};
        var valid = true;

        dialogState.fields.forEach(function (field, index) {
            var input = document.getElementById('dialogField' + index);
            var raw = input ? input.value : '';
            var value;
            if (field.type === 'number') {
                value = raw === '' ? null : Number(raw);
            } else if (field.type === 'select') {
                /* Prefer the picked option's value; fall back to the typed
                   text when the field allows custom entries. */
                value = (input && input.dataset.value) || (field.allowCustom ? raw : '');
            } else {
                value = raw;
            }

            var missing = field.required && (value === null || value === '' || (field.type === 'number' && isNaN(value)));
            if (input) input.classList.toggle('dialog__input--invalid', !!missing);
            if (missing) { valid = false; return; }

            if (value !== null && value !== '') values[field.name || String(index + 1)] = value;
        });

        if (!valid) return;
        dialogClose({ values: values });
    });

    document.getElementById('dialogCancel').addEventListener('click', function () {
        dialogClose({ cancelled: true });
    });

    document.addEventListener('keydown', function (event) {
        if (!dialogState.open) return;
        if (event.key === 'Escape') { event.preventDefault(); dialogClose({ cancelled: true }); }
    });

    window.addEventListener('message', function (event) {
        var data = event.data || {};
        if (data.action === 'photo:shrink') {
            /* The camera's full-resolution capture downscales here on a
               canvas before it goes anywhere near the network. */
            var shot = new Image();
            shot.onload = function () {
                var scale = Math.min(1, (data.maxWidth || 1280) / shot.width);
                var canvas = document.createElement('canvas');
                canvas.width = Math.max(1, Math.round(shot.width * scale));
                canvas.height = Math.max(1, Math.round(shot.height * scale));
                canvas.getContext('2d').drawImage(shot, 0, 0, canvas.width, canvas.height);
                post('photoShrunk', { id: data.id, data: canvas.toDataURL('image/jpeg', data.quality || 0.72) });
            };
            shot.onerror = function () { post('photoShrunk', { id: data.id, data: null }); };
            shot.src = data.data;
            return;
        }
        if (data.action === 'mdt:open') { mdtOpen(data.mdt); return; }
        if (data.action === 'mdt:close') { mdtClose(false); return; }
        if (data.action === 'mdt:map') {
            if (mdt.open && mdt.data.map) {
                mdt.data.map.units = data.units || [];
                if (mdt.view === 'dispatch') { mdtRenderDispatch(); mapRender(); }
            }
            return;
        }
        if (data.action === 'hud') { hudRender(data.hud); return; }
        if (data.action === 'camera') { cameraMode = !!data.enabled; return; }
        if (data.action === 'door:prompt') { doorPrompt(data); return; }
        if (data.action === 'notify') { toast(data); return; }
        if (data.action === 'grid:open') { applyTheme(data.theme); gridOpen(data.grid); return; }
        if (data.action === 'grid:close') { gridClose(false); return; }
        if (data.action === 'config:open') { cfgOpen(data.config); return; }
        if (data.action === 'config:update') { cfgUpdate(data.config); return; }
        if (data.action === 'config:close') { cfgClose(false); return; }
        if (data.action === 'input:open') { applyTheme(data.theme); dialogOpen(data.input); return; }
        if (data.action === 'input:close') { dialogClose(null); return; }
        if (data.action === 'open') { applyTheme(data.theme); open(data.menu || {}); }
        else if (data.action === 'close') close(false);
        else if (data.action === 'theme') applyTheme(data.theme);
        else if (data.action === 'progress:open') progressOpen(data);
        else if (data.action === 'progress:close') progressClose();
    });

    // Exposed for the offline preview in tests/ui.
    window.__dagMenu = {
        open: open, close: close, applyTheme: applyTheme, state: state,
        progressOpen: progressOpen, progressClose: progressClose,
        hudRender: hudRender, mdtOpen: mdtOpen, mdtClose: mdtClose, mdtState: mdt,
        dialogOpen: dialogOpen, dialogClose: dialogClose,
        cfgOpen: cfgOpen, cfgClose: cfgClose, cfgState: cfg
    };
})();
