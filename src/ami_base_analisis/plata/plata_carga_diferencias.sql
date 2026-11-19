-- =============================================================
-- PLATA ANALISIS - diferencias carga vs contador
-- Batch/no streaming. Resultado limitado a la ventana (ventana_analisis).
-- Conserva una lectura de consumo previa al periodo para calcular correctamente
-- el primer LAG del mes.
--
-- Calidad por MEDIDOR, salida por NISE:
--   * Los lapsos del contador se arman por (NISE, MEDIDOR, OPERACION): un cambio de
--     medidor no genera un lapso falso entre el contador viejo y el nuevo.
--   * La curva se une al lapso del mismo medidor. plata_carga ya es unica por
--     (NISE, FECHA_LECTURA_REAL, OPERACION), asi que cada lectura de la curva sale
--     una sola vez (con el MEDIDOR que la origino).
-- Bordes: la curva se etiqueta al FINAL del intervalo (la lectura de las 12:00 cubre
--   11:45-12:00). Un lapso del contador (INI, FIN] usa las etiquetas desde la primera
--   posterior a INI hasta la ultima <= FIN. Lapsos consecutivos no comparten lecturas.
-- Unidades: el contador de consumo viene en unidades secundarias (MULTIPLICADOR 1/0)
--   aunque la curva tenga CONSTANTE > 1. La energia del contador se lleva a primarias
--   con la CONSTANTE de la curva del mismo medidor (o con el multiplicador del contador
--   si este es > 1).
-- Solo operaciones de energia que existen en las dos fuentes.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_analisis}.plata_carga_diferencias
AS
WITH consumo_energia AS (
  SELECT
    CAST(NISE AS STRING) AS NISE,
    CAST(MEDIDOR AS STRING) AS MEDIDOR,
    CAST(OPERACION AS STRING) AS OPERACION,
    CAST(FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA_REAL,
    CAST(VALOR_LECTURA AS DOUBLE) AS VALOR_LECTURA,
    CAST(CONSTANTE AS DOUBLE) AS CONSTANTE_CONTADOR
  FROM ${project.catalog}.${project.schema_plata}.plata_consumo
  WHERE NISE IS NOT NULL
    AND MEDIDOR IS NOT NULL
    AND FECHA_LECTURA_REAL IS NOT NULL
    AND VALOR_LECTURA IS NOT NULL
    AND OPERACION IN (
      'Consumo_Activo_kWh',
      'Inyeccion_Activo_kWh',
      'Generacion_SGD_Activa_kWh',
      'Demanda_SGD_Activa_kWh'
    )
),
consumo_previo AS (
  SELECT NISE, MEDIDOR, OPERACION, FECHA_LECTURA_REAL, VALOR_LECTURA, CONSTANTE_CONTADOR
  FROM consumo_energia
  WHERE FECHA_LECTURA_REAL < (SELECT CAST(FECHA_INICIO AS TIMESTAMP) FROM ventana_analisis)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY NISE, MEDIDOR, OPERACION
    ORDER BY FECHA_LECTURA_REAL DESC
  ) = 1
),
consumo_periodo AS (
  SELECT NISE, MEDIDOR, OPERACION, FECHA_LECTURA_REAL, VALOR_LECTURA, CONSTANTE_CONTADOR
  FROM consumo_energia
  WHERE FECHA_LECTURA_REAL >= (SELECT CAST(FECHA_INICIO AS TIMESTAMP) FROM ventana_analisis)
    AND FECHA_LECTURA_REAL < (SELECT CAST(DATE_ADD(FECHA_FIN, 1) AS TIMESTAMP) FROM ventana_analisis)
),
consumo_contexto AS (
  SELECT * FROM consumo_previo
  UNION ALL
  SELECT * FROM consumo_periodo
),
consumo_lag AS (
  SELECT
    NISE,
    MEDIDOR,
    OPERACION,
    LAG(FECHA_LECTURA_REAL) OVER (
      PARTITION BY NISE, MEDIDOR, OPERACION ORDER BY FECHA_LECTURA_REAL
    ) AS INI_ORIG,
    FECHA_LECTURA_REAL AS FIN_ORIG,
    VALOR_LECTURA - LAG(VALOR_LECTURA) OVER (
      PARTITION BY NISE, MEDIDOR, OPERACION ORDER BY FECHA_LECTURA_REAL
    ) AS DELTA_CONTADOR,
    CONSTANTE_CONTADOR
  FROM consumo_contexto
),
intervalos AS (
  SELECT
    NISE,
    MEDIDOR,
    OPERACION,
    INI_ORIG,
    FIN_ORIG,
    DELTA_CONTADOR,
    CONSTANTE_CONTADOR,
    -- primera etiqueta posterior a INI (la lectura etiquetada en INI pertenece al lapso anterior)
    to_timestamp(FLOOR(unix_timestamp(INI_ORIG) / 900.0) * 900 + 900) AS INICIO_C,
    -- ultima etiqueta <= FIN
    to_timestamp(FLOOR(unix_timestamp(FIN_ORIG) / 900.0) * 900) AS FIN_C
  FROM consumo_lag
  WHERE INI_ORIG IS NOT NULL
    AND DELTA_CONTADOR IS NOT NULL
    AND FIN_ORIG >= (SELECT CAST(FECHA_INICIO AS TIMESTAMP) FROM ventana_analisis)
    AND FIN_ORIG < (SELECT CAST(DATE_ADD(FECHA_FIN, 1) AS TIMESTAMP) FROM ventana_analisis)
),
metricas AS (
  SELECT
    i.NISE,
    i.MEDIDOR,
    i.OPERACION,
    i.INI_ORIG,
    i.FIN_ORIG,
    i.INICIO_C,
    i.FIN_C,
    CAST(
      i.DELTA_CONTADOR * CASE
        WHEN i.CONSTANTE_CONTADOR > 1 THEN i.CONSTANTE_CONTADOR
        ELSE MAX(CAST(l.CONSTANTE AS DOUBLE))
      END AS DOUBLE
    ) AS ENERGIA_CONTADOR,
    COUNT(*) AS LECTURAS_PRESENTES,
    SUM(CAST(l.ENERGIA AS DOUBLE)) AS ENERGIA_LECTURAS,
    CAST(((unix_timestamp(i.FIN_C) - unix_timestamp(i.INICIO_C)) / 900) + 1 AS BIGINT) AS LECTURAS_ESPERADAS
  FROM intervalos i
  INNER JOIN ${project.catalog}.${project.schema_plata}.plata_carga l
    ON CAST(l.NISE AS STRING) = i.NISE
   AND CAST(l.MEDIDOR AS STRING) = i.MEDIDOR
   AND CAST(l.OPERACION AS STRING) = i.OPERACION
   AND CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) >= i.INICIO_C
   AND CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) <= i.FIN_C
  WHERE i.INICIO_C <= i.FIN_C
  GROUP BY
    i.NISE, i.MEDIDOR, i.OPERACION, i.INI_ORIG, i.FIN_ORIG,
    i.INICIO_C, i.FIN_C, i.DELTA_CONTADOR, i.CONSTANTE_CONTADOR
),
metricas_finales AS (
  SELECT
    *,
    CASE
      WHEN LECTURAS_ESPERADAS > 0
        THEN ((LECTURAS_ESPERADAS - LECTURAS_PRESENTES) / CAST(LECTURAS_ESPERADAS AS DOUBLE)) * 100.0
      ELSE 100.0
    END AS PORCENTAJE_FALTANTES,
    CASE
      WHEN COALESCE(ENERGIA_LECTURAS, 0.0) = 0.0
       AND COALESCE(ENERGIA_CONTADOR, 0.0) = 0.0 THEN 0.0
      ELSE (
        (COALESCE(ENERGIA_LECTURAS, 0.0) - COALESCE(ENERGIA_CONTADOR, 0.0)) /
        NULLIF(
          (COALESCE(ENERGIA_LECTURAS, 0.0) + COALESCE(ENERGIA_CONTADOR, 0.0)) / 2.0,
          0.0
        )
      ) * 100.0
    END AS PORCENTAJE_DIFERENCIA,
    concat(
      date_format(INI_ORIG, 'yyyy-MM-dd HH:mm:ss'), '_',
      NISE, '_', MEDIDOR, '_', OPERACION, '_',
      date_format(FIN_ORIG, 'yyyy-MM-dd HH:mm:ss')
    ) AS LAPSO
  FROM metricas
  WHERE LECTURAS_PRESENTES > 0
)
SELECT
  CAST(l.NISE AS STRING) AS NISE,
  CAST(l.MEDIDOR AS STRING) AS MEDIDOR,
  CAST(l.OPERACION AS STRING) AS OPERACION,
  CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA,
  CAST(l.FECHA_LECTURA_REAL AS DATE) AS FECHA,
  CAST(l.ENERGIA AS DOUBLE) AS ENERGIA,
  CAST(l.DEMANDA AS DOUBLE) AS DEMANDA,
  m.LAPSO,
  m.PORCENTAJE_DIFERENCIA,
  m.INI_ORIG AS INICIO_LAPSO,
  m.FIN_ORIG AS FIN_LAPSO,
  m.ENERGIA_CONTADOR,
  m.ENERGIA_LECTURAS,
  m.LECTURAS_ESPERADAS,
  m.LECTURAS_PRESENTES,
  m.PORCENTAJE_FALTANTES
FROM ${project.catalog}.${project.schema_plata}.plata_carga l
INNER JOIN metricas_finales m
  ON CAST(l.NISE AS STRING) = m.NISE
 AND CAST(l.MEDIDOR AS STRING) = m.MEDIDOR
 AND CAST(l.OPERACION AS STRING) = m.OPERACION
 AND CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) >= m.INICIO_C
 AND CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) <= m.FIN_C
WHERE CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) >= (SELECT CAST(FECHA_INICIO AS TIMESTAMP) FROM ventana_analisis)
  AND CAST(l.FECHA_LECTURA_REAL AS TIMESTAMP) < (SELECT CAST(DATE_ADD(FECHA_FIN, 1) AS TIMESTAMP) FROM ventana_analisis);
