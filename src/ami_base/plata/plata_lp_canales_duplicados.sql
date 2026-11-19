-- =============================================================
-- PLATA - PERFIL DE CARGA CON CANALES DUPLICADOS (por medidor y mes)
-- Detecta medidores cuyo perfil de carga (bronce `carga`, 15 min) trae pocos
-- intervalos y el canal Received casi igual a Delivered. Caso tipico: lote de
-- medidores REXU-EA con ~32% de los intervalos, donde el contador (bronce
-- consumo) muestra Received ~0: el Received (y el kVARh) del perfil no es real.
--
-- FLAG_LP_CANALES_DUPLICADOS = 1 si en el mes:
--   intervalos < 45% de los esperados (dias del mes x 96)
--   y KWH_DELIVERED > 10
--   y KWH_RECEIVED / KWH_DELIVERED entre 0.8 y 1.25
-- plata_carga descarta Received y kVARh de los medidores marcados ese mes y
-- conserva Delivered kWh (magnitud consistente con el contador).
-- Mismos filtros de entrada que plata_carga (LOCALIZACION, INTERVALO = 15, sin 'Sum').
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_plata}.plata_lp_canales_duplicados
AS
WITH base AS (
  SELECT
    CAST(c.MEDIDOR AS STRING) AS MEDIDOR,
    CAST(c.LOCALIZACION AS STRING) AS NISE,
    c.TIPO_MEDIDOR,
    YEAR(c.FECHA_LECTURA_REAL) AS PERIODO,
    MONTH(c.FECHA_LECTURA_REAL) AS MES,
    CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA_REAL,
    c.OPERACION,
    c.UNIDAD,
    CAST(c.VALOR_LECTURA AS DOUBLE) * COALESCE(CAST(c.CONSTANTE AS DOUBLE), 1.0) AS ENERGIA
  FROM carga c
  WHERE c.FECHA_LECTURA_REAL IS NOT NULL
    AND c.LOCALIZACION IS NOT NULL
    AND CAST(c.INTERVALO AS INT) = 15
    AND c.OPERACION != 'Sum'
),
metricas AS (
  SELECT
    MEDIDOR,
    PERIODO,
    MES,
    ARRAY_SORT(COLLECT_SET(NISE)) AS NISES,
    ARRAY_SORT(COLLECT_SET(TIPO_MEDIDOR)) AS TIPOS_MEDIDOR,
    COUNT(DISTINCT FECHA_LECTURA_REAL) AS INTERVALOS,
    CAST(DAY(LAST_DAY(MAKE_DATE(PERIODO, MES, 1))) * 96 AS BIGINT) AS INTERVALOS_ESPERADOS,
    SUM(CASE WHEN OPERACION = 'Delivered' AND UNIDAD = 'kWh' THEN ENERGIA END) AS KWH_DELIVERED,
    SUM(CASE WHEN OPERACION = 'Received' AND UNIDAD = 'kWh' THEN ENERGIA END) AS KWH_RECEIVED
  FROM base
  GROUP BY MEDIDOR, PERIODO, MES
)
SELECT
  MEDIDOR,
  PERIODO,
  MES,
  NISES,
  TIPOS_MEDIDOR,
  INTERVALOS,
  INTERVALOS_ESPERADOS,
  ROUND(100.0 * INTERVALOS / INTERVALOS_ESPERADOS, 2) AS PCT_COBERTURA,
  ROUND(KWH_DELIVERED, 3) AS KWH_DELIVERED,
  ROUND(KWH_RECEIVED, 3) AS KWH_RECEIVED,
  ROUND(TRY_DIVIDE(KWH_RECEIVED, KWH_DELIVERED), 4) AS RATIO_RECEIVED_SOBRE_DELIVERED,
  CASE
    WHEN INTERVALOS < 0.45 * INTERVALOS_ESPERADOS
     AND KWH_DELIVERED > 10
     AND TRY_DIVIDE(KWH_RECEIVED, KWH_DELIVERED) BETWEEN 0.8 AND 1.25 THEN 1
    ELSE 0
  END AS FLAG_LP_CANALES_DUPLICADOS
FROM metricas;
