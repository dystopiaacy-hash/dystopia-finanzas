-- =====================================================================
-- Plantilla de carga de gastos de webinar (octubre / noviembre 2026). NO es una migracion numerada: es un molde.
-- Se llena con lo que se recolecte de Meta Ads, GHL, ManyChat, Zoom y WhatsApp y lo corre Joaquin en el SQL Editor.
-- Requiere la migracion 267 corrida. Alternativa sin SQL: pantalla Webinars > webinar > «+ Gasto» (mismos campos).
--
-- Columnas de cada fila:  webinar (nombre exacto de fin_webinars.nombre), concepto, monto USD, fecha, fuente, nota, en_opps
--   concepto: ads_webinar | ads_replay | zoom | landing | ghl | manychat | whatsapp | addevent | comision_closer | otros
--   fecha: fija el MES en que el gasto suma a los gastos del cliente (poner un dia del mes al que corresponde).
--   en_opps: true si ese gasto YA esta en los gastos de Opps del mes (no se vuelve a sumar al cliente). Ante la duda: false
--            y revisar el Opps del cliente (octubre: solo esta el Zoom 500 y los editores).
--   Un gasto se carga UNA vez. Si ya existe en la pantalla Gastos (fin_gastos) no cargarlo aca tambien.
-- Idempotente: no inserta una fila identica (mismo webinar, concepto, monto, fecha y fuente).
-- =====================================================================
insert into public.fin_webinar_gastos (webinar_id, concepto, monto_usd, fecha, fuente, nota, en_opps)
select w.id, v.concepto, v.monto, v.fecha::date, v.fuente, v.nota, v.en_opps
  from (values
    -- EJEMPLOS (reemplazar por los datos reales):
    ('AF 25/10',            'manychat',  0::numeric, '2026-10-25', 'ManyChat',  'Octubre, a completar', false),
    ('AF 25/10',            'whatsapp',  0::numeric, '2026-10-25', 'WhatsApp',  'Octubre, a completar', false),
    ('BPF 14/10',           'manychat',  0::numeric, '2026-10-14', 'ManyChat',  'Octubre, a completar', false),
    ('BPF 14/10',           'whatsapp',  0::numeric, '2026-10-14', 'WhatsApp',  'Octubre, a completar', false),
    ('AF 15/11',            'ads_webinar', 0::numeric, '2026-11-15', 'Meta Ads', 'Noviembre', false),
    ('AF 15/11',            'zoom',    500::numeric, '2026-11-15', 'Regla Zoom 500', 'Revisar si ya esta en Opps de noviembre', false),
    ('AF 15/11',            'landing', 300::numeric, '2026-11-15', 'Regla landing Agus 300', null, false),
    ('Liam Wharton 11/11',  'zoom',    500::numeric, '2026-11-11', 'Regla Zoom 500', 'Revisar si ya esta en Opps de noviembre', false),
    ('Liam Wharton 11/11',  'landing', 200::numeric, '2026-11-11', 'Regla landing Liam 200', null, false)
  ) as v(webinar, concepto, monto, fecha, fuente, nota, en_opps)
  join public.fin_webinars w on lower(btrim(w.nombre)) = lower(btrim(v.webinar)) and w.activo
 where not exists (select 1 from public.fin_webinar_gastos g
                    where g.webinar_id = w.id and g.concepto = v.concepto and g.monto_usd = v.monto
                      and g.fecha = v.fecha::date and g.fuente is not distinct from v.fuente and g.activo);

-- Control: gastos por webinar y concepto (de a una; con el uuid de un fundador para la vista).
-- select w.nombre, g.concepto, g.monto_usd, g.fecha, g.fuente, g.en_opps
--   from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id where g.activo order by w.fecha, g.concepto;
-- select nombre, cash_usd, gastos_usd, ads_usd, ganancia_usd, roas from public.fin_v_webinar_resultado order by fecha;
