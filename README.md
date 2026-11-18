# AMI_base

Bundle de Databricks (Declarative Automation Bundle `databricks_ami_base`) que lleva los datos AMI
desde el **landing** (parquet en `vol_alunizaje`) hasta **`plata_950_carga`**, la plata validada
que consumen los proyectos aguas abajo (por ejemplo, Curvas Q3).

## Alcance

```
landing (vol_alunizaje/ami, parquet)
  └─ bronce   carga, consumo, tension, pme        (+ tmt, tmtb: listas oficiales de NIS)
      └─ plata    plata_carga, plata_consumo       (toda la masa de clientes)
          └─ plata_analisis  plata_carga_diferencias, plata_carga_completitud
              └─ plata_950_carga                   (fin del alcance; PLAN = TMT/TMTB o NULL)
```

Fuera de alcance: capa oro, margenes y dashboards. El filtro TMT/TMTB (`PLAN IS NOT NULL`)
se aplica solo en el analisis de margenes de comercializacion (bundle `tmt_tmtb_oro`).

## Recursos

| Recurso | Que hace |
| --- | --- |
| Pipeline `AMI_base` | Landing -> bronce -> plata (`src/ami_base/`) |
| Pipeline `AMI_base_Analisis` | Calidad (diferencias y completitud) -> `plata_950_carga` (`src/ami_base_analisis/`) |
| Job `AMI_base_Workflow` | `retencion_bronce` -> `AMI_base` -> `AMI_base_Analisis` |

## Ventana de meses

* El bronce son streaming tables con Auto Loader: cada corrida solo lee archivos nuevos, con un
  flujo por mes. Plata y plata_analisis son materialized views.
* La ventana se calcula en `src/ami_base/utilities/ventana.py` listando el landing. Solo cuentan los
  meses con parquet en las 4 fuentes (carga, consumo, tension, PME).
* Por defecto (`ami_periodo`/`ami_mes` = `ultimo`, `ami_meses_historial` = `1`) se procesa solo el
  ultimo mes disponible. Cuando llega un mes nuevo, la tarea `retencion_bronce` borra el anterior.
* Para subir todos los meses: `ami_meses_historial: todos` (o `N` para los ultimos N meses).
* `periodo_inicio`/`periodo_fin` = `auto`: el analisis usa la misma ventana que el bronce
  (`src/ami_base_analisis/plata/00_ventana_analisis.sql`).

## Variables principales (`databricks.yml`)

| Variable | Uso |
| --- | --- |
| `catalog`, `schema_*` | Destino de las tablas |
| `ami_base_path` | Raiz del landing AMI/PME |
| `ami_periodo`, `ami_mes`, `ami_meses_historial` | Ventana de meses del bronce (`ultimo`, `1` / `N` / `todos`) |
| `volume_oficiales`, `oficial_periodo`, `oficial_mes` | Excel oficiales TMT/TMTB (lista de NIS y plan) |
| `periodo_inicio`, `periodo_fin` | Periodo evaluado en plata_analisis / plata_950 (`auto` o fechas) |

## Uso

```bash
databricks bundle validate --strict --target free_dev
databricks bundle deploy --target free_dev
databricks bundle run ami_base_workflow --target free_dev
```

Para otro entorno, copia `databricks.local.yml.example` a `databricks.local.yml` y ajusta el catalogo.
`scripts/bootstrap.py` verifica o crea el catalogo, los esquemas y el volumen de oficiales.
