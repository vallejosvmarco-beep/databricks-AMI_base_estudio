import subprocess
import sys
import json
import os


def _resolve_catalog():
    """Resolve catalog from CLI args, env var, or bundle config files."""
    if len(sys.argv) > 1:
        return sys.argv[1]
    if os.environ.get("CATALOG"):
        return os.environ["CATALOG"]
    try:
        import yaml
        script_dir = os.path.dirname(os.path.abspath(__file__))
        bundle_root = os.path.dirname(script_dir)
        target = os.environ.get("BUNDLE_TARGET", "free_dev")
        for fname in ("databricks.local.yml", "databricks.yml"):
            config_path = os.path.join(bundle_root, fname)
            if os.path.exists(config_path):
                with open(config_path) as f:
                    data = yaml.safe_load(f)
                if not data:
                    continue
                # Check target-level variables first
                targets = data.get("targets", {})
                if target in targets:
                    target_vars = targets[target].get("variables", {})
                    if "catalog" in target_vars:
                        val = target_vars["catalog"]
                        if isinstance(val, dict) and "default" in val:
                            return val["default"]
                        elif isinstance(val, str):
                            return val
                # Fallback to top-level variables
                if "variables" in data:
                    cat_var = data["variables"].get("catalog", {})
                    if isinstance(cat_var, dict) and "default" in cat_var:
                        return cat_var["default"]
                    elif isinstance(cat_var, str):
                        return cat_var
    except Exception:
        pass
    return "workspace"


CATALOG = _resolve_catalog()


SCHEMAS = [
    "alunizaje",
    "bronce",
    "plata",
    "plata_analisis",
]


VOLUMES = [
    ("alunizaje", "datos_oficiales"),
]


def run(cmd, check=True):
    print(f"> {' '.join(cmd)}")

    result = subprocess.run(
        cmd,
        text=True,
        capture_output=True
    )

    if result.stdout:
        print(result.stdout)

    if result.returncode != 0 and result.stderr:
        print(result.stderr)

    if check and result.returncode != 0:
        raise RuntimeError(
            f"Comando fallo con codigo {result.returncode}: "
            f"{' '.join(cmd)}"
        )

    return result


def catalog_exists():
    """Verifica si el catalogo existe."""
    result = run(
        [
            "databricks",
            "catalogs",
            "get",
            CATALOG,
        ],
        check=False,
    )
    return result.returncode == 0


def list_available_catalogs():
    """Lista catalogos disponibles en el workspace."""
    result = run(
        [
            "databricks",
            "catalogs",
            "list",
            "--output",
            "json",
        ],
        check=False,
    )
    
    if result.returncode == 0 and result.stdout:
        try:
            catalogs_data = json.loads(result.stdout)
            if "catalogs" in catalogs_data:
                return [c["name"] for c in catalogs_data["catalogs"]]
        except json.JSONDecodeError:
            pass
    
    return []


def create_catalog():
    """Intenta crear el catalogo."""
    print(f"[CREATE] Intentando crear catalogo {CATALOG}...")
    result = run(
        [
            "databricks",
            "catalogs",
            "create",
            CATALOG,
        ],
        check=False,
    )
    return result.returncode == 0


def schema_exists(schema):
    full_name = f"{CATALOG}.{schema}"

    result = run(
        [
            "databricks",
            "schemas",
            "get",
            full_name,
        ],
        check=False,
    )

    return result.returncode == 0


def create_schema(schema):
    run(
        [
            "databricks",
            "schemas",
            "create",
            schema,
            CATALOG,
        ]
    )


def volume_exists(schema, volume):
    full_name = f"{CATALOG}.{schema}.{volume}"

    result = run(
        [
            "databricks",
            "volumes",
            "read",
            full_name,
        ],
        check=False,
    )

    return result.returncode == 0


def create_volume(schema, volume):
    run(
        [
            "databricks",
            "volumes",
            "create",
            CATALOG,
            schema,
            volume,
            "MANAGED",
        ]
    )


# ============================================================
# VALIDACION DEL CATALOGO
# ============================================================

if not catalog_exists():
    print(f"[WARNING] El catalogo '{CATALOG}' NO existe en este workspace.")
    print()
    
    available = list_available_catalogs()
    
    if available:
        print("Catalogos disponibles en este workspace:")
        for cat in available:
            print(f"  - {cat}")
        print()
    
    print("Intentando crear el catalogo...")
    if create_catalog():
        print(f"[OK] Catalogo '{CATALOG}' creado exitosamente.")
    else:
        print(f"[ERROR] No se pudo crear el catalogo '{CATALOG}'.")
        print()
        print("SOLUCION:")
        print("  1. Si no tienes permisos para crear catalogos:")
        print(f"     - Usa un catalogo existente: databricks bundle deploy --var catalog=<nombre>")
        print("  2. O crea un archivo databricks.local.yml:")
        print("     targets:")
        print("       free_dev:")
        print("         variables:")
        print("           catalog: <nombre_catalogo_existente>")
        print()
        sys.exit(1)
else:
    print(f"[OK] Catalogo '{CATALOG}' existe.")


# ============================================================
# SCHEMAS
# ============================================================

for schema in SCHEMAS:

    full_name = f"{CATALOG}.{schema}"

    if schema_exists(schema):

        print(f"[OK] {full_name} ya existe. Se conserva.")

    else:

        print(f"[CREATE] {full_name}")

        create_schema(schema)


# ============================================================
# VOLUMES
# ============================================================

for schema, volume in VOLUMES:

    full_name = f"{CATALOG}.{schema}.{volume}"

    if volume_exists(schema, volume):

        print(f"[OK] {full_name} ya existe. Se conserva.")

    else:

        print(f"[CREATE] {full_name}")

        create_volume(schema, volume)





print("=" * 70)
print("BOOTSTRAP COMPLETADO")
print("=" * 70)
