// lector-xlsx.mjs - lector minimo de .xlsx (zip + XML), sin dependencias.
// leerXlsx(ruta) -> [{ nombre, matriz }]  (matriz[fila][columna], 0-based).
// Fechas: se devuelven como numero de serie (lo que espera parseFecha).
// Solo para las cargas puntuales de scripts/: la sync de produccion no lo usa.
import fs from 'node:fs';
import zlib from 'node:zlib';

function unzip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error('el archivo no es un .xlsx (zip)');
  const n = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const out = {};
  for (let k = 0; k < n; k++) {
    const metodo = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const nlen = buf.readUInt16LE(p + 28), elen = buf.readUInt16LE(p + 30), clen = buf.readUInt16LE(p + 32);
    const off = buf.readUInt32LE(p + 42);
    const nombre = buf.toString('utf8', p + 46, p + 46 + nlen);
    const ini = off + 30 + buf.readUInt16LE(off + 26) + buf.readUInt16LE(off + 28);
    const datos = buf.subarray(ini, ini + csize);
    out[nombre] = metodo === 0 ? datos : zlib.inflateRawSync(datos);
    p += 46 + nlen + elen + clen;
  }
  return out;
}

const dec = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
  .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
  .replace(/&amp;/g, '&');
const colIdx = (ref) => { let n = 0; for (const c of ref.replace(/\d+/g, '')) n = n * 26 + c.charCodeAt(0) - 64; return n - 1; };
const textos = (x) => [...x.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((m) => dec(m[1])).join('');

export function leerXlsx(ruta) {
  const z = unzip(fs.readFileSync(ruta));
  const get = (n) => (z[n] ? z[n].toString('utf8') : '');
  const ss = [...get('xl/sharedStrings.xml').matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => textos(m[1]));
  const rels = {};
  for (const m of get('xl/_rels/workbook.xml.rels').matchAll(/<Relationship\b[^>]*>/g)) {
    const id = /\bId="([^"]+)"/.exec(m[0]), t = /\bTarget="([^"]+)"/.exec(m[0]);
    if (id && t) rels[id[1]] = t[1].startsWith('/') ? t[1].slice(1) : `xl/${t[1].replace(/^\.\//, '')}`;
  }
  const hojas = [];
  for (const m of get('xl/workbook.xml').matchAll(/<sheet\b[^>]*>/g)) {
    const nombre = dec(/name="([^"]*)"/.exec(m[0])[1]);
    const rid = /r:id="([^"]+)"/.exec(m[0])[1];
    const xml = get(rels[rid]);
    const matriz = [];
    for (const r of xml.matchAll(/<row\b([^>]*)>([\s\S]*?)<\/row>/g)) {
      const rn = +/\br="(\d+)"/.exec(r[1])[1] - 1;
      const fila = (matriz[rn] = matriz[rn] || []);
      for (const c of r[2].matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const ref = /\br="([A-Z]+\d+)"/.exec(c[1]);
        if (!ref || c[2] === undefined) continue;
        const t = (/\bt="(\w+)"/.exec(c[1]) || [])[1];
        const v = /<v>([\s\S]*?)<\/v>/.exec(c[2]);
        let val = null;
        if (t === 's' && v) val = ss[+v[1]];
        else if (t === 'inlineStr') val = textos(c[2]);
        else if ((t === 'str' || t === 'e') && v) val = dec(v[1]);
        else if (t === 'b' && v) val = v[1] === '1';
        else if (v && v[1] !== '') val = Number(v[1]);
        if (val !== null) fila[colIdx(ref[1])] = val;
      }
    }
    for (let i = 0; i < matriz.length; i++) if (!matriz[i]) matriz[i] = [];
    hojas.push({ nombre, matriz });
  }
  return hojas;
}

// CSV (por si se exporta la hoja a mano). Separador coma, comillas dobles.
export function leerCsv(ruta) {
  const s = fs.readFileSync(ruta, 'utf8').replace(/^﻿/, '');
  const filas = [];
  let fila = [], celda = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) {
      if (ch === '"' && s[i + 1] === '"') { celda += '"'; i++; } else if (ch === '"') q = false; else celda += ch;
    } else if (ch === '"') q = true;
    else if (ch === ',') { fila.push(celda); celda = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && s[i + 1] === '\n') i++;
      fila.push(celda); filas.push(fila); fila = []; celda = '';
    } else celda += ch;
  }
  if (celda !== '' || fila.length) { fila.push(celda); filas.push(fila); }
  return [{ nombre: 'csv', matriz: filas.map((f) => f.map((c) => (c === '' ? null : c))) }];
}
