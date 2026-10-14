// Shared helpers for Git Tools webviews.
/* exported gt */
const gt = (() => {
  /**
   * Creates an element: h('div.cls#id', {attr}, ...children)
   * @returns {HTMLElement}
   */
  function h(tag, attrs, ...children) {
    const [name, ...rest] = tag.split(/(?=[.#])/);
    const el = document.createElement(name || 'div');
    for (const r of rest) {
      if (r[0] === '.') el.classList.add(r.slice(1));
      else el.id = r.slice(1);
    }
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === undefined || v === null || v === false) continue;
        if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
        else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
        else if (k === 'text') el.textContent = v;
        else el.setAttribute(k, v === true ? '' : v);
      }
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }

  let menuEl = null;
  function closeMenu() {
    if (menuEl) {
      menuEl.remove();
      menuEl = null;
    }
  }
  window.addEventListener('blur', closeMenu);
  document.addEventListener('mousedown', (e) => {
    if (menuEl && !menuEl.contains(e.target)) closeMenu();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeMenu();
  });

  /**
   * Shows a context menu. items: {label, id, disabled?, danger?} | '-'
   */
  function showMenu(x, y, items, onPick) {
    closeMenu();
    menuEl = h('div.menu', null, items.map((it) => (it === '-'
      ? h('div.sep')
      : h(`div.item${it.disabled ? '.disabled' : ''}${it.danger ? '.danger' : ''}`, {
        text: it.label,
        onclick: () => {
          if (it.disabled) return;
          closeMenu();
          onPick(it.id);
        },
      }))));
    document.body.append(menuEl);
    const r = menuEl.getBoundingClientRect();
    menuEl.style.left = `${Math.max(0, Math.min(x, window.innerWidth - r.width - 4))}px`;
    menuEl.style.top = `${Math.max(0, Math.min(y, window.innerHeight - r.height - 4))}px`;
  }

  function formatDate(ms) {
    const d = new Date(ms);
    const now = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
    const diff = (day(now) - day(d)) / 86400000;
    if (diff === 0) return `Today ${time}`;
    if (diff === 1) return `Yesterday ${time}`;
    return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${time}`;
  }

  function basename(p) {
    const i = p.lastIndexOf('/');
    return i < 0 ? p : p.slice(i + 1);
  }

  function dirname(p) {
    const i = p.lastIndexOf('/');
    return i < 0 ? '' : p.slice(0, i);
  }

  return { h, showMenu, closeMenu, formatDate, basename, dirname };
})();
