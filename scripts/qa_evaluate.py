"""
QA evaluation stage of the promotion pipeline.

Triggered by CI/CD (qa-eval workflow) on every PR targeting the `qa` branch.
Runs as MLOPS_QA_SVC / MLOPS_QA_ROLE.

What it does
------------
1. Resolves whichever model version currently holds the `DEV` alias in
   MLOPS_DEV -- this is the ONLY place the "which model do we test next"
   decision is made; nothing is passed in via git or workflow inputs.
2. Copies that exact version into MLOPS_QA's own Model Registry via
   `CREATE/ALTER MODEL ... FROM MODEL ...` (a real, independent copy).
3. Runs inference on MLOPS_QA.MLOPS.HOLDOUT_DATA (synthetic hold-out data
   the DEV role never has access to) and computes accuracy.
4. Compares against the `holdout_accuracy` metric stored on the PROD
   model's DEFAULT version (the incumbent) in MLOPS_PROD's Model Registry.
5. If the candidate beats the incumbent, moves the `QA_PASSED` alias onto
   it -- this is the ONLY thing that can make prod_deploy.py promote a
   version to PROD. If not, the script exits non-zero and the pipeline
   stops here.
"""

from __future__ import annotations

import os
import sys

from snowflake.ml.registry import Registry

sys.path.insert(0, os.path.dirname(__file__))
from common import copy_model_version, get_alias_holder, get_session, model_exists, set_alias, version_exists  # noqa: E402

MODEL_NAME = "CHURN_MODEL"
FEATURE_COLUMNS = ["FEATURE_1", "FEATURE_2", "FEATURE_3", "FEATURE_4", "FEATURE_5", "FEATURE_6"]
LABEL_COLUMN = "LABEL"
METRIC_NAME = "accuracy"

DEV_DB, DEV_SCHEMA = "MLOPS_DEV", "MLOPS"
QA_DB, QA_SCHEMA = "MLOPS_QA", "MLOPS"
PROD_DB, PROD_SCHEMA = "MLOPS_PROD", "MLOPS"


def compute_accuracy(session, database: str, schema: str, model_name: str, version: str) -> float:
    reg = Registry(session=session, database_name=database, schema_name=schema)
    mv = reg.get_model(model_name).version(version)

    holdout = session.table(f"{QA_DB}.{QA_SCHEMA}.HOLDOUT_DATA")
    predictions = mv.run(holdout.select(*FEATURE_COLUMNS, LABEL_COLUMN), function_name="predict")

    pdf = predictions.to_pandas()
    pred_col = [c for c in pdf.columns if c.upper() not in FEATURE_COLUMNS and c.upper() != LABEL_COLUMN][0]
    correct = (pdf[pred_col].astype(int) == pdf[LABEL_COLUMN].astype(int)).sum()
    return float(correct) / float(len(pdf))


def main() -> int:
    session = get_session(role="MLOPS_QA_ROLE")
    # Platform-agnostic: each CI platform maps its own env var into CI_RUN_ID / CI_COMMIT_SHA.
    # GitHub: GITHUB_RUN_ID / GITHUB_SHA
    # Azure DevOps: BUILD_BUILDID / BUILD_SOURCEVERSION
    ci_run_id = os.environ.get("CI_RUN_ID") or os.environ.get("GITHUB_RUN_ID") or os.environ.get("BUILD_BUILDID", "local")
    ci_commit_sha = os.environ.get("CI_COMMIT_SHA") or os.environ.get("GITHUB_SHA") or os.environ.get("BUILD_SOURCEVERSION", "local")

    dev_version = get_alias_holder(session, DEV_DB, DEV_SCHEMA, MODEL_NAME, "DEV")
    if dev_version is None:
        print(f"No version currently holds the DEV alias on {DEV_DB}.{DEV_SCHEMA}.{MODEL_NAME}. Nothing to evaluate.")
        return 1
    print(f"Resolved DEV alias -> {dev_version}")

    qa_version = f"QA_CANDIDATE_{dev_version.removeprefix('DEV_')}"
    if version_exists(session, QA_DB, QA_SCHEMA, MODEL_NAME, qa_version):
        print(f"{qa_version} already exists in QA. Retrain and move the DEV alias if wanting to evaluate a new candidate.")
        return 0

    copy_model_version(
        session,
        source_database=DEV_DB, source_schema=DEV_SCHEMA, source_model=MODEL_NAME, source_version_or_alias="DEV",
        target_database=QA_DB, target_schema=QA_SCHEMA, target_model=MODEL_NAME, target_version=qa_version,
    )
    print(f"Copied into QA as {qa_version}")

    candidate_metric = compute_accuracy(session, QA_DB, QA_SCHEMA, MODEL_NAME, qa_version)
    print(f"Candidate {METRIC_NAME}: {candidate_metric:.4f}")

    reg_qa = Registry(session=session, database_name=QA_DB, schema_name=QA_SCHEMA)
    reg_qa.get_model(MODEL_NAME).version(qa_version).set_metric("holdout_accuracy", candidate_metric)

    if model_exists(session, PROD_DB, PROD_SCHEMA, MODEL_NAME):
        reg_prod = Registry(session=session, database_name=PROD_DB, schema_name=PROD_SCHEMA)
        incumbent = reg_prod.get_model(MODEL_NAME).default
        incumbent_metric = float(incumbent.get_metric("holdout_accuracy"))
        print(f"Incumbent PROD {incumbent.version_name} {METRIC_NAME}: {incumbent_metric:.4f}")
    else:
        incumbent_metric = 0.0
        print("No PROD model promoted yet -- treating incumbent metric as 0.0")

    passed = candidate_metric > incumbent_metric

    session.sql(
        f"INSERT INTO {QA_DB}.{QA_SCHEMA}.EVAL_LOG "
        f"(MODEL_NAME, DEV_VERSION, QA_VERSION, CANDIDATE_METRIC, INCUMBENT_METRIC, METRIC_NAME, PASSED, CI_RUN_ID, CI_COMMIT_SHA) "
        f"SELECT '{MODEL_NAME}', '{dev_version}', '{qa_version}', {candidate_metric}, {incumbent_metric}, "
        f"'{METRIC_NAME}', {passed}, '{ci_run_id}', '{ci_commit_sha}'"
    ).collect()

    if passed:
        set_alias(session, QA_DB, QA_SCHEMA, MODEL_NAME, qa_version, "QA_PASSED")
        print(f"PASSED: {qa_version} beats incumbent ({candidate_metric:.4f} > {incumbent_metric:.4f}). QA_PASSED alias set.")
        return 0

    print(f"FAILED: {qa_version} does not beat incumbent ({candidate_metric:.4f} <= {incumbent_metric:.4f}). Not promoting.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
