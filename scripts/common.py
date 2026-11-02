"""Shared helpers for the CI/CD scripts (qa_evaluate.py, prod_deploy.py).

Connects to Snowflake using OIDC (OAuth) authentication. The
snowflakedb/snowflake-actions action (use-oidc: true) obtains a short-lived
GitHub OIDC token and exports it as SNOWFLAKE_TOKEN. Snowflake validates the
token's subject claim against the WORKLOAD_IDENTITY configured on each service
user (MLOPS_QA_SVC / MLOPS_PROD_SVC).
"""

from __future__ import annotations

import json
import os

from snowflake.ml.registry import Registry
from snowflake.snowpark import Session


def get_session(role: str) -> Session:
    """Open a Snowpark session using the OIDC token from snowflake-actions.

    The `snowflakedb/snowflake-actions@v3` step (with `use-oidc: true`) exports
    SNOWFLAKE_TOKEN with the GitHub OIDC JWT. We pass it to the Snowpark
    connector using the workload identity federation authenticator, per:
    https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect#authenticating-with-workload-identity-federation-wif
    """
    return Session.builder.configs({
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "authenticator": "WORKLOAD_IDENTITY",
        "workload_identity_provider": "OIDC",
        "token": os.environ["SNOWFLAKE_TOKEN"],
        "role": role,
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "MLOPS_WH"),
    }).create()


def get_alias_holder(session: Session, database: str, schema: str, model_name: str, alias: str) -> str | None:
    """Return the version name currently holding `alias` on the given model, or None.

    Uses the Model Registry Python API's `model.show_versions()` (a pandas
    DataFrame) rather than parsing `SHOW VERSIONS IN MODEL` SQL output --
    simpler, and avoids a SQL type mismatch: RESULT_SCAN surfaces the
    "aliases" column as VARCHAR (a JSON-encoded string), not a native ARRAY,
    so ARRAY_CONTAINS(..., "aliases") fails to compile against it directly.

    Also returns None if the model doesn't exist yet -- e.g. the very first
    time this pipeline runs, before anyone has trained and logged a model.
    """
    if not model_exists(session, database, schema, model_name):
        return None

    reg = Registry(session=session, database_name=database, schema_name=schema)
    versions_df = reg.get_model(model_name).show_versions()

    for _, row in versions_df.iterrows():
        aliases = row["aliases"]
        if isinstance(aliases, str):
            try:
                aliases = json.loads(aliases)
            except (TypeError, ValueError):
                aliases = []
        if aliases and alias in aliases:
            return row["name"]
    return None


def model_exists(session: Session, database: str, schema: str, model_name: str) -> bool:
    rows = session.sql(f"SHOW MODELS LIKE '{model_name}' IN SCHEMA {database}.{schema}").collect()
    return len(rows) > 0


def version_exists(session: Session, database: str, schema: str, model_name: str, version: str) -> bool:
    if not model_exists(session, database, schema, model_name):
        return False
    rows = session.sql(
        f"SHOW VERSIONS LIKE '{version}' IN MODEL {database}.{schema}.{model_name}"
    ).collect()
    return len(rows) > 0


def copy_model_version(
    session: Session,
    source_database: str,
    source_schema: str,
    source_model: str,
    source_version_or_alias: str,
    target_database: str,
    target_schema: str,
    target_model: str,
    target_version: str,
) -> None:
    """Copy a model version across databases/schemas via CREATE/ALTER MODEL ... FROM MODEL.

    This creates a brand-new, independent artifact in the target schema (not
    a pointer back to the source) -- the documented, supported mechanism for
    moving a model version between registries without local export/re-upload.
    """
    target_fq = f"{target_database}.{target_schema}.{target_model}"
    source_fq = f"{source_database}.{source_schema}.{source_model}"

    if model_exists(session, target_database, target_schema, target_model):
        session.sql(
            f"ALTER MODEL {target_fq} ADD VERSION {target_version} "
            f"FROM MODEL {source_fq} VERSION {source_version_or_alias}"
        ).collect()
    else:
        session.sql(
            f"CREATE MODEL {target_fq} WITH VERSION {target_version} "
            f"FROM MODEL {source_fq} VERSION {source_version_or_alias}"
        ).collect()


def set_alias(session: Session, database: str, schema: str, model_name: str, version: str, alias: str) -> None:
    """Move `alias` to `version`, first unsetting it from wherever it currently is."""
    fq_model = f"{database}.{schema}.{model_name}"
    current_holder = get_alias_holder(session, database, schema, model_name, alias)
    if current_holder is not None and current_holder != version:
        session.sql(f"ALTER MODEL {fq_model} VERSION {current_holder} UNSET ALIAS").collect()
    session.sql(f"ALTER MODEL {fq_model} VERSION {version} SET ALIAS = {alias}").collect()


def unset_alias(session: Session, database: str, schema: str, model_name: str, alias: str) -> None:
    """Remove `alias` from whichever version currently holds it, if any."""
    current_holder = get_alias_holder(session, database, schema, model_name, alias)
    if current_holder is not None:
        fq_model = f"{database}.{schema}.{model_name}"
        session.sql(f"ALTER MODEL {fq_model} VERSION {current_holder} UNSET ALIAS").collect()
