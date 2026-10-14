// Log view: commit table with branch graph and commit details.
(() => {
  const vscode = acquireVsCodeApi();
  const { h, showMenu, formatDate, basename, dirname } = gt;

  const ROW = 22;
  const LANE = 12;
  const COLORS = ['#4f9ded', '#73bd79', '#e5a54b', '#c678dd', '#e06c75', '#56b6c2', '#d19a66', '#98c379', '#b57edc', '#61afef'];

  const saved = vscode.getState() || {};
  let detailsWidth = saved.detailsWidth || 380;
  let data = { commits: [], graph: [], head: null, loading: true, filter: {}, branches: [], repo: null };
  let rows = []; // [{c, g}]
  let text = saved.text || '';
  let selected = new Set();
  let primary = null;
  let details = null;
  let selectedFile = null;

  // ------------------------------------------------------------- layout

  const search = h('input#search', { type: 'search', placeholder: 'Text or hash', value: text });
  const branchSel = h('select#branch');
  const pathChip = h('span.chip#pathChip');
  const status = h('span.muted#status');
  const toolbar = h('div#toolbar', null, search, h('span.muted', { text: 'Branch:' }), branchSel, pathChip, h('span.spacer'), status);
  const spacer = h('div#spacer');
  const rowsEl = h('div#rows');
  const table = h('div#table', { tabindex: '0' }, spacer, rowsEl);
  const splitter = h('div#splitter');
  const detailsEl = h('div#details');
  const main = h('div#main', null, table, splitter, detailsEl);
  document.getElementById('app').append(toolbar, main);
  detailsEl.style.width = `${detailsWidth}px`;

  const post = (type, d = {}) => vscode.postMessage({ type, ...d });
  const persist = () => vscode.setState({ detailsWidth, text });

  // ------------------------------------------------------------- events

  search.addEventListener('input', () => {
    text = search.value;
    persist();
    computeRows();
    renderRows();
  });
  branchSel.addEventListener('change', () => post('filter', { branch: branchSel.value || null }));
  table.addEventListener('scroll', renderRows);
  window.addEventListener('resize', renderRows);

  let dragging = false;
  splitter.addEventListener('mousedown', (e) => { dragging = true; e.preventDefault(); });
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    detailsWidth = Math.max(220, Math.min(window.innerWidth - 300, window.innerWidth - e.clientX));
    detailsEl.style.width = `${detailsWidth}px`;
  });
  window.addEventListener('mouseup', () => {
    if (dragging) {
      dragging = false;
      persist();
      renderRows();
    }
  });

  table.addEventListener('keydown', (e) => {
    if (!rows.length) return;
    const delta = { ArrowDown: 1, ArrowUp: -1, PageDown: 20, PageUp: -20 }[e.key];
    if (delta) {
      e.preventDefault();
      let i = rows.findIndex((r) => r.c.hash === primary);
      i = Math.max(0, Math.min(rows.length - 1, i + delta));
      select(rows[i].c, false, false);
      ensureVisible(i);
    } else if (e.key === 'c' && e.ctrlKey && e.altKey && e.shiftKey && primary) {
      post('commitAction', { action: 'copy', hashes: [primary] });
    }
  });

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.type === 'log') {
      data = msg.data;
      const known = new Set(data.commits.map((c) => c.hash));
      selected = new Set([...selected].filter((x) => known.has(x)));
      if (primary && !known.has(primary)) {
        primary = null;
        details = null;
      }
      computeRows();
      renderToolbar();
      renderRows();
      renderDetails();
    } else if (msg.type === 'details') {
      if (msg.details.hash === primary) {
        details = msg.details;
        renderDetails();
      }
    } else if (msg.type === 'select') {
      const i = rows.findIndex((r) => r.c.hash === msg.hash);
      if (i >= 0) {
        select(rows[i].c, false, false);
        ensureVisible(i);
      }
    }
  });

  // ------------------------------------------------------------- data

  function computeRows() {
    const q = text.trim().toLowerCase();
    if (!q) {
      rows = data.commits.map((c, i) => ({ c, g: data.graph[i] }));
      return;
    }
    rows = data.commits
      .filter((c) => c.subject.toLowerCase().includes(q) || c.hash.startsWith(q) ||
        c.author.toLowerCase().includes(q) || c.email.toLowerCase().includes(q) ||
        c.refs.some((r) => r.name.toLowerCase().includes(q)))
      .map((c) => ({ c, g: null }));
  }

  function select(c, ctrl, shift) {
    if (ctrl) {
      if (selected.has(c.hash)) selected.delete(c.hash);
      else selected.add(c.hash);
    } else if (shift && primary) {
      const hashes = rows.map((r) => r.c.hash);
      const a = hashes.indexOf(primary);
      const b = hashes.indexOf(c.hash);
      if (a >= 0 && b >= 0) selected = new Set(hashes.slice(Math.min(a, b), Math.max(a, b) + 1));
      renderRows();
      return;
    } else {
      selected = new Set([c.hash]);
    }
    if (primary !== c.hash) {
      primary = c.hash;
      details = null;
      selectedFile = null;
      post('details', { hash: c.hash });
    }
    renderRows();
    renderDetails();
  }

  function ensureVisible(i) {
    const top = i * ROW;
    if (top < table.scrollTop) table.scrollTop = top;
    else if (top + ROW > table.scrollTop + table.clientHeight) table.scrollTop = top + ROW - table.clientHeight;
  }

  // ------------------------------------------------------------- render

  function renderToolbar() {
    const f = data.filter || {};
    branchSel.replaceChildren(
      h('option', { value: '', text: 'All' }),
      h('option', { value: 'HEAD', text: 'HEAD', selected: f.branch === 'HEAD' }),
      h('optgroup', { label: 'Local' }, data.branches.filter((b) => !b.remote).map((b) =>
        h('option', { value: b.name, text: b.name, selected: f.branch === b.name }))),
      h('optgroup', { label: 'Remote' }, data.branches.filter((b) => b.remote).map((b) =>
        h('option', { value: b.name, text: b.name, selected: f.branch === b.name }))),
    );
    if (f.branch && ![...branchSel.options].some((o) => o.value === f.branch)) {
      branchSel.append(h('option', { value: f.branch, text: f.branch, selected: true }));
    }
    pathChip.replaceChildren();
    pathChip.hidden = !f.path;
    if (f.path) {
      pathChip.append(h('span', { text: `Path: ${f.path}` }), h('span.x', { text: ' ×', title: 'Clear', onclick: () => post('filter', { path: null }) }));
    }
    status.replaceChildren(
      data.loading ? h('span.spinner') : '',
      ` ${data.repo ? `${data.commits.length} commits` : 'No repository'}`,
    );
  }

  function renderRows() {
    spacer.style.height = `${rows.length * ROW}px`;
    const first = Math.max(0, Math.floor(table.scrollTop / ROW) - 5);
    const last = Math.min(rows.length, Math.ceil((table.scrollTop + table.clientHeight) / ROW) + 5);
    rowsEl.replaceChildren();
    if (!rows.length) {
      rowsEl.append(h('div.empty', { text: data.loading ? 'Loading…' : 'No commits' }));
      return;
    }
    for (let i = first; i < last; i++) {
      const { c, g } = rows[i];
      const isHead = c.hash === data.head;
      const row = h(`div.crow${selected.has(c.hash) ? '.selected' : ''}${isHead ? '.head' : ''}`, {
        style: { top: `${i * ROW}px` },
        onclick: (e) => {
          table.focus();
          select(c, e.ctrlKey || e.metaKey, e.shiftKey);
        },
        oncontextmenu: (e) => {
          e.preventDefault();
          if (!selected.has(c.hash)) select(c, false, false);
          commitMenu(e.clientX, e.clientY, c);
        },
      },
      g ? graphCanvas(g, isHead) : h('span', { style: { width: '8px', flexShrink: '0' } }),
      c.refs.map(refChip),
      h('span.subject.ellipsis', { text: c.subject, title: c.subject }),
      h('span.author.ellipsis', { text: c.author }),
      h('span.date', { text: formatDate(c.time) }),
      h('span.hash.mono', { text: c.hash.slice(0, 8) }));
      rowsEl.append(row);
    }
  }

  function refChip(r) {
    const icon = r.kind === 'head' ? '◉' : r.kind === 'tag' ? '🏷' : '⑂';
    return h(`span.ref.${r.kind}`, { title: r.name }, r.kind === 'head' ? icon : `${icon} ${r.name}`);
  }

  function graphCanvas(g, isHead) {
    const w = g.width * LANE + 6;
    const dpr = window.devicePixelRatio || 1;
    const cv = h('canvas.graph', { width: String(Math.ceil(w * dpr)), height: String(ROW * dpr), style: { width: `${w}px`, height: `${ROW}px` } });
    const ctx = cv.getContext('2d');
    ctx.scale(dpr, dpr);
    const x = (lane) => lane * LANE + LANE / 2 + 2;
    const mid = ROW / 2;
    ctx.lineWidth = 1.6;
    for (const [from, to, part, color] of g.segments) {
      ctx.strokeStyle = COLORS[color % COLORS.length];
      ctx.beginPath();
      if (part === 2) {
        ctx.moveTo(x(from), 0);
        ctx.lineTo(x(from), ROW);
      } else {
        const ay = part === 0 ? 0 : mid;
        const by = part === 0 ? mid : ROW;
        ctx.moveTo(x(from), ay);
        if (from === to) ctx.lineTo(x(to), by);
        else ctx.bezierCurveTo(x(from), (ay + by) / 2, x(to), (ay + by) / 2, x(to), by);
      }
      ctx.stroke();
    }
    const color = COLORS[g.color % COLORS.length];
    ctx.beginPath();
    ctx.arc(x(g.lane), mid, isHead ? 4.5 : 3.8, 0, Math.PI * 2);
    if (isHead) {
      ctx.fillStyle = getComputedStyle(document.body).getPropertyValue('--vscode-panel-background') || '#1e1e1e';
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = color;
      ctx.stroke();
    } else {
      ctx.fillStyle = color;
      ctx.fill();
    }
    return cv;
  }

  function renderDetails() {
    detailsEl.replaceChildren();
    if (!primary) {
      detailsEl.append(h('div.empty', { text: 'Select a commit to view details' }));
      return;
    }
    if (!details) {
      detailsEl.append(h('div.empty', null, h('span.spinner')));
      return;
    }
    const d = details;
    const files = h('div#files');
    files.append(h('div.dhead', null,
      h('span', { text: `${d.files.length} file${d.files.length === 1 ? '' : 's'} changed` }),
      d.parents.length > 1 ? h('span.muted', { text: ' (vs first parent)' }) : null));
    for (const f of d.files) {
      files.append(h(`div.frow${selectedFile === f.path ? '.selected' : ''}`, {
        title: f.path,
        onclick: () => {
          selectedFile = f.path;
          renderDetails();
          post('openDiff', { hash: d.hash, path: f.path, preview: true });
        },
        ondblclick: () => post('openDiff', { hash: d.hash, path: f.path, preview: false }),
        oncontextmenu: (e) => {
          e.preventDefault();
          selectedFile = f.path;
          renderDetails();
          showMenu(e.clientX, e.clientY, [
            { label: 'Show Diff', id: 'diff' },
            { label: 'Compare with Local', id: 'local', disabled: f.type === 'deleted' },
            { label: 'Show History for File', id: 'history' },
            '-',
            { label: 'Get from Revision', id: 'get', disabled: f.type === 'deleted' },
            { label: 'Copy Path', id: 'copy' },
          ], (action) => post('fileAction', { action, hash: d.hash, path: f.path }));
        },
      },
      h(`span.t-${f.type}`, { text: basename(f.path) }),
      h('span.muted.ellipsis', { text: f.oldPath ? `← ${f.oldPath}` : dirname(f.path) })));
    }
    const info = h('div#info', null,
      h('div.body', { text: d.body }),
      h('div.refs', null, (d.refs || []).map(refChip)),
      h('div.meta', null,
        h('a.hash.mono', { text: d.hash.slice(0, 10), title: 'Copy hash', href: '#', onclick: (e) => { e.preventDefault(); post('commitAction', { action: 'copy', hashes: [d.hash] }); } })),
      h('div.meta', null, h('b', { text: d.author }), h('span.muted', { text: ` <${d.email}> on ${new Date(d.time).toLocaleString()}` })),
      d.committer !== d.author ? h('div.meta.muted', { text: `committed by ${d.committer} on ${new Date(d.commitTime).toLocaleString()}` }) : null,
      d.parents.length ? h('div.meta.muted', { text: `${d.parents.length > 1 ? 'Parents' : 'Parent'}: ${d.parents.map((p) => p.slice(0, 8)).join(', ')}` }) : null,
      h('div.meta.muted', { text: d.containedIn ? `In ${d.containedIn.length} branch${d.containedIn.length === 1 ? '' : 'es'}: ${d.containedIn.slice(0, 20).join(', ')}${d.containedIn.length > 20 ? ', …' : ''}` : 'Looking for branches…' }));
    detailsEl.append(files, info);
  }

  function commitMenu(x, y, c) {
    const sel = rows.filter((r) => selected.has(r.c.hash)).map((r) => r.c);
    const single = sel.length === 1;
    const isHead = c.hash === data.head;
    showMenu(x, y, [
      { label: 'Copy Revision Number', id: 'copy' },
      '-',
      { label: 'Cherry-Pick', id: 'cherryPick' },
      { label: `Checkout Revision '${c.hash.slice(0, 8)}'`, id: 'checkout', disabled: !single },
      { label: 'Compare with Local', id: 'compare', disabled: !single },
      '-',
      { label: 'Reset Current Branch to Here…', id: 'reset', disabled: !single },
      { label: 'Revert Commit', id: 'revert' },
      { label: 'Undo Commit…', id: 'undo', disabled: !(single && isHead && c.parents.length) },
      '-',
      { label: 'Edit Commit Message…', id: 'reword', disabled: !(single && isHead) },
      { label: 'Drop Commit', id: 'drop', disabled: !(single && c.parents.length === 1), danger: true },
      '-',
      { label: 'New Branch…', id: 'branch', disabled: !single },
      { label: 'New Tag…', id: 'tag', disabled: !single },
    ], (action) => post('commitAction', { action, hashes: sel.map((s) => s.hash) }));
  }

  renderToolbar();
  renderRows();
  renderDetails();
  post('ready');
})();
