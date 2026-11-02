# GitHub Actions setup

## Prerequisites

1. **Create GitHub Environments** `qa` and `prod` in the repo settings
   (Settings > Environments).
2. **Lock `prod`** to the `main` branch only (Deployment branches rule).
3. **Find your GitHub numeric IDs** (needed for the OIDC subject claim):
   ```bash
   gh api repos/<OWNER>/<REPO> --jq '{repository_owner_id: .owner.id, repository_id: .id}'
   ```
4. **Configure GitHub Actions secrets** (Settings > Secrets and variables > Actions):
   - `SNOWFLAKE_ACCOUNT` — your Snowflake account identifier
   - `SNOWFLAKE_WAREHOUSE` — `MLOPS_WH`

## Snowflake setup

```bash
# 1. Run the common setup (warehouse, roles, DBs, datasets, human user)
#    Paste into a Snowsight worksheet as ACCOUNTADMIN
cat setup/common.sql

# 2. Add the GitHub OIDC workload identities to the service users
#    Replace <OWNER>, <OWNER_ID>, <REPO>, <REPO_ID> placeholders first.
#    Re-running is safe: if the same ISSUER + SUBJECT already exists, the ADD
#    fails with error 099706 and nothing changes. Check what's registered with:
#    SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_QA_SVC;
cat setup/github/cicd.sql
```

## Pipeline files

| File                                | Trigger                                    | What it does                               |
| ----------------------------------- | ------------------------------------------ | ------------------------------------------ |
| `.github/workflows/qa-eval.yml`     | PR into `qa` (notebooks/scripts changes)   | Evaluates DEV candidate against QA holdout |
| `.github/workflows/prod-deploy.yml` | Push to `main` (notebooks/scripts changes) | Promotes QA_PASSED to PROD default         |

## Network policy

GitHub Actions uses Snowflake's managed network rule
`SNOWFLAKE.NETWORK_SECURITY.GITHUBACTIONS_GLOBAL` — no manual IP management needed.

## References

- [Snowflake CLI GitHub Action](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action)
- [Workload identity federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation)
