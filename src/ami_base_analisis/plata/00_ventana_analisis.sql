-- =============================================================
-- VENTANA DEL ANALISIS (plata_analisis / plata_950)
-- periodo_inicio / periodo_fin = "auto": se toma del bronce `carga`
-- (primer dia del primer mes .. ultimo dia del ultimo mes ingerido),
-- asi el analisis cubre exactamente la ventana de AMI_base.
-- Con fechas explicitas ("yyyy-MM-dd") se usan esas fechas.
-- Vista temporal del pipeline: no crea tabla en el catalogo.
-- =============================================================

CREATE TEMPORARY VIEW ventana_analisis AS
SELECT
  CASE
    WHEN LOWER('${project.periodo_inicio}') = 'auto' THEN MIN(MAKE_DATE(periodo, mes, 1))
    ELSE TRY_CAST('${project.periodo_inicio}' AS DATE)
  END AS FECHA_INICIO,
  CASE
    WHEN LOWER('${project.periodo_fin}') = 'auto' THEN LAST_DAY(MAX(MAKE_DATE(periodo, mes, 1)))
    ELSE TRY_CAST('${project.periodo_fin}' AS DATE)
  END AS FECHA_FIN
FROM (
  SELECT DISTINCT periodo, mes
  FROM ${project.catalog}.${project.schema_bronce}.carga
);
