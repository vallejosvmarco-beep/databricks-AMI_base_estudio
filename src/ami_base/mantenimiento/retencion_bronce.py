"""Retencion del bronce AMI_base: conserva solo la ventana de meses configurada.

Primera tarea de AMI_base_Workflow, antes del pipeline AMI_base. Calcula la misma
ventana que el pipeline (src/ami_base/utilities/ventana.py, por defecto el ultimo mes
disponible en el landing) y borra de las tablas bronce indicadas las particiones
(periodo, mes) que no estan en ella. Las tablas estan particionadas por (periodo, mes),
asi que el DELETE es de metadatos. Con ami_meses_historial = "todos" no se borra nada
que siga en el landing. La tabla consumo conserva ademas el mes de contexto (mes
anterior a la ventana), igual que el pipeline.

Uso: retencion_bronce.py <catalog> <schema> <ami_base_path> <periodo> <mes> <meses_historial> <tabla1,tabla2,...>
"""
import os
import sys

from pyspark.sql import SparkSession

try:
    _script = os.path.abspath(__file__)
except NameError:  # spark_python_task ejecuta el archivo sin __file__
    _script = os.path.abspath(sys.argv[0])
sys.path.insert(0, os.path.dirname(os.path.dirname(_script)))
from utilities.ventana import meses_contexto, meses_ventana  # noqa: E402

TABLAS_PERMITIDAS = {"carga", "consumo", "tension", "pme"}


def main(argv):
    catalog, schema, base, periodo, mes, meses, tablas = argv[1:8]
    ventana = meses_ventana(base, periodo, mes, meses)
    print(f"Ventana AMI: {ventana[0]} .. {ventana[-1]} ({len(ventana)} meses)")
    contexto_consumo = meses_contexto(base, ventana, "consumo", "AMI")
    print(f"Mes de contexto consumo: {contexto_consumo}")

    spark = SparkSession.builder.getOrCreate()
    for tabla in [t.strip() for t in tablas.split(",") if t.strip()]:
        if tabla not in TABLAS_PERMITIDAS:
            raise ValueError(f"Tabla no permitida para retencion: {tabla}")
        conservar = (contexto_consumo + ventana) if tabla == "consumo" else ventana
        claves = ", ".join(str(p * 12 + m - 1) for p, m in conservar)
        fuera_ventana = f"(periodo * 12 + (mes - 1)) NOT IN ({claves})"
        nombre = f"`{catalog}`.`{schema}`.`{tabla}`"
        if not spark.catalog.tableExists(f"{catalog}.{schema}.{tabla}"):
            print(f"[SKIP] {nombre} no existe todavia")
            continue
        fuera = spark.sql(
            f"SELECT periodo, mes, COUNT(*) AS filas FROM {nombre} "
            f"WHERE {fuera_ventana} GROUP BY periodo, mes ORDER BY periodo, mes"
        ).collect()
        if not fuera:
            print(f"[OK] {nombre}: nada fuera de la ventana")
            continue
        for r in fuera:
            print(f"[DELETE] {nombre}: periodo={r.periodo} mes={r.mes} ({r.filas} filas)")
        spark.sql(f"DELETE FROM {nombre} WHERE {fuera_ventana}")


if __name__ == "__main__":
    main(sys.argv)
