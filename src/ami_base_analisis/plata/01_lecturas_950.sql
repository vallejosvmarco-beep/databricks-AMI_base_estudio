-- =============================================================
-- VISTA TEMPORAL lecturas_950 (no crea tabla en el catalogo)
-- Lecturas de 15 min de plata_carga dentro de la ventana, marcadas para la calidad
-- diaria de plata_950 (metodologia CNFL 2025: dias con >= 90 valores validos,
-- imputacion de faltantes con el promedio horario del mes).
--
-- * FECHA_CURVA / INTERVALO: la curva se etiqueta al FINAL del intervalo, asi que la
--   lectura de las 00:00 pertenece al ultimo intervalo (96) del dia anterior.
--   FECHA_CURVA = fecha(FECHA_LECTURA - 15 min); INTERVALO 1..96.
-- * FUENTE_CALIDAD por NISE/OPERACION (no por NISE completo):
--     'diferencias' si >= 95% de sus lecturas en lapsos EVALUABLES cuadra con el
--       contador (|dif| <= 5%); entonces una lectura es valida si su lapso cuadra o si
--       su lapso no es evaluable.
--     Lapso no evaluable = le faltan lecturas de la curva (LECTURAS_PRESENTES <
--       LECTURAS_ESPERADAS): la suma queda corta por el hueco, no por lecturas malas, asi
--       que no se invalidan las lecturas presentes (la cobertura la exige la regla diaria).
--       Evita que un hueco de un dia invalide el dia vecino del mismo lapso.
--     'completitud' en otro caso (sin contador comparable o sin cuadre): cuentan
--       todas sus lecturas; la cobertura se exige por dia.
-- * FLAG_PICO_3SIGMA: ENERGIA > media + 3 desviaciones del NISE/OPERACION en la
--   ventana (sobre las lecturas validadas). SOLO MARCA: el valor se conserva y cuenta
--   como valido (en residencial suelen ser picos reales; imputarlos suaviza la curva).
-- Solo operaciones de energia activa (base de las curvas de demanda).
-- Solo lecturas alineadas a 15 min (hh:00/15/30/45): un medidor con reloj desfasado
-- (ej. hh:07:30) quedaria con dos lecturas en el mismo intervalo; se cuentan como faltantes.
-- =============================================================

CREATE TEMPORARY VIEW lecturas_950 AS
WITH dif_lecturas AS (
  SELECT
    NISE,
    OPERACION,
    FECHA_LECTURA,
    CASE WHEN LECTURAS_PRESENTES >= LECTURAS_ESPERADAS THEN 1 ELSE 0 END AS LAPSO_EVALUABLE,
    CASE WHEN ABS(PORCENTAJE_DIFERENCIA) <= 5 THEN 1 ELSE 0 END AS CUADRA
  FROM ${project.catalog}.${project.schema_analisis}.plata_carga_diferencias
),
dif_pares AS (
  SELECT
    NISE,
    OPERACION,
    AVG(CASE WHEN LAPSO_EVALUABLE = 1 THEN CAST(CUADRA AS DOUBLE) END) AS PCT_LECTURAS_DIF_OK
  FROM dif_lecturas
  GROUP BY NISE, OPERACION
),
dif_ok AS (
  -- lecturas aceptadas por el contador: lapso que cuadra o lapso no evaluable
  SELECT NISE, OPERACION, FECHA_LECTURA
  FROM dif_lecturas
  WHERE CUADRA = 1 OR LAPSO_EVALUABLE = 0
),
base AS (
  SELECT
    CAST(c.NISE AS STRING) AS NISE,
    CAST(c.MEDIDOR AS STRING) AS MEDIDOR,
    CAST(c.OPERACION AS STRING) AS OPERACION,
    c.SGDA_NORMALIZADO,
    CAST(c.CONSTANTE AS DOUBLE) AS CONSTANTE,
    CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP) AS FECHA_LECTURA,
    CAST(c.ENERGIA AS DOUBLE) AS ENERGIA,
    c.FLAG_LP_CANALES_DUPLICADOS,
    CAST(CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP) - INTERVAL 15 MINUTES AS DATE) AS FECHA_CURVA
  FROM ${project.catalog}.${project.schema_plata}.plata_carga c
  WHERE c.ENERGIA IS NOT NULL
    AND unix_timestamp(CAST(c.FECHA_LECTURA_REAL AS TIMESTAMP)) % 900 = 0
    AND c.OPERACION IN (
      'Consumo_Activo_kWh',
      'Inyeccion_Activo_kWh',
      'Generacion_SGD_Activa_kWh',
      'Demanda_SGD_Activa_kWh'
    )
),
en_ventana AS (
  SELECT *
  FROM base
  WHERE FECHA_CURVA >= (SELECT FECHA_INICIO FROM ventana_analisis)
    AND FECHA_CURVA <= (SELECT FECHA_FIN FROM ventana_analisis)
),
con_fuente AS (
  SELECT
    b.*,
    p.PCT_LECTURAS_DIF_OK,
    CASE WHEN p.PCT_LECTURAS_DIF_OK >= 0.95 THEN 'diferencias' ELSE 'completitud' END AS FUENTE_CALIDAD
  FROM en_ventana b
  LEFT JOIN dif_pares p
    ON b.NISE = p.NISE AND b.OPERACION = p.OPERACION
),
validacion AS (
  SELECT f.*, 1 AS VALIDADA_CONTADOR
  FROM con_fuente f
  WHERE f.FUENTE_CALIDAD = 'completitud'
  UNION ALL
  SELECT f.*, CASE WHEN d.NISE IS NOT NULL THEN 1 ELSE 0 END AS VALIDADA_CONTADOR
  FROM con_fuente f
  LEFT JOIN dif_ok d
    ON f.NISE = d.NISE
   AND f.OPERACION = d.OPERACION
   AND f.FECHA_LECTURA = d.FECHA_LECTURA
  WHERE f.FUENTE_CALIDAD = 'diferencias'
),
estadisticos AS (
  SELECT NISE, OPERACION, AVG(ENERGIA) AS MU, STDDEV_POP(ENERGIA) AS SIGMA
  FROM validacion
  WHERE VALIDADA_CONTADOR = 1
  GROUP BY NISE, OPERACION
)
SELECT
  v.*,
  CAST((unix_timestamp(v.FECHA_LECTURA) - unix_timestamp(CAST(v.FECHA_CURVA AS TIMESTAMP))) / 900 AS INT) AS INTERVALO,
  CASE
    WHEN v.VALIDADA_CONTADOR = 1 AND e.SIGMA > 0 AND v.ENERGIA > e.MU + 3 * e.SIGMA THEN 1
    ELSE 0
  END AS FLAG_PICO_3SIGMA
FROM validacion v
LEFT JOIN estadisticos e
  ON v.NISE = e.NISE AND v.OPERACION = e.OPERACION;
