-- ============================================================================
-- sf-mlops : GitHub Actions CI/CD setup
--
-- Run AFTER setup/common.sql (which creates MLOPS_QA_SVC / MLOPS_PROD_SVC).
-- Attaches a named GitHub Actions OIDC workload identity to each service user
-- and, optionally, a network policy for GitHub-hosted runners.
--
-- Safe alongside other platforms: this ADDS an identity, it does not replace
-- anything. An Azure DevOps identity on the same users keeps working.
--
-- Prerequisites on the GitHub side:
--   1. Create GitHub Environments `qa` and `prod` in the repo settings.
--   2. Lock `prod` to the `main` branch only (Deployment branches rule).
--   3. Each workflow job declares `environment:` and
--      `permissions: { id-token: write }`.
--   4. Use `snowflakedb/snowflake-actions@v3` with `use-oidc: true`.
--
-- SUBJECT format (immutable-ID form, used by repos created after mid-2026 or
-- that opted in):
--   repo:<OWNER>@<owner_id>/<REPO>@<repo_id>:environment:<env>
-- Find the numeric IDs with:
--   gh api repos/<OWNER>/<REPO> --jq '{repository_owner_id: .owner.id, repository_id: .id}'
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- Workload identities
-- ----------------------------------------------------------------------------

-- QA -- only jobs running in the GitHub `qa` environment get a matching token
ALTER USER MLOPS_QA_SVC ADD WORKLOAD IDENTITY GITHUB_QA
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:qa';

-- PROD -- only jobs running in the GitHub `prod` environment (locked to main)
ALTER USER MLOPS_PROD_SVC ADD WORKLOAD IDENTITY GITHUB_PROD
  TYPE    = OIDC
  ISSUER  = 'https://token.actions.githubusercontent.com'
  SUBJECT = 'repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:prod';

-- Verify
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_QA_SVC;
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_PROD_SVC;

-- Re-running: ADD fails with 099706 if the same ISSUER+SUBJECT already exists
-- (on any user). That means it's already set up -- nothing to do. To change
-- an identity, REMOVE it and ADD it again:
--   ALTER USER MLOPS_QA_SVC REMOVE WORKLOAD IDENTITY GITHUB_QA;

-- ----------------------------------------------------------------------------
-- Network policy (optional -- only needed if your account restricts inbound IPs)
--
-- Snowflake provides a managed network rule for GitHub Actions runner IPs
-- (SNOWFLAKE.NETWORK_SECURITY.GITHUBACTIONS_GLOBAL). Applied at USER level --
-- this does NOT touch your human user or any account-level policy.
--
-- A user has only ONE network policy, so add any further allowed ranges to
-- this policy (see the commented line) rather than creating a second one.
-- ----------------------------------------------------------------------------
CREATE NETWORK POLICY IF NOT EXISTS MLOPS_CICD_NETWORK_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('SNOWFLAKE.NETWORK_SECURITY.GITHUBACTIONS_GLOBAL')
  COMMENT = 'Allows CI/CD runner IPs to authenticate as the MLOPS CI/CD service users. Scoped per-user, not account-wide.';
-- ALTER NETWORK POLICY MLOPS_CICD_NETWORK_POLICY ADD ALLOWED_NETWORK_RULE_LIST = ('<ADDITIONAL_RULE>');

ALTER USER MLOPS_QA_SVC   SET NETWORK_POLICY = MLOPS_CICD_NETWORK_POLICY;
ALTER USER MLOPS_PROD_SVC SET NETWORK_POLICY = MLOPS_CICD_NETWORK_POLICY;
