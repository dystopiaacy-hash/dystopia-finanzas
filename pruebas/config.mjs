// pruebas/config.mjs — configuracion de las fuentes para correr los parsers
// contra los fixtures. Es espejo de migraciones/002_seed_config.sql (y de
// CONTRATO.md): en produccion la Edge Function arma esto desde fin_fuentes y
// fin_alias_columnas. Si cambia uno, cambian los tres.

const COMUNES = [
  ['programa', 'PROGRAMA'],
  ['telefono', 'NUMERO'],
  ['concepto', 'CONCEPTO'],
  ['setter', 'SETTER'],
  ['comprobante', 'COMPROBANTE'],
  ['metodo_pago', 'MÉTODO DE PAGO'],
];

function alias(obligatorios, opcionales) {
  return [
    ...Object.entries(obligatorios).map(([campo, a]) => ({ campo, alias: a, obligatorio: true })),
    ...opcionales.map(([campo, a]) => ({ campo, alias: a, obligatorio: false })),
  ];
}

const ESTANDAR = alias(
  { fecha: 'FECHA DE CARGA', alumno: 'NOMBRE DEL ALUMNO', monto: 'PAGO' },
  [...COMUNES, ['closer', 'CLOSER'], ['quien_recibe', 'QUIÉN RECIBE']],
);

export const CONFIG = {
  liam: {
    pagos: { fila_encabezado: 1, tope_monto: 10000, alias: ESTANDAR },
    opps: { anio: 2026 },
    cuotas: { forma: 'cuotas_ancho', fila_encabezado: 2, tope_monto: 10000 },
  },
  agus: {
    pagos: { fila_encabezado: 1, tope_monto: 10000, alias: ESTANDAR },
    opps: { anio: 2026 },
  },
  teo: {
    pagos: {
      fila_encabezado: 1, tope_monto: 10000,
      alias: alias(
        { fecha: 'Fecha', alumno: 'NOMBRE DEL ALUMNO', monto: 'PAGO' },
        [...COMUNES, ['closer', 'CLOSER'], ['quien_recibe', 'QUIÉN RECIBE']],
      ),
    },
    opps: { anio: 2026 },
    // Vive en la planilla de CRM (inactiva en el seed), pero el parser se prueba igual.
    cuotas: { forma: 'cuotas_plano', fila_encabezado: 1, tope_monto: 10000 },
  },
  mauro: {
    pagos: {
      fila_encabezado: 1, tope_monto: 10000,
      alias: alias(
        { fecha: 'Nombre', alumno: 'NOMBRE DEL ALUMNO', monto: 'PAGO' },
        [...COMUNES, ['closer', 'CLOSER'], ['quien_recibe', 'QUIÉN RECIBE'],
          ['monto_pesos', 'PESOS'], ['monto_restante', 'Monto Restante a Pagar']],
      ),
    },
    opps: { anio: 2026 },
    cuotas: { forma: 'cuotas_ancho', fila_encabezado: 2, tope_monto: 10000 },
  },
  lucas: {
    pagos: {
      fila_encabezado: 1, tope_monto: 10000,
      alias: alias(
        { fecha: 'FECHA DE CARGA', alumno: 'Nombre', monto: 'MONTO EN USD' },
        [...COMUNES, ['closer', 'Closer'], ['quien_recibe', 'Quien Recibe'], ['estado', 'ESTADO']],
      ),
    },
    opps: { anio: 2026 },
  },
};
