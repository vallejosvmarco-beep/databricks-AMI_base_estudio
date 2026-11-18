import re
import unicodedata

from pyspark import pipelines as dp
from pyspark.sql import functions as F

# =============================================================
# LISTA OFICIAL TMT (Excel en datos_oficiales/tmt/<periodo>/<mes>)
# =============================================================
# tmt_historial: streaming table con Auto Loader; solo ingiere archivos Excel
#   nuevos (un flujo por snapshot oficial_periodo/oficial_mes).
# tmt: materialized view con el snapshot vigente. Al leer una tabla Delta,
#   si no llegan archivos nuevos la vista no se recalcula y plata no se toca.
# =============================================================

PLAN = "TMT"
SUBCARPETA = "tmt"
HISTORIAL = "tmt_historial"
PROPIEDADES = {"delta.enableRowTracking": "true", "delta.enableDeletionVectors": "true"}


def _normalizar_nombre(nombre: str) -> str:
    texto = unicodedata.normalize("NFKD", str(nombre))
    texto = "".join(c for c in texto if not unicodedata.combining(c))
    texto = texto.strip().lower()
    texto = re.sub(r"[^a-z0-9]+", "_", texto)
    return texto.strip("_")


dp.create_streaming_table(
    name=HISTORIAL,
    comment=f"Historial de snapshots oficiales {PLAN} (Excel) ingeridos incrementalmente.",
    table_properties=PROPIEDADES,
)


def _crear_flujo_snapshot(periodo: str, mes: str):
    @dp.append_flow(target=HISTORIAL, name=f"{HISTORIAL}_{periodo}_{mes}")
    def _flujo():
        catalog = spark.conf.get("project.catalog")
        schema = spark.conf.get("project.schema_alunizaje")
        volume = spark.conf.get("project.volume_oficiales")
        path = f"/Volumes/{catalog}/{schema}/{volume}/{SUBCARPETA}/{periodo}/{mes}"

        df = (
            spark.readStream
            .format("cloudFiles")
            .option("cloudFiles.format", "excel")
            .option("cloudFiles.inferColumnTypes", "true")
            # Excel no admite evolucion de esquema en Auto Loader
            .option("cloudFiles.schemaEvolutionMode", "none")
            .option("headerRows", 1)
            .load(path)
        )
        df = df.toDF(*[_normalizar_nombre(c) for c in df.columns])

        # Columnas clave se tipan de forma estable; el resto conserva la inferencia del lector Excel.
        if "nis" in df.columns:
            df = df.withColumn("nis", F.col("nis").cast("string"))
        if "localizacion" in df.columns:
            df = df.withColumn("localizacion", F.col("localizacion").cast("string"))
        if "medidor" in df.columns:
            df = df.withColumn("medidor", F.col("medidor").cast("string"))
        if "plan" in df.columns:
            df = df.withColumn("plan", F.upper(F.trim(F.col("plan").cast("string"))))
        if "fecha_lectura" in df.columns:
            fecha_txt = F.col("fecha_lectura").cast("string")
            df = df.withColumn(
                "fecha_lectura",
                F.coalesce(
                    F.to_date(fecha_txt, "dd-MM-yyyy"),
                    F.to_date(fecha_txt, "yyyy-MM-dd"),
                    F.col("fecha_lectura").cast("date"),
                ),
            )
        return (
            df.withColumn("oficial_periodo", F.lit(periodo))
              .withColumn("oficial_mes", F.lit(mes))
        )


_crear_flujo_snapshot(spark.conf.get("project.oficial_periodo"), spark.conf.get("project.oficial_mes"))


@dp.materialized_view(
    name=SUBCARPETA,
    comment=f"Snapshot oficial {PLAN} vigente (oficial_periodo/oficial_mes).",
    table_properties=PROPIEDADES,
)
def lista_vigente():
    periodo = spark.conf.get("project.oficial_periodo")
    mes = spark.conf.get("project.oficial_mes")
    df = (
        spark.read.table(HISTORIAL)
        .filter((F.col("oficial_periodo") == periodo) & (F.col("oficial_mes") == mes))
    )
    return (
        df.drop("oficial_periodo", "oficial_mes", "_rescued_data", "rescued_data")
        .filter(F.col("nis").isNotNull())
        .filter(F.col("plan") == F.lit(PLAN))
        .dropDuplicates(["nis"])
    )
