"""
PROD deployment stage of the promotion pipeline.

Triggered by CI/CD (prod-deploy workflow) on every push to `main`.
Runs as MLOPS_PROD_SVC / MLOPS_PROD_ROLE -- the only role that can ever
write to MLOPS_PROD.

What it does
------------
1. Resolves whichever model version currently holds the `QA_PASSED` alias
   in MLOPS_QA. If none does (eval never passed, or was already promoted
   and cleared), the script exits successfully as a no-op -- there is
   nothing to deploy.
2. Copies that exact version into MLOPS_PROD's own Model Registry via
   `CREATE/ALTER MODEL ... FROM MODEL ...`.
3. Sets it as the model's DEFAULT_VERSION -- the convention production
   consumers should always call (`SELECT MLOPS_PROD.MLOPS.CHURN_MODEL!predict(...)`).
4. Logs the promotion (with its evaluation metric) to
   MLOPS_PROD.MLOPS.MODEL_PROMOTIONS -- this is what qa_evaluate.py reads
   on its next run to know the incumbent's metric, and it's the ONLY
   window MLOPS_QA_ROLE has into MLOPS_PROD.
5. Clears the `QA_PASSED` alias so the same candidate can't be
   re-promoted by an unrelated later push to `main`.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from common import copy_model_version, get_alias_holder, get_session, unset_alias  # noqa: E402

MODEL_NAME = "CHURN_MODEL"
METRIC_NAME = "accuracy"

QA_DB, QA_SCHEMA = "MLOPS_QA", "MLOPS"
PROD_DB, PROD_SCHEMA = "MLOPS_PROD", "MLOPS"


def main() -> int:
    session = get_session(role="MLOPS_PROD_ROLE")
    # Platform-agnostic: each CI platform maps its own env var.
    ci_run_id = os.environ.get("CI_RUN_ID") or os.environ.get("GITHUB_RUN_ID") or os.environ.get("BUILD_BUILDID", "local")
    ci_commit_sha = os.environ.get("CI_COMMIT_SHA") or os.environ.get("GITHUB_SHA") or os.environ.get("BUILD_SOURCEVERSION", "local")

    qa_version = get_alias_holder(session, QA_DB, QA_SCHEMA, MODEL_NAME, "QA_PASSED")
    if qa_version is None:
        print(f"No version holds the QA_PASSED alias on {QA_DB}.{QA_SCHEMA}.{MODEL_NAME}. Nothing to deploy.")
        return 0
    print(f"Resolved QA_PASSED alias -> {qa_version}")

    metric_rows = session.sql(
        f"SELECT CANDIDATE_METRIC FROM {QA_DB}.{QA_SCHEMA}.EVAL_LOG "
        f"WHERE MODEL_NAME = '{MODEL_NAME}' AND QA_VERSION = '{qa_version}' AND PASSED = TRUE "
        f"ORDER BY EVALUATED_AT DESC LIMIT 1"
    ).collect()
    if not metric_rows:
        print(f"No passing eval log entry found for {qa_version} -- refusing to promote without a recorded metric.")
        return 1
    metric_value = float(metric_rows[0]["CANDIDATE_METRIC"])

    prod_version = f"PROD_{qa_version.removeprefix('QA_CANDIDATE_')}"
    copy_model_version(
        session,
        source_database=QA_DB, source_schema=QA_SCHEMA, source_model=MODEL_NAME, source_version_or_alias="QA_PASSED",
        target_database=PROD_DB, target_schema=PROD_SCHEMA, target_model=MODEL_NAME, target_version=prod_version,
    )
    print(f"Copied into PROD as {prod_version}")

    session.sql(
        f"ALTER MODEL {PROD_DB}.{PROD_SCHEMA}.{MODEL_NAME} SET DEFAULT_VERSION = {prod_version}"
    ).collect()
    print(f"Set {prod_version} as the DEFAULT_VERSION of {PROD_DB}.{PROD_SCHEMA}.{MODEL_NAME}")

    session.sql(
        f"INSERT INTO {PROD_DB}.{PROD_SCHEMA}.MODEL_PROMOTIONS "
        f"(MODEL_NAME, VERSION_NAME, METRIC_NAME, METRIC_VALUE, PROMOTED_BY, CI_RUN_ID, CI_COMMIT_SHA) "
        f"SELECT '{MODEL_NAME}', '{prod_version}', '{METRIC_NAME}', {metric_value}, "
        f"CURRENT_USER(), '{ci_run_id}', '{ci_commit_sha}'"
    ).collect()

    unset_alias(session, QA_DB, QA_SCHEMA, MODEL_NAME, "QA_PASSED")
    print(f"Promotion complete: {prod_version} is now PROD default (metric={metric_value:.4f}). QA_PASSED cleared.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
