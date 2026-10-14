---
name: terraform-gcs-state
description: Update, sync, migrate or verify the Terraform state for the HR deployment in the GCS bucket terraform-hr-bucket under the super-terraform/ folder, enforcing the state rules in docs/TERRAFORM_BEST_PRACTICES.md. Use when the user asks to push, update, refresh, migrate, back up or verify Terraform state in GCS, or after terraform apply to confirm the remote state is current.
---

# Terraform state in GCS

Remote state for this project lives here (defaults; confirm with the user and the `backend` block in `main.tf`):

- **Bucket:** `gs://terraform-hr-bucket` (owned by project `super-terraform`, ID `project-0732d7b6-0b40-4bcb-9d6`)
- **Folder (prefix):** `super-terraform/`, so the state object is `gs://terraform-hr-bucket/super-terraform/default.tfstate`
- **Managed project:** `hr-deployment-prod`, under organization `varakwelfaresociety-org` (551525761061)

Run every command from the Terraform directory: `/Users/manishsingh/Documents/ziniapps/hr-deployment files/terraform` (quote the path, it has a space). The standard is `docs/TERRAFORM_BEST_PRACTICES.md` (sections 4, 5, 6 and 8): read it at the start of every run. A failed check below blocks the step. Never skip one silently. If a check can't run, say so and get the user's explicit approval to continue, and record the waiver in `docs/PROGRESS.md`.

## Steps

1. **Check credentials and quota project.** The ADC quota project must be a live project that can serve the bucket, not a deleted one, or the backend fails with `404 The requested project was not found`.
   ```
   gcloud config get-value account
   gcloud projects describe <bucket's project> --format="value(lifecycleState)"   # must be ACTIVE
   gcloud auth application-default set-quota-project project-0732d7b6-0b40-4bcb-9d6
   ```
   The account needs `roles/storage.objectAdmin` (or equivalent) on the bucket.

2. **Check the bucket against the best practices.** All of these must pass:
   ```
   gcloud storage buckets describe gs://terraform-hr-bucket \
     --format="json(versioning_enabled,uniform_bucket_level_access,public_access_prevention,location)"
   gcloud storage buckets get-iam-policy gs://terraform-hr-bucket
   ```
   - `versioning_enabled` is `true`. If not, offer `gcloud storage buckets update gs://terraform-hr-bucket --versioning`.
   - `uniform_bucket_level_access` is `true`. If not, offer `--uniform-bucket-level-access`.
   - `public_access_prevention` is `enforced`. If not, offer `--public-access-prevention`.
   - IAM is restricted: no `allUsers` or `allAuthenticatedUsers`, and only the people or service accounts that run Terraform have write access. List any extra members and ask the user whether they should stay.
   - Offer a lifecycle rule that keeps a sensible number of old state versions so versioning doesn't grow without limit. Don't set one without the user's agreement.

3. **Check the backend block** in `main.tf`:
   ```hcl
   backend "gcs" {
     bucket = "terraform-hr-bucket"
     prefix = "super-terraform"
   }
   ```
   The bucket must exist, and the prefix should be unique per environment (one state per environment: never share a prefix between dev, staging and prod). If the prefix differs from the one the user wants, tell the user it moves the state, and get confirmation before migrating. Since backend blocks can't use variables, an override is passed at init with `-backend-config="bucket=..." -backend-config="prefix=..."` and should be documented in `docs/PROGRESS.md`.

4. **Check that state isn't local or committed.**
   - No `terraform.tfstate` with resources remains in the folder. An empty one (`"resources": []`) left from before the migration is safe to leave, but mention it.
   - If this is a git repo: `git ls-files | grep -E '\.tfstate|\.tfvars|tfplan'` must return nothing, and `.gitignore` must contain `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `*.tfvars.json`, `tfplan`, `crash.log`, `override.tf`, `override.tf.json`. `.terraform.lock.hcl` stays committed. If it isn't a git repo, tell the user and offer `git init` and the `.gitignore`.
   - State contains sensitive values. Treat it like a secret, and never copy it into the repo, chat or another bucket.

5. **Back up before any state-changing operation.** Versioning keeps history, but record the current generation first so you can roll back:
   ```
   gcloud storage ls -l -a gs://terraform-hr-bucket/<prefix>/default.tfstate
   ```
   Note the generation number in your answer. For a migration, also save a local copy with `terraform state pull > <scratchpad path>/state-backup.json`, outside the repo and out of git, and tell the user it holds secrets and should be deleted afterwards.

6. **Migrate or refresh the state.** Show what will happen and get approval before each.
   - Backend or prefix changed: `terraform init -migrate-state`. Use `-force-copy` only after the user agrees to overwrite the destination. Check the destination first (`gcloud storage ls gs://terraform-hr-bucket/<new prefix>/`): if it already holds state, stop and ask.
   - Unchanged: `terraform init`, then `terraform plan -refresh-only -out=tfplan`. Read the whole plan and report every drifted resource. If it shows anything to destroy or replace, stop and ask. Apply only the saved plan after approval: `terraform apply tfplan`. Delete `tfplan` afterwards, because it may contain secrets.
   - Run `terraform fmt -recursive -check` and `terraform validate` before the plan. A failure blocks this step.

7. **Verify the result.**
   ```
   gcloud storage ls -l gs://terraform-hr-bucket/<prefix>/
   terraform state list
   terraform plan -detailed-exitcode
   ```
   Report the object size, update time and generation, and the number of resources in state. Expect `default.tfstate`. `terraform plan` should report no changes (exit code 0). Exit code 2 means drift or pending changes: report it, and don't fix it as part of this skill.
   If state migrated, also confirm a lock is not left behind: `gcloud storage ls gs://terraform-hr-bucket/<prefix>/ | grep tflock` should return nothing.

8. **Record it.** Update `docs/PROGRESS.md` with the state location, what changed, the generation, and any waived check. Walk the state items of the pre-apply checklist (remote and backed up) and report each as pass, fail or waived.

9. **Clean up the old location** only if the user asks. If the state was migrated from another prefix (for example `terraform/state/`), list it first, confirm the new state is correct, and delete only after explicit confirmation. Versioning keeps old generations anyway.

## Rules

- Never edit or delete the state object by hand. Use `terraform state mv`, `terraform state rm` and `terraform import` when state has to change.
- Never run `terraform destroy`, and never run `terraform apply -auto-approve`. This skill only touches state. The one allowed apply is the saved refresh-only plan, with the user's go-ahead.
- Make small, reviewable changes. One concern per run.
- If you see `Error acquiring the state lock`, read the lock ID and who holds it, and ask the user before running `terraform force-unlock <id>`. Another run may still be active.
- Don't copy state files elsewhere or commit them. They can contain secrets.
- If a command fails with a 404 or permission error, recheck step 1 and that the account has access to the bucket.
