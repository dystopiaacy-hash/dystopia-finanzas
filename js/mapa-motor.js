/* Mapa: motor del canvas. Cámara (translate+scale sobre #world), arrastre, pellizco, rueda, vuelo animado, flechas SVG,
   minimapa en canvas, atajos, modo Presentar y relleno automático de los marcos. Sin datos: el contenido lo pone la vista.
   Reglas del spec: ZMIN 0.06, ZMAX 2.2, flyTo 650 ms, vh de encuadre = alto - 120 (70 presentando), marcos con pad .94. */
const ZMIN = 0.06, ZMAX = 2.2;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const quieto = () => window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
const esCampo = t => t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA' || t.isContentEditable);

/* Relleno automático: agrega bloques del pool mientras entren; el último se estira hasta el borde. */
export function rellenar(vista, pool) {
  vista.querySelectorAll('[data-fill]').forEach(e => e.remove());
  vista.querySelectorAll('.grow').forEach(e => { if (!e.querySelector('.mvacio')) e.classList.remove('grow'); });
  const sobra = () => vista.scrollHeight > vista.clientHeight + 1;
  let ultimo = null;
  for (const mk of pool || []) {
    const t = document.createElement('div');
    t.dataset.fill = '1';
    t.innerHTML = mk();
    vista.appendChild(t);
    if (sobra()) t.remove(); else ultimo = t;
  }
  if (!ultimo) { const k = [...vista.children].filter(c => !c.classList.contains('grow')).pop(); if (k && k.classList.contains('mcard') && !vista.querySelector('.grow')) ultimo = k; }
  if (ultimo) ultimo.classList.add('grow');
}

export function crearMotor(root, { rects, bounds, onCambio }) {
  const board = root.querySelector('#board'), world = root.querySelector('#world');
  const mini = root.querySelector('#minic'), zlab = root.querySelector('#zpct'), svg = root.querySelector('#links');
  let cam = { x: 0, y: 0, z: 0.2 }, cur = null, presentando = false, anim = 0, activo = -1;
  const limpiezas = [];
  const on = (t, ev, fn, o) => { t.addEventListener(ev, fn, o); limpiezas.push(() => t.removeEventListener(ev, fn, o)); };
  const vw = () => board.clientWidth, vh = () => board.clientHeight;

  /* ---------- cámara ---------- */
  const camFor = (r, pad) => {
    const z = clamp(Math.min(vw() * pad / r.w, (vh() - (presentando ? 70 : 120) + (vh() < 600 ? 60 : 0)) * pad / r.h), ZMIN, ZMAX);
    return { x: vw() / 2 - (r.x + r.w / 2) * z, y: vh() / 2 + (presentando ? 0 : 24) - (r.y + r.h / 2) * z, z };
  };
  const rectMarco = i => { const r = rects[i]; return i === 0 ? { ...r } : { x: r.x, y: r.y - 50, w: r.w, h: r.h + 60 }; };

  function apply() {
    world.style.transform = `translate(${cam.x}px,${cam.y}px) scale(${cam.z})`;
    const s = 24 * clamp(cam.z * 2, 0.5, 2);
    board.style.backgroundSize = `${s}px ${s}px`;
    board.style.backgroundPosition = `${((cam.x % s) + s) % s}px ${((cam.y % s) + s) % s}px`;
    world.style.setProperty('--ls', clamp(0.95 / cam.z, 1, 5).toFixed(3));
    world.style.setProperty('--ll', clamp(0.95 / cam.z, 1, 2.4).toFixed(3));
    world.classList.toggle('far', cam.z < 0.24);
    zlab.textContent = `${Math.round(cam.z * 100)}%`;
    /* marco activo: el que contiene el centro de la pantalla, solo si hay zoom */
    let a = -1;
    if (cam.z > 0.3) {
      const cx = (vw() / 2 - cam.x) / cam.z, cy = (vh() / 2 - cam.y) / cam.z;
      a = rects.findIndex(r => cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h);
    }
    if (a !== activo) {
      activo = a;
      root.querySelectorAll('.frame,.intro').forEach(f => f.classList.toggle('active', +f.dataset.i === a));
      root.querySelectorAll('#plist button').forEach(b => b.classList.toggle('on', +b.dataset.go === a));
    }
    dibujarMini();
    if (onCambio) onCambio(cam);
  }

  function flyTo(dest, ms = 650) {
    cancelAnimationFrame(anim);
    if (quieto() || ms <= 0) { cam = dest; apply(); return; }
    const c0 = { x: (vw() / 2 - cam.x) / cam.z, y: (vh() / 2 - cam.y) / cam.z }, z0 = cam.z;
    const c1 = { x: (vw() / 2 - dest.x) / dest.z, y: (vh() / 2 - dest.y) / dest.z }, t0 = performance.now();
    /* centro de mundo lineal + zoom logarítmico (vuelo panorámico) */
    const paso = now => {
      const k = clamp((now - t0) / ms, 0, 1), e = k < 0.5 ? 4 * k ** 3 : 1 - (-2 * k + 2) ** 3 / 2;
      const z = Math.exp(Math.log(z0) + (Math.log(dest.z) - Math.log(z0)) * e);
      const cx = c0.x + (c1.x - c0.x) * e, cy = c0.y + (c1.y - c0.y) * e;
      cam = { x: vw() / 2 - cx * z, y: vh() / 2 - cy * z, z };
      apply();
      if (k < 1) anim = requestAnimationFrame(paso); else { cam = dest; apply(); }
    };
    anim = requestAnimationFrame(paso);
  }
  const zoomEn = (px, py, f) => {
    const z = clamp(cam.z * f, ZMIN, ZMAX), k = z / cam.z;
    cam = { x: px - (px - cam.x) * k, y: py - (py - cam.y) * k, z };
    apply();
  };
  const verTodo = () => { cur = null; flyTo(camFor(bounds, 0.96)); };
  const goFrame = i => {
    const n = rects.length;
    cur = ((i % n) + n) % n;
    flyTo(camFor(rectMarco(cur), 0.94));
    actualizarPres();
  };
  const sig = d => goFrame((cur == null ? (d > 0 ? 0 : rects.length - 1) : cur + d));

  /* ---------- puntero: arrastrar y pellizcar ---------- */
  const ptrs = new Map();
  let arr = null, pinch = null;
  on(board, 'pointerdown', e => {
    if (e.target.closest('a,button,select,input,.mapa-sel')) return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    cancelAnimationFrame(anim);
    if (ptrs.size === 1) arr = { x: e.clientX, y: e.clientY, cx: cam.x, cy: cam.y, mov: false };
    if (ptrs.size === 2) {
      const [a, b] = [...ptrs.values()];
      pinch = { d: Math.hypot(a.x - b.x, a.y - b.y) || 1, z: cam.z };
      arr = null;
    }
  });
  on(board, 'pointermove', e => {
    if (!ptrs.has(e.pointerId)) return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && ptrs.size >= 2) {
      const [a, b] = [...ptrs.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y) || 1, mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      const r = board.getBoundingClientRect();
      const z = clamp(pinch.z * (d / pinch.d), ZMIN, ZMAX), k = z / cam.z;
      cam = { x: (mx - r.left) - ((mx - r.left) - cam.x) * k, y: (my - r.top) - ((my - r.top) - cam.y) * k, z };
      apply();
      return;
    }
    if (!arr) return;
    const dx = e.clientX - arr.x, dy = e.clientY - arr.y;
    if (!arr.mov && Math.hypot(dx, dy) < 4) return;
    if (!arr.mov) { arr.mov = true; try { board.setPointerCapture(e.pointerId); } catch (_) { /* nada */ } board.classList.add('grab'); }
    cam = { ...cam, x: arr.cx + dx, y: arr.cy + dy };
    apply();
  });
  const soltar = e => {
    ptrs.delete(e.pointerId);
    if (ptrs.size < 2) pinch = null;
    if (ptrs.size === 0) { arr = null; board.classList.remove('grab'); }
  };
  on(board, 'pointerup', soltar); on(board, 'pointercancel', soltar);
  on(board, 'wheel', e => {
    e.preventDefault();
    const r = board.getBoundingClientRect(), px = e.clientX - r.left, py = e.clientY - r.top;
    const rueda = e.deltaMode === 1 || (Number.isInteger(e.deltaY) && Math.abs(e.deltaY) >= 50);
    if (e.ctrlKey || e.metaKey || rueda) { cancelAnimationFrame(anim); zoomEn(px, py, Math.exp(-e.deltaY * (rueda && !e.ctrlKey ? 0.0018 : 0.012))); }
    else { cam = { ...cam, x: cam.x - e.deltaX, y: cam.y - e.deltaY }; apply(); }
  }, { passive: false });
  on(board, 'dblclick', e => {
    if (e.target.closest('.frame .app,.intro,a,button')) return;
    const r = board.getBoundingClientRect();
    zoomEn(e.clientX - r.left, e.clientY - r.top, 1.6);
  });
  on(root, 'click', e => {
    const g = e.target.closest('[data-go]');
    if (!g || !root.contains(g)) return;
    e.preventDefault();
    goFrame(+g.dataset.go);
    if (g.closest('#panel') && matchMedia('(max-width:760px)').matches) panel(false);
  });

  /* ---------- panel de marcos, presentar, atajos ---------- */
  const panelEl = root.querySelector('#panel');
  const panel = v => { panelEl.hidden = v === undefined ? !panelEl.hidden : !v; root.querySelector('#b-marcos').classList.toggle('on', !panelEl.hidden); };
  const nombre = i => root.querySelector(`[data-go="${i}"].pitem .pn`)?.textContent || '';
  function actualizarPres() {
    if (!presentando) return;
    root.querySelector('#pcont').textContent = `${(cur ?? 0) + 1} / ${rects.length} · ${nombre(cur ?? 0)}`;
  }
  function presentar(v) {
    presentando = v === undefined ? !presentando : v;
    root.classList.toggle('presentando', presentando);
    if (presentando) { panelEl.hidden = true; goFrame(cur || 0); } else if (cur != null) goFrame(cur); else verTodo();
  }
  on(root.querySelector('#b-pres'), 'click', () => presentar());
  on(root.querySelector('#p-salir'), 'click', () => presentar(false));
  on(root.querySelector('#p-ant'), 'click', () => sig(-1));
  on(root.querySelector('#p-sig'), 'click', () => sig(1));
  on(root.querySelector('#b-marcos'), 'click', () => panel());
  on(root.querySelector('#panel-x'), 'click', () => panel(false));
  on(root.querySelector('#t-todo'), 'click', verTodo);
  on(root.querySelector('#t-ant'), 'click', () => sig(-1));
  on(root.querySelector('#t-sig'), 'click', () => sig(1));
  on(root.querySelector('#z-mas'), 'click', () => zoomEn(vw() / 2, vh() / 2, 1.25));
  on(root.querySelector('#z-menos'), 'click', () => zoomEn(vw() / 2, vh() / 2, 0.8));
  on(zlab, 'click', verTodo);
  const buscar = root.querySelector('#pbuscar');
  const sinTilde = s => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  on(buscar, 'input', () => root.querySelectorAll('#plist .pitem').forEach(b => { b.hidden = !sinTilde(b.textContent).includes(sinTilde(buscar.value.trim())); }));

  on(document, 'keydown', e => {
    if (esCampo(e.target) || e.altKey) return;
    const k = e.key;
    if ((e.ctrlKey || e.metaKey) && ['+', '=', '-', '0'].includes(k)) {
      e.preventDefault();
      if (k === '0') verTodo(); else zoomEn(vw() / 2, vh() / 2, k === '-' ? 0.8 : 1.25);
      return;
    }
    if (e.ctrlKey || e.metaKey) return;
    if (/^[1-9]$/.test(k)) { if (+k < rects.length) goFrame(+k); }
    else if (k === '0') verTodo();
    else if (k === 'ArrowRight' || k === 'PageDown' || (k === ' ' && presentando)) { e.preventDefault(); sig(1); }
    else if (k === 'ArrowLeft' || k === 'PageUp') { e.preventDefault(); sig(-1); }
    else if (k === '+' || k === '=') zoomEn(vw() / 2, vh() / 2, 1.25);
    else if (k === '-') zoomEn(vw() / 2, vh() / 2, 0.8);
    else if (k === 'f' || k === 'F') panel();
    else if (k === 'p' || k === 'P') presentar();
    else if (k === 'Escape') { if (presentando) presentar(false); else panel(false); }
  });

  /* ---------- minimapa ---------- */
  const tokens = () => getComputedStyle(root);
  function dibujarMini() {
    if (!mini) return;
    const c = mini.getContext('2d'), W = mini.width, H = mini.height, st = tokens();
    const col = n => st.getPropertyValue(n).trim() || '#888';
    c.clearRect(0, 0, W, H);
    c.fillStyle = col('--surface-2'); c.fillRect(0, 0, W, H);
    const s = Math.min(W / bounds.w, H / bounds.h), ox = (W - bounds.w * s) / 2, oy = (H - bounds.h * s) / 2;
    const X = x => ox + (x - bounds.x) * s, Y = y => oy + (y - bounds.y) * s;
    rects.forEach((r, i) => {
      c.fillStyle = i === 0 ? col('--accent') : col('--surface'); c.fillRect(X(r.x), Y(r.y), r.w * s, r.h * s);
      if (i) { c.strokeStyle = col('--line-2'); c.lineWidth = 1; c.strokeRect(X(r.x), Y(r.y), r.w * s, r.h * s); }
    });
    c.strokeStyle = col('--accent'); c.lineWidth = 3;
    c.strokeRect(X(-cam.x / cam.z), Y(-cam.y / cam.z), (vw() / cam.z) * s, (vh() / cam.z) * s);
  }
  on(mini, 'click', e => {
    const r = mini.getBoundingClientRect(), W = mini.width, H = mini.height;
    const s = Math.min(W / bounds.w, H / bounds.h), ox = (W - bounds.w * s) / 2, oy = (H - bounds.h * s) / 2;
    const wx = bounds.x + (((e.clientX - r.left) / r.width) * W - ox) / s, wy = bounds.y + (((e.clientY - r.top) / r.height) * H - oy) / s;
    const z = Math.max(cam.z, 0.35);
    flyTo({ x: vw() / 2 - wx * z, y: vh() / 2 - wy * z, z }, 450);
  });
  on(window, 'resize', apply);
  const mo = new MutationObserver(dibujarMini);
  mo.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  limpiezas.push(() => mo.disconnect());

  /* ---------- flechas del recorrido ---------- */
  const NORMAL = { r: [1, 0], l: [-1, 0], t: [0, -1], b: [0, 1] };
  const punto = (r, lado) => ({ r: [r.x + r.w, r.y + r.h / 2], l: [r.x, r.y + r.h / 2], t: [r.x + r.w / 2, r.y], b: [r.x + r.w / 2, r.y + r.h] }[lado]);
  function flechas(lista) {
    world.querySelectorAll('.link-label').forEach(e => e.remove());
    svg.innerHTML = '';
    for (const l of lista) {
      const rd = rects[l.de + 1], ra = rects[l.a + 1];   // de/a = índice de área (0 = Marketing); el rect 0 es «Empieza aquí»
      if (!rd || !ra) continue;
      const nd = NORMAL[l.ladoDe], na = NORMAL[l.ladoA], pd = punto(rd, l.ladoDe), pa = punto(ra, l.ladoA);
      const A = [pd[0] + nd[0] * 18, pd[1] + nd[1] * 18], B = [pa[0] + na[0] * 30, pa[1] + na[1] * 30];
      const k = Math.max(120, Math.hypot(B[0] - A[0], B[1] - A[1]) * 0.4);
      const c1 = [A[0] + nd[0] * k, A[1] + nd[1] * k], c2 = [B[0] + na[0] * k, B[1] + na[1] * k];
      const tip = [pa[0] + na[0] * 8, pa[1] + na[1] * 8], ang = Math.atan2(tip[1] - c2[1], tip[0] - c2[0]), L = 22;
      const base = [tip[0] - Math.cos(ang) * L, tip[1] - Math.sin(ang) * L], px = -Math.sin(ang) * L * 0.45, py = Math.cos(ang) * L * 0.45;
      svg.insertAdjacentHTML('beforeend', `<path d="M${A[0]},${A[1]} C${c1[0]},${c1[1]} ${c2[0]},${c2[1]} ${base[0]},${base[1]}" class="lk"/>
        <polygon points="${tip[0]},${tip[1]} ${base[0] + px},${base[1] + py} ${base[0] - px},${base[1] - py}" class="lh"/>`);
      const mx = (A[0] + 3 * c1[0] + 3 * c2[0] + base[0]) / 8, my = (A[1] + 3 * c1[1] + 3 * c2[1] + base[1]) / 8;
      const d = document.createElement('div');
      d.className = 'link-label'; d.style.left = `${mx}px`; d.style.top = `${my}px`; d.textContent = l.txt;
      world.appendChild(d);
    }
  }

  const inicial = () => { cam = camFor(innerWidth < 760 ? rectMarco(0) : bounds, 0.96); apply(); };
  return {
    apply, flechas, goFrame, verTodo, inicial, redibujar: dibujarMini,
    destroy() { cancelAnimationFrame(anim); limpiezas.forEach(f => f()); }
  };
}
