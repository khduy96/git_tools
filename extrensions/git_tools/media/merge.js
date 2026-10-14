// Three-way merge tool: Yours | Result | Theirs per conflict.
(() => {
  const vscode = acquireVsCodeApi();
  const { h } = gt;
  const app = document.getElementById('app');
  let segments = [];
  /** @type {{choice: string|null, custom?: string[]}[]} */
  let res = [];
  let editing = -1;
  let titles = { left: 'Yours', right: 'Theirs', path: '' };

  const post = (type, d = {}) => vscode.postMessage({ type, ...d });

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.type === 'init') {
      segments = msg.segments;
      titles = { left: msg.left, right: msg.right, path: msg.path };
      res = segments.filter((s) => s.kind === 'conflict').map(() => ({ choice: null }));
      render();
    }
  });

  const unresolved = () => res.filter((r) => !r.choice).length;

  function resultLines(i) {
    const c = segments.filter((s) => s.kind === 'conflict')[i];
    const r = res[i];
    switch (r.choice) {
      case 'ours': return c.ours;
      case 'theirs': return c.theirs;
      case 'oursTheirs': return [...c.ours, ...c.theirs];
      case 'theirsOurs': return [...c.theirs, ...c.ours];
      case 'base': return c.base || [];
      case 'custom': return r.custom || [];
      default: return null;
    }
  }

  function setAll(choice) {
    res.forEach((r) => { if (!r.choice) r.choice = choice; });
    render();
  }

  function nextConflict() {
    const i = res.findIndex((r) => !r.choice);
    const el = document.querySelector(`[data-conflict="${i}"]`);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  function code(lines) {
    return h('pre.code', { text: lines.length ? lines.join('\n') : ' ' });
  }

  function render() {
    const n = unresolved();
    const total = res.length;
    const body = h('div#body');
    let k = 0;
    for (const s of segments) {
      if (s.kind === 'text') {
        const lines = s.lines.length > 10
          ? [...s.lines.slice(0, 4), `⋯ ${s.lines.length - 8} unchanged lines ⋯`, ...s.lines.slice(-4)]
          : s.lines;
        body.append(h('div.plain', null, code(lines)));
        continue;
      }
      const i = k++;
      const r = res[i];
      const result = resultLines(i);
      const pick = (choice) => () => { r.choice = choice; if (editing === i) editing = -1; render(); };
      let center;
      if (editing === i) {
        const ta = h('textarea.editor', { rows: String(Math.max(4, (result || [...s.ours, ...s.theirs]).length + 1)) });
        ta.value = (result || [...s.ours, ...s.theirs]).join('\n');
        center = h('div.cell.result', null,
          h('div.bar', null,
            h('button', { text: 'OK', onclick: () => { r.choice = 'custom'; r.custom = ta.value.split('\n'); editing = -1; render(); } }),
            h('button.secondary', { text: 'Cancel', onclick: () => { editing = -1; render(); } })),
          ta);
        setTimeout(() => ta.focus(), 0);
      } else if (result) {
        center = h('div.cell.result.done', null,
          h('div.bar', null,
            h('span.ok', { text: '✓ resolved' }),
            h('button.chip', { text: 'Edit…', onclick: () => { editing = i; render(); } }),
            h('button.chip', { text: 'Undo', onclick: pick(null) })),
          code(result));
      } else {
        center = h('div.cell.result.open', null,
          h('div.bar', null,
            h('button.chip', { text: 'Left + Right', onclick: pick('oursTheirs') }),
            h('button.chip', { text: 'Right + Left', onclick: pick('theirsOurs') }),
            s.base ? h('button.chip', { text: 'Base', onclick: pick('base') }) : null,
            h('button.chip', { text: 'Edit…', onclick: () => { editing = i; render(); } })),
          s.base && s.base.length ? h('div.basehint', null, h('div.muted', { text: 'Base:' }), code(s.base)) : h('div.muted.pad', { text: 'Unresolved conflict' }));
      }
      const dim = (side) => (r.choice && r.choice !== side ? '.dim' : '');
      body.append(h(`div.conflict${r.choice ? '' : '.unresolved'}`, { 'data-conflict': String(i) },
        h(`div.cell.left${dim('ours')}`, null,
          h('div.bar.right', null, h('span.muted', { text: `${s.ours.length} line(s)` }),
            h('button.arrow', { text: '»', title: 'Accept left', onclick: pick('ours') })),
          code(s.ours)),
        center,
        h(`div.cell.rightc${dim('theirs')}`, null,
          h('div.bar', null, h('button.arrow', { text: '«', title: 'Accept right', onclick: pick('theirs') }),
            h('span.muted', { text: `${s.theirs.length} line(s)` })),
          code(s.theirs))));
    }

    app.replaceChildren(
      h('div#top', null,
        h('div.title', { text: `Merge Revisions for ${titles.path}` }),
        h('div.actions', null,
          h('button.secondary', { text: '» Accept Left', disabled: n === 0, onclick: () => setAll('ours') }),
          h('button.secondary', { text: '« Accept Right', disabled: n === 0, onclick: () => setAll('theirs') }),
          h('button.secondary', { text: '↓ Next Conflict', disabled: n === 0, onclick: nextConflict }))),
      h('div#heads', null,
        h('div.lefth', { text: titles.left }),
        h('div', { text: 'Result' }),
        h('div.righth', { text: titles.right })),
      body,
      h('div#footer', null,
        h(`span.${n ? 'warn' : 'okmsg'}`, { text: n ? `${n} of ${total} conflict${total === 1 ? '' : 's'} unresolved` : 'All changes have been processed.' }),
        h('span.spacer'),
        h('button.secondary', { text: 'Cancel', onclick: () => post('cancel') }),
        h('button', { text: 'Apply', disabled: n > 0, title: n ? 'Resolve all conflicts first' : '', onclick: () => post('apply', { resolutions: res }) })),
    );
  }

  post('ready');
})();
