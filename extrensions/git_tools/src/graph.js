// @ts-check
'use strict';

/**
 * Lane layout for the commit graph.
 *
 * Each row gets the lane of its node, its color and a list of segments:
 *   [from, to, part, color] where part is 0 = top half (row top at `from`
 *   to node at `to`), 1 = bottom half (node at `from` to row bottom at `to`),
 *   2 = straight through lane `from`.
 *
 * @param {{hash: string, parents: string[]}[]} commits children before parents
 * @returns {{lane: number, color: number, width: number, segments: number[][]}[]}
 */
function layoutGraph(commits) {
  /** @type {(string|null)[]} */
  const active = [];
  /** @type {number[]} */
  const colors = [];
  const known = new Set(commits.map((c) => c.hash));
  let nextColor = 0;
  const rows = [];

  const freeLane = () => {
    const i = active.indexOf(null);
    if (i >= 0) return i;
    active.push(null);
    colors.push(0);
    return active.length - 1;
  };

  for (const c of commits) {
    const segments = [];
    let idx = active.indexOf(c.hash);
    let color;
    if (idx < 0) {
      idx = freeLane();
      color = nextColor++;
      colors[idx] = color;
    } else {
      color = colors[idx];
    }

    for (let j = 0; j < active.length; j++) {
      const h = active[j];
      if (h === null) continue;
      if (h === c.hash) segments.push([j, idx, 0, colors[j]]);
      else segments.push([j, j, 2, colors[j]]);
    }
    const widthBefore = active.length;

    for (let j = 0; j < active.length; j++) {
      if (j !== idx && active[j] === c.hash) active[j] = null;
    }

    // Parents outside the loaded range are not drawn.
    const parents = c.parents.filter((p) => known.has(p));
    if (parents.length === 0) {
      active[idx] = null;
    } else {
      active[idx] = parents[0];
      segments.push([idx, idx, 1, colors[idx]]);
      for (const p of parents.slice(1)) {
        let k = active.indexOf(p);
        if (k < 0) {
          k = freeLane();
          active[k] = p;
          colors[k] = nextColor++;
        }
        segments.push([idx, k, 1, colors[k]]);
      }
    }

    const width = Math.max(widthBefore, active.length, idx + 1);
    while (active.length && active[active.length - 1] === null) {
      active.pop();
      colors.pop();
    }
    rows.push({ lane: idx, color, width, segments });
  }
  return rows;
}

module.exports = { layoutGraph };
