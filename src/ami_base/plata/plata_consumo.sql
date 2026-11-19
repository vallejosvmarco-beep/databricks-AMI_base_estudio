-- =============================================================
-- PLATA CONSUMO
-- Materialized view: refleja solo la ventana de meses del bronce `consumo`
-- (ami_meses_historial). Una fila por (NISE, FECHA_LECTURA_REAL, OPERACION),
-- (NISE, FECHA_LECTURA_REAL, OPERACION) es la llave unica.
-- Incluye toda la masa de clientes (sin filtro TMT/TMTB; ese filtro es
-- exclusivo del analisis de margenes de comercializacion, aguas abajo).
-- NISE = LOCALIZACION (filas sin LOCALIZACION se excluyen; misma regla que plata_carga).
-- SGDA se normaliza igual que en plata_carga (mayusculas/espacios, TOTA_SUMA, vacio = Consumo).
-- NULL, vacio, el texto 'null' y codigos con formato de ciclo (ej. '3037_2') = Consumo.
-- Proyecto solo si no hay LOCALIZACION (plantas; se excluyen aguas abajo).
-- Cualquier otro valor = 'Desconocido' (OPERACION 'Otros'), para detectarlo y revisarlo.
-- Se ignoran tildes (Generación = Generacion).
-- Rol del medidor (misma regla que plata_carga):
--   Medidor de red (SGDA Consumo/Bidireccional): ENE Delivered = Consumo_Activo_kWh,
--     ENE Received = Inyeccion_Activo_kWh, MDE = Demanda_*_kW, Voltage = Tension_Fase_*.
--   Medidor de generacion (SGDA Generacion): ENE Delivered = Generacion_SGD_Activa_kWh,
--     ENE Received = Demanda_SGD_Activa_kWh, MDE Delivered = Generacion_SGD_Max_kW,
--     MDE Received = Demanda_SGD_Max_kW, FPO = Generacion_SGD_Reactiva_Coincidente_kVAR,
--     Voltage = Tension_SGD_Fase_*. Asi los dos medidores de un NIS no se mezclan.
-- Tension_Fase_* solo con TIPO_CONSUMO = 'Voltage' (Current, kVA, kW y angulos vienen
-- tambien con UNIDAD = 'Voltage' y se descartan).
-- FPO (UNIDAD kVAR) NO es un contador de energia reactiva: es la potencia reactiva
-- coincidente con la maxima demanda (mismo instante/archivo/medidor que MDE Delivered).
-- Se mapea a Demanda_Reactiva_Coincidente_kVAR (unidad kVAR) y no participa en
-- plata_carga_diferencias. La fuente consumo no trae contador acumulado de kVARh.
-- Incluye ademas el mes anterior a la ventana (mes de contexto del bronce consumo) para
-- que plata_carga_diferencias tenga la lectura previa del contador.
-- =============================================================

CREATE OR REFRESH MATERIALIZED VIEW ${project.catalog}.${project.schema_plata}.plata_consumo AS
WITH base AS (
  SELECT
    c.*,
    CASE
      WHEN c.SGDA IS NULL OR TRIM(c.SGDA) = '' OR UPPER(TRIM(c.SGDA)) = 'NULL' THEN 'Consumo'
      WHEN TRIM(c.SGDA) RLIKE '^[0-9]+_[0-9]+$' THEN 'Consumo'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') IN ('BIDIRECCIONAL', 'BIDIRRECIONAL') THEN 'Bidireccional'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') = 'GENERACION' THEN 'Generacion'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') IN ('TOTALIZACION', 'TOTA SUMA', 'TOTA_SUMA') THEN 'Totalizacion'
      WHEN c.LOCALIZACION IS NULL THEN 'Proyecto'
      ELSE 'Desconocido'
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
        WHEN 'Generacion' THEN 'Generacion_SGD_Activa_kWh'
        WHEN 'Totalizacion' THEN 'Totalizacion_Activo_kWh'
        WHEN 'Proyecto' THEN 'Proyecto_Activo_kWh'
        WHEN 'Desconocido' THEN 'Otros'
        ELSE 'Consumo_Activo_kWh'
      END
    WHEN c.SGDA_NORM = 'Desconocido' THEN 'Otros'
    -- Medidor de generacion (entre el SGD y el panel de carga del cliente)
    WHEN c.SGDA_NORM = 'Generacion' AND c.TIPO_CONSUMO = 'ENE Received' AND c.UNIDAD = 'kWh' THEN 'Demanda_SGD_Activa_kWh'
    WHEN c.SGDA_NORM = 'Generacion' AND c.TIPO_CONSUMO = 'FPO' AND c.UNIDAD = 'kVAR' THEN 'Generacion_SGD_Reactiva_Coincidente_kVAR'
    WHEN c.SGDA_NORM = 'Generacion' AND c.TIPO_CONSUMO = 'MDE Delivered' AND c.UNIDAD = 'kW' THEN 'Generacion_SGD_Max_kW'
    WHEN c.SGDA_NORM = 'Generacion' AND c.TIPO_CONSUMO = 'MDE Received' AND c.UNIDAD = 'kW' THEN 'Demanda_SGD_Max_kW'
    WHEN c.SGDA_NORM = 'Generacion' AND c.TIPO_CONSUMO = 'Voltage' AND c.UNIDAD = 'Voltage' THEN
      CASE
        WHEN c.CONTADOR = 'A' THEN 'Tension_SGD_Fase_A'
        WHEN c.CONTADOR = 'B' THEN 'Tension_SGD_Fase_B'
        WHEN c.CONTADOR = 'C' THEN 'Tension_SGD_Fase_C'
        ELSE 'Tension_SGD_Otros'
      END
    -- Medidor de red (entre el centro de carga del cliente y la red)
    WHEN c.TIPO_CONSUMO = 'ENE Received' AND c.UNIDAD = 'kWh' THEN 'Inyeccion_Activo_kWh'
    WHEN c.TIPO_CONSUMO = 'ENE Sum' AND c.UNIDAD = 'kWh' THEN 'Totalizacion_Activo_kWh'
    WHEN c.TIPO_CONSUMO = 'FPO' AND c.UNIDAD = 'kVAR' THEN 'Demanda_Reactiva_Coincidente_kVAR'
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
  c.UNIDAD AS UNIDAD,
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
