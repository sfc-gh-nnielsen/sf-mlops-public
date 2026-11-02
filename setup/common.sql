-- ============================================================================
-- sf-mlops : common Snowflake setup (platform-agnostic)
--
-- Creates three isolated environments (DEV / QA / PROD) for a Model-Registry
-- based promotion pipeline:
--
--   MLOPS_DEV  -- human-editable, owned by MLOPS_DEV_ROLE
--   MLOPS_QA   -- CI-only,        owned by MLOPS_QA_ROLE
--   MLOPS_PROD -- CI-only,        owned by MLOPS_PROD_ROLE
--
-- Isolation guarantee: MLOPS_DEV_ROLE receives ZERO grants on MLOPS_QA or
-- MLOPS_PROD (not even USAGE). A human holding only MLOPS_DEV_ROLE cannot
-- resolve `USE DATABASE MLOPS_PROD` or any fully-qualified MLOPS_PROD.* object
-- reference -- the privilege check fails before Snowflake even evaluates
-- model-level privileges. This is a structural guarantee, not a convention.
-- See README.md for the full explanation.
--
-- After running this script, run the platform-specific setup:
--   setup/github/cicd.sql        -- for GitHub Actions
--   setup/azure-devops/cicd.sql  -- for Azure DevOps Pipelines
--
-- Run as a role with ACCOUNTADMIN-equivalent privileges
-- (CREATE DATABASE, CREATE WAREHOUSE, CREATE ROLE, CREATE USER, MANAGE GRANTS).
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- 1. Warehouse (shared compute across all three environments -- this demo
--    intentionally isolates at the database/role level, not the compute level)
-- ----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS MLOPS_WH
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT             = 'Shared compute for the sf-mlops DEV/QA/PROD demo pipeline.';

-- ----------------------------------------------------------------------------
-- 2. Roles -- one per environment
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS MLOPS_DEV_ROLE
  COMMENT = 'Full control of MLOPS_DEV only. Granted to human developers. NEVER grant this role any privilege on MLOPS_QA or MLOPS_PROD.';

CREATE ROLE IF NOT EXISTS MLOPS_QA_ROLE
  COMMENT = 'Full control of MLOPS_QA. Granted only to the CI/CD service user. Has narrow read-only USAGE into MLOPS_DEV models plus SELECT on MLOPS_PROD.MLOPS.MODEL_PROMOTIONS -- nothing else outside its own database.';

CREATE ROLE IF NOT EXISTS MLOPS_PROD_ROLE
  COMMENT = 'Full control of MLOPS_PROD. Granted only to the CI/CD service user. Has narrow read-only USAGE into MLOPS_QA models. This is the ONLY role that can ever set the default/production model version.';

-- Fold the three roles into the SYSADMIN hierarchy so ACCOUNTADMIN (which
-- includes SYSADMIN) can create objects inside their schemas below without
-- juggling USE ROLE mid-script, while true OWNERSHIP still sits with the
-- functional role (granted explicitly per-schema further down).
GRANT ROLE MLOPS_DEV_ROLE  TO ROLE SYSADMIN;
GRANT ROLE MLOPS_QA_ROLE   TO ROLE SYSADMIN;
GRANT ROLE MLOPS_PROD_ROLE TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE MLOPS_WH TO ROLE MLOPS_DEV_ROLE;
GRANT USAGE ON WAREHOUSE MLOPS_WH TO ROLE MLOPS_QA_ROLE;
GRANT USAGE ON WAREHOUSE MLOPS_WH TO ROLE MLOPS_PROD_ROLE;

-- ----------------------------------------------------------------------------
-- 3. Databases / schemas -- one working schema (MLOPS) per environment,
--    ownership transferred to the matching role so CREATE MODEL, CREATE TABLE,
--    CREATE NOTEBOOK etc. all just work inside it without further per-object
--    grants (OWNERSHIP on a schema implies CREATE MODEL on it).
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS MLOPS_DEV  COMMENT = 'DEV environment for sf-mlops. Human-editable.';
CREATE DATABASE IF NOT EXISTS MLOPS_QA   COMMENT = 'QA environment for sf-mlops. Written to only by CI/CD.';
CREATE DATABASE IF NOT EXISTS MLOPS_PROD COMMENT = 'PROD environment for sf-mlops. Written to only by CI/CD.';

CREATE SCHEMA IF NOT EXISTS MLOPS_DEV.MLOPS  COMMENT = 'Working schema: training data, notebooks, DEV alias audit log, and the Model Registry for DEV.';
CREATE SCHEMA IF NOT EXISTS MLOPS_QA.MLOPS   COMMENT = 'Working schema: holdout data, eval log, and the Model Registry for QA.';
CREATE SCHEMA IF NOT EXISTS MLOPS_PROD.MLOPS COMMENT = 'Working schema: promotion log and the Model Registry for PROD.';

GRANT USAGE ON DATABASE MLOPS_DEV  TO ROLE MLOPS_DEV_ROLE;
GRANT USAGE ON DATABASE MLOPS_QA   TO ROLE MLOPS_QA_ROLE;
GRANT USAGE ON DATABASE MLOPS_PROD TO ROLE MLOPS_PROD_ROLE;

GRANT OWNERSHIP ON SCHEMA MLOPS_DEV.MLOPS  TO ROLE MLOPS_DEV_ROLE  COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA MLOPS_QA.MLOPS   TO ROLE MLOPS_QA_ROLE   COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA MLOPS_PROD.MLOPS TO ROLE MLOPS_PROD_ROLE COPY CURRENT GRANTS;


GRANT ROLE MLOPS_DEV_ROLE TO ROLE MLOPS_QA_ROLE;
GRANT ROLE MLOPS_QA_ROLE  TO ROLE MLOPS_PROD_ROLE;

-- ----------------------------------------------------------------------------
-- 4. Synthetic datasets
--    TRAIN_DATA lives only in DEV (used to train).
--    HOLDOUT_DATA lives only in QA (used to evaluate) -- DEV/human never has
--    access to it, so nobody can tune against the eval set.
--    Both are drawn from the same generating process but are disjoint samples.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE MLOPS_DEV.MLOPS.TRAIN_DATA AS
WITH base AS (
    SELECT
        SEQ4()                          AS ID,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_1,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_2,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_3,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_4,
        NORMAL(0.0, 1.0, RANDOM())      AS FEATURE_5,
        NORMAL(0.0, 1.0, RANDOM())      AS FEATURE_6,
        NORMAL(0.0, 1.5, RANDOM())      AS NOISE
    FROM TABLE(GENERATOR(ROWCOUNT => 2000))
)
SELECT
    ID, FEATURE_1, FEATURE_2, FEATURE_3, FEATURE_4, FEATURE_5, FEATURE_6,
    IFF(
        1.5 * FEATURE_1 - 1.2 * FEATURE_2 + 0.8 * FEATURE_3
        - 0.5 * FEATURE_4 + FEATURE_5 - FEATURE_6 + NOISE > 0,
        1, 0
    ) AS LABEL
FROM base;

GRANT OWNERSHIP ON TABLE MLOPS_DEV.MLOPS.TRAIN_DATA TO ROLE MLOPS_DEV_ROLE COPY CURRENT GRANTS;

CREATE OR REPLACE TABLE MLOPS_QA.MLOPS.HOLDOUT_DATA AS
WITH base AS (
    SELECT
        SEQ4() + 1000000                AS ID,   -- offset so IDs never collide with TRAIN_DATA
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_1,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_2,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_3,
        UNIFORM(-3.0, 3.0, RANDOM())    AS FEATURE_4,
        NORMAL(0.0, 1.0, RANDOM())      AS FEATURE_5,
        NORMAL(0.0, 1.0, RANDOM())      AS FEATURE_6,
        NORMAL(0.0, 1.5, RANDOM())      AS NOISE
    FROM TABLE(GENERATOR(ROWCOUNT => 500))
)
SELECT
    ID, FEATURE_1, FEATURE_2, FEATURE_3, FEATURE_4, FEATURE_5, FEATURE_6,
    IFF(
        1.5 * FEATURE_1 - 1.2 * FEATURE_2 + 0.8 * FEATURE_3
        - 0.5 * FEATURE_4 + FEATURE_5 - FEATURE_6 + NOISE > 0,
        1, 0
    ) AS LABEL
FROM base;

GRANT OWNERSHIP ON TABLE MLOPS_QA.MLOPS.HOLDOUT_DATA TO ROLE MLOPS_QA_ROLE COPY CURRENT GRANTS;

-- ----------------------------------------------------------------------------
-- 5. Audit / log tables
--
--    Column names CI_RUN_ID and CI_COMMIT_SHA are platform-agnostic -- each
--    CI platform maps its own env var (GITHUB_RUN_ID, BUILD_BUILDID,
--    etc.) into these columns via the Python scripts.
-- ----------------------------------------------------------------------------

-- Every QA evaluation run (pass or fail) is logged here by qa_evaluate.py.
CREATE TABLE IF NOT EXISTS MLOPS_QA.MLOPS.EVAL_LOG (
    MODEL_NAME       STRING,
    DEV_VERSION      STRING,
    QA_VERSION       STRING,
    CANDIDATE_METRIC FLOAT,
    INCUMBENT_METRIC FLOAT,
    METRIC_NAME      STRING,
    PASSED           BOOLEAN,
    EVALUATED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CI_RUN_ID        STRING,
    CI_COMMIT_SHA    STRING
);

GRANT OWNERSHIP ON TABLE MLOPS_QA.MLOPS.EVAL_LOG TO ROLE MLOPS_QA_ROLE COPY CURRENT GRANTS;

-- Every PROD promotion is logged here by prod_deploy.py. This is the ONLY
-- window QA has into PROD (a single narrow SELECT grant on this table below)
-- -- QA never gets any grant on PROD's model registry itself.
CREATE TABLE IF NOT EXISTS MLOPS_PROD.MLOPS.MODEL_PROMOTIONS (
    MODEL_NAME    STRING,
    VERSION_NAME  STRING,
    METRIC_NAME   STRING,
    METRIC_VALUE  FLOAT,
    PROMOTED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    PROMOTED_BY   STRING,
    CI_RUN_ID     STRING,
    CI_COMMIT_SHA STRING
);

GRANT OWNERSHIP ON TABLE MLOPS_PROD.MLOPS.MODEL_PROMOTIONS TO ROLE MLOPS_PROD_ROLE COPY CURRENT GRANTS;

GRANT USAGE ON DATABASE MLOPS_PROD       TO ROLE MLOPS_QA_ROLE;
GRANT USAGE ON SCHEMA   MLOPS_PROD.MLOPS TO ROLE MLOPS_QA_ROLE;
-- qa_evaluate.py reads the incumbent's holdout_accuracy from the PROD model's
-- DEFAULT version metadata. The model is created by prod_deploy.py, so grant
-- on current and future models.
GRANT USAGE ON ALL MODELS    IN SCHEMA MLOPS_PROD.MLOPS TO ROLE MLOPS_QA_ROLE;
GRANT USAGE ON FUTURE MODELS IN SCHEMA MLOPS_PROD.MLOPS TO ROLE MLOPS_QA_ROLE;

-- Note: prod_deploy.py also reads MLOPS_QA.MLOPS.EVAL_LOG to fetch the
-- candidate's recorded metric -- no separate grant needed for that; it's
-- already covered by MLOPS_PROD_ROLE inheriting MLOPS_QA_ROLE above.

-- ----------------------------------------------------------------------------
-- 6. Human user -- DEV only
--    Replace NNIELSEN with your own username.
-- ----------------------------------------------------------------------------
GRANT ROLE MLOPS_DEV_ROLE TO USER NNIELSEN;

-- ----------------------------------------------------------------------------
-- 7. CI/CD service users -- one per environment
--
--    Created here WITHOUT any authentication method. Each CI platform then
--    attaches its own named workload identity (OIDC) to these same users via
--    ALTER USER ... ADD WORKLOAD IDENTITY in setup/<platform>/cicd.sql. A user
--    can hold up to 10 workload identities, so GitHub Actions and
--    Azure DevOps can all authenticate as MLOPS_QA_SVC / MLOPS_PROD_SVC side
--    by side, each bound to its own environment / branch / service connection.
--
--    Until at least one cicd.sql has been run, nothing can log in as these
--    users (no password, no key pair, no workload identity).
-- ----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS MLOPS_QA_SVC
  TYPE              = SERVICE
  DEFAULT_WAREHOUSE = MLOPS_WH
  DEFAULT_ROLE      = MLOPS_QA_ROLE
  COMMENT           = 'QA CI/CD service user. Authenticates only via per-platform OIDC workload identities (see setup/<platform>/cicd.sql).';

GRANT ROLE MLOPS_QA_ROLE TO USER MLOPS_QA_SVC;

CREATE USER IF NOT EXISTS MLOPS_PROD_SVC
  TYPE              = SERVICE
  DEFAULT_WAREHOUSE = MLOPS_WH
  DEFAULT_ROLE      = MLOPS_PROD_ROLE
  COMMENT           = 'PROD CI/CD service user. Authenticates only via per-platform OIDC workload identities (see setup/<platform>/cicd.sql).';

GRANT ROLE MLOPS_PROD_ROLE TO USER MLOPS_PROD_SVC;
