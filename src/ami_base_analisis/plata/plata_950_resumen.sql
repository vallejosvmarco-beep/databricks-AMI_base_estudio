-- =============================================================
-- PLATA 950 - REPORTE mensual por NISE / OPERACION
-- Dias validos, invalidos y sin datos, valores imputados y picos 3-sigma.
-- FLAG_PICOS_EXCESIVOS = 1 si mas del 5% de los valores del mes son picos 3-sigma
-- (referencia del Load Profile Generator del ADMS: < 5% por 3-sigma). Los picos solo
-- se marcan; no se imputan ni invalidan dias.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_analisis}.plata_950_resumen
AS
WITH meses AS (
  SELECT
    YEAR(d) AS PERIODO,
    MONTH(d) AS MES,
    COUNT(*) AS DIAS_MES
  FROM (
    SELECT EXPLODE(SEQUENCE(FECHA_INICIO, FECHA_FIN, INTERVAL 1 DAY)) AS d
    FROM ventana_analisis
  )
  GROUP BY YEAR(d), MONTH(d)
)
SELECT
  d.NISE,
  d.OPERACION,
  d.PERIODO,
  d.MES,
  MAX(d.FUENTE_CALIDAD) AS FUENTE_CALIDAD,
  MAX(d.PCT_LECTURAS_DIF_OK) AS PCT_LECTURAS_DIF_OK,
  ARRAY_SORT(COLLECT_SET(d.MEDIDOR)) AS MEDIDORES,
  MAX(m.DIAS_MES) AS DIAS_MES,
  COUNT(*) AS DIAS_CON_DATOS,
  SUM(d.DIA_VALIDO) AS DIAS_VALIDOS,
  COUNT(*) - SUM(d.DIA_VALIDO) AS DIAS_INVALIDOS,
  MAX(m.DIAS_MES) - COUNT(*) AS DIAS_SIN_DATOS,
  SUM(CASE WHEN d.DIA_VALIDO = 1 THEN d.VALORES_A_IMPUTAR ELSE 0 END) AS VALORES_IMPUTADOS,
  SUM(d.VALORES_PRESENTES) AS VALORES_PRESENTES,
  SUM(d.VALORES_NO_VALIDADOS_CONTADOR) AS VALORES_NO_VALIDADOS_CONTADOR,
  SUM(d.VALORES_PICO_3SIGMA) AS VALORES_PICO_3SIGMA,
  ROUND(100.0 * SUM(d.VALORES_PICO_3SIGMA) / NULLIF(SUM(d.VALORES_PRESENTES), 0), 3) AS PCT_PICOS_3SIGMA,
  CASE
    WHEN SUM(d.VALORES_PICO_3SIGMA) > 0.05 * SUM(d.VALORES_PRESENTES) THEN 1 ELSE 0
  END AS FLAG_PICOS_EXCESIVOS,
  MAX(d.FLAG_LP_CANALES_DUPLICADOS) AS FLAG_LP_CANALES_DUPLICADOS
FROM ${project.catalog}.${project.schema_analisis}.plata_950_dias d
LEFT JOIN meses m
  ON d.PERIODO = m.PERIODO AND d.MES = m.MES
GROUP BY d.NISE, d.OPERACION, d.PERIODO, d.MES;
