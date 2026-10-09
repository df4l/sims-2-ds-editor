// Sims 2 DS editor UI: location picker, item list, details, scripts, top-down view. 3D view in view3d.js.
import { View3D } from './view3d.js';

export const COLORS = {
  1: '#4fc3f7', 2: '#ffb74d', 3: '#e57373', 4: '#81c784', 5: '#ba68c8', 7: '#90a4ae',
  8: '#fff176', 9: '#a1887f', 10: '#ffcc80', 11: '#4db6ac', entry: '#ffd54f', furniture: '#f06292',
};
const NAMES = { 1: 'npc', 2: 'prop', 3: 'trigger box', 4: 'door / object box', 5: 'light?', 7: 'box', 8: 'event watcher',
  9: 'waypoint', 10: 'timed prop', 11: 'sound', entry: 'entry point', furniture: 'room furniture (default)' };

const $ = (id) => document.getElementById(id);
const S = { locs: [], loc: null, bsp: null, block: 0, lang: 'en', sel: null, view: '2d', mode: 'items', cell: null };
const ui = {
  bsp: () => $('showBsp').checked, scene: () => $('showScene').checked,
  models: () => $('showModels').checked, labels: () => $('showLabels').checked,
};

async function api(path) {
  const r = await fetch(path);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
const status = (t) => { $('status').textContent = t; };

// ---- edits: every change is a POST /api/edit, saved at once by the server; the location is then reloaded -------
async function edit(op, args = {}) {
  const r = await fetch('/api/edit', { method: 'POST', body: JSON.stringify({ op, loc: S.loc?.id, ...args }) });
  const j = await r.json();
  if (!r.ok) { status(`Edit refused: ${j.error}`); alert(j.error); return null; }
  await reload();
  return j;
}
const itemAddr = (it) => ({ b: it.block, g: it.group, i: it.index });
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// ---- visible things: block 0 is always loaded by the game, plus the variant block chosen at load time --------
export function visibleItems() {
  const out = [];
  if (!S.loc) return out;
  const blocks = S.block === 0 ? [0] : [0, S.block];
  for (const b of blocks) {
    (S.loc.blocks[b]?.groups || []).forEach((g, gi) => g.forEach((it, ii) =>
      out.push({ key: `${b}/${gi}/${ii}`, block: b, group: gi, index: ii, ...it })));
  }
  S.loc.entries.forEach((e, k) => out.push({ key: `e/${k}`, type: 'entry', type_name: 'entry point', index: k, ...e }));
  // default hotel room furniture (arm9 table, spawned by code on room entry; tools/roomfurn.py)
  (S.loc.furniture?.items || []).filter((f) => f.placed).forEach((f) =>
    out.push({ ...f, key: `f/${f.index}`, type: 'furniture', type_name: 'room furniture' }));
  const g = S.ghost && out.find((i) => i.key === S.ghost.key);   // item being dragged
  if (g) { g.x = S.ghost.x; g.z = S.ghost.z; }
  return out;
}
const label = (it) => it.type === 'entry' ? `entry ${it.id}` : (it.model_name || it.type_name);
const fmt = (v) => (Number.isInteger(v) ? v : v.toFixed(1));
const pos3 = (it) => `${fmt(it.x)}, ${fmt(it.y)}, ${fmt(it.z)}`;

// ---- selection ------------------------------------------------------------------------------------------------
export function select(key, from) {
  S.sel = key;
  if (S.loc) location.hash = `loc=${S.loc.id}&block=${S.block}` + (key ? `&item=${key}` : '');
  document.querySelectorAll('.it').forEach((el) => el.classList.toggle('sel', el.dataset.key === key));
  const it = visibleItems().find((i) => i.key === key);
  renderDetails(it);
  if (from !== 'list') document.querySelector(`.it[data-key="${key}"]`)?.scrollIntoView({ block: 'nearest' });
  draw2d();
  view3d.setSelection(key);
}

function renderDetails(it) {
  if (!it) { $('details').innerHTML = '<p class="muted">Click an item.</p>'; return; }
  if (it.type === 'furniture') return renderFurniture(it);
  const rows = [['kind', it.type === 'entry' ? 'entry point' : `${it.type_name} (type ${it.type})`],
    ['position x, y, z', `${it.x}, ${it.y}, ${it.z}`]];
  if (it.type === 'entry') {
    rows.push(['entry id', it.id], ['angle', `${(it.angle_rad * 180 / Math.PI).toFixed(1)}°`]);
  } else {
    rows.push(['block / group / item', `${it.block} / ${it.group} / ${it.index + 1}`]);
    if (it.model != null) rows.push(['model', `${it.model_name} (rom.bin ${it.model})`]);
    for (const [k, v] of Object.entries(it.fields)) rows.push([k, Array.isArray(v) ? v.join(', ') : v ?? '—']);
    if (it.type === 4) {
      const d = S.locs[it.fields.dest];
      rows.push(['→ destination', d ? `${d.id} ${d.place}, entry ${it.fields.entry}` : '?']);
    }
  }
  $('details').innerHTML = `<table class="kv">${rows.map(([k, v]) =>
    `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('')}</table>` + editForm(it) +
    (it.type === 4 && S.locs[it.fields.dest] ? `<p><button id="goDest">Open destination</button></p>` : '') +
    '<p class="assumed">Assumed, not verified: facing direction (sign of the angle) and box placement (centred on the item position, not rotated).</p>';
  $('goDest')?.addEventListener('click', () => openLocation(it.fields.dest));
  bindEditForm(it);
}

// default room furniture: the arm9 table copied into the game state by a NEW game (saves keep their own copy)
function renderFurniture(it) {
  const F = S.loc.furniture;
  const rows = [['kind', 'default room furniture (arm9 0x0211FA70, not in the layout)'],
    ['model', `${it.model_name} (prop ${it.prop}, rom.bin ${it.model})`],
    ['placement', it.wall ? `wall-mounted: wall slot ${it.cell[0]}, cell ${it.cell[1]} along it (rot unused)` :
      `floor: cell (${it.cell[0]}, ${it.cell[1]}), rot ${it.rot} = ${it.rot * 90}°`],
    ['world x, y, z', pos3(it)], ['angle', `${(it.angle_rad * 180 / Math.PI).toFixed(0)}°`],
    ['room grid', `rom.bin ${F.grid_entry}: ${F.grid.width} x ${F.grid.depth} cells of ${F.grid.cell}, ${F.grid.walls} wall slots`]];
  const num = (id, v, max) => `<input id="${id}" type="number" step="1" min="0" max="${max}" value="${v}">`;
  $('details').innerHTML = `<table class="kv">${rows.map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('')}</table>` +
    `<div class="form"><span>prop</span><select id="ffp" class="wide">${F.props.map((p) =>
      `<option value="${p.prop}"${p.prop === it.prop ? ' selected' : ''}>${p.prop} ${esc(p.name)} (${p.wall ? 'wall' : 'floor'})</option>`).join('')}` +
    `${F.props.some((p) => p.prop === it.prop) ? '' : `<option value="${it.prop}" selected>${it.prop} (not furniture)</option>`}</select>` +
    `<span>rot</span>${num('ffr', it.rot, 3)}<span></span><span></span>` +
    `<span>${it.wall ? 'wall, cell' : 'cell x, z'}</span>${num('ffx', it.cell[0], 255)}${num('ffz', it.cell[1], 255)}<span></span></div>` +
    '<div class="btns"><button id="ffapply">Apply</button></div>' +
    '<p class="muted">Drag it in the top-down view: it snaps to the grid (wall props slide along their wall).</p>' +
    '<p class="warn">Only a new game uses this table: it is copied into the game state (and so into the save) at new game.</p>' +
    (it.exact ? '<p class="muted">Position computed like Room_PlacePropOnGrid: wall flag and offsets decoded for all 182 furniture props, checked against the game on 72 placements.</p>' :
      '<p class="warn">This prop is not furniture: the game has no placement object for it. Pick one from the list.</p>');
  const v = (id) => +$(id).value;
  $('ffapply').addEventListener('click', () => edit('furniture', { i: it.index, prop: v('ffp'), rot: v('ffr'), x: v('ffx'), z: v('ffz') }));
}

// ---- typed fields (tools/layout.py FIELDS, served by /api/palette): one widget per field, ids picked from lists --
const opt = (v, text, cur) => `<option value="${v}"${v === cur ? ' selected' : ''}>${esc(text)}</option>`;
function fieldInput(t, f, v, pre) {
  const P = S.palette, id = `${pre}_${f.name}`;
  const sel = (opts) => `<select id="${id}" data-f="${f.name}">${opts}</select>`;
  if (f.name === 'npc') return sel(P.npcs.map((n) => opt(n.id, `${n.id} ${n.name} (${n.model})`, v)).join(''));
  if (f.name === 'prop') return sel(P.props.filter((p) => p.id >= f.min && p.id <= f.max).map((p) => opt(p.id, `${p.id} ${p.name}`, v)).join(''));
  if (f.name === 'object') return sel(P.objects.map((o) => opt(o.id, `${o.id} ${o.name}`, v)).join(''));
  if (f.name === 'dest') return sel(S.locs.map((l) => opt(l.id, `${l.id} ${l.place}${l.nav == null ? ' (no layout)' : ''}`, v)).join(''));
  if (f.name === 'entry') return sel(entryOptions(null, v));
  return `<input id="${id}" data-f="${f.name}" type="number" step="1" min="${f.min}" max="${f.max}" value="${v}">`;
}
// entry point ids of the door destination (a location may list one id twice: location 2 has two entries 0)
function entryOptions(dest, cur) {
  const ids = [...new Set(S.palette.entry_ids[dest] ?? [])];
  if (cur != null && !ids.includes(cur)) ids.push(cur);
  return ids.map((e) => opt(e, `entry ${e}${(S.palette.entry_ids[dest] ?? []).includes(e) ? '' : ' (missing!)'}`, cur)).join('');
}
function fieldsForm(t, vals, pre) {
  const T = S.palette.types.find((x) => x.type === t);
  if (!T) return '';
  return `<div class="form fields" id="${pre}">` + T.fields.map((f) =>
    `<span title="${f.min}..${f.max}">${f.name.replace('_', ' ')}</span>${fieldInput(t, f, vals[f.name], pre)}`).join('') + '</div>';
}
// wire the destination -> entry list after the form is in the DOM
function bindFields(pre, vals) {
  const d = $(`${pre}_dest`), e = $(`${pre}_entry`);
  if (!d || !e) return;
  const fill = (cur) => { e.innerHTML = entryOptions(+d.value, cur); };
  fill(vals.entry);
  d.addEventListener('change', () => fill(null));
}
function readFields(pre) {
  const out = {};
  document.querySelectorAll(`#${pre} [data-f]`).forEach((el) => { if (el.value !== '') out[el.dataset.f] = +el.value; });
  return out;
}

// edit form of the selected item / entry point (angles in degrees; entry points store radians * 4096)
function editForm(it) {
  const ent = it.type === 'entry';
  const num = (id, v) => `<input id="${id}" type="number" step="1" value="${v}">`;
  let h = `<div class="form"><span>x, y, z</span>${num('fx', it.x)}${num('fy', it.y)}${num('fz', it.z)}`;
  if (ent) h += `<span>angle °</span>${num('fa', (it.angle_rad * 180 / Math.PI).toFixed(1))}<span></span><span></span>`;
  h += '</div>';
  if (!ent) h += fieldsForm(it.type, it.typed, 'tf') +
    `<div class="form"><span>raw</span><input id="fraw" class="raw" value="${it.raw}" spellcheck="false"></div>`;
  h += '<div class="btns"><button id="fapply">Apply</button>';
  if (!ent) h += '<button id="fdup" title="Copy to the end of the group (no index shift)">Duplicate</button><button id="fdel" title="Del">Delete</button>';
  h += '</div>';
  const shared = S.loc.shared_with.filter((l) => S.locs[l] && S.loc.nav === S.locs[l].nav);
  if (shared.length) h += `<p class="warn">This layout is shared with location ${shared.join(', ')}: edits change it too.</p>`;
  return h + '<p class="muted">Drag the selected item in the top-down view to move it.</p>';
}

function bindEditForm(it) {
  const v = (id) => ($(id) && $(id).value !== '' ? +$(id).value : null);
  if (it.type !== 'entry') bindFields('tf', it.typed);
  $('fapply').addEventListener('click', () => {
    const pos = { x: v('fx'), y: v('fy'), z: v('fz') };
    if (it.type === 'entry') {
      const a = v('fa');
      return edit('entry', { k: it.index, ...pos, angle_rad: a == null ? null : a * Math.PI / 180 });
    }
    // a hand-edited raw record wins; otherwise only the typed fields that changed are sent
    const raw = $('fraw').value.trim().toLowerCase();
    if (raw !== it.raw) return edit('item', { ...itemAddr(it), ...pos, raw });
    const f = Object.fromEntries(Object.entries(readFields('tf')).filter(([k, x]) => x !== it.typed[k]));
    edit('item', { ...itemAddr(it), ...pos, fields: Object.keys(f).length ? f : null });
  });
  $('fdup')?.addEventListener('click', async () => {
    const j = await edit('duplicate', itemAddr(it));
    if (j) select(`${it.block}/${it.group}/${j.index}`);
  });
  $('fdel')?.addEventListener('click', () => deleteItem(it));
}

async function deleteItem(it) {
  if (it?.type == null || it.type === 'entry') return;
  if (await edit('delete', itemAddr(it))) select(null);
}

// ---- add item palette: type + typed fields + target group, then a click in the top-down view places it ---------
// The new item is appended to the group (no index shift). Its y is that of the nearest item (edit it after).
const PAL = { type: 2, group: null, vals: null };
function renderPalette() {
  const P = S.palette;
  if (!P || !S.loc) return;
  if (S.loc.nav == null) { $('palette').innerHTML = '<p class="muted">This location has no layout file.</p>'; return; }
  const T = P.types.find((x) => x.type === PAL.type);
  PAL.vals ??= { ...T.template, ...(PAL.type === 10 ? { collect_bit: P.free_collect_bit } : {}) };
  const groups = [];
  for (const b of S.block === 0 ? [0] : [0, S.block]) {
    (S.loc.blocks[b]?.group_info || []).forEach((gi, g) => groups.push({ key: `${b}/${g}`, b, g, ...gi,
      n: S.loc.blocks[b].groups[g].length }));
  }
  if (!groups.some((x) => x.key === PAL.group)) PAL.group = groups.find((x) => x.b === S.block)?.key ?? groups[0]?.key;
  const G = groups.find((x) => x.key === PAL.group);
  const lim = S.loc.limits?.[S.block];
  const hint = !G ? 'This block has no group.' : G.permanent ? 'Group 0 of block 0: always there (permanent content).' :
    G.spawned_by.length ? `Spawned by ${G.spawned_by.join(', ')}.` :
    'No script or trigger of this block spawns this group: the item will not appear in game.';
  $('palette').innerHTML =
    `<div class="form fields"><span>type</span><select id="ptype">${P.types.map((t) =>
      opt(t.type, `${t.type} ${NAMES[t.type] ?? t.name}`, PAL.type)).join('')}</select>` +
    `<span>group</span><select id="pgroup">${groups.map((x) =>
      opt(x.key, `block ${x.b} · group ${x.g} (${x.n} items)`, PAL.group)).join('')}</select></div>` +
    `<p class="${G && (G.permanent || G.spawned_by.length) ? 'muted' : 'warn'}">${esc(hint)}</p>` +
    fieldsForm(PAL.type, PAL.vals, 'pf') +
    `<div class="btns"><button id="pplace" class="tab${S.placing ? ' on' : ''}">${S.placing ? 'Click on the map… (Esc)' : 'Place on map'}</button>` +
    '<button id="pcentre" title="At the centre of the top-down view">Add at view centre</button></div>' +
    (lim ? `<p class="muted">Variant ${S.block}: parse arena ${lim.arena} / ${P.limits.arena} bytes (8 per item), ` +
      `waypoints ${lim.waypoints} / ${P.limits.waypoints}.</p>` : '') +
    (PAL.type === 10 ? '<p class="assumed">Collect bit: one per timed prop (0..49 used by the game). Bits 50..63 are assumed free.</p>' : '') +
    (PAL.type === 4 ? '<p class="muted">Door: walking into the box loads the destination at that entry point. Object = door model, or box only.</p>' : '');
  bindFields('pf', PAL.vals);
  $('ptype').addEventListener('change', () => { PAL.type = +$('ptype').value; PAL.vals = null; S.placing = null; renderPalette(); });
  $('pgroup').addEventListener('change', () => { PAL.group = $('pgroup').value; renderPalette(); });
  $('pf')?.addEventListener('change', () => { PAL.vals = readFields('pf'); });
  $('pplace').addEventListener('click', () => {
    S.placing = S.placing ? null : true;
    if (S.placing) { setView('2d'); status('Click in the top-down view to place the new item (Esc cancels)'); }
    renderPalette();
  });
  $('pcentre').addEventListener('click', () => addItemAt(cam.cx, cam.cz));
}

async function addItemAt(x, z) {
  S.placing = null;
  const [b, g] = PAL.group.split('/').map(Number);
  PAL.vals = readFields('pf');
  // y: the nearest item (in x, z) of the location, else 0; the floor height is not derived from the BSP
  let y = 0, bd = Infinity;
  for (const it of visibleItems()) {
    const d = Math.hypot(it.x - x, it.z - z);
    if (d < bd && it.y != null) { bd = d; y = it.y; }
  }
  const j = await edit('add', { b, g, type: PAL.type, x: Math.round(x), y: Math.round(y), z: Math.round(z), fields: PAL.vals });
  if (j) { PAL.vals = null; renderPalette(); select(`${b}/${g}/${j.index}`); }
  else renderPalette();
}

// ---- collision cells (mode 'cells'): the cell is addressed by an inside point, see backend.bsp_json -------------
function selectCell(brush, at) {
  S.cell = brush;
  const r = (v) => Math.round(v * 10) / 10;
  const num = (id, v) => `<input id="${id}" type="number" step="1" value="${r(v)}">`;
  let h = '';
  let lo, hi;
  if (brush) {
    lo = [0, 1, 2].map((k) => Math.min(...brush.verts.map((v) => v[k])));
    hi = [0, 1, 2].map((k) => Math.max(...brush.verts.map((v) => v[k])));
    h += `<table class="kv"><tr><td>solid cell</td><td>leaf ${brush.leaf}, ${brush.verts.length} vertices</td></tr>` +
      `<tr><td>min x, y, z</td><td>${lo.map(r).join(', ')}</td></tr><tr><td>max x, y, z</td><td>${hi.map(r).join(', ')}</td></tr></table>` +
      `<div class="form"><span>move by</span>${num('cdx', 0)}${num('cdy', 0)}${num('cdz', 0)}</div>` +
      '<div class="btns"><button id="cmove">Move cell</button><button id="cdel">Delete cell</button></div>';
  } else {
    h += '<p class="muted">No solid cell here (empty space).</p>';
  }
  const top = brush ? hi[1] : 0, [x, z] = at || [0, 0];
  h += `<p class="muted">Add an axis-aligned solid box:</p><div class="form"><span>min</span>${num('blx', x - 5)}${num('bly', top)}${num('blz', z - 5)}` +
    `<span>max</span>${num('bhx', x + 5)}${num('bhy', top + 10)}${num('bhz', z + 5)}</div><div class="btns"><button id="cbox">Add box</button></div>` +
    '<p class="muted">Click the same spot again to pick the next cell below. Moving a cell = delete it + add its planes shifted.</p>';
  $('details').innerHTML = h;
  const v = (id) => +$(id).value;
  $('cmove')?.addEventListener('click', () => edit('bsp_move', { p: brush.inside, delta: [v('cdx'), v('cdy'), v('cdz')] }).then((j) => j && selectCell(null)));
  $('cdel')?.addEventListener('click', () => edit('bsp_delete', { p: brush.inside }).then((j) => j && selectCell(null)));
  $('cbox').addEventListener('click', () => edit('bsp_box', { lo: [v('blx'), v('bly'), v('blz')], hi: [v('bhx'), v('bhy'), v('bhz')] }));
  draw2d();
}

function setMode(m) {
  S.mode = m; S.cell = null;
  $('modeCells').classList.toggle('on', m === 'cells');
  if (m === 'cells') { setView('2d'); $('showBsp').checked = true; selectCell(null); } else renderDetails(null);
  draw2d();
}

// ---- sidebar --------------------------------------------------------------------------------------------------
function renderList() {
  const items = visibleItems();
  let html = '', last = '';
  for (const it of items) {
    const grp = it.type === 'entry' ? 'Entry points' : it.type === 'furniture' ? 'Room furniture (default, arm9)' : `Block ${it.block} · group ${it.group}`;
    if (grp !== last) { html += `<div class="grp">${grp}</div>`; last = grp; }
    html += `<div class="it" data-key="${it.key}"><i style="background:${COLORS[it.type]}"></i>` +
      `${esc(label(it))} <span class="muted">(${pos3(it)})</span></div>`;
  }
  $('items').innerHTML = html;
  $('items').querySelectorAll('.it').forEach((el) => el.addEventListener('click', () => {
    select(el.dataset.key, 'list');
    center2d(items.find((i) => i.key === el.dataset.key));
  }));
}

function renderScripts() {
  const blocks = S.block === 0 ? [0] : [0, S.block];
  let html = '';
  for (const b of blocks) {
    const sc = S.loc.blocks[b]?.scripts || [];
    html += `<div class="grp">Block ${b}: ${sc.length} scripts</div>`;
    sc.forEach((lines, k) => { html += `<pre><b>script ${k + 1}</b>\n${lines.map((l) => '  ' + esc(l)).join('\n')}</pre>`; });
  }
  $('scripts').innerHTML = html || '<p class="muted">No layout.</p>';
}

function renderLegend() {
  const types = new Set(visibleItems().map((i) => i.type));
  $('legend').innerHTML = [...types].map((t) => `<span><i style="background:${COLORS[t]}"></i>${NAMES[t]}</span>`).join('');
}

// ---- top-down view (x right, z down: same orientation as tools/bsp.py png) ------------------------------------
const cv = $('view2d');
const ctx = cv.getContext('2d');
const cam = { cx: 0, cz: 0, scale: 2 };
let brushes2d = [];

function hull(pts) {
  pts = [...pts].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  if (pts.length < 3) return pts;
  const cross = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const half = (ps) => { const h = []; for (const p of ps) { while (h.length >= 2 && cross(h[h.length - 2], h[h.length - 1], p) <= 0) h.pop(); h.push(p); } return h; };
  const lo = half(pts), hi = half(pts.reverse());
  return lo.slice(0, -1).concat(hi.slice(0, -1));
}

function prepare2d() {
  brushes2d = [];
  if (!S.bsp) return;
  let ylo = Infinity, yhi = -Infinity;
  for (const b of S.bsp.brushes) for (const v of b.verts) { ylo = Math.min(ylo, v[1]); yhi = Math.max(yhi, v[1]); }
  for (const b of S.bsp.brushes) {
    const ys = b.verts.map((v) => v[1]);
    const top = Math.max(...ys), h = top - Math.min(...ys), t = (top - ylo) / Math.max(yhi - ylo, 1);
    const col = h < 8 ? `rgb(${60 + 150 * t | 0},${90 + 120 * t | 0},200)` : `rgb(${170 + 80 * t | 0},${80 + 60 * t | 0},60)`;
    brushes2d.push({ top, col, brush: b, poly: hull(b.verts.map((v) => [v[0], v[2]])) });
  }
  brushes2d.sort((a, b) => a.top - b.top);
}

function fit2d() {
  const pts = [];
  for (const b of brushes2d) for (const p of b.poly) pts.push(p);
  for (const it of visibleItems()) pts.push([it.x, it.z]);
  if (!pts.length) return;
  const xs = pts.map((p) => p[0]), zs = pts.map((p) => p[1]);
  const [x0, x1, z0, z1] = [Math.min(...xs), Math.max(...xs), Math.min(...zs), Math.max(...zs)];
  cam.cx = (x0 + x1) / 2; cam.cz = (z0 + z1) / 2;
  cam.scale = 0.92 * Math.min(cv.clientWidth / Math.max(x1 - x0, 1), cv.clientHeight / Math.max(z1 - z0, 1));
}

const toS = (x, z) => [(x - cam.cx) * cam.scale + cv.width / 2 / devicePixelRatio, (z - cam.cz) * cam.scale + cv.height / 2 / devicePixelRatio];

function center2d(it) { if (it && S.view === '2d') { cam.cx = it.x; cam.cz = it.z; draw2d(); } view3d.focus(it); }

export function draw2d() {
  if (S.view !== '2d') return;
  const dpr = devicePixelRatio, w = cv.clientWidth, h = cv.clientHeight;
  if (cv.width !== w * dpr || cv.height !== h * dpr) { cv.width = w * dpr; cv.height = h * dpr; }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#18181f'; ctx.fillRect(0, 0, w, h);
  if (ui.bsp()) {
    ctx.strokeStyle = '#000';
    for (const b of brushes2d) {
      if (b.poly.length < 3) continue;
      ctx.beginPath(); b.poly.forEach(([x, z], k) => { const [sx, sy] = toS(x, z); k ? ctx.lineTo(sx, sy) : ctx.moveTo(sx, sy); });
      ctx.closePath(); ctx.fillStyle = b.col; ctx.fill(); ctx.stroke();
    }
    const c = brushes2d.find((b) => b.brush === S.cell);
    if (c) {
      ctx.beginPath(); c.poly.forEach(([x, z], k) => { const [sx, sy] = toS(x, z); k ? ctx.lineTo(sx, sy) : ctx.moveTo(sx, sy); });
      ctx.closePath(); ctx.fillStyle = '#ffffff40'; ctx.fill(); ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke(); ctx.lineWidth = 1;
    }
  }
  if (S.mode === 'cells') return;
  ctx.font = '11px system-ui';
  for (const it of visibleItems()) {
    const [sx, sy] = toS(it.x, it.z), col = COLORS[it.type], sel = it.key === S.sel;
    const hs = it.fields?.half_size;
    if (hs) {
      ctx.strokeStyle = col; ctx.lineWidth = sel ? 3 : 1.5;
      ctx.strokeRect(sx - hs[0] * cam.scale, sy - hs[2] * cam.scale, 2 * hs[0] * cam.scale, 2 * hs[2] * cam.scale);
    }
    const ang = it.angle_rad != null ? it.angle_rad : it.angle_deg != null ? it.angle_deg * Math.PI / 180 : null;
    if (ang != null) {   // ASSUMED: angle 0 faces +z, positive angles turn towards +x
      ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(sx, sy);
      ctx.lineTo(sx + 12 * Math.sin(ang), sy + 12 * Math.cos(ang)); ctx.stroke();
    }
    ctx.beginPath(); ctx.arc(sx, sy, sel ? 6 : 4, 0, 2 * Math.PI);
    ctx.fillStyle = col; ctx.fill(); ctx.lineWidth = sel ? 2 : 1; ctx.strokeStyle = sel ? '#fff' : '#000'; ctx.stroke();
    if (ui.labels() || sel) { ctx.fillStyle = '#fff'; ctx.fillText(label(it), sx + 7, sy - 5); }
  }
  ctx.lineWidth = 1;
}

const toW = (sx, sy) => [cam.cx + (sx - cv.clientWidth / 2) / cam.scale, cam.cz + (sy - cv.clientHeight / 2) / cam.scale];

function inPoly(poly, x, z) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, zi] = poly[i], [xj, zj] = poly[j];
    if ((zi > z) !== (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi) inside = !inside;
  }
  return inside;
}

function itemAt(sx, sy) {
  let best = null, bd = 10;
  for (const it of visibleItems()) {
    const [px, py] = toS(it.x, it.z), d = Math.hypot(px - sx, py - sy);
    if (d < bd) { bd = d; best = it; }
  }
  return best;
}

// drag: pans the view, or moves the selected item when it starts on it (released -> one 'item' / 'entry' edit)
let drag = null;
cv.addEventListener('mousedown', (e) => {
  const hit = S.mode === 'items' ? itemAt(e.offsetX, e.offsetY) : null;
  const moving = hit && hit.key === S.sel ? hit : null;
  drag = { x: e.offsetX, y: e.offsetY, cx: cam.cx, cz: cam.cz, moved: false, item: moving, ox: hit?.x, oz: hit?.z };
});
window.addEventListener('mouseup', (e) => {
  const d = drag;
  drag = null;
  if (!d) return;
  if (d.item && d.moved) {
    const it = d.item, pos = { x: Math.round(S.ghost.x), z: Math.round(S.ghost.z) }, step = S.ghost.step;
    S.ghost = null;
    if (it.type === 'furniture') {
      if (!step.x && !step.z) return draw2d();
      return edit('furniture', { i: it.index, x: it.cell[0] + step.x, z: it.cell[1] + step.z });
    }
    if (pos.x === d.ox && pos.z === d.oz) return draw2d();
    return it.type === 'entry' ? edit('entry', { k: it.index, ...pos }) : edit('item', { ...itemAddr(it), ...pos });
  }
  if (d.moved || e.target !== cv) return;
  if (S.placing && S.mode === 'items') return addItemAt(...toW(e.offsetX, e.offsetY));
  if (S.mode === 'cells') {
    const [x, z] = toW(e.offsetX, e.offsetY);
    const hits = brushes2d.filter((b) => b.poly.length >= 3 && inPoly(b.poly, x, z));
    // click again on the same spot: next cell down (cells overlap in the top-down view)
    const k = hits.findIndex((b) => b.brush === S.cell);
    const pick = hits.length ? hits[k > 0 ? k - 1 : hits.length - 1] : null;
    selectCell(pick?.brush ?? null, [x, z]);
  } else {
    select(itemAt(e.offsetX, e.offsetY)?.key ?? null);
  }
});
cv.addEventListener('mousemove', (e) => {
  if (!drag) return;
  const dx = e.offsetX - drag.x, dy = e.offsetY - drag.y;
  if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
  if (!drag.moved) return;
  if (drag.item) {
    S.ghost = { key: drag.item.key, x: drag.ox + dx / cam.scale, z: drag.oz + dy / cam.scale };
    if (drag.item.type === 'furniture') snapFurniture(drag.item);
    else status(`move to x ${Math.round(S.ghost.x)}, z ${Math.round(S.ghost.z)}`);
  } else {
    cam.cx = drag.cx - dx / cam.scale; cam.cz = drag.cz - dy / cam.scale;
  }
  draw2d();
});
// furniture moves by whole grid cells; a wall prop only along its wall (= the cell z of its entry)
function snapFurniture(it) {
  const g = S.loc.furniture.grid.cell, cx = Math.round((S.ghost.x - it.x) / g), cz = Math.round((S.ghost.z - it.z) / g);
  const along = it.along === 'z' ? cz : cx;
  S.ghost.step = it.wall ? { x: 0, z: along } : { x: cx, z: cz };
  S.ghost.x = it.x + (it.wall ? (it.along === 'x' ? along : 0) : cx) * g;
  S.ghost.z = it.z + (it.wall ? (it.along === 'z' ? along : 0) : cz) * g;
  status(it.wall ? `wall slot ${it.cell[0]}, cell ${it.cell[1] + along}` : `cell ${it.cell[0] + cx}, ${it.cell[1] + cz}`);
}

cv.addEventListener('wheel', (e) => {
  e.preventDefault();
  const f = Math.exp(-e.deltaY * 0.0015), w = cv.clientWidth, h = cv.clientHeight;
  const wx = cam.cx + (e.offsetX - w / 2) / cam.scale, wz = cam.cz + (e.offsetY - h / 2) / cam.scale;
  cam.scale *= f; cam.cx = wx - (e.offsetX - w / 2) / cam.scale; cam.cz = wz - (e.offsetY - h / 2) / cam.scale; draw2d();
}, { passive: false });
window.addEventListener('resize', () => { draw2d(); view3d.resize(); });

// ---- loading --------------------------------------------------------------------------------------------------
const view3d = new View3D($('view3d'), { select: (k) => select(k), visibleItems, ui, colors: COLORS });

async function openLocation(id, block, item) {
  status('Loading…');
  S.sel = null; S.cell = null; S.placing = null;
  try {
    const [loc, bspj] = await Promise.all([api(`/api/location/${id}?lang=${S.lang}`), api(`/api/bsp/${id}`)]);
    S.loc = loc; S.bsp = bspj;
    $('loc').value = id;
    const bs = $('block');
    bs.innerHTML = loc.blocks.map((b, k) => `<option value="${k}">${k === 0 ? 'block 0 only' : `block 0 + ${k}`}</option>`).join('');
    S.block = block != null && block < loc.blocks.length ? block : (loc.blocks.length > 1 ? 1 : 0);
    bs.value = S.block;
    location.hash = `loc=${id}&block=${S.block}`;
    prepare2d(); refresh(true);
    if (item) select(item);
    if (S.mode === 'cells') selectCell(null);
    showEdited();
  } catch (e) { status(`Error: ${e.message}`); }
}

// after an edit: same location, view and selection (the item keeps its key unless it was deleted)
async function reload() {
  status('Saving…');
  const [loc, bspj, pal] = await Promise.all([api(`/api/location/${S.loc.id}?lang=${S.lang}`), api(`/api/bsp/${S.loc.id}`),
    api(`/api/palette?lang=${S.lang}`)]);
  const sel = S.sel;
  S.loc = loc; S.bsp = bspj; S.cell = null; S.palette = pal;
  prepare2d(); refresh(false);
  if (S.mode === 'items' && sel) select(sel);
  if (S.mode === 'cells') selectCell(null);
  showEdited();
}

async function showEdited() {
  const j = await api('/api/edits');
  const e = S.loc?.edited || {};
  const here = [e.layout && 'layout', e.bsp && 'collision', e.furniture && 'furniture'].filter(Boolean);
  $('edited').textContent = `${j.edits.length} edited file(s)` + (here.length ? ` · this location: ${here.join(' + ')}` : '');
  $('undo').disabled = !j.undo;
  status(`${S.loc.place} · layout ${S.loc.nav ?? '—'} · BSP ${S.loc.bsp} · ${S.bsp.brushes.length} solid cells`);
}

async function buildRom() {
  status('Building the ROM…'); $('build').disabled = true;
  try {
    const r = await fetch('/api/build', { method: 'POST', body: '{}' });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error);
    status(`Built ${j.rom} (${(j.size / 1048576).toFixed(1)} MB, ${j.edits.length} edited file(s))`);
  } catch (e) { status(`Build failed: ${e.message}`); } finally { $('build').disabled = false; }
}

function refresh(refit) {
  renderList(); renderScripts(); renderLegend(); renderDetails(null); renderPalette();
  if (refit) fit2d();
  draw2d();
  view3d.load(S.loc, S.bsp, refit);
}

function setView(v) {
  S.view = v;
  $('tab2d').classList.toggle('on', v === '2d'); $('tab3d').classList.toggle('on', v === '3d');
  $('view2d').hidden = v !== '2d'; $('view3d').hidden = v !== '3d';
  view3d.setActive(v === '3d'); draw2d();
}

async function init() {
  const [j, pal] = await Promise.all([api('/api/locations'), api(`/api/palette?lang=${S.lang}`)]);
  S.locs = j.locations; S.palette = pal;
  $('loc').innerHTML = S.locs.map((l) => `<option value="${l.id}">${l.id} · ${esc(l.place)}</option>`).join('');
  $('lang').innerHTML = j.langs.map((l) => `<option>${l}</option>`).join('');
  $('loc').addEventListener('change', () => openLocation(+$('loc').value));
  $('block').addEventListener('change', () => { S.block = +$('block').value; location.hash = `loc=${S.loc.id}&block=${S.block}`; refresh(false); });
  $('lang').addEventListener('change', async () => {
    S.lang = $('lang').value; S.palette = await api(`/api/palette?lang=${S.lang}`); openLocation(S.loc.id, S.block);
  });
  $('tab2d').addEventListener('click', () => setView('2d'));
  $('modeCells').addEventListener('click', () => setMode(S.mode === 'cells' ? 'items' : 'cells'));
  $('undo').addEventListener('click', () => edit('undo'));
  $('revert').addEventListener('click', () => confirm(`Drop every edit of ${S.loc.place} (layout, collision, room furniture)?`) && edit('revert'));
  $('build').addEventListener('click', buildRom);
  window.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT') return;
    if (e.key === 'Escape' && S.placing) { S.placing = null; renderPalette(); status('Placing cancelled'); }
    if (e.key === 'z' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); edit('undo'); }
    if (e.key === 'Delete' && S.mode === 'items' && !S.sel?.startsWith('f/')) deleteItem(visibleItems().find((i) => i.key === S.sel));
  });
  $('tab3d').addEventListener('click', () => setView('3d'));
  for (const id of ['showBsp', 'showScene', 'showModels', 'showLabels']) $(id).addEventListener('change', () => { draw2d(); view3d.updateVisibility(); });
  const h = new URLSearchParams(location.hash.slice(1));
  if (h.get('view') === '3d') setView('3d');
  openLocation(+(h.get('loc') ?? 5), h.has('block') ? +h.get('block') : null, h.get('item'));
}
init();
window.editor = { S, visibleItems, toS, brushes: () => brushes2d };   // handle for the browser console and UI tests
