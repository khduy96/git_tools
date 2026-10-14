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
    } else if ((e.key === 'a' || e.key === 'A') && e.ctrlKey && e.altKey) {
      // Ctrl+Alt+A: Add to VCS (Android Studio shortcut).
      e.preventDefault();
      const untracked = state.changes.filter((c) => selected.has(c.path) && c.type === 'untracked');
      if (untracked.length) post('addToVcs', { paths: untracked.map((c) => c.path) });
    }
  });

  // ------------------------------------------------------------- drag & drop
  // Unversioned files dropped on "Changes" are added to git; newly added
  // files dropped on "Unversioned Files" are removed from the index again.

  /** @type {{from: string, paths: string[]}|null} */
  let dragging = null;

  const dropAllowed = (to) => !!dragging &&
    ((dragging.from === 'unversioned' && to === 'changes') || (dragging.from === 'changes' && to === 'unversioned'));

  function clearDropHighlight() {
    for (const el of tree.querySelectorAll('.drop')) el.classList.remove('drop');
  }

  function highlight(group) {
    clearDropHighlight();
    for (const el of tree.querySelectorAll(`[data-group="${group}"]`)) el.classList.add('drop');
  }

  tree.addEventListener('dragover', (e) => {
    const target = e.target instanceof Element ? e.target.closest('[data-group]') : null;
    const to = target ? target.getAttribute('data-group') : null;
    if (!to || !dropAllowed(to)) {
      clearDropHighlight();
      return;
    }
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    highlight(to);
  });

  tree.addEventListener('dragleave', (e) => {
    if (!tree.contains(/** @type {Node} */ (e.relatedTarget))) clearDropHighlight();
  });

  tree.addEventListener('drop', (e) => {
    const target = e.target instanceof Element ? e.target.closest('[data-group]') : null;
    const to = target ? target.getAttribute('data-group') : null;
    clearDropHighlight();
    if (!to || !dropAllowed(to)) return;
    e.preventDefault();
    post(to === 'changes' ? 'addToVcs' : 'unversion', { paths: dragging.paths });
    dragging = null;
  });

  /** Files of group `g` that can be moved to the other group. */
  const movable = (g, c) => (g.key === 'unversioned' ? c.type === 'untracked' : c.type === 'added');

  function onDragStart(e, g, f) {
    // Drag the whole selection when the row is part of it.
    const paths = selected.has(f.path)
      ? state.changes.filter((c) => selected.has(c.path) && movable(g, c)).map((c) => c.path)
      : [f.path];
    startDrag(e, g, paths, paths.length === 1 ? basename(paths[0]) : `${paths.length} files`);
  }

  /** Dragging a folder moves every file below it. */
  function onDirDragStart(e, g, d, files) {
    const paths = files.map((c) => c.path);
    startDrag(e, g, paths, `${d.name}/ (${paths.length} file${paths.length === 1 ? '' : 's'})`);
  }

  function startDrag(e, g, paths, label) {
    dragging = { from: g.key, paths };
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', paths.join('\n'));
    const ghost = h('div.dragghost', { text: label });
    document.body.append(ghost);
    e.dataTransfer.setDragImage(ghost, -10, -10);
    setTimeout(() => ghost.remove(), 0);
  }

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

  /** Files in the order they are rendered (for keyboard navigation). */
  let order = [];
  function visibleFiles() {
    return order;
  }

  /** Builds a directory tree; single-child directory chains are merged ("a/b/c"). */
  function buildTree(files) {
    const root = { name: '', path: '', dirs: new Map(), files: [] };
    for (const f of files) {
      const dir = dirname(f.path);
      let node = root;
      if (dir) {
        for (const part of dir.split('/')) {
          if (!node.dirs.has(part)) {
            node.dirs.set(part, { name: part, path: node.path ? `${node.path}/${part}` : part, dirs: new Map(), files: [] });
          }
          node = node.dirs.get(part);
        }
      }
      node.files.push(f);
    }
    const compress = (node) => {
      for (const [key, child] of [...node.dirs]) {
        let c = child;
        while (!c.files.length && c.dirs.size === 1) {
          const only = c.dirs.values().next().value;
          c = { name: `${c.name}/${only.name}`, path: only.path, dirs: only.dirs, files: only.files };
        }
        node.dirs.set(key, c);
        compress(c);
      }
    };
    compress(root);
    return root;
  }

  function filesUnder(node) {
    return [...node.files, ...[...node.dirs.values()].flatMap(filesUnder)];
  }

  function checkbox(files) {
    const n = files.filter((f) => f.included).length;
    const box = h('input', {
      type: 'checkbox',
      checked: files.length > 0 && n === files.length,
      disabled: !files.length,
      onchange: (e) => post('toggle', { paths: files.map((f) => f.path), value: e.target.checked }),
    });
    if (n > 0 && n < files.length) box.indeterminate = true;
    return box;
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
    order = [];
    if (!state.repo) {
      tree.append(h('div.empty', { text: 'No Git repository found in this workspace.' }));
      return;
    }
    for (const g of groups()) {
      const isCollapsed = collapsed.has(g.key);
      const n = g.files.filter((f) => f.included).length;
      const header = h('div.row.group', {
        'data-group': g.key,
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
        tree.append(h('div.empty', { 'data-group': g.key, text: 'No changes' }));
      }
      if (isCollapsed) continue;
      if (state.groupBy === 'directory') {
        renderDir(g, buildTree(g.files), 0);
      } else {
        for (const f of g.files) renderFile(g, f, 0);
      }
    }
    tree.scrollTop = scroll;
    renderBottom();
  }

  function renderDir(g, node, depth) {
    const dirs = [...node.dirs.values()].sort((a, b) => a.name.localeCompare(b.name));
    for (const d of dirs) {
      const key = `${g.key}:${d.path}`;
      const isCollapsed = collapsed.has(key);
      const files = filesUnder(d);
      // A folder can be dragged when every file below it can move groups.
      const draggable = files.length > 0 && files.every((c) => movable(g, c)) &&
        (g.key === 'unversioned' || g.key === 'changes');
      tree.append(h('div.row.dir', {
        'data-group': g.key,
        style: { paddingLeft: `${24 + depth * 14}px` },
        draggable: draggable ? 'true' : null,
        ondragstart: draggable ? (e) => onDirDragStart(e, g, d, files) : null,
        ondragend: draggable ? () => { dragging = null; clearDropHighlight(); } : null,
        title: `${d.path}${draggable ? (g.key === 'unversioned'
          ? '\nDrag to "Changes" to add the whole folder to Git'
          : '\nDrag to "Unversioned Files" to unversion the whole folder') : ''}`,
        onclick: (e) => {
          if (e.target.tagName === 'INPUT') return;
          if (isCollapsed) collapsed.delete(key);
          else collapsed.add(key);
          persist();
          render();
        },
      },
      h('span.chev', { text: isCollapsed ? '▸' : '▾' }),
      g.checkable ? checkbox(files) : null,
      h('span.folder'),
      h('span.dname.ellipsis', { text: d.name }),
      h('span.muted', { text: String(files.length) })));
      if (!isCollapsed) renderDir(g, d, depth + 1);
    }
    for (const f of node.files) renderFile(g, f, depth);
  }

  function renderFile(g, f, depth) {
    order.push(f);
    const flat = state.groupBy !== 'directory';
    // In directory mode files line up with the checkbox of sibling folders.
    const draggable = (g.key === 'unversioned' && f.type === 'untracked') || (g.key === 'changes' && f.type === 'added');
    tree.append(h(`div.row.file${selected.has(f.path) ? '.selected' : ''}`, {
      style: { paddingLeft: `${24 + depth * 14 + (flat ? 0 : 16)}px` },
      'data-path': f.path,
      'data-group': g.key,
      draggable: draggable ? 'true' : null,
      ondragstart: draggable ? (e) => onDragStart(e, g, f) : null,
      ondragend: draggable ? () => { dragging = null; clearDropHighlight(); } : null,
      title: `${f.type}: ${f.path}${f.oldPath ? ` (from ${f.oldPath})` : ''}${
        g.key === 'unversioned' ? '\nDrag to "Changes" to add to Git' : f.type === 'added' ? '\nDrag to "Unversioned Files" to unversion' : ''}`,
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
    g.checkable ? fileCheckbox(f) : h('span.nocheck'),
    h(`span.name.t-${f.type}`, { text: basename(f.path) }),
    f.lines ? h('span.partial', {
      text: `${f.lines.selected}/${f.lines.total} lines`,
      title: 'Only some lines are committed. Click to change the selection.',
      onclick: (e) => {
        e.stopPropagation();
        post('menu', { action: 'selectLines', paths: [f.path] });
      },
    }) : null,
    h('span.dir.muted.ellipsis', { text: f.oldPath ? `← ${f.oldPath}` : flat ? dirname(f.path) : '' })));
  }

  /** File checkbox; half-checked when only some lines are committed. */
  function fileCheckbox(f) {
    const box = h('input', {
      type: 'checkbox',
      checked: f.included,
      onchange: (e) => {
        const paths = selected.has(f.path) && selected.size > 1 ? [...selected] : [f.path];
        post('toggle', { paths, value: e.target.checked });
      },
    });
    if (f.lines) box.indeterminate = true;
    return box;
  }

  function renderBottom() {
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
      { label: 'Select Lines to Commit…', id: 'selectLines', disabled: !(single && single.canLines) },
      { label: 'Include in Commit', id: 'include' },
      { label: 'Exclude from Commit', id: 'exclude' },
      '-',
      { label: 'Rollback…', id: 'rollback', disabled: !anyTracked });
    if (sel.some((c) => c.type === 'untracked')) {
      items.push({ label: 'Add to VCS    Ctrl+Alt+A', id: 'addToVcs' });
    }
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
