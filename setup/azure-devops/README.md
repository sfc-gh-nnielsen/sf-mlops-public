# Azure DevOps setup

How to run the sf-mlops DEV → QA → PROD pipeline from **Azure DevOps Pipelines**.
The pipelines authenticate as the Snowflake service users (`MLOPS_QA_SVC`,
`MLOPS_PROD_SVC`), each through its own named OIDC workload identity.

| Pipeline file                     | Runs when                                          | Snowflake identity                    |
| --------------------------------- | -------------------------------------------------- | ------------------------------------- |
| `azure-pipelines/qa-eval.yml`     | PR into `qa` (via Build Validation policy, step 7) | `MLOPS_QA_SVC` via `snowflake-qa`     |
| `azure-pipelines/prod-deploy.yml` | Push to `main` touching `notebooks/` or `scripts/` | `MLOPS_PROD_SVC` via `snowflake-prod` |

Do the steps in order. Steps 1–3 happen in Azure DevOps / Azure, step 4 in
Snowflake, steps 5–8 back in Azure DevOps.

---

## 1. Push the code to Azure Repos

Create a repository in your Azure DevOps project and push this code to it:

```bash
git remote add origin https://<ADO_ORG>@dev.azure.com/<ADO_ORG>/<ADO_PROJECT>/_git/sf-mlops
git push -u origin --all
```

If `origin` already points somewhere else, use another remote name and pass it
to `git push` instead.

Authenticate with an Azure DevOps personal access token (scope **Code: Read &
write**) as the password, or let Git Credential Manager handle it.

## 2. Install the Snowflake CLI extension

Install **[DevOps for Snowflake CLI](https://marketplace.visualstudio.com/items?itemName=snowflake.build-release-task)**
(publisher: Snowflake, ID `snowflake.build-release-task`, public preview) from
the Visual Studio Marketplace: open the link → **Get it free** → select your
organization → **Install**. Alternatively, **Organization settings →
Extensions → Browse marketplace** and search for "DevOps for Snowflake CLI".

It provides the `ConfigureSnowflakeCLI@1` task used by every pipeline.
Installing requires organization-level permission to manage extensions.

## 3. Create two service connections

These are what bind a pipeline run to a Snowflake identity: the OIDC token
Azure DevOps issues for a connection carries that connection's own subject, and
Snowflake only accepts it for the matching workload identity. Name them
**`snowflake-qa`** and **`snowflake-prod`** — the pipeline YAML refers to them
by these names (`connectedServiceName`).

For each of `snowflake-qa` and `snowflake-prod`:

1. **Project settings → Service connections → New service connection →
   Azure Resource Manager**.
2. Choose **Workload identity federation** as the credential (not a secret).
   The automatic option creates the Entra ID app registration and federated
   credential for you; the manual option lets you use an existing app
   registration. Snowflake's extension requires an Azure Resource Manager
   connection with workload identity federation — see the
   [Azure docs](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure)
   for the scope options available to you.
3. **Service connection name:** `snowflake-qa` (or `snowflake-prod`).
4. Leave **Grant access permission to all pipelines** unchecked — you'll
   authorize each pipeline individually on its first run (step 6).
5. Save, then open the connection and note its **Issuer** and **Subject
   identifier**. You need both for step 4.

The connection doesn't need any Azure role assignments — it's only used to mint
an OIDC token for Snowflake.

## 4. Register the identities in Snowflake

Edit `setup/azure-devops/cicd.sql` and paste each connection's **Issuer** and
**Subject identifier** (from step 3) into its `ADD WORKLOAD IDENTITY`
statement — `snowflake-qa` into `ADO_QA`, `snowflake-prod` into `ADO_PROD`.
Copy them verbatim; they must match the token exactly, including case. The two
connections normally share the issuer but have **different** subjects.

Which format you see depends on when the connection was created:

|          | Newer connections                                     | Older connections                        |
| -------- | ----------------------------------------------------- | ---------------------------------------- |
| Issuer   | `https://login.microsoftonline.com/<tenant-id>/v2.0`  | `https://vstoken.dev.azure.com/<id>`     |
| Subject  | `/eid1/c/pub/t/<…>/a/<…>/sc/<org-id>/<connection-id>` | `sc://<org>/<project>/<connection-name>` |
| Audience | `fb60f99c-7a34-4190-8149-302f77469936`                | `api://AzureADTokenExchange`             |

Snowflake's docs show the older format; use whatever your connection shows. If
authentication fails, print the token's actual claims with the debug step under
**Troubleshooting** and use those.

**Audience (`OIDC_AUDIENCE_LIST`).** Both formats target the same Microsoft
application, **AAD Token Exchange Endpoint** — newer connections put its app ID
(`fb60f99c-7a34-4190-8149-302f77469936`) in the token's `aud`, older ones its
URI (`api://AzureADTokenExchange`, the value in Snowflake's docs). It's the same
for every service connection, so `cicd.sql` lists both and works either way:

```sql
OIDC_AUDIENCE_LIST = ('api://AzureADTokenExchange', 'fb60f99c-7a34-4190-8149-302f77469936')
```

It is **not** the connection's app registration client ID and **not** the
service connection ID. If authentication fails with _"JWT contains an invalid
audience ('aud') claim. The JWT's audience is [<value>]…"_, that `<value>` is
what the token carries — add it to the list.

QA and PROD stay separated by their **subjects** (unique per service
connection), not by the audience.

Keep `TYPE = OIDC`. Then run the script as ACCOUNTADMIN. An existing identity
can't be changed in place — to fix one, `REMOVE WORKLOAD IDENTITY` it and run the
`ADD` again (commands at the end of `cicd.sql`).

Run `setup/common.sql` first (it creates the service users).

Then run `setup/azure-devops/cicd.sql`, it adds identities named `ADO_QA` / `ADO_PROD`.

Verify:

```sql
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER MLOPS_QA_SVC;
-- expect ADO_QA, ACTIVE
```

## 5. Create the variable group

**Pipelines → Library → + Variable group**, name it **`sf-mlops`** (the
pipelines reference it by that name):

| Variable              | Value                                              | Secret?  |
| --------------------- | -------------------------------------------------- | -------- |
| `SNOWFLAKE_ACCOUNT`   | Account identifier, e.g. `SFPSCOGS-NNIELSEN_AWS_1` | optional |
| `SNOWFLAKE_WAREHOUSE` | `MLOPS_WH`                                         | no       |

## 6. Create the two pipelines

For each of the two YAML files in `azure-pipelines/`:

1. **Pipelines → New pipeline → Azure Repos Git →** `sf-mlops` **→ Existing
   Azure Pipelines YAML file** → pick the branch (`main`) and the path, e.g.
   `/azure-pipelines/qa-eval.yml`.
2. **Save** (not Run), then rename it via **⋯ → Rename/move**:
   `sf-mlops-qa-eval`, `sf-mlops-prod-deploy`.
3. The first run will pause with **"This pipeline needs permission to access
   a resource"** for the service connection and the variable group — click
   **View → Permit**. One-time per pipeline per resource.

## 7. Branch policies (PR gating)

In Azure DevOps PR builds happen through a **Build Validation** branch policy. This is required for `sf-mlops-qa-eval` to run on PRs.

**Repos → Branches → `qa` → ⋯ → Branch policies:**

- **Require a minimum number of reviewers** (optional for a demo).
- **Build Validation → +**:
  - Build pipeline: `sf-mlops-qa-eval`
  - Path filter: `/notebooks/*; /scripts/*`
  - Trigger: Automatic · Policy requirement: **Required** · Build expiration:
    _Immediately when `qa` is updated_

**Repos → Branches → `main` → ⋯ → Branch policies:**

- **Require a minimum number of reviewers** — this is the human review gate
  before PROD. Setting any policy on `main` also blocks direct pushes.

## 8. Lock the PROD identity to `main`

This is what stops a pipeline run from any other branch from obtaining a PROD token.

**Project settings → Service connections → `snowflake-prod` → ⋯ → Approvals
and checks → + → Branch control:**

- Allowed branches: `refs/heads/main`
- Check **Verify branch protection** (requires the `main` policy from step 7).

Optionally also add an **Approvals** check here for a manual sign-off before
every PROD promotion.

Leave `snowflake-qa` without a branch-control check. QA runs on PR builds,
whose source is `refs/pull/<id>/merge`, so restricting it to `refs/heads/qa`
would block them.

---

## Testing it

1. Train in DEV (notebook as `MLOPS_DEV_ROLE`), commit, push to `dev`.
2. Open a PR `dev → qa` in Azure Repos → `sf-mlops-qa-eval` runs as the
   required check. Verify `MLOPS_QA.MLOPS.EVAL_LOG` and the `QA_PASSED` alias.
3. Complete the PR, then open and complete `qa → main` → `sf-mlops-prod-deploy`
   runs on the push to `main`.

`EVAL_LOG` / `MODEL_PROMOTIONS` record the Azure build ID (`BUILD_BUILDID`) and
commit (`BUILD_SOURCEVERSION`) in `CI_RUN_ID` / `CI_COMMIT_SHA`.

## Network policy

Only needed if your account restricts inbound IPs. Azure DevOps has no
Snowflake-managed network rule. Use the commented block in `cicd.sql` to
create a policy for the service users, scoped per user rather than
account-wide. A user can have only **one** network policy, so add further
allowed ranges to that policy instead of creating a second one.
Microsoft-hosted agent ranges are large and change; self-hosted agents with a
static egress IP give a tighter allowlist.

## Troubleshooting

| Symptom                                                   | Likely cause                                                                                                                                                                                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `qa-eval` never runs on a PR                              | No Build Validation policy on `qa` (step 7)                                                                                                                                                                                   |
| Run paused, "needs permission"                            | Permit the service connection / variable group (step 6.3)                                                                                                                                                                     |
| Auth failure in `snow connection test`                    | ISSUER/SUBJECT in Snowflake doesn't match the token exactly (wrong format, QA/PROD subjects swapped, or the connection was recreated) — print the claims with the step below                                                  |
| "JWT contains an invalid audience ('aud') claim"          | `OIDC_AUDIENCE_LIST` doesn't contain the token's `aud`. The error prints the actual audience; for newer connections it's `fb60f99c-…` (AAD Token Exchange Endpoint). REMOVE and re-ADD the identity with both values (step 4) |
| "No OIDC provider detected … Available providers: github" | Harmless noise from `snow` auto-detection; the token is still passed via `SNOWFLAKE_TOKEN`                                                                                                                                    |
| `prod-deploy` blocked by a check                          | Expected if not on `main` — branch control (step 8)                                                                                                                                                                           |
| `SNOWFLAKE_TOKEN` empty in a script step                  | Step is missing `env: SNOWFLAKE_TOKEN: $(SNOWFLAKE_TOKEN)`                                                                                                                                                                    |

To see the exact `iss` / `sub` / `aud` values Azure DevOps puts in the token
(and compare them with the workload identity in Snowflake), add this step
temporarily after `ConfigureSnowflakeCLI@1`:

```yaml
- bash: |
    echo "$SNOWFLAKE_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -m json.tool
  displayName: "Debug: inspect OIDC token claims"
  env:
    SNOWFLAKE_TOKEN: $(SNOWFLAKE_TOKEN)
```

It prints the token's claims, not the signature. Even so, the claims list your
tenant ID, organization and project, so remove the step once the identities
match and you no longer need it.

## References

- [Snowflake CLI Azure DevOps Extension](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/azure-devops-extension) (public preview)
- [DevOps for Snowflake CLI — Marketplace listing](https://marketplace.visualstudio.com/items?itemName=snowflake.build-release-task)
- [ALTER USER … ADD WORKLOAD IDENTITY](https://docs.snowflake.com/en/sql-reference/sql/alter-user-add-workload-identity)
- [Workload identity federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation)
