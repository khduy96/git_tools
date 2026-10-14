// Select Lines to Commit: unified diff with a checkbox per changed line and
// per hunk (Android Studio partial commit).
(() => {
  const vscode = acquireVsCodeApi();
  const { h } = gt;
  const app = document.getElementById('app');
  let filePath = '';
  let hunks = [];
  /** @type {Set<string>} */
  let excluded = new Set();
  let lastKey = null;
  let gone = null;

  const post = (type, d = {}) => vscode.postMessage({ type, ...d });
  const key = (i, j) => `${i}:${j}`;

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.type === 'init') {
      filePath = msg.path;
      hunks = msg.hunks;
      excluded = new Set(msg.excluded);
      gone = null;
      render();
    } else if (msg.type === 'gone') {
      gone = msg.reason;
      render();
    }
  });

  function allKeys() {
    const keys = [];
    hunks.forEach((hk, i) => hk.lines.forEach((l, j) => { if (l.kind !== ' ') keys.push(key(i, j)); }));
    return keys;
  }

  function hunkKeys(i) {
    return hunks[i].lines.map((l, j) => (l.kind === ' ' ? null : key(i, j))).filter(Boolean);
  }

  function setKeys(keys, include) {
    for (const k of keys) {
      if (include) excluded.delete(k);
      else excluded.add(k);
    }
    post('selection', { excluded: [...excluded] });
    render();
  }

  /** Click toggles one line; Shift+click applies the same state to a range. */
  function clickLine(i, j, e) {
    const k = key(i, j);
    const include = excluded.has(k);
    if (e.shiftKey && lastKey) {
      const keys = allKeys();
      const a = keys.indexOf(lastKey);
      const b = keys.indexOf(k);
      if (a >= 0 && b >= 0) {
        setKeys(keys.slice(Math.min(a, b), Math.max(a, b) + 1), !excluded.has(lastKey));
        return;
      }
    }
    lastKey = k;
    setKeys([k], include);
  }

  function render() {
    const keys = allKeys();
    const selected = keys.filter((k) => !excluded.has(k)).length;
    const top = h('div#top', null,
      h('div.title', null,
        h('b', { text: filePath }),
        h('span.muted', { text: gone ? '' : `  ·  ${selected} of ${keys.length} changed line${keys.length === 1 ? '' : 's'} will be committed` })),
      h('div.actions', null,
        h('button.secondary', { text: 'Select All', disabled: !!gone, onclick: () => setKeys(keys, true) }),
        h('button.secondary', { text: 'Select None', disabled: !!gone, onclick: () => setKeys(keys, false) }),
        h('button.secondary', { text: 'Open Diff', onclick: () => post('openDiff') }),
        h('button.secondary', { text: 'Open File', onclick: () => post('openFile') }),
        h('button', { text: 'Go to Commit', onclick: () => post('commit') })));
    const hint = h('div.hint.muted', {
      text: 'Tick the changes to include in the next commit. Unticked lines stay in your working copy. Click a line to toggle it, Shift+click to toggle a range.',
    });
    const body = h('div#body');
    if (gone) {
      body.append(h('div.empty', { text: gone }));
    } else {
      hunks.forEach((hk, i) => {
        const hkKeys = hunkKeys(i);
        const n = hkKeys.filter((k) => !excluded.has(k)).length;
        const box = h('input', {
          type: 'checkbox',
          checked: n === hkKeys.length,
          onchange: (e) => setKeys(hkKeys, e.target.checked),
        });
        box.indeterminate = n > 0 && n < hkKeys.length;
        const rows = [];
        let oldNo = hk.oldStart - (hk.oldLen === 0 ? 0 : 1);
        let newNo = hk.newStart - (hk.newLen === 0 ? 0 : 1);
        hk.lines.forEach((l, j) => {
          if (l.kind !== '+') oldNo++;
          if (l.kind !== '-') newNo++;
          if (l.kind === ' ') {
            rows.push(h('div.line.ctx', null,
              h('span.cb'),
              h('span.no', { text: String(oldNo) }),
              h('span.no', { text: String(newNo) }),
              h('span.mark', { text: ' ' }),
              h('span.code', { text: l.text || ' ' })));
            return;
          }
          const k = key(i, j);
          const on = !excluded.has(k);
          rows.push(h(`div.line.${l.kind === '+' ? 'add' : 'del'}${on ? '' : '.off'}`, {
            title: on ? 'Included in the commit (click to leave out)' : 'Left out of the commit (click to include)',
            onclick: (e) => {
              if (e.target.tagName === 'INPUT') return;
              clickLine(i, j, e);
            },
          },
          h('span.cb', null, h('input', {
            type: 'checkbox',
            checked: on,
            onclick: (e) => {
              e.preventDefault();
              clickLine(i, j, e);
            },
          })),
          h('span.no', { text: l.kind === '-' ? String(oldNo) : '' }),
          h('span.no', { text: l.kind === '+' ? String(newNo) : '' }),
          h('span.mark', { text: l.kind }),
          h('span.code', { text: (l.text || ' ') + (l.noEol ? '  ⏎̸' : '') })));
        });
        body.append(h('div.hunk', null,
          h('div.hhead', null, box,
            h('span.mono', { text: `@@ -${hk.oldStart},${hk.oldLen} +${hk.newStart},${hk.newLen} @@` }),
            h('span.muted.ellipsis', { text: hk.header ? ` ${hk.header}` : '' }),
            h('span.spacer'),
            h('span.muted', { text: `${n}/${hkKeys.length}` })),
          rows));
      });
    }
    const scroll = document.getElementById('body');
    const y = scroll ? scroll.scrollTop : 0;
    app.replaceChildren(top, hint, body);
    body.scrollTop = y;
  }

  post('ready');
})();
