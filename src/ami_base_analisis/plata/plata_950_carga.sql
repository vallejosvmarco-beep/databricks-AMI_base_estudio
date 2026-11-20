-- =============================================================
-- PLATA 950 - curva validada de 15 min por NISE, salida final del bundle AMI_base
-- Base para las curvas caracteristicas (metodologia CNFL 2025):
--   * Calidad DIARIA por NISE/OPERACION (plata_950_dias): solo dias con >= 90 valores
--     validos; los faltantes (<= 6) se imputan con el promedio del NISE/OPERACION en
--     la misma hora y mes (ES_IMPUTADO = 1, MOTIVO_IMPUTACION); si ese mes no tiene
--     datos validos en esa hora, se usa el promedio de esa hora en toda la ventana.
--   * FLAG_PICO_3SIGMA = 1 marca lecturas reales por encima de media + 3 sigma del
--     NISE/OPERACION; se conservan (no se imputan).
--   * Fuente por NISE/OPERACION (no por NISE completo): 'diferencias' = solo lecturas
--     que cuadran con el contador; 'completitud' = lecturas sin contador comparable.
--   * Una fila por NISE / OPERACION / FECHA (dia de la curva) / INTERVALO 1..96.
--     FECHA_LECTURA = fin del intervalo; la etiqueta de las 00:00 es el intervalo 96
--     del dia anterior.
--   * TEMPORADA: verano (ene-abr), invierno (may-sep), fuera_estudio (oct-dic).
--     TIPO_DIA: laboral / fin_de_semana.
--   * Atributos del maestro de clientes (tarifa, sector, GD, estado, red) y marcas:
--     sin cliente, GD inconsistente, constante distinta, servicio no activo, canales
--     duplicados del perfil, sin medidor de red, canal duplicado del SGD.
-- Solo energia activa: Consumo_Activo, Inyeccion_Activo, Generacion_SGD_Activa,
-- Demanda_SGD_Activa. PLAN = TMT/TMTB segun las listas oficiales; NULL para el resto.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_analisis}.plata_950_carga
AS
WITH dias_validos AS (
  SELECT
    NISE,
    OPERACION,
    FECHA_CURVA,
    MEDIDOR AS MEDIDOR_DIA,
    FUENTE_CALIDAD,
    VALORES_VALIDOS,
    FLAG_LP_CANALES_DUPLICADOS
  FROM ${project.catalog}.${project.schema_analisis}.plata_950_dias
  WHERE DIA_VALIDO = 1
),
grilla AS (
  SELECT d.*, g.INTERVALO
  FROM dias_validos d
  LATERAL VIEW EXPLODE(SEQUENCE(1, 96)) g AS INTERVALO
),
lecturas AS (
  SELECT
    NISE,
    OPERACION,
    FECHA_CURVA,
    INTERVALO,
    MEDIDOR,
    ENERGIA,
    VALIDADA_CONTADOR,
    FLAG_PICO_3SIGMA,
    VALIDADA_CONTADOR AS ES_VALIDA
  FROM lecturas_950
),
promedio_horario AS (
  SELECT
    NISE,
    OPERACION,
    YEAR(FECHA_CURVA) AS PERIODO,
    MONTH(FECHA_CURVA) AS MES,
    CAST(FLOOR((INTERVALO - 1) / 4) AS INT) AS HORA,
    AVG(ENERGIA) AS ENERGIA_PROMEDIO_HORA
  FROM lecturas
  WHERE ES_VALIDA = 1
  GROUP BY NISE, OPERACION, YEAR(FECHA_CURVA), MONTH(FECHA_CURVA), CAST(FLOOR((INTERVALO - 1) / 4) AS INT)
),
promedio_horario_ventana AS (
  SELECT
    NISE,
    OPERACION,
    CAST(FLOOR((INTERVALO - 1) / 4) AS INT) AS HORA,
    AVG(ENERGIA) AS ENERGIA_PROMEDIO_HORA_VENTANA
  FROM lecturas
  WHERE ES_VALIDA = 1
  GROUP BY NISE, OPERACION, CAST(FLOOR((INTERVALO - 1) / 4) AS INT)
),
curva AS (
  SELECT
    g.NISE,
    g.OPERACION,
    g.FECHA_CURVA,
    g.INTERVALO,
    CAST(FLOOR((g.INTERVALO - 1) / 4) AS INT) AS HORA,
    COALESCE(l.MEDIDOR, g.MEDIDOR_DIA) AS MEDIDOR,
    g.FUENTE_CALIDAD,
    g.VALORES_VALIDOS AS VALORES_VALIDOS_DIA,
    g.FLAG_LP_CANALES_DUPLICADOS,
    CASE
      WHEN l.ES_VALIDA = 1 THEN l.ENERGIA
      ELSE COALESCE(ph.ENERGIA_PROMEDIO_HORA, pv.ENERGIA_PROMEDIO_HORA_VENTANA)
    END AS ENERGIA,
    CASE WHEN l.ES_VALIDA = 1 THEN 0 ELSE 1 END AS ES_IMPUTADO,
    CASE
      WHEN l.ES_VALIDA = 1 THEN NULL
      WHEN l.NISE IS NULL THEN 'faltante'
      ELSE 'no_validada_contador'
    END AS MOTIVO_IMPUTACION,
    CASE WHEN l.ES_VALIDA = 1 THEN l.FLAG_PICO_3SIGMA ELSE 0 END AS FLAG_PICO_3SIGMA
  FROM grilla g
  LEFT JOIN lecturas l
    ON g.NISE = l.NISE
   AND g.OPERACION = l.OPERACION
   AND g.FECHA_CURVA = l.FECHA_CURVA
   AND g.INTERVALO = l.INTERVALO
  LEFT JOIN promedio_horario ph
    ON g.NISE = ph.NISE
   AND g.OPERACION = ph.OPERACION
   AND YEAR(g.FECHA_CURVA) = ph.PERIODO
   AND MONTH(g.FECHA_CURVA) = ph.MES
   AND CAST(FLOOR((g.INTERVALO - 1) / 4) AS INT) = ph.HORA
  LEFT JOIN promedio_horario_ventana pv
    ON g.NISE = pv.NISE
   AND g.OPERACION = pv.OPERACION
   AND CAST(FLOOR((g.INTERVALO - 1) / 4) AS INT) = pv.HORA
),
nis_ami AS (
  SELECT
    NISE,
    MAX(CASE WHEN SGDA_NORMALIZADO = 'Generacion' THEN 1 ELSE 0 END) AS TIENE_MEDIDOR_GENERACION,
    MAX(CASE WHEN SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') THEN CONSTANTE END) AS CONSTANTE_AMI
  FROM lecturas_950
  GROUP BY NISE
),
clientes AS (
  SELECT
    CAST(NISE AS STRING) AS NISE,
    TARIFA,
    SECTOR,
    DESC_SECTOR,
    TIENE_GD,
    ESTADO_SERVICIO,
    CIRCUITO,
    TRANSFORMADOR,
    CAST(CONSTANTE AS DOUBLE) AS CONSTANTE_CLIENTE
  FROM ${project.catalog}.${project.schema_plata}.${project.tabla_clientes}
),
atributos AS (
  SELECT
    a.NISE,
    c.TARIFA,
    c.SECTOR,
    c.DESC_SECTOR,
    c.TIENE_GD,
    a.TIENE_MEDIDOR_GENERACION,
    c.ESTADO_SERVICIO,
    c.CIRCUITO,
    c.TRANSFORMADOR,
    CASE WHEN c.NISE IS NULL THEN 1 ELSE 0 END AS FLAG_SIN_CLIENTE,
    CASE
      WHEN c.TIENE_GD = TRUE AND a.TIENE_MEDIDOR_GENERACION = 0 THEN 1
      WHEN c.TIENE_GD = FALSE AND a.TIENE_MEDIDOR_GENERACION = 1 THEN 1
      ELSE 0
    END AS FLAG_GD_INCONSISTENTE,
    CASE
      WHEN c.CONSTANTE_CLIENTE IS NOT NULL AND a.CONSTANTE_AMI IS NOT NULL
       AND c.CONSTANTE_CLIENTE <> a.CONSTANTE_AMI THEN 1
      ELSE 0
    END AS FLAG_CONSTANTE_DISTINTA,
    CASE
      WHEN c.NISE IS NOT NULL AND COALESCE(c.ESTADO_SERVICIO, '') <> 'Activo' THEN 1
      ELSE 0
    END AS FLAG_SERVICIO_NO_ACTIVO
  FROM nis_ami a
  LEFT JOIN clientes c
    ON a.NISE = c.NISE
),
alertas_sgd AS (
  SELECT NISE, PERIODO, MES, FLAG_SIN_MEDIDOR_RED, FLAG_CANAL_DUPLICADO
  FROM ${project.catalog}.${project.schema_plata}.plata_alertas_medidores
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
  cu.NISE,
  p.PLAN,
  cu.OPERACION,
  cu.MEDIDOR,
  TIMESTAMPADD(MINUTE, cu.INTERVALO * 15, CAST(cu.FECHA_CURVA AS TIMESTAMP)) AS FECHA_LECTURA,
  cu.FECHA_CURVA AS FECHA,
  cu.INTERVALO,
  cu.HORA,
  CASE
    WHEN MONTH(cu.FECHA_CURVA) BETWEEN 1 AND 4 THEN 'verano'
    WHEN MONTH(cu.FECHA_CURVA) BETWEEN 5 AND 9 THEN 'invierno'
    ELSE 'fuera_estudio'
  END AS TEMPORADA,
  CASE WHEN DAYOFWEEK(cu.FECHA_CURVA) IN (1, 7) THEN 'fin_de_semana' ELSE 'laboral' END AS TIPO_DIA,
  ROUND(cu.ENERGIA, 3) AS ENERGIA,
  ROUND(cu.ENERGIA * 4, 3) AS DEMANDA,
  cu.ES_IMPUTADO,
  cu.MOTIVO_IMPUTACION,
  cu.FLAG_PICO_3SIGMA,
  cu.FUENTE_CALIDAD,
  cu.VALORES_VALIDOS_DIA,
  atr.TARIFA,
  atr.SECTOR,
  atr.DESC_SECTOR,
  atr.TIENE_GD,
  atr.TIENE_MEDIDOR_GENERACION,
  atr.ESTADO_SERVICIO,
  atr.CIRCUITO,
  atr.TRANSFORMADOR,
  atr.FLAG_SIN_CLIENTE,
  atr.FLAG_GD_INCONSISTENTE,
  atr.FLAG_CONSTANTE_DISTINTA,
  atr.FLAG_SERVICIO_NO_ACTIVO,
  cu.FLAG_LP_CANALES_DUPLICADOS,
  COALESCE(s.FLAG_SIN_MEDIDOR_RED, 0) AS FLAG_SIN_MEDIDOR_RED,
  COALESCE(s.FLAG_CANAL_DUPLICADO, 0) AS FLAG_CANAL_DUPLICADO
FROM curva cu
LEFT JOIN atributos atr
  ON cu.NISE = atr.NISE
LEFT JOIN alertas_sgd s
  ON cu.NISE = s.NISE
 AND YEAR(cu.FECHA_CURVA) = s.PERIODO
 AND MONTH(cu.FECHA_CURVA) = s.MES
LEFT JOIN plan_unico p
  ON cu.NISE = p.NISE;
