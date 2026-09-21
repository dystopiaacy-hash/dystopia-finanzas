// pruebas/corte.test.ts — ciclo de vida de las corridas cuando la funcion muere.
// Corre nucleo.ts contra una base FALSA en memoria y un Google FALSO que sirve
// los fixtures reales como grid (pasan por los parsers de verdad). Sin red.
//
//   A. Corrida normal: 12 corridas cerradas, payload_bytes en cada una, nada abierto.
//   B. Muere en la fuente 3 (colgada despues de registrar el payload):
//      2 cerradas, 1 en_curso CON payload_bytes, 9 pendiente. El barrido de la
//      invocacion siguiente: la 3 -> error con corte; las 9 -> omitida. Nunca 12 iguales.
//   C. beforeunload (alApagar): vuelve enseguida, no tira aunque la base falle o
//      no conteste, marca con el motivo del runtime y no pisa corridas cerradas.
//   D. Umbral de payload: ok -> revisar con motivo 'payload grande'; peor estado se conserva.
//   E. dry_run: no abre corridas, igual informa payload_bytes.
// Uso: deno test --no-check=remote -A pruebas/corte.test.ts   (o npm run test:fn)

import { assert, assertEquals } from 'jsr:@std/assert@1';
import { ABIERTAS, alApagar, barrerHuerfanas, sincronizar, type Google } from '../supabase/functions/sincronizar/nucleo.ts';
import { aplicarUmbralPayload, MOTIVO_PAYLOAD, umbralPayload, UMBRAL_PAYLOAD_DEFECTO, HUERFANA_MIN } from '../supabase/functions/_shared/corridas.js';
import { isoASerial } from '../supabase/functions/_shared/grid.js';
import { CONFIG } from './config.mjs';

const DIR = new URL('./fixtures/', import.meta.url);
const indice = JSON.parse(Deno.readTextFileSync(new URL('index.json', DIR)));
const leer = (archivo: string) => JSON.parse(Deno.readTextFileSync(new URL(archivo, DIR))).filas;

// --- Google falso: fixture -> respuesta de grid (como pruebas/formato.mjs) ---
const num = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 10 });
const ISO = /^(\d{4})-(\d{2})-(\d{2})(?:T00:00:00)?$/;
function celda(v: unknown) {
  if (v === null || v === undefined || v === '') return {};
  if (typeof v === 'number') return { formattedValue: num.format(v), effectiveValue: { numberValue: v }, effectiveFormat: { numberFormat: { type: 'NUMBER' } } };
  const m = String(v).match(ISO);
  if (m) return { formattedValue: `${+m[3]}/${+m[2]}/${m[1]}`, effectiveValue: { numberValue: isoASerial(`${m[1]}-${m[2]}-${m[3]}`) }, effectiveFormat: { numberFormat: { type: 'DATE' } } };
  return { formattedValue: String(v), effectiveValue: { stringValue: String(v) } };
}

// Las 12 fuentes activas, en el orden de produccion (ids 4..15).
const ACTIVAS: [string, string][] = [
  ['liam', 'opps'], ['liam', 'pagos'], ['liam', 'cuotas'], ['agus', 'opps'], ['agus', 'pagos'],
  ['teo', 'opps'], ['teo', 'pagos'], ['mauro', 'opps'], ['mauro', 'pagos'], ['mauro', 'cuotas'],
  ['lucas', 'opps'], ['lucas', 'pagos'],
];
const FUENTES = ACTIVAS.map(([cuenta, tipo], i) => {
  const c = (CONFIG as any)[cuenta][tipo];
  return {
    id: i + 4, cliente_id: cuenta, spreadsheet_id: `SS_${cuenta}`, gid: (i + 4) * 100,
    nombre_hoja_esperado: indice[cuenta][tipo].hoja, tipo, forma: c.forma ?? null, fila_encabezado: c.fila_encabezado ?? 4,
    anio: c.anio ?? null, tope_monto: c.tope_monto ?? null, activo: true,
    fin_alias_columnas: (c.alias ?? []).map((a: any) => ({ campo_canonico: a.campo, alias: a.alias, obligatorio: a.obligatorio })),
    _archivo: indice[cuenta][tipo].archivo,
  };
});
const TEXTOS = new Map(FUENTES.map((f) => [f.nombre_hoja_esperado + f.spreadsheet_id, JSON.stringify({
  sheets: [{ properties: { title: f.nombre_hoja_esperado }, data: [{ rowData: leer(f._archivo).map((r: unknown[]) => ({ values: (r || []).map(celda) })) }] }],
})]));

function googleFalso(colgarEnDescarga = 0): Google & { descargas: number } {
  const g = {
    descargas: 0,
    token: () => Promise.resolve('tok'),
    metadatos: (_t: string, id: string) => Promise.resolve({
      locale: 'es_AR',
      hojas: FUENTES.filter((f) => f.spreadsheet_id === id).map((f) => ({ gid: f.gid, titulo: f.nombre_hoja_esperado })),
    }),
    descargarHoja: (_t: string, id: string, titulo: string) => {
      g.descargas++;
      if (g.descargas === colgarEnDescarga) return new Promise<never>(() => {});
      const texto = TEXTOS.get(titulo + id)!;
      return Promise.resolve({ texto, bytes: new TextEncoder().encode(texto).length });
    },
  };
  return g;
}

// --- Base falsa: el subconjunto del query builder de supabase-js que usa nucleo.ts ---
type Fila = Record<string, any>;
class Base {
  corridas: Fila[] = [];
  sig = 1000;
  // Si devuelve una promesa que no resuelve, esa consulta queda colgada (el worker "muere").
  gancho: ((q: Consulta) => Promise<never> | undefined) | null = null;
  from(t: string) { return new Consulta(this, t); }
  rpc(nombre: string, a: Fila) {
    assertEquals(nombre, 'fin_sync_escribir');
    const c = this.corridas.find((x) => x.id === a.p_corrida);
    if (!c) return Promise.resolve({ data: null, error: { message: `no existe la corrida ${a.p_corrida}` } });
    if (c.estado !== 'en_curso') return Promise.resolve({ data: null, error: { message: `la corrida ${c.id} ya esta cerrada (${c.estado})` } });
    const n = (k: string) => (a.p_datos?.[k] ?? []).length;
    Object.assign(c, { estado: a.p_estado, fin: new Date().toISOString(), mensaje: a.p_mensaje, controles: a.p_controles, filas_cargadas: n('pagos') + n('pnl') + n('cuotas') });
    return Promise.resolve({ data: { pagos: n('pagos'), pnl: n('pnl'), cuotas: n('cuotas') }, error: null });
  }
  estados() { return this.corridas.map((c) => c.estado); }
  cuenta(estado: string) { return this.corridas.filter((c) => c.estado === estado).length; }
}

class Consulta {
  op = 'select'; filtros: ((r: Fila) => boolean)[] = []; filas: Fila[] = []; valores: Fila = {}; uno = false;
  constructor(public db: Base, public tabla: string) {}
  select(_c?: string) { return this; }
  insert(filas: Fila[]) { this.op = 'insert'; this.filas = filas; return this; }
  update(v: Fila) { this.op = 'update'; this.valores = v; return this; }
  eq(c: string, v: unknown) { this.filtros.push((r) => r[c] === v); return this; }
  in(c: string, vs: unknown[]) { this.filtros.push((r) => vs.includes(r[c])); return this; }
  lt(c: string, v: string) { this.filtros.push((r) => r[c] < v); return this; }
  order() { return this; }
  limit() { return this; }
  maybeSingle() { this.uno = true; return this; }
  then(ok: (r: any) => unknown, ko?: (e: unknown) => unknown) {
    const colgada = this.db.gancho?.(this);
    return (colgada ?? Promise.resolve(this.ejecutar())).then(ok, ko);
  }
  ejecutar() {
    const pasa = (r: Fila) => this.filtros.every((f) => f(r));
    if (this.tabla === 'fin_fuentes') return { data: FUENTES.filter(pasa).map((f) => ({ ...f })), error: null };
    const t = this.db.corridas;
    if (this.op === 'insert') {
      const nuevas = this.filas.map((f) => ({ id: this.db.sig++, inicio: new Date().toISOString(), fin: null, corte: null, payload_bytes: null, ...f }));
      t.push(...nuevas);
      return { data: nuevas.map((n) => ({ ...n })), error: null };
    }
    if (this.op === 'update') {
      const tocadas = t.filter(pasa);
      for (const r of tocadas) Object.assign(r, this.valores);
      return { data: tocadas.map((r) => ({ id: r.id })), error: null };
    }
    const filas = t.filter(pasa).sort((a, b) => b.id - a.id);
    return { data: this.uno ? (filas[0] ?? null) : filas, error: null };
  }
}

const OPC = { fuenteId: null, dryRun: false, aceptarEncabezado: false, umbralPayload: UMBRAL_PAYLOAD_DEFECTO };
const respirar = () => new Promise((r) => setTimeout(r, 30));
const antes = (min: number) => new Date(Date.now() - min * 60_000).toISOString();

Deno.test('A. corrida normal: 12 cerradas, payload en cada una, nada abierto', async () => {
  ABIERTAS.clear();
  const db = new Base();
  const res = await sincronizar(db as any, googleFalso(), OPC);
  assertEquals(res.length, 12);
  assertEquals(db.corridas.length, 12);
  for (const c of db.corridas) {
    assert(['ok', 'revisar', 'parcial'].includes(c.estado), `corrida ${c.id} quedo en ${c.estado}: ${c.mensaje}`);
    assert(c.payload_bytes > 0, `corrida ${c.id} sin payload_bytes`);
    assertEquals(c.corte, null);
  }
  assertEquals(new Set(db.corridas.map((c) => c.invocacion)).size, 1);
  assertEquals(ABIERTAS.size, 0);
  // Con los fixtures ninguna hoja llega a 5 MB: ninguna corrida por payload grande.
  assert(!db.corridas.some((c) => (c.controles ?? []).some((x: any) => x.motivo === MOTIVO_PAYLOAD)));
});

Deno.test('B. muere en la fuente 3: 1 intentada, 9 sin intentar; el barrido las distingue', async () => {
  ABIERTAS.clear();
  const db = new Base();
  // La fuente 3 (liam cuotas, id 6) descarga y registra el payload; muere despues,
  // leyendo la corrida previa (como si muriera en el parseo).
  let idMuerta = 0;
  db.gancho = (q) => {
    const muerta = db.corridas.find((c) => c.fuente_id === 6);
    if (q.tabla === 'fin_sync_corridas' && q.op === 'select' && muerta?.payload_bytes) { idMuerta = muerta.id; return new Promise<never>(() => {}); }
    return undefined;
  };
  sincronizar(db as any, googleFalso(), OPC); // no se espera: queda colgada para siempre
  await respirar();

  assertEquals(db.corridas.length, 12, 'las 12 corridas se abren antes de hablar con Google');
  assertEquals(db.corridas.filter((c) => ['ok', 'revisar', 'parcial'].includes(c.estado)).length, 2);
  const muerta = db.corridas.find((c) => c.id === idMuerta)!;
  assertEquals(muerta.estado, 'en_curso');
  assert(muerta.payload_bytes > 0, 'el payload quedo escrito antes de morir');
  assertEquals(db.cuenta('pendiente'), 9);

  // Invocacion siguiente, 5 minutos despues: todavia puede estar viva -> no se toca nada.
  assertEquals(await barrerHuerfanas(db as any, Date.now() + 5 * 60_000), { cortadas: 0, omitidas: 0 });
  // A los HUERFANA_MIN + 1: se cierran, distinguidas.
  db.gancho = null;
  const b = await barrerHuerfanas(db as any, Date.now() + (HUERFANA_MIN + 1) * 60_000);
  assertEquals(b, { cortadas: 1, omitidas: 9 });
  assertEquals(muerta.estado, 'error');
  assertEquals(muerta.corte, 'sin_cierre');
  assert(/se corto durante esta corrida/.test(muerta.mensaje));
  const omitidas = db.corridas.filter((c) => c.estado === 'omitida');
  assertEquals(omitidas.length, 9);
  assert(omitidas.every((c) => c.corte === 'sin_cierre' && /no se llego a intentar/.test(c.mensaje)));
  // Las 2 que terminaron bien no se tocaron.
  assertEquals(db.corridas.filter((c) => ['ok', 'revisar', 'parcial'].includes(c.estado)).length, 2);
  ABIERTAS.clear();
});

Deno.test('B2. muere descargando (sin payload): igual queda en_curso, no pendiente', async () => {
  ABIERTAS.clear();
  const db = new Base();
  sincronizar(db as any, googleFalso(3), OPC);
  await respirar();
  const enCurso = db.corridas.filter((c) => c.estado === 'en_curso');
  assertEquals(enCurso.length, 1);
  assertEquals(enCurso[0].payload_bytes, null);
  assertEquals(db.cuenta('pendiente'), 9);
  ABIERTAS.clear();
});

Deno.test('C. beforeunload: no bloquea, no tira, marca con el motivo y no pisa lo cerrado', async () => {
  ABIERTAS.clear();
  const db = new Base();
  db.gancho = (q) => (q.tabla === 'fin_sync_corridas' && q.op === 'select' && db.corridas.find((c) => c.fuente_id === 6)?.payload_bytes ? new Promise<never>(() => {}) : undefined);
  sincronizar(db as any, googleFalso(), OPC);
  await respirar();
  db.gancho = null;
  const cerradasAntes = db.corridas.filter((c) => ['ok', 'revisar', 'parcial'].includes(c.estado)).map((c) => ({ ...c }));

  const t0 = performance.now();
  const r = alApagar(db as any, 'memory');
  const ms = performance.now() - t0;
  assertEquals(r, undefined, 'no devuelve una promesa: no hay nada que esperar');
  assert(ms < 20, `alApagar tardo ${ms} ms`);
  assertEquals(ABIERTAS.size, 0);
  await respirar();
  assertEquals(db.corridas.filter((c) => c.estado === 'error' && c.corte === 'memory').length, 1);
  assertEquals(db.corridas.filter((c) => c.estado === 'omitida' && c.corte === 'memory').length, 9);
  for (const c of cerradasAntes) assertEquals(db.corridas.find((x) => x.id === c.id)!.estado, c.estado);

  // Una corrida que cerro bien mientras tanto no se pisa: el filtro por estado lo impide.
  ABIERTAS.set(cerradasAntes[0].id, 'en_curso');
  alApagar(db as any, 'cpu');
  await respirar();
  assertEquals(db.corridas.find((x) => x.id === cerradasAntes[0].id)!.estado, cerradasAntes[0].estado);

  // Base que tira sincronicamente, base que nunca contesta, sin base: vuelve igual.
  ABIERTAS.set(1, 'en_curso'); ABIERTAS.set(2, 'pendiente');
  alApagar({ from() { throw new Error('boom'); } } as any, 'memory');
  ABIERTAS.set(1, 'en_curso');
  const colgada = { from: () => ({ update: () => ({ in: () => ({ eq: () => new Promise(() => {}) }) }) }) };
  const t1 = performance.now();
  alApagar(colgada as any, 'wall_clock');
  assert(performance.now() - t1 < 20);
  ABIERTAS.set(1, 'en_curso');
  alApagar(null, 'memory');
  // Apagado normal (nada abierto): no escribe nada.
  let escribio = false;
  alApagar({ from() { escribio = true; return {}; } } as any, 'early_drop');
  assert(!escribio);
});

Deno.test('D. umbral de payload', async () => {
  assertEquals(umbralPayload(undefined), UMBRAL_PAYLOAD_DEFECTO);
  assertEquals(umbralPayload(''), UMBRAL_PAYLOAD_DEFECTO);
  assertEquals(umbralPayload('abc'), UMBRAL_PAYLOAD_DEFECTO);
  assertEquals(umbralPayload('-5'), UMBRAL_PAYLOAD_DEFECTO);
  assertEquals(umbralPayload(' 8000000 '), 8_000_000);
  assertEquals(aplicarUmbralPayload('ok', [], 100, 200), { estado: 'ok', controles: [] });
  assertEquals(aplicarUmbralPayload('ok', [], 200, 200).estado, 'ok', 'igual al umbral no avisa');
  const g = aplicarUmbralPayload('ok', [{ motivo: 'x' }], 201, 200);
  assertEquals(g.estado, 'revisar');
  assertEquals(g.controles[1], { motivo: MOTIVO_PAYLOAD, payload_bytes: 201, umbral_bytes: 200 });
  for (const e of ['revisar', 'parcial', 'error']) assertEquals(aplicarUmbralPayload(e, [], 999, 1).estado, e);

  // De punta a punta: con un umbral chico, las que eran ok pasan a revisar y se cargan igual.
  ABIERTAS.clear();
  const normal = new Base();
  await sincronizar(normal as any, googleFalso(), OPC);
  const db = new Base();
  await sincronizar(db as any, googleFalso(), { ...OPC, umbralPayload: 1000 });
  assert(normal.cuenta('ok') > 0);
  assertEquals(db.cuenta('ok'), 0);
  for (const c of db.corridas) {
    assert((c.controles ?? []).some((x: any) => x.motivo === MOTIVO_PAYLOAD && x.payload_bytes === c.payload_bytes), `corrida ${c.id} sin control de payload`);
    assert(/payload grande/.test(c.mensaje));
  }
  assertEquals(db.corridas.map((c) => c.filas_cargadas), normal.corridas.map((c) => c.filas_cargadas), 'los datos se cargan igual');
});

Deno.test('E. dry_run: no abre corridas y informa payload_bytes', async () => {
  ABIERTAS.clear();
  const db = new Base();
  const res = await sincronizar(db as any, googleFalso(), { ...OPC, dryRun: true });
  assertEquals(db.corridas.length, 0);
  assertEquals(res.length, 12);
  assert(res.every((r) => (r.payload_bytes ?? 0) > 0));
  assertEquals(ABIERTAS.size, 0);
});

Deno.test('F. el barrido no toca corridas recientes ni cerradas', async () => {
  const db = new Base();
  db.corridas.push(
    { id: 1, fuente_id: 4, estado: 'en_curso', inicio: antes(3) },
    { id: 2, fuente_id: 5, estado: 'pendiente', inicio: antes(3) },
    { id: 3, fuente_id: 6, estado: 'ok', inicio: antes(60) },
    { id: 4, fuente_id: 7, estado: 'error', inicio: antes(60), corte: null },
  );
  assertEquals(await barrerHuerfanas(db as any), { cortadas: 0, omitidas: 0 });
  assertEquals(db.estados(), ['en_curso', 'pendiente', 'ok', 'error']);
});
