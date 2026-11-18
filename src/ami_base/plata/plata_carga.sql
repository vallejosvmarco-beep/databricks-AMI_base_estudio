-- =============================================================
-- PLATA CARGA
-- Reglas de negocio (normalizacion SGDA, mapeo de OPERACION, energia y demanda)
-- expresadas con SQL nativo, sin funciones persistentes en el catalogo.
-- Materialized view: refleja solo la ventana de meses del bronce `carga`
-- (ami_meses_historial). Una fila por (NISE, FECHA_LECTURA_REAL, OPERACION),
-- (NISE, FECHA_LECTURA_REAL, OPERACION) es la llave unica.
-- Incluye toda la masa de clientes (sin filtro TMT/TMTB; ese filtro es
-- exclusivo del analisis de margenes de comercializacion, aguas abajo).
-- NISE = LOCALIZACION (filas sin LOCALIZACION se excluyen; misma regla que plata_consumo).
-- SGDA se normaliza igual que en plata_consumo (mayusculas/espacios, TOTA_SUMA, vacio = Consumo).
-- Solo lecturas de 15 minutos (INTERVALO = 15): completitud (96 lecturas/dia) y
-- diferencias (bloques de 900 s) asumen ese intervalo.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_plata}.plata_carga AS
WITH base AS (
  SELECT
    CAST(c.LOCALIZACION AS STRING) AS NISE,
    CAST(c.MEDIDOR AS STRING) AS MEDIDOR,
    CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA_REAL,
    c.SGDA AS SGDA_ORIGINAL,
    CASE
      WHEN c.SGDA IS NULL OR TRIM(c.SGDA) = '' THEN 'Consumo'
      WHEN UPPER(TRIM(c.SGDA)) IN ('BIDIRECCIONAL', 'BIDIRRECIONAL') THEN 'Bidireccional'
      WHEN UPPER(TRIM(c.SGDA)) = 'GENERACION' THEN 'Generacion'
      WHEN UPPER(TRIM(c.SGDA)) IN ('TOTALIZACION', 'TOTA SUMA', 'TOTA_SUMA') THEN 'Totalizacion'
      ELSE 'Proyecto'
    END AS SGDA_NORMALIZADO,
    c.OPERACION AS OPERACION_ORIGINAL,
    c.UNIDAD,
    CAST(c.VALOR_LECTURA AS DOUBLE) AS VALOR_LECTURA,
    COALESCE(CAST(c.CONSTANTE AS DOUBLE), 1.0) AS CONSTANTE,
    c.TIPO_MEDIDOR,
    CAST(c.INTERVALO AS INT) AS INTERVALO,
    c.LOCALIZACION_REAL AS LOCALIZACION_FISICA
  FROM carga c
  WHERE c.FECHA_LECTURA_REAL IS NOT NULL
    AND c.LOCALIZACION IS NOT NULL
    AND CAST(c.INTERVALO AS INT) = 15
    AND c.OPERACION != 'Sum'
),
transformada AS (
  SELECT
    *,
    CASE
      WHEN SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Consumo_Activo_kWh'
      WHEN SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Consumo_Reactivo_kVARh'
      WHEN SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') AND OPERACION_ORIGINAL = 'Received' AND UNIDAD = 'kWh' THEN 'Inyeccion_Activo_kWh'
      WHEN SGDA_NORMALIZADO IN ('Consumo', 'Bidireccional') AND OPERACION_ORIGINAL = 'Received' AND UNIDAD = 'kVARh' THEN 'Inyeccion_Reactivo_kVARh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Generacion_SGDA_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Generacion_SGDA_Reactivo_kVARh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Received' AND UNIDAD = 'kWh' THEN 'Autoconsumo_SGDA_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Totalizacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Totalizacion_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Totalizacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Totalizacion_Reactivo_kVARh'
      WHEN SGDA_NORMALIZADO = 'Proyecto' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Proyecto_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Proyecto' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Proyecto_Reactivo_kVARh'
      ELSE 'Otros'
    END AS OPERACION
  FROM base
)
SELECT
  NISE,
  MEDIDOR,
  FECHA_LECTURA_REAL,
  SGDA_ORIGINAL,
  SGDA_NORMALIZADO,
  OPERACION,
  UNIDAD,
  VALOR_LECTURA,
  CONSTANTE,
  TIPO_MEDIDOR,
  INTERVALO,
  ROUND(VALOR_LECTURA * CONSTANTE, 3) AS ENERGIA,
  CASE
    WHEN INTERVALO IS NULL OR INTERVALO = 0 THEN NULL
    ELSE ROUND(VALOR_LECTURA * CONSTANTE * (60.0 / INTERVALO), 3)
  END AS DEMANDA,
  LOCALIZACION_FISICA
FROM transformada
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY NISE, FECHA_LECTURA_REAL, OPERACION
  ORDER BY MEDIDOR, SGDA_ORIGINAL, UNIDAD
) = 1;
