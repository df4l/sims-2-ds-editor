// 3D view: scene BMD0 models (nitrogen GLB) at the origin, item models / markers at their layout position,
// BSP collision as translucent cells. Layout, BSP and GLB share one space (checked on AlienRoom, journal 2026-10-06).
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const glbCache = new Map();
const loader = new GLTFLoader();

function fetchGlb(entry, tex) {   // tex: prop variant texture entry (couch colours, dirty toilets...), or null
  const url = tex == null ? `/api/model/${entry}.glb` : `/api/model/${entry}.glb?tex=${tex}`;
  if (!glbCache.has(url)) {
    glbCache.set(url, fetch(url).then((r) => (r.ok ? r.arrayBuffer() : null)).catch(() => null));
  }
  return glbCache.get(url);
}

async function loadModel(entry, tex = null) {
  const buf = await fetchGlb(entry, tex);
  if (!buf) return null;
  return new Promise((ok) => loader.parse(buf.slice(0), '', (g) => ok(g.scene), () => ok(null)));
}

export class View3D {
  constructor(el, opts) {
    this.el = el; this.opts = opts; this.active = false; this.token = 0;
    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setPixelRatio(devicePixelRatio);
    el.appendChild(this.renderer.domElement);
    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x18181f);
    this.scene.add(new THREE.AmbientLight(0xffffff, 2));
    this.camera = new THREE.PerspectiveCamera(50, 1, 0.5, 5000);
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.addEventListener('change', () => this.render());
    this.root = { scene: new THREE.Group(), bsp: new THREE.Group(), items: new THREE.Group() };
    for (const g of Object.values(this.root)) this.scene.add(g);
    this.helper = null;
    let down = null;
    this.renderer.domElement.addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; });
    this.renderer.domElement.addEventListener('pointerup', (e) => {
      if (down && Math.hypot(e.clientX - down[0], e.clientY - down[1]) < 4) this.pick(e);
      down = null;
    });
  }

  setActive(on) { this.active = on; if (on) { this.resize(); this.render(); } }

  resize() {
    const w = this.el.clientWidth, h = this.el.clientHeight;
    if (!w || !h) return;
    this.renderer.setSize(w, h); this.camera.aspect = w / h; this.camera.updateProjectionMatrix(); this.render();
  }

  render() { if (this.active) this.renderer.render(this.scene, this.camera); }

  clear(g) {
    for (const c of [...g.children]) {
      g.remove(c);
      c.traverse((o) => { o.geometry?.dispose(); const m = o.material; (Array.isArray(m) ? m : m ? [m] : []).forEach((x) => { x.map?.dispose(); x.dispose(); }); });
    }
  }

  load(loc, bsp, refit) {
    const token = ++this.token;
    for (const g of Object.values(this.root)) this.clear(g);
    this.setSelection(null);
    this.buildBsp(bsp);
    if (refit) this.fit();
    for (const m of loc.scene_models) {
      loadModel(m.entry).then((s) => { if (s && token === this.token) { s.name = m.name; this.root.scene.add(s); this.render(); } });
    }
    for (const it of this.opts.visibleItems()) this.addItem(it, token);
    this.updateVisibility();
  }

  buildBsp(bsp) {
    const pos = [], edges = [];
    for (const b of bsp.brushes) {
      for (const f of b.faces) {
        for (let k = 1; k + 1 < f.length; k++) for (const i of [f[0], f[k], f[k + 1]]) pos.push(...b.verts[i]);
        for (let k = 0; k < f.length; k++) edges.push(...b.verts[f[k]], ...b.verts[f[(k + 1) % f.length]]);
      }
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.computeVertexNormals();
    this.root.bsp.add(new THREE.Mesh(g, new THREE.MeshNormalMaterial({ transparent: true, opacity: 0.25, depthWrite: false, side: THREE.DoubleSide })));
    const e = new THREE.BufferGeometry();
    e.setAttribute('position', new THREE.Float32BufferAttribute(edges, 3));
    this.root.bsp.add(new THREE.LineSegments(e, new THREE.LineBasicMaterial({ color: 0x6fa8dc, transparent: true, opacity: 0.6 })));
    this.bounds = new THREE.Box3().setFromBufferAttribute(g.getAttribute('position'));
  }

  addItem(it, token) {
    const col = new THREE.Color(this.opts.colors[it.type]);
    const g = new THREE.Group();
    g.position.set(it.x, it.y, it.z);
    g.userData.key = it.key;
    const ang = it.angle_rad != null ? it.angle_rad : it.angle_deg != null ? it.angle_deg * Math.PI / 180 : 0;
    g.rotation.y = ang;   // furniture: game actor angle (+0x88), same matrix as three.js; layout items: ASSUMED sign
    const marker = new THREE.Mesh(new THREE.SphereGeometry(1.2, 12, 8), new THREE.MeshBasicMaterial({ color: col }));
    marker.userData.marker = true;
    g.add(marker);
    if (it.angle_deg != null || it.angle_rad != null) {
      const arrow = new THREE.ArrowHelper(new THREE.Vector3(0, 0, 1), new THREE.Vector3(0, 0.5, 0), 5, col.getHex(), 1.5, 1);
      arrow.userData.marker = true;
      g.add(arrow);
    }
    const hs = it.fields?.half_size;
    if (hs) {   // ASSUMED: centred on the item position, axis aligned
      const box = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(2 * hs[0], 2 * hs[1], 2 * hs[2])),
        new THREE.LineBasicMaterial({ color: col }));
      box.rotation.y = -ang;
      g.add(box);
    }
    this.root.items.add(g);
    if (it.model != null) {
      loadModel(it.model, it.model_tex).then((s) => {
        if (!s || token !== this.token) return;
        s.userData.itemModel = true; s.visible = this.opts.ui.models(); g.add(s); this.render();
      });
    }
  }

  updateVisibility() {
    this.root.bsp.visible = this.opts.ui.bsp();
    this.root.scene.visible = this.opts.ui.scene();
    for (const g of this.root.items.children) for (const c of g.children) if (c.userData.itemModel) c.visible = this.opts.ui.models();
    this.render();
  }

  fit() {
    if (!this.bounds || this.bounds.isEmpty()) return;
    const c = this.bounds.getCenter(new THREE.Vector3()), s = this.bounds.getSize(new THREE.Vector3());
    const r = Math.max(s.x, s.z, 20);
    this.controls.target.copy(c);
    this.camera.position.set(c.x, c.y + r * 0.8, c.z + r * 0.8);
    this.camera.far = r * 10; this.camera.updateProjectionMatrix(); this.controls.update();
  }

  focus(it) {
    if (!it) return;
    const d = this.camera.position.clone().sub(this.controls.target);
    this.controls.target.set(it.x, it.y, it.z);
    this.camera.position.copy(this.controls.target).add(d.setLength(Math.min(d.length(), 80)));
    this.controls.update();
  }

  setSelection(key) {
    if (this.helper) { this.scene.remove(this.helper); this.helper.dispose(); this.helper = null; }
    const g = this.root.items.children.find((c) => c.userData.key === key);
    if (g) { this.helper = new THREE.BoxHelper(g, 0xffffff); this.scene.add(this.helper); }
    this.render();
  }

  pick(e) {
    const r = this.renderer.domElement.getBoundingClientRect();
    const ray = new THREE.Raycaster();
    ray.setFromCamera(new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1), this.camera);
    for (const h of ray.intersectObjects(this.root.items.children, true)) {
      let o = h.object;
      while (o && !o.userData.key) o = o.parent;
      if (o && o.visible !== false) { this.opts.select(o.userData.key); return; }
    }
  }
}
