// Commit view: changes tree with checkboxes, commit message and buttons.
(() => {
  const vscode = acquireVsCodeApi();
  const { h, showMenu, basename, dirname } = gt;

  const saved = vscode.getState() || {};
  let state = null;
  const collapsed = new Set(saved.collapsed || []);
  let selected = new Set();
  let anchor = null;
  let messageFocused = false;

  const app = document.getElementById('app');
  const banner = h('div#banner');
  const tree = h('div#tree', { tabindex: '0' });
  const amend = h('input', { type: 'checkbox', id: 'amend' });
  const genBtn = h('button.icon#gen', { title: 'Generate Commit Message' }, '✨');
  const message = h('textarea#message', { rows: '5', placeholder: 'Commit Message' });
  const commitBtn = h('button#commit', { text: 'Commit' });
  const pushBtn = h('button.secondary#commitPush', { text: 'Commit and Push…' });
  const count = h('span.muted#count');
  const bottom = h('div#bottom', null,
    h('div.row', null,
      h('label.amend', null, amend, ' Amend'),
      h('span.spacer'),
      genBtn),
    message,
    h('div.row', null, commitBtn, pushBtn, h('span.spacer'), count));
  app.append(banner, tree, bottom);

  const post = (type, data = {}) => vscode.postMessage({ type, ...data });
  const persist = () => vscode.setState({ collapsed: [...collapsed] });

  // ------------------------------------------------------------- events

  amend.addEventListener('change', () => post('amend', { value: amend.checked }));
  genBtn.addEventListener('click', () => post(state && state.generating ? 'cancelGenerate' : 'generate'));
  message.addEventListener('input', () => post('message', { text: message.value }));
  message.addEventListener('focus', () => { messageFocused = true; });
  message.addEventListener('blur', () => { messageFocused = false; });
  message.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      post('commit', { push: false });
    }
  });
  commitBtn.addEventListener('click', () => post('commit', { push: false }));
  pushBtn.addEventListener('click', () => post('commit', { push: true }));

  tree.addEventListener('keydown', (e) => {
    if (!state) return;
    const files = visibleFiles();
    const sel = [...selected];
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      let i = files.findIndex((f) => f.path === anchor);
      i = Math.max(0, Math.min(files.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)));
      if (files[i]) select(files[i], false, false, true);
    } else if (e.key === ' ' && sel.length) {
      e.preventDefault();
      const changes = state.changes.filter((c) => selected.has(c.path) && c.type !== 'conflicted');
      post('toggle', { paths: changes.map((c) => c.path), value: !changes.every((c) => c.included) });
    } else if (e.key === 'Enter' && sel.length) {
      post('open', { path: sel[0], preview: false });
    } else if (e.key === 'a' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      selected = new Set(files.map((f) => f.path));
      render();
    } else if (e.key === 'Delete' && sel.length) {
      post('menu', { action: 'rollback', paths: sel });
    }
  });

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.type === 'state') {
      state = msg.state;
      const paths = new Set(state.changes.map((c) => c.path));
      selected = new Set([...selected].filter((p) => paths.has(p)));
      render();
    } else if (msg.type === 'message') {
      if (message.value !== msg.text && (!messageFocused || msg.force)) message.value = msg.text;
    } else if (msg.type === 'focusMessage') {
      message.focus();
    }
  });

  // ------------------------------------------------------------- render

  function groups() {
    const c = state.changes;
    return [
      { key: 'conflicts', label: 'Merge Conflicts', files: c.filter((x) => x.type === 'conflicted'), checkable: false, hideEmpty: true },
      { key: 'changes', label: 'Changes', files: c.filter((x) => x.type !== 'conflicted' && x.type !== 'untracked'), checkable: true },
      { key: 'unversioned', label: 'Unversioned Files', files: c.filter((x) => x.type === 'untracked'), checkable: true, hideEmpty: true },
    ].filter((g) => !(g.hideEmpty && !g.files.length));
  }

  function visibleFiles() {
    return groups().flatMap((g) => (collapsed.has(g.key) ? [] : g.files));
  }

  function select(f, ctrl, shift, open) {
    if (ctrl) {
      if (selected.has(f.path)) selected.delete(f.path);
      else selected.add(f.path);
      anchor = f.path;
    } else if (shift && anchor) {
      const files = visibleFiles().map((x) => x.path);
      const a = files.indexOf(anchor);
      const b = files.indexOf(f.path);
      if (a >= 0 && b >= 0) selected = new Set(files.slice(Math.min(a, b), Math.max(a, b) + 1));
    } else {
      selected = new Set([f.path]);
      anchor = f.path;
      if (open && f.type !== 'conflicted') post('open', { path: f.path, preview: true });
    }
    render();
    const row = tree.querySelector(`[data-path="${CSS.escape(f.path)}"]`);
    if (row) row.scrollIntoView({ block: 'nearest' });
  }

  function render() {
    if (!state) return;
    renderBanner();
    const scroll = tree.scrollTop;
    tree.replaceChildren();
    if (!state.repo) {
      tree.append(h('div.empty', { text: 'No Git repository found in this workspace.' }));
      return;
    }
    for (const g of groups()) {
      const isCollapsed = collapsed.has(g.key);
      const n = g.files.filter((f) => f.included).length;
      const header = h('div.row.group', {
        onclick: (e) => {
          if (e.target.tagName === 'INPUT' || e.target.classList.contains('link')) return;
          if (isCollapsed) collapsed.delete(g.key);
          else collapsed.add(g.key);
          persist();
          render();
        },
      },
      h('span.chev', { text: isCollapsed ? '▸' : '▾' }),
      g.checkable ? h('input', {
        type: 'checkbox',
        checked: g.files.length > 0 && n === g.files.length,
        disabled: !g.files.length,
        onchange: (e) => post('toggle', { paths: g.files.map((f) => f.path), value: e.target.checked }),
      }) : null,
      h('span.glabel', { text: g.label }),
      h('span.muted', { text: `${g.files.length} file${g.files.length === 1 ? '' : 's'}` }),
      g.key === 'conflicts' ? h('span.link', { text: 'Resolve', onclick: () => post('resolve') }) : null);
      if (g.checkable && n > 0 && n < g.files.length) header.querySelector('input').indeterminate = true;
      tree.append(header);
      if (!g.files.length && g.key === 'changes') {
        tree.append(h('div.empty', { text: 'No changes' }));
      }
      if (isCollapsed) continue;
      for (const f of g.files) {
        const row = h(`div.row.file${selected.has(f.path) ? '.selected' : ''}`, {
          'data-path': f.path,
          title: `${f.type}: ${f.path}${f.oldPath ? ` (from ${f.oldPath})` : ''}`,
          onclick: (e) => {
            if (e.target.tagName === 'INPUT') return;
            tree.focus();
            select(f, e.ctrlKey || e.metaKey, e.shiftKey, true);
          },
          ondblclick: () => post(f.type === 'conflicted' ? 'resolve' : 'open', { path: f.path, preview: false }),
          oncontextmenu: (e) => {
            e.preventDefault();
            if (!selected.has(f.path)) select(f, false, false, false);
            contextMenu(e.clientX, e.clientY);
          },
        },
        g.checkable ? h('input', {
          type: 'checkbox',
          checked: f.included,
          onchange: (e) => {
            const paths = selected.has(f.path) && selected.size > 1 ? [...selected] : [f.path];
            post('toggle', { paths, value: e.target.checked });
          },
        }) : h('span.nocheck'),
        h(`span.name.t-${f.type}`, { text: basename(f.path) }),
        h('span.dir.muted.ellipsis', { text: f.oldPath ? `← ${f.oldPath}` : dirname(f.path) }));
        tree.append(row);
      }
    }
    tree.scrollTop = scroll;

    amend.checked = !!state.amend;
    amend.disabled = !state.hasCommits;
    if (!messageFocused || state.generating) {
      if (message.value !== state.message) message.value = state.message;
    }
    message.placeholder = state.repoState !== 'normal' ? 'Merge commit message' : 'Commit Message';
    commitBtn.textContent = state.amend ? 'Amend Commit' : 'Commit';
    commitBtn.disabled = !!state.busy;
    pushBtn.disabled = !!state.busy;
    genBtn.textContent = state.generating ? '■' : '✨';
    genBtn.title = state.generating
      ? 'Stop generating'
      : state.aiReady ? `Generate Commit Message (${state.aiModel})` : 'Generate Commit Message (set up AI first)';
    genBtn.classList.toggle('busy', !!state.generating);
    message.readOnly = !!state.generating;
    const inc = state.changes.filter((c) => c.included).length;
    count.textContent = state.busy ? `${state.busy}…` : inc ? `${inc} selected` : '';
  }

  function renderBanner() {
    banner.replaceChildren();
    if (!state || state.repoState === 'normal') {
      banner.hidden = true;
      return;
    }
    banner.hidden = false;
    const label = { merging: 'Merging', rebasing: 'Rebasing', cherryPicking: 'Cherry-picking', reverting: 'Reverting' }[state.repoState];
    const conflicts = state.changes.filter((c) => c.type === 'conflicted').length;
    banner.append(
      h('div', { text: conflicts ? `${label} in progress · ${conflicts} conflict${conflicts === 1 ? '' : 's'}` : `${label} in progress · all conflicts resolved` }),
      h('div.row', null,
        conflicts ? h('button.secondary', { text: 'Resolve…', onclick: () => post('resolve') })
          : h('button.secondary', { text: 'Continue', onclick: () => post('continue') }),
        h('button.secondary', { text: 'Abort', onclick: () => post('abort') })),
    );
  }

  function contextMenu(x, y) {
    const sel = state.changes.filter((c) => selected.has(c.path));
    if (!sel.length) return;
    const single = sel.length === 1 ? sel[0] : null;
    const allUntracked = sel.every((c) => c.type === 'untracked');
    const anyTracked = sel.some((c) => c.type !== 'untracked' && c.type !== 'conflicted');
    const anyConflict = sel.some((c) => c.type === 'conflicted');
    const items = [
      { label: 'Show Diff', id: 'diff', disabled: anyConflict && !!single },
      { label: 'Open File', id: 'openFile', disabled: !single || single.type === 'deleted' },
    ];
    if (anyConflict) items.push({ label: 'Resolve Conflicts…', id: 'resolve' });
    items.push('-',
      { label: 'Include in Commit', id: 'include' },
      { label: 'Exclude from Commit', id: 'exclude' },
      '-',
      { label: 'Rollback…', id: 'rollback', disabled: !anyTracked });
    if (allUntracked) {
      items.push({ label: 'Delete…', id: 'delete', danger: true }, { label: 'Add to .gitignore', id: 'ignore' });
    }
    items.push('-',
      { label: 'Show History', id: 'history', disabled: !single || single.type === 'untracked' },
      { label: 'Copy Path', id: 'copy' },
      { label: 'Reveal in Explorer View', id: 'reveal', disabled: !single || single.type === 'deleted' });
    showMenu(x, y, items, (action) => post('menu', { action, paths: sel.map((c) => c.path) }));
  }

  post('ready');
})();
