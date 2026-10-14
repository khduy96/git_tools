// Source Control Repositories: one row per repository with a branch widget
// (⑂ branch ↑ahead ↓behind ▾) like the top bar of the Git Tools app.
(() => {
  const vscode = acquireVsCodeApi();
  const { h, showMenu } = gt;
  const app = document.getElementById('app');
  let repos = [];

  const post = (type, d = {}) => vscode.postMessage({ type, ...d });

  window.addEventListener('message', (e) => {
    if (e.data.type === 'repos') {
      repos = e.data.repos;
      render();
    }
  });

  const SVG = 'http://www.w3.org/2000/svg';
  /** Branch icon (fork), drawn inline so no icon font is needed. */
  function branchIcon() {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('class', 'bicon');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', 'M5 3.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0zM3.5 6v4M5 12.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0zM14 5.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0zM12.5 7c0 2.5-3 3-6 3.4-1.4.2-2.4.6-3 1.1');
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '1.2');
    svg.append(path);
    return svg;
  }

  function chevron() {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('class', 'chev');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', 'M4 6l4 4 4-4');
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '1.4');
    svg.append(path);
    return svg;
  }

  /** The branch widget: ⑂ name ↑ahead ↓behind ▾ */
  function branchWidget(r) {
    return h('button.branch', {
      title: r.upstream ? `Tracking ${r.upstream}` : 'No upstream branch',
      onclick: (e) => {
        e.stopPropagation();
        post('branches', { root: r.root });
      },
    },
    branchIcon(),
    h('span.bname', { text: r.branchLabel }),
    r.ahead > 0 ? h('span.ahead', { text: `↑${r.ahead}` }) : null,
    r.behind > 0 ? h('span.behind', { text: `↓${r.behind}` }) : null,
    chevron());
  }

  function action(label, title, act, r) {
    return h('button.icon.act', {
      text: label,
      title,
      onclick: (e) => {
        e.stopPropagation();
        post('action', { root: r.root, action: act });
      },
    });
  }

  function render() {
    app.replaceChildren();
    if (!repos.length) {
      app.append(h('div.empty', { text: 'No Git repositories found. Use "+" to open one.' }));
      return;
    }
    for (const r of repos) {
      const status = [];
      if (r.state) status.push(h('span.state', { text: r.state }));
      if (r.conflicts) status.push(h('span.conflicts', { text: `${r.conflicts} conflict${r.conflicts === 1 ? '' : 's'}` }));
      if (r.busy) status.push(h('span.muted', null, h('span.spinner'), ` ${r.busy}…`));
      else if (r.changes) status.push(h('span.muted', { text: `${r.changes} change${r.changes === 1 ? '' : 's'}` }));

      app.append(h(`div.repo${r.current ? '.current' : ''}`, {
        title: r.root,
        onclick: () => post('select', { root: r.root }),
        oncontextmenu: (e) => {
          e.preventDefault();
          showMenu(e.clientX, e.clientY, [
            { label: 'Select Repository', id: 'select', disabled: r.current },
            { label: 'Branches…', id: 'branches' },
            '-',
            { label: 'Fetch', id: 'fetch' },
            { label: 'Update Project / Pull…', id: 'update' },
            { label: 'Push…', id: 'push' },
            '-',
            { label: 'Refresh', id: 'refresh' },
            { label: 'Open in Integrated Terminal', id: 'terminal' },
            { label: 'Reveal in File Explorer', id: 'reveal' },
            '-',
            { label: 'Close Repository', id: 'close' },
          ], (id) => {
            if (id === 'select' || id === 'branches') post(id, { root: r.root });
            else post('action', { root: r.root, action: id });
          });
        },
      },
      h('span.check', { text: r.current ? '✓' : '' }),
      h('div.main', null,
        h('div.line', null,
          h('span.rname.ellipsis', { text: r.name }),
          r.relPath ? h('span.rel.muted.ellipsis', { text: r.relPath }) : null),
        h('div.line', null, branchWidget(r), ...status)),
      h('div.acts', null,
        action('⟳', 'Fetch', 'fetch', r),
        action('↙', 'Update Project / Pull…', 'update', r),
        action('↗', 'Push…', 'push', r))));
    }
  }

  post('ready');
})();
