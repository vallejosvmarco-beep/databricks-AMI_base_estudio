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
-- NULL, vacio, el texto 'null' y codigos con formato de ciclo (ej. '3037_2') = Consumo.
-- Proyecto solo si no hay LOCALIZACION (plantas; se excluyen aguas abajo).
-- Cualquier otro valor = 'Desconocido' (OPERACION 'Otros'), para detectarlo y revisarlo.
-- Se ignoran tildes (Generación = Generacion).
-- Rol del medidor:
--   Medidor de red (SGDA Consumo/Bidireccional), entre el centro de carga y la red:
--     Delivered = demanda facturada (Consumo_*), Received = inyeccion (Inyeccion_*).
--   Medidor de generacion (SGDA Generacion), entre el SGD y el panel de carga:
--     Delivered = generacion (Generacion_SGD_*), Received = demanda del SGD (Demanda_SGD_*).
-- Medidores con perfil de carga de canales duplicados (plata_lp_canales_duplicados,
-- FLAG = 1 en ese mes): se descartan sus lecturas Received y kVARh (no son reales) y se
-- conserva Delivered kWh. La columna FLAG_LP_CANALES_DUPLICADOS marca esas filas.
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
      WHEN c.SGDA IS NULL OR TRIM(c.SGDA) = '' OR UPPER(TRIM(c.SGDA)) = 'NULL' THEN 'Consumo'
      WHEN TRIM(c.SGDA) RLIKE '^[0-9]+_[0-9]+$' THEN 'Consumo'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') IN ('BIDIRECCIONAL', 'BIDIRRECIONAL') THEN 'Bidireccional'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') = 'GENERACION' THEN 'Generacion'
      WHEN TRANSLATE(UPPER(TRIM(c.SGDA)), 'ÁÉÍÓÚ', 'AEIOU') IN ('TOTALIZACION', 'TOTA SUMA', 'TOTA_SUMA') THEN 'Totalizacion'
      WHEN c.LOCALIZACION IS NULL THEN 'Proyecto'
      ELSE 'Desconocido'
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
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Generacion_SGD_Activa_kWh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Generacion_SGD_Reactiva_kVARh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Received' AND UNIDAD = 'kWh' THEN 'Demanda_SGD_Activa_kWh'
      WHEN SGDA_NORMALIZADO = 'Generacion' AND OPERACION_ORIGINAL = 'Received' AND UNIDAD = 'kVARh' THEN 'Demanda_SGD_Reactiva_kVARh'
      WHEN SGDA_NORMALIZADO = 'Totalizacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Totalizacion_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Totalizacion' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Totalizacion_Reactivo_kVARh'
      WHEN SGDA_NORMALIZADO = 'Proyecto' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kWh' THEN 'Proyecto_Activo_kWh'
      WHEN SGDA_NORMALIZADO = 'Proyecto' AND OPERACION_ORIGINAL = 'Delivered' AND UNIDAD = 'kVARh' THEN 'Proyecto_Reactivo_kVARh'
      ELSE 'Otros'
    END AS OPERACION
  FROM base
),
lp_duplicado AS (
  SELECT MEDIDOR, PERIODO, MES
  FROM ${project.catalog}.${project.schema_plata}.plata_lp_canales_duplicados
  WHERE FLAG_LP_CANALES_DUPLICADOS = 1
)
SELECT
  t.NISE,
  t.MEDIDOR,
  t.FECHA_LECTURA_REAL,
  t.SGDA_ORIGINAL,
  t.SGDA_NORMALIZADO,
  t.OPERACION,
  t.UNIDAD,
  t.VALOR_LECTURA,
  t.CONSTANTE,
  t.TIPO_MEDIDOR,
  t.INTERVALO,
  ROUND(t.VALOR_LECTURA * t.CONSTANTE, 3) AS ENERGIA,
  CASE
    WHEN t.INTERVALO IS NULL OR t.INTERVALO = 0 THEN NULL
    ELSE ROUND(t.VALOR_LECTURA * t.CONSTANTE * (60.0 / t.INTERVALO), 3)
  END AS DEMANDA,
  t.LOCALIZACION_FISICA,
  CASE WHEN d.MEDIDOR IS NOT NULL THEN 1 ELSE 0 END AS FLAG_LP_CANALES_DUPLICADOS
FROM transformada t
LEFT JOIN lp_duplicado d
  ON t.MEDIDOR = d.MEDIDOR
 AND YEAR(t.FECHA_LECTURA_REAL) = d.PERIODO
 AND MONTH(t.FECHA_LECTURA_REAL) = d.MES
WHERE NOT (d.MEDIDOR IS NOT NULL AND (t.OPERACION_ORIGINAL = 'Received' OR t.UNIDAD = 'kVARh'))
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY t.NISE, t.FECHA_LECTURA_REAL, t.OPERACION
  ORDER BY t.MEDIDOR, t.SGDA_ORIGINAL, t.UNIDAD
) = 1;
