-- =============================================================
-- PLATA CONSUMO
-- Materialized view: refleja solo la ventana de meses del bronce `consumo`
-- (ami_meses_historial). Una fila por (NISE, FECHA_LECTURA_REAL, OPERACION),
-- (NISE, FECHA_LECTURA_REAL, OPERACION) es la llave unica.
-- Incluye toda la masa de clientes (sin filtro TMT/TMTB; ese filtro es
-- exclusivo del analisis de margenes de comercializacion, aguas abajo).
-- NISE = LOCALIZACION (filas sin LOCALIZACION se excluyen; misma regla que plata_carga).
-- SGDA se normaliza igual que en plata_carga (mayusculas/espacios, TOTA_SUMA, vacio = Consumo).
-- Tension_Fase_* solo con TIPO_CONSUMO = 'Voltage' (Current, kVA, kW y angulos vienen
-- tambien con UNIDAD = 'Voltage' y se descartan).
-- Incluye ademas el mes anterior a la ventana (mes de contexto del bronce consumo) para
-- que plata_carga_diferencias tenga la lectura previa del contador.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_plata}.plata_consumo AS
WITH base AS (
  SELECT
    c.*,
    CASE
      WHEN c.SGDA IS NULL OR TRIM(c.SGDA) = '' THEN 'Consumo'
      WHEN UPPER(TRIM(c.SGDA)) IN ('BIDIRECCIONAL', 'BIDIRRECIONAL') THEN 'Bidireccional'
      WHEN UPPER(TRIM(c.SGDA)) = 'GENERACION' THEN 'Generacion'
      WHEN UPPER(TRIM(c.SGDA)) IN ('TOTALIZACION', 'TOTA SUMA', 'TOTA_SUMA') THEN 'Totalizacion'
      ELSE 'Proyecto'
    END AS SGDA_NORM
  FROM consumo c
  WHERE c.LOCALIZACION IS NOT NULL
),
transformada AS (
SELECT
  CAST(c.LOCALIZACION AS STRING) AS NISE,
  CAST(c.MEDIDOR AS STRING) AS MEDIDOR,
  CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA_REAL,
  c.SGDA_NORM AS SGDA_NORMALIZADO,
  c.SGDA AS SGDA_ORIGINAL,
  CASE
    WHEN c.TIPO_CONSUMO = 'ENE Delivered' AND c.UNIDAD = 'kWh' THEN
      CASE c.SGDA_NORM
        WHEN 'Bidireccional' THEN 'Consumo_Activo_kWh'
        WHEN 'Generacion' THEN 'Generacion_SGDA_Activo_kWh'
        WHEN 'Totalizacion' THEN 'Totalizacion_Activo_kWh'
        WHEN 'Proyecto' THEN 'Proyecto_Activo_kWh'
        ELSE 'Consumo_Activo_kWh'
      END
    WHEN c.TIPO_CONSUMO = 'ENE Received' AND c.UNIDAD = 'kWh' THEN 'Inyeccion_Activo_kWh'
    WHEN c.TIPO_CONSUMO = 'ENE Sum' AND c.UNIDAD = 'kWh' THEN 'Totalizacion_Activo_kWh'
    WHEN c.TIPO_CONSUMO = 'FPO' AND c.UNIDAD = 'kVAR' THEN 'Consumo_Reactivo_kVARh'
    WHEN c.TIPO_CONSUMO = 'MDE Delivered' AND c.UNIDAD = 'kW' THEN 'Demanda_Delivered_kW'
    WHEN c.TIPO_CONSUMO = 'MDE Received' AND c.UNIDAD = 'kW' THEN 'Demanda_Received_kW'
    WHEN c.TIPO_CONSUMO = 'MDE Sum' AND c.UNIDAD = 'kW' THEN 'Demanda_Sum_kW'
    WHEN c.TIPO_CONSUMO = 'Voltage' AND c.UNIDAD = 'Voltage' THEN
      CASE
        WHEN c.CONTADOR = 'A' THEN 'Tension_Fase_A'
        WHEN c.CONTADOR = 'B' THEN 'Tension_Fase_B'
        WHEN c.CONTADOR = 'C' THEN 'Tension_Fase_C'
        ELSE 'Tension_Otros'
      END
    ELSE 'Otros'
  END AS OPERACION,
  CASE WHEN c.UNIDAD = 'kVAR' THEN 'kVARh' ELSE c.UNIDAD END AS UNIDAD,
  CAST(c.VALOR_LECTURA AS DOUBLE) AS VALOR_LECTURA,
  CASE
    WHEN COALESCE(CAST(c.MULTIPLICADOR AS DOUBLE), 0.0) = 0.0 THEN 1.0
    ELSE CAST(c.MULTIPLICADOR AS DOUBLE)
  END AS CONSTANTE,
  CAST(c.VALOR_LECTURA AS DOUBLE) *
    CASE
      WHEN COALESCE(CAST(c.MULTIPLICADOR AS DOUBLE), 0.0) = 0.0 THEN 1.0
      ELSE CAST(c.MULTIPLICADOR AS DOUBLE)
    END AS ENERGIA,
  c.LOCALIZACION_REAL AS LOCALIZACION_FISICA
FROM base c
WHERE c.UNIDAD IN ('kWh', 'kVAR', 'kW', 'Voltage')
  AND c.VALOR_LECTURA IS NOT NULL
  AND (
    c.CONTADOR IN ('Total')
    OR (c.TIPO_CONSUMO = 'Voltage' AND c.UNIDAD = 'Voltage' AND c.CONTADOR IN ('A', 'B', 'C'))
  )
)
-- La deduplicacion se aplica sobre las columnas ya transformadas (OPERACION mapeada),
-- no sobre la columna OPERACION cruda de la fuente.
SELECT *
FROM transformada
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY NISE, FECHA_LECTURA_REAL, OPERACION
  ORDER BY MEDIDOR, SGDA_ORIGINAL, VALOR_LECTURA DESC
) = 1;
