-- =============================================================
-- PLATA 950 - calidad DIARIA por NISE / OPERACION / FECHA_CURVA
-- Metodologia CNFL 2025: un dia es valido si tiene >= 90 valores validos de 96.
-- Valor valido = presente y validado por el contador (si la fuente es 'diferencias').
-- Los picos 3-sigma solo se cuentan (VALORES_PICO_3SIGMA); no invalidan el valor. Los faltantes de un dia valido (<= 6) se imputan en plata_950_carga.
-- Incluye tambien los dias NO validos (para reportes); los dias sin ninguna lectura no
-- aparecen (ver plata_950_resumen).
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_analisis}.plata_950_dias
AS
SELECT
  NISE,
  OPERACION,
  FECHA_CURVA,
  YEAR(FECHA_CURVA) AS PERIODO,
  MONTH(FECHA_CURVA) AS MES,
  MAX(FUENTE_CALIDAD) AS FUENTE_CALIDAD,
  MAX(PCT_LECTURAS_DIF_OK) AS PCT_LECTURAS_DIF_OK,
  MAX_BY(MEDIDOR, FECHA_LECTURA) AS MEDIDOR,
  COUNT(DISTINCT MEDIDOR) AS MEDIDORES_DIA,
  CAST(COUNT(*) AS INT) AS VALORES_PRESENTES,
  CAST(SUM(CASE WHEN VALIDADA_CONTADOR = 0 THEN 1 ELSE 0 END) AS INT) AS VALORES_NO_VALIDADOS_CONTADOR,
  CAST(SUM(FLAG_PICO_3SIGMA) AS INT) AS VALORES_PICO_3SIGMA,
  CAST(SUM(VALIDADA_CONTADOR) AS INT) AS VALORES_VALIDOS,
  CAST(96 - SUM(VALIDADA_CONTADOR) AS INT) AS VALORES_A_IMPUTAR,
  MAX(FLAG_LP_CANALES_DUPLICADOS) AS FLAG_LP_CANALES_DUPLICADOS,
  CASE
    WHEN SUM(VALIDADA_CONTADOR) >= 90 THEN 1
    ELSE 0
  END AS DIA_VALIDO
FROM lecturas_950
GROUP BY NISE, OPERACION, FECHA_CURVA;
