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
    var mdtTitle = document.getElementById('mdtTitle');
    var mdtSubtitle = document.getElementById('mdtSubtitle');
    var mdtTabsEl = document.getElementById('mdtTabs');
    var mdtListEl = document.getElementById('mdtList');
    var mdtDetailEl = document.getElementById('mdtDetail');
    var mdtToolbar = document.getElementById('mdtToolbar');
    var mdtSearch = document.getElementById('mdtSearch');
    var mdtStatus = document.getElementById('mdtStatus');

    var mdt = { open: false, data: {}, tab: null, selected: null, query: '' };

    /* Which tabs exist, what they read, and how a row renders. Adding a tab is
       a matter of adding an entry here and shipping the list from Lua. */
    var MDT_TABS = [
        { key: 'incidents', label: 'Incidents', search: true },
        { key: 'warrants', label: 'Warrants' },
        { key: 'bolos', label: 'BOLOs' },
        { key: 'records', label: 'Records', search: true },
        { key: 'evidence', label: 'Evidence' },
        { key: 'leads', label: 'Leads' },
        { key: 'reports', label: 'Reports' },
        { key: 'units', label: 'Units' },
        { key: 'custody', label: 'Custody' }
    ];

    function mdtRows(key) {
        var rows = mdt.data[key];
        return Array.isArray(rows) ? rows : [];
    }

    function mdtVisibleRows(key) {
        var rows = mdtRows(key);
        if (!mdt.query) return rows;

        var needle = mdt.query.toLowerCase();
        return rows.filter(function (row) {
            return [row.title, row.meta, row.pill].some(function (field) {
                return field && String(field).toLowerCase().indexOf(needle) !== -1;
            });
        });
    }

    function mdtRenderTabs() {
        mdtTabsEl.innerHTML = '';
        MDT_TABS.forEach(function (tab) {
            if (!mdt.data[tab.key]) return;

            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mdt__tab';
            button.dataset.tab = tab.key;
            button.setAttribute('role', 'tab');
            button.setAttribute('aria-selected', String(tab.key === mdt.tab));
            button.innerHTML = '<span>' + escapeHtml(tab.label) + '</span>'
                + '<span class="mdt__tabCount">' + mdtRows(tab.key).length + '</span>';
            mdtTabsEl.appendChild(button);
        });
    }

    function mdtRenderList() {
        var definition = MDT_TABS.filter(function (tab) { return tab.key === mdt.tab; })[0] || {};
        mdtToolbar.hidden = !definition.search;

        var rows = mdtVisibleRows(mdt.tab);
        mdtListEl.innerHTML = '';

        if (!rows.length) {
            var empty = document.createElement('li');
            empty.className = 'mdt__empty';
            empty.textContent = mdt.query ? 'Nothing matches.' : 'Nothing on file.';
            mdtListEl.appendChild(empty);
            return;
        }

        rows.forEach(function (row, index) {
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
    }

    function mdtRenderDetail() {
        var rows = mdtVisibleRows(mdt.tab);
        var row = rows[mdt.selected];

        if (!row) {
            mdtDetailEl.innerHTML = '<div class="mdt__empty">Select an entry.</div>';
            return;
        }

        var html = '<h2 class="mdt__h">' + escapeHtml(row.title || '') + '</h2>';
        if (row.meta) html += '<p class="mdt__sub">' + escapeHtml(row.meta) + '</p>';

        (row.sections || []).forEach(function (section) {
            html += '<div class="mdt__section">' + escapeHtml(section.label || '') + '</div>';

            (section.fields || []).forEach(function (field) {
                html += '<div class="mdt__field"><span class="mdt__fieldLabel">'
                    + escapeHtml(field.label || '') + '</span><span class="mdt__fieldValue">'
                    + escapeHtml(field.value === undefined || field.value === null ? '' : field.value)
                    + '</span></div>';
            });

            (section.notes || []).forEach(function (note) {
                html += '<div class="mdt__note">'
                    + (note.meta ? '<div class="mdt__noteMeta">' + escapeHtml(note.meta) + '</div>' : '')
                    + escapeHtml(note.text || '') + '</div>';
            });
        });

        if ((row.actions || []).length) {
            html += '<div class="mdt__actions">';
            row.actions.forEach(function (action, index) {
                html += '<button type="button" class="mdt__action'
                    + (action.tone === 'danger' ? ' mdt__action--danger' : '')
                    + '" data-action="' + index + '">' + escapeHtml(action.label || '') + '</button>';
            });
            html += '</div>';
        }

        mdtDetailEl.innerHTML = html;
    }

    function mdtRender() {
        mdtAgency.textContent = mdt.data.agency || 'FED';
        mdtTitle.textContent = mdt.data.title || 'Mobile data terminal';
        mdtSubtitle.textContent = mdt.data.subtitle || '';
        mdtStatus.textContent = mdt.data.status || 'Ready';

        mdtRenderTabs();
        mdtRenderList();
        mdtRenderDetail();
    }

    function mdtOpen(data) {
        mdt.data = data || {};
        mdt.open = true;

        /* Keep the tab across a refresh so acting on a row does not throw the
           officer back to the first tab. */
        var available = MDT_TABS.filter(function (tab) { return mdt.data[tab.key]; });
        if (!mdt.tab || !mdt.data[mdt.tab]) {
            mdt.tab = available.length ? available[0].key : null;
            mdt.selected = null;
            mdt.query = '';
            mdtSearch.value = '';
        }

        mdtEl.hidden = false;
        requestAnimationFrame(function () { mdtEl.dataset.open = 'true'; });
        mdtRender();
    }

    function mdtClose(notify) {
        if (!mdt.open) return;
        mdt.open = false;
        mdtEl.dataset.open = 'false';
        window.setTimeout(function () { if (!mdt.open) mdtEl.hidden = true; }, 140);
        if (notify !== false) post('mdtClose', {});
    }

    mdtTabsEl.addEventListener('click', function (event) {
        var tab = event.target.closest('.mdt__tab');
        if (!tab) return;
        mdt.tab = tab.dataset.tab;
        mdt.selected = null;
        mdt.query = '';
        mdtSearch.value = '';
        mdtRender();
    });

    mdtListEl.addEventListener('click', function (event) {
        var row = event.target.closest('.mdt__row');
        if (!row) return;
        mdt.selected = Number(row.dataset.index);
        mdtRenderList();
        mdtRenderDetail();
    });

    mdtDetailEl.addEventListener('click', function (event) {
        var button = event.target.closest('.mdt__action');
        if (!button) return;

        var row = mdtVisibleRows(mdt.tab)[mdt.selected];
        var action = row && (row.actions || [])[Number(button.dataset.action)];
        if (!action) return;

        /* Handlers stay in Lua: the UI sends what was pressed and on which
           record, never anything executable. */
        post('mdtAction', { tab: mdt.tab, id: row.id, action: action.id });
    });

    mdtSearch.addEventListener('input', function () {
        mdt.query = mdtSearch.value || '';
        mdt.selected = null;
        mdtRenderList();
        mdtRenderDetail();
    });

    document.getElementById('mdtClose').addEventListener('click', function () { mdtClose(); });

    document.addEventListener('keydown', function (event) {
        if (!mdt.open) return;
        if (event.key === 'Escape') { event.preventDefault(); mdtClose(); }
    });

    window.addEventListener('message', function (event) {
        var data = event.data || {};
        if (data.action === 'mdt:open') { mdtOpen(data.mdt); return; }
        if (data.action === 'mdt:close') { mdtClose(false); return; }
        if (data.action === 'hud') { hudRender(data.hud); return; }
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
        hudRender: hudRender, mdtOpen: mdtOpen, mdtClose: mdtClose, mdtState: mdt
    };
})();
