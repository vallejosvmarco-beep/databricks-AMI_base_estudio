from pyspark import pipelines as dp
from pyspark.sql import functions as F

from utilities.ventana import meses_ventana_pipeline, ruta_mes

# =============================================================
# BRONCE TENSION - ingesta incremental desde el landing (vol_alunizaje)
# =============================================================
# Streaming table alimentada con Auto Loader: cada corrida solo lee los
# archivos parquet nuevos (los ya ingeridos no se vuelven a leer).
# Un append flow por mes de la ventana (utilities/ventana.py; por defecto el
# ultimo mes disponible en el landing):
#   - al avanzar la ventana se crea el flujo del mes nuevo y solo se ingiere ese mes;
#   - los meses que salen de la ventana se eliminan con la tarea de retencion
#     (src/ami_base/mantenimiento/retencion_bronce.py), que borra por particion.
# =============================================================

FUENTE = "tension"
SOURCE = "AMI"
TABLA = "tension"


dp.create_streaming_table(
    name=TABLA,
    comment="Bronce de tension AMI (parquet de vol_alunizaje), ingesta incremental por mes.",
    partition_cols=["periodo", "mes"],
    table_properties={
        "delta.enableRowTracking": "true",
        "delta.enableDeletionVectors": "true",
    },
)


def _crear_flujo_mes(p: int, m: int):
    @dp.append_flow(target=TABLA, name=f"{TABLA}_{p}_{m:02d}")
    def _flujo():
        # Cada mes puede venir dividido en subcarpetas (r1, r2, ...): Auto Loader las recorre.
        path = ruta_mes(spark.conf.get("project.ami_base_path"), FUENTE, SOURCE, p, m)
        return (
            spark.readStream
            .format("cloudFiles")
            .option("cloudFiles.format", "parquet")
            .load(path)
            .withColumn("periodo", F.lit(p))
            .withColumn("mes", F.lit(m))
        )


for _p, _m in meses_ventana_pipeline(spark):
    _crear_flujo_mes(_p, _m)
