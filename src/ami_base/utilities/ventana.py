"""Ventana de meses AMI_base, compartida por los bronces y la tarea de retencion.

Los meses se descubren listando el landing:
    <ami_base_path>/<fuente>/source=AMI/format=PARQUET/periodo=<yyyy>/mes=<m>
Solo cuentan los meses que tienen al menos un .parquet en TODAS las fuentes
(carga, consumo, tension), para que bronce y plata queden alineados.
PME ya no es parte de AMI_base: se ingiere en el bundle PME_base.

Parametros (configuracion del pipeline / argumentos de la tarea):
    ami_periodo, ami_mes   "ultimo" = ultimo mes disponible en el landing,
                           o un mes fijo (ej. "2025", "12") como fin de la ventana.
    ami_meses_historial    "1" = solo el mes final; "N" = N meses hacia atras;
                           "todos" = todos los meses disponibles hasta el mes final.

Mes de contexto: el bronce consumo conserva ademas el mes anterior al primero de la
ventana (si existe en el landing), para que plata_carga_diferencias tenga la ultima
lectura del contador previa al periodo. Las demas fuentes no lo usan.
"""
import os
import re

FUENTES = (("carga", "AMI"), ("consumo", "AMI"), ("tension", "AMI"))

_RE_PERIODO = re.compile(r"periodo=(\d{4})")
_RE_MES = re.compile(r"mes=(\d{1,2})")


def ruta_mes(base: str, fuente: str, source: str, periodo: int, mes: int) -> str:
    return f"{base.rstrip('/')}/{fuente}/source={source}/format=PARQUET/periodo={periodo}/mes={mes}"


def _tiene_parquet(path: str) -> bool:
    for _, _, archivos in os.walk(path):
        if any(a.endswith(".parquet") for a in archivos):
            return True
    return False


def meses_disponibles(base: str, fuente: str, source: str) -> set:
    raiz = f"{base.rstrip('/')}/{fuente}/source={source}/format=PARQUET"
    if not os.path.isdir(raiz):
        return set()
    meses = set()
    for carpeta_p in os.listdir(raiz):
        mp = _RE_PERIODO.fullmatch(carpeta_p)
        if not mp:
            continue
        for carpeta_m in os.listdir(f"{raiz}/{carpeta_p}"):
            mm = _RE_MES.fullmatch(carpeta_m)
            if not mm:
                continue
            p, m = int(mp.group(1)), int(mm.group(1))
            if 1 <= m <= 12 and _tiene_parquet(f"{raiz}/{carpeta_p}/{carpeta_m}"):
                meses.add((p, m))
    return meses


def meses_comunes(base: str) -> list:
    comunes = None
    for fuente, source in FUENTES:
        disp = meses_disponibles(base, fuente, source)
        comunes = disp if comunes is None else comunes & disp
    return sorted(comunes or [])


def meses_ventana(base: str, periodo="ultimo", mes="ultimo", historial="1") -> list:
    """Lista ordenada de (periodo, mes) a ingerir/conservar."""
    disponibles = meses_comunes(base)
    if not disponibles:
        raise ValueError(f"No hay meses con datos en todas las fuentes AMI bajo {base}")

    periodo, mes, historial = (str(v).strip().lower() for v in (periodo, mes, historial))
    if periodo == "ultimo" or mes == "ultimo":
        fin = disponibles[-1]
    else:
        fin = (int(periodo), int(mes))
        if not 1 <= fin[1] <= 12:
            raise ValueError(f"Mes invalido: {mes}")
    fin_i = fin[0] * 12 + fin[1] - 1

    if historial == "todos":
        ini_i = None
    else:
        n = int(historial)
        if n < 1:
            raise ValueError(f"ami_meses_historial invalido: {historial}")
        ini_i = fin_i - n + 1

    ventana = [
        (p, m) for p, m in disponibles
        if p * 12 + m - 1 <= fin_i and (ini_i is None or p * 12 + m - 1 >= ini_i)
    ]
    if not ventana:
        raise ValueError(f"La ventana AMI esta vacia (fin={fin}, historial={historial})")
    return ventana


def mes_anterior(periodo: int, mes: int) -> tuple:
    return (periodo - 1, 12) if mes == 1 else (periodo, mes - 1)


def meses_contexto(base: str, ventana: list, fuente: str, source: str) -> list:
    """Mes previo al inicio de la ventana, si la fuente lo tiene en el landing."""
    previo = mes_anterior(*ventana[0])
    return [previo] if previo in meses_disponibles(base, fuente, source) else []


def meses_ventana_pipeline(spark) -> list:
    """Ventana leida de la configuracion del pipeline (project.*)."""
    return meses_ventana(
        spark.conf.get("project.ami_base_path"),
        spark.conf.get("project.ami_periodo", "ultimo"),
        spark.conf.get("project.ami_mes", "ultimo"),
        spark.conf.get("project.ami_meses_historial", "1"),
    )


def meses_consumo_pipeline(spark) -> list:
    """Ventana + mes de contexto para el bronce consumo."""
    ventana = meses_ventana_pipeline(spark)
    base = spark.conf.get("project.ami_base_path")
    return meses_contexto(base, ventana, "consumo", "AMI") + ventana
