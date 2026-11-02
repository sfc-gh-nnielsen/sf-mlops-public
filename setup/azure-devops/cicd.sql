-- ============================================================================
-- sf-mlops : Azure DevOps CI/CD setup
--
-- Run AFTER setup/common.sql (which creates MLOPS_QA_SVC / MLOPS_PROD_SVC).
-- Attaches a named Azure DevOps OIDC workload identity to each service user
-- and, optionally, a network policy for Azure DevOps agents.
--
-- Adds one OIDC workload identity per service user. Each user can hold several
-- identities, so re-running this only adds the ones that are missing.
--
-- Prerequisites (see setup/azure-devops/README.md for the full walkthrough):
--   - Two Azure Resource Manager service connections using workload identity
--     federation, named `snowflake-qa` and `snowflake-prod`.
--
-- ISSUER / SUBJECT: copy them from each service connection's details page in
-- Azure DevOps ("Issuer" and "Subject identifier"). They must match the token
-- exactly (case-sensitive), and each connection has its OWN subject.
--
-- Azure DevOps has two formats, depending on when the connection was created:
--   newer:  ISSUER  = https://login.microsoftonline.com/<tenant-id>/v2.0
--           SUBJECT = /eid1/c/pub/t/<...>/a/<...>/sc/<org-id>/<connection-id>
--   older:  ISSUER  = https://vstoken.dev.azure.com/<id>
--           SUBJECT = sc://<org>/<project>/<connection-name>
-- Use whichever your connection shows. If unsure what the token actually
-- carries, print its claims (debug step in the README) and use those.
--
-- OIDC_AUDIENCE_LIST must contain every value of the token's `aud` claim. Both
-- connection formats target the same Microsoft app, "AAD Token Exchange
-- Endpoint", but express it differently:
--   newer connections: its app ID  fb60f99c-7a34-4190-8149-302f77469936
--   older connections: its URI     api://AzureADTokenExchange  (Snowflake's docs)
-- The statements below list BOTH, so they work for either format. The value
-- is the same for every service connection -- it is NOT the connection's app
-- registration client ID, and NOT the service connection ID. A wrong audience
-- fails with "JWT contains an invalid audience ('aud') claim. The JWT's
-- audience is [<value>]..." -- that <value> is what the token actually carries.
--
-- Reference: https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/azure-devops-extension
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- Workload identities
-- ----------------------------------------------------------------------------

-- QA -- only pipelines using the `snowflake-qa` service connection
ALTER USER MLOPS_QA_SVC ADD WORKLOAD IDENTITY ADO_QA
  TYPE               = OIDC
  ISSUER             = 'https://login.microsoftonline.com/<tenant_id>/v2.0'
  SUBJECT            = '/eid1/c/pub/t/<...>/a/<...>/sc/<org-id>/<connection-id>'
  OIDC_AUDIENCE_LIST = ('api://AzureADTokenExchange', 'fb60f99c-7a34-4190-8149-302f77469936');

-- PROD -- only pipelines using the `snowflake-prod` service connection
-- (restrict that connection to `main` in Azure DevOps -- see README)
ALTER USER MLOPS_PROD_SVC ADD WORKLOAD IDENTITY ADO_PROD
  TYPE               = OIDC
  ISSUER             = 'https://login.microsoftonline.com/aa344178-8c84-4f72-9e99-3d56f410305d/v2.0'
  SUBJECT            = '/eid1/c/pub/t/<...>/a/<...>/sc/<org-id>/<connection-id>'
  OIDC_AUDIENCE_LIST = ('api://AzureADTokenExchange', 'fb60f99c-7a34-4190-8149-302f77469936');

-- Verify
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_QA_SVC;
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_PROD_SVC;

-- Changing an identity (e.g. a wrong audience): ISSUER, SUBJECT and
-- OIDC_AUDIENCE_LIST can't be altered in place -- REMOVE it, then re-run
-- the ADD above:
--   ALTER USER MLOPS_QA_SVC   REMOVE WORKLOAD IDENTITY ADO_QA;
--   ALTER USER MLOPS_PROD_SVC REMOVE WORKLOAD IDENTITY ADO_PROD;

-- ----------------------------------------------------------------------------
-- Network policy (optional -- only needed if your account restricts inbound IPs)
--
-- Azure DevOps has NO Snowflake-managed network rule. Microsoft-hosted agents
-- use large, changing Azure IP ranges; for a tight allowlist use self-hosted
-- agents with a static egress IP. Ranges for Microsoft-hosted agents:
--   https://learn.microsoft.com/en-us/azure/devops/organizations/security/allow-list-ip-url
-- ----------------------------------------------------------------------------

CREATE NETWORK RULE IF NOT EXISTS MLOPS_DEV.MLOPS.MLOPS_ADO_AGENT_RULE
  MODE = INGRESS
  TYPE = IPV4
  VALUE_LIST = ('<YOUR_ADO_AGENT_IP_RANGE>');

-- If the policy already exists:
ALTER NETWORK POLICY MLOPS_CICD_NETWORK_POLICY
  ADD ALLOWED_NETWORK_RULE_LIST = ('MLOPS_DEV.MLOPS.MLOPS_ADO_AGENT_RULE');

-- Otherwise, create it and attach it:
CREATE NETWORK POLICY MLOPS_CICD_NETWORK_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('MLOPS_DEV.MLOPS.MLOPS_ADO_AGENT_RULE');

ALTER USER MLOPS_QA_SVC   SET NETWORK_POLICY = MLOPS_CICD_NETWORK_POLICY;
ALTER USER MLOPS_PROD_SVC SET NETWORK_POLICY = MLOPS_CICD_NETWORK_POLICY;
