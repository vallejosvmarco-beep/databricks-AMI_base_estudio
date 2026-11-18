-- =============================================================
-- PLATA 950 - plata validada, salida final del bundle AMI_base
-- Prioridad global: diferencias (|dif| <= 5%) sobre completitud (>=95%).
-- Diferencias solo se elige para un par NISE/OPERACION si al menos el 95%
-- de sus lecturas cumple |dif| <= 5%; si no, se usa completitud.
-- El resultado contiene toda la masa de clientes de la ventana (ventana_analisis).
-- PLAN = TMT/TMTB segun las listas oficiales; NULL para el resto de clientes
-- (el analisis de margenes filtra PLAN IS NOT NULL).
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_analisis}.plata_950_carga
AS
WITH dif_pares_ok AS (
  SELECT NISE, OPERACION
  FROM ${project.catalog}.${project.schema_analisis}.plata_carga_diferencias
  GROUP BY NISE, OPERACION
  HAVING AVG(CASE WHEN ABS(PORCENTAJE_DIFERENCIA) <= 5 THEN 1.0 ELSE 0.0 END) >= 0.95
),
dif_ok AS (
  SELECT d.*
  FROM ${project.catalog}.${project.schema_analisis}.plata_carga_diferencias d
  INNER JOIN dif_pares_ok p
    ON d.NISE = p.NISE
   AND d.OPERACION = p.OPERACION
  WHERE ABS(d.PORCENTAJE_DIFERENCIA) <= 5
),
comp_ok AS (
  SELECT *
  FROM ${project.catalog}.${project.schema_analisis}.plata_carga_completitud
  WHERE FLAG_COMPLETITUD_GENERAL_95 = 1
),
fuente_seleccionada AS (
  SELECT DISTINCT
    COALESCE(d.NISE, c.NISE) AS NISE,
    COALESCE(d.OPERACION, c.OPERACION) AS OPERACION,
    CASE WHEN d.NISE IS NOT NULL THEN 'diferencias' ELSE 'completitud' END AS fuente_elegida
  FROM (SELECT DISTINCT NISE, OPERACION FROM dif_ok) d
  FULL OUTER JOIN (SELECT DISTINCT NISE, OPERACION FROM comp_ok) c
    ON d.NISE = c.NISE AND d.OPERACION = c.OPERACION
),
total_ops AS (
  SELECT
    CAST(NISE AS STRING) AS NISE,
    COUNT(DISTINCT OPERACION) AS total_ops
  FROM ${project.catalog}.${project.schema_plata}.plata_carga
  WHERE OPERACION IN (
    'Consumo_Activo_kWh',
    'Inyeccion_Activo_kWh',
    'Consumo_Reactivo_kVARh'
  )
    AND CAST(FECHA_LECTURA_REAL AS TIMESTAMP) >= (SELECT CAST(FECHA_INICIO AS TIMESTAMP) FROM ventana_analisis)
    AND CAST(FECHA_LECTURA_REAL AS TIMESTAMP) < (SELECT CAST(DATE_ADD(FECHA_FIN, 1) AS TIMESTAMP) FROM ventana_analisis)
  GROUP BY CAST(NISE AS STRING)
),
-- ops_calidad AS (
--   SELECT NISE, COUNT(DISTINCT OPERACION) AS ops_calidad
--   FROM fuente_seleccionada
--   GROUP BY NISE
-- ),
ops_calidad AS (
  -- Solo las mismas operaciones base que total_ops; las adicionales
  -- (Generacion_SGDA_*) no excluyen al NIS y siguen en la salida si cumplen calidad.
  SELECT CAST(NISE AS STRING) AS NISE, COUNT(DISTINCT OPERACION) AS ops_calidad
  FROM fuente_seleccionada
  WHERE OPERACION IN (
    'Consumo_Activo_kWh',
    'Inyeccion_Activo_kWh',
    'Consumo_Reactivo_kVARh'
  )
  GROUP BY CAST(NISE AS STRING)
),
nises_completos AS (
  SELECT t.NISE
  FROM total_ops t
  INNER JOIN ops_calidad o ON t.NISE = o.NISE
  WHERE t.total_ops = o.ops_calidad
),
plan_ref AS (
  SELECT CAST(nis AS STRING) AS NISE, 'TMT' AS PLAN
  FROM ${project.catalog}.${project.schema_bronce}.tmt
  UNION ALL
  SELECT CAST(nis AS STRING) AS NISE, 'TMTB' AS PLAN
  FROM ${project.catalog}.${project.schema_bronce}.tmtb
),
plan_unico AS (
  SELECT NISE, MAX(PLAN) AS PLAN
  FROM plan_ref
  GROUP BY NISE
)
SELECT
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.NISE ELSE c.NISE END AS NISE,
  p.PLAN,
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.OPERACION ELSE c.OPERACION END AS OPERACION,
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.FECHA_LECTURA ELSE c.FECHA_LECTURA END AS FECHA_LECTURA,
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.FECHA ELSE c.FECHA END AS FECHA,
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.ENERGIA ELSE c.ENERGIA END AS ENERGIA,
  CASE WHEN fs.fuente_elegida = 'diferencias' THEN d.DEMANDA ELSE c.DEMANDA END AS DEMANDA,
  fs.fuente_elegida AS FUENTE_CALIDAD
FROM fuente_seleccionada fs
INNER JOIN nises_completos nc
  ON fs.NISE = nc.NISE
LEFT JOIN dif_ok d
  ON fs.NISE = d.NISE
 AND fs.OPERACION = d.OPERACION
 AND fs.fuente_elegida = 'diferencias'
LEFT JOIN comp_ok c
  ON fs.NISE = c.NISE
 AND fs.OPERACION = c.OPERACION
 AND fs.fuente_elegida = 'completitud'
LEFT JOIN plan_unico p
  ON fs.NISE = p.NISE
WHERE CASE
        WHEN fs.fuente_elegida = 'diferencias' THEN d.FECHA_LECTURA
        ELSE c.FECHA_LECTURA
      END IS NOT NULL
  AND CASE
        WHEN fs.fuente_elegida = 'diferencias' THEN d.FECHA
        ELSE c.FECHA
      END >= (SELECT FECHA_INICIO FROM ventana_analisis)
  AND CASE
        WHEN fs.fuente_elegida = 'diferencias' THEN d.FECHA
        ELSE c.FECHA
      END <= (SELECT FECHA_FIN FROM ventana_analisis);
