-- =============================================================
-- PLATA ALERTAS DE MEDIDORES (clientes con SGD)
-- Una fila por NISE con medidor de generacion (SGDA Generacion) y mes (PERIODO, MES)
-- de plata_carga. Marca casos para analisis posterior; no filtra ni corrige datos.
--
-- FLAG_SIN_MEDIDOR_RED: el NIS tiene medidor de generacion pero ningun medidor de red
--   (SGDA Consumo/Bidireccional) ni en plata_carga ni en plata_consumo en ese mes.
-- FLAG_CANAL_DUPLICADO: el canal Demanda_SGD (Received del medidor de generacion)
--   repite la generacion: energia del mes entre 0.8 y 1.25 veces la generacion y menos
--   del 25% de esa energia de noche (19:00-04:59). La demanda real del SGD es pequena
--   y repartida en el dia. Tambien = 1 si el medidor de generacion esta marcado en
--   plata_lp_canales_duplicados ese mes (su Received ya se descarto de plata_carga).
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_plata}.plata_alertas_medidores
AS
WITH carga_mes AS (
  SELECT
    NISE,
    YEAR(FECHA_LECTURA_REAL) AS PERIODO,
    MONTH(FECHA_LECTURA_REAL) AS MES,
    HOUR(FECHA_LECTURA_REAL) AS HORA,
    MEDIDOR,
    SGDA_NORMALIZADO,
    OPERACION,
    ENERGIA
  FROM ${project.catalog}.${project.schema_plata}.plata_carga
),
nis_generacion AS (
  SELECT DISTINCT NISE, PERIODO, MES
  FROM carga_mes
  WHERE SGDA_NORMALIZADO = 'Generacion'
),
carga_nis AS (
  SELECT
    c.NISE,
    c.PERIODO,
    c.MES,
    ARRAY_SORT(COLLECT_SET(CASE WHEN c.SGDA_NORMALIZADO = 'Generacion' THEN c.MEDIDOR END)) AS MEDIDORES_GENERACION,
    ARRAY_SORT(COLLECT_SET(CASE WHEN c.SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') THEN c.MEDIDOR END)) AS MEDIDORES_RED_CARGA,
    SUM(CASE WHEN c.OPERACION = 'Generacion_SGD_Activa_kWh' THEN c.ENERGIA END) AS KWH_GENERACION_SGD,
    SUM(CASE WHEN c.OPERACION = 'Demanda_SGD_Activa_kWh' THEN c.ENERGIA END) AS KWH_DEMANDA_SGD,
    SUM(CASE WHEN c.OPERACION = 'Demanda_SGD_Activa_kWh' AND (c.HORA >= 19 OR c.HORA <= 4) THEN c.ENERGIA END) AS KWH_DEMANDA_SGD_NOCHE
  FROM carga_mes c
  INNER JOIN nis_generacion g
    ON c.NISE = g.NISE AND c.PERIODO = g.PERIODO AND c.MES = g.MES
  GROUP BY c.NISE, c.PERIODO, c.MES
),
red_consumo AS (
  SELECT
    k.NISE,
    YEAR(k.FECHA_LECTURA_REAL) AS PERIODO,
    MONTH(k.FECHA_LECTURA_REAL) AS MES,
    ARRAY_SORT(COLLECT_SET(k.MEDIDOR)) AS MEDIDORES_RED_CONSUMO
  FROM ${project.catalog}.${project.schema_plata}.plata_consumo k
  INNER JOIN nis_generacion g
    ON k.NISE = g.NISE
   AND YEAR(k.FECHA_LECTURA_REAL) = g.PERIODO
   AND MONTH(k.FECHA_LECTURA_REAL) = g.MES
  WHERE k.SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional')
  GROUP BY k.NISE, YEAR(k.FECHA_LECTURA_REAL), MONTH(k.FECHA_LECTURA_REAL)
),
lp_duplicado AS (
  SELECT DISTINCT g.NISE, g.PERIODO, g.MES
  FROM ${project.catalog}.${project.schema_plata}.plata_lp_canales_duplicados l
  INNER JOIN carga_nis g
    ON l.PERIODO = g.PERIODO
   AND l.MES = g.MES
   AND ARRAY_CONTAINS(g.MEDIDORES_GENERACION, l.MEDIDOR)
  WHERE l.FLAG_LP_CANALES_DUPLICADOS = 1
),
metricas AS (
  SELECT
    CASE WHEN l.NISE IS NOT NULL THEN 1 ELSE 0 END AS LP_GENERACION_DUPLICADO,
    c.NISE,
    c.PERIODO,
    c.MES,
    c.MEDIDORES_GENERACION,
    c.MEDIDORES_RED_CARGA,
    COALESCE(r.MEDIDORES_RED_CONSUMO, ARRAY()) AS MEDIDORES_RED_CONSUMO,
    ROUND(c.KWH_GENERACION_SGD, 3) AS KWH_GENERACION_SGD,
    ROUND(c.KWH_DEMANDA_SGD, 3) AS KWH_DEMANDA_SGD,
    ROUND(TRY_DIVIDE(c.KWH_DEMANDA_SGD, c.KWH_GENERACION_SGD), 4) AS RATIO_DEMANDA_SOBRE_GENERACION,
    ROUND(100.0 * TRY_DIVIDE(c.KWH_DEMANDA_SGD_NOCHE, c.KWH_DEMANDA_SGD), 2) AS PCT_DEMANDA_SGD_NOCHE
  FROM carga_nis c
  LEFT JOIN red_consumo r
    ON c.NISE = r.NISE AND c.PERIODO = r.PERIODO AND c.MES = r.MES
  LEFT JOIN lp_duplicado l
    ON c.NISE = l.NISE AND c.PERIODO = l.PERIODO AND c.MES = l.MES
)
SELECT
  * EXCEPT (LP_GENERACION_DUPLICADO),
  CASE
    WHEN SIZE(MEDIDORES_RED_CARGA) = 0 AND SIZE(MEDIDORES_RED_CONSUMO) = 0 THEN 1 ELSE 0
  END AS FLAG_SIN_MEDIDOR_RED,
  CASE
    WHEN LP_GENERACION_DUPLICADO = 1 THEN 1
    WHEN KWH_GENERACION_SGD > 0
     AND RATIO_DEMANDA_SOBRE_GENERACION BETWEEN 0.8 AND 1.25
     AND PCT_DEMANDA_SGD_NOCHE < 25 THEN 1 ELSE 0
  END AS FLAG_CANAL_DUPLICADO
FROM metricas;
