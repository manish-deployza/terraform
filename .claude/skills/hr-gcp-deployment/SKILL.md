---
name: hr-gcp-deployment
description: Configurable, confirm-before-create flow to build the HR deployment on GCP with Terraform, enforcing docs/TERRAFORM_BEST_PRACTICES.md at every gate. Asks the user for every setting (project, org, billing, region, VM, image, state bucket), shows a summary, then creates the project, network, Packer image (Cloud Build) and VM step by step with approval at each stage. Use when the user asks to create, rebuild, redeploy or recreate the HR project, image or VM.
---

# HR deployment on GCP: configurable, gated flow

```
 ask settings ─► summary + approval ─► prereqs ─► repo hygiene ─► state backend ─► [GATES] ─► project + APIs ─► network ─► image ─► VM ─► org move ─► verify ─► record
```

Nothing is created until the user has approved the summary, and each creating step needs its own approval. Values below are **defaults to offer, not facts to assume**. Ask every time.

Run Terraform from the directory that holds `main.tf` and `project.tf` (here `/Users/manishsingh/Documents/ziniapps/hr-deployment files/terraform`; quote the path, it has a space). Packer files are in `../vm_images/`. The standard is `docs/TERRAFORM_BEST_PRACTICES.md`: read it at the start of every run and treat a failed gate as a stop, not a warning.

## The gates (run before EVERY plan/apply in steps 5, 6, 8 and 9)

A gate failure blocks the step. Report the failure and its fix, and ask the user how to proceed. Never skip a gate silently. If a gate can't run (for example a tool isn't installed), say so, and get the user's explicit approval to continue without it, then record that waiver in `docs/PROGRESS.md`.

**Gate A: code checks**
1. `terraform fmt -recursive -check`. If it fails, run `terraform fmt -recursive` and show the diff.
2. `terraform validate`.
3. Security scan: run whichever of `trivy config .`, `tfsec .` or `checkov -d .` is installed (`which trivy tfsec checkov`). If none is installed, tell the user, offer `brew install trivy`, and don't continue without an install or an explicit waiver. Show HIGH and CRITICAL findings, and don't continue until the user accepts or fixes each one.
4. Secrets: grep the `.tf` files, `terraform.tfvars`, `startup.sh` and `../vm_images/` for passwords, tokens, private keys and `metadata_startup_script` containing secrets. Any hit blocks the step.
5. Firewall: no rule may open `0.0.0.0/0` except ports 80 and 443 on tag `hr-web`. SSH, MySQL (3306) and Tomcat (8080) must never be open to the world.
6. IAM: no `roles/owner` or `roles/editor` granted by this config, and the VM must use the dedicated `hr-server1-sa`, never the default compute SA.
7. Conventions (check the files, fix by asking the user):
   - Every variable has `description` and `type`; constrained values (CIDRs, project ID, region, machine type) have `validation` blocks. Sensitive values are `sensitive = true` with no default.
   - No hard-coded project IDs, regions or CIDRs inside resources.
   - Resource names are `snake_case` without the type repeated; GCP names are lowercase with the `hr-` prefix.
   - Outputs have a `description`.
   - Collections use `for_each`; `count` is only used for on/off toggles.
   - Labels (`app`, `env`, `owner`) on every resource that supports them, including the VM, disk and IP. Offer to add any that are missing.
   - No `provisioner` blocks. Any startup script is idempotent.
   - Provider is pinned with `~>`, `required_version` is set, and `.terraform.lock.hcl` exists.
8. Production protection: the VM has `deletion_protection = true` and stateful resources (disks, databases) have `lifecycle { prevent_destroy = true }`. If missing, tell the user, and ask whether to add them. Adding `deletion_protection` means the VM must be updated, so show the plan.
9. Cost check: machine type and region are free-tier eligible, or the user has accepted the cost. Any static IP must be attached to something. Review the plan for billable resources the user didn't expect.

**Gate B: repo and state hygiene**
1. The folder is a git repo (`git rev-parse --is-inside-work-tree`). If not, offer `git init` and a `.gitignore` with exactly the entries in the best-practices doc (`.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `*.tfvars.json`, `tfplan`, `crash.log`, `override.tf`, `override.tf.json`). Commit `.terraform.lock.hcl`. Never commit state, plan files or tfvars.
2. State is remote (GCS), not local. No `terraform.tfstate` with resources should remain in the folder. The bucket has versioning, uniform bucket-level access and public access prevention on, and restricted IAM. Check with `gcloud storage buckets describe gs://<bucket> --format="json(versioning_enabled,uniform_bucket_level_access,public_access_prevention)"` and `gcloud storage buckets get-iam-policy gs://<bucket>`. Fix or get a waiver. Use the `terraform-gcs-state` skill for state work.
3. One state per environment: the prefix is unique per environment (for example `hr-prod`). Never share a prefix between environments.

**Gate C: plan review and apply**
1. `terraform plan -out=tfplan` (add the same `-target` flags as the step). Read the whole plan.
2. Show the user the plan summary and list every `destroy` and every `-/+` replace with the `# forces replacement` reason. Unexpected destroys or replaces block the step. A replaced VM loses its disk.
3. Ask for approval, then `terraform apply tfplan`. **Never** use `-auto-approve`, never apply without the saved plan, and never run `terraform destroy` from this skill.
4. If the plan is older than the last config change, or anything changed after approval, delete `tfplan` and replan. Delete `tfplan` after the apply (it can contain secrets), and make sure it's gitignored.

**Gate D: after the change**
1. `terraform plan` must report no changes (no drift). If it does, investigate before continuing.
2. Update `docs/PROGRESS.md` (project, IP, status, change log, any waived gate).
3. Walk the pre-apply checklist from the best-practices doc (section 10) and report each item as pass, fail or waived.

## Step 0: Ask for every setting

Use AskUserQuestion (up to 4 questions per call, several calls). Offer the default first, marked as recommended. Never fill in a value the user hasn't confirmed. "Other" takes the user's text.

| Setting | Terraform variable | Default to offer | Notes |
|---|---|---|---|
| Project ID | `project` | `hr-deployment-prod` | Globally unique, 6-30 chars, lowercase letters, digits, hyphens. A deleted project's ID is reserved for 30 days. |
| Project display name | `project_name` | `HR Deployment` | |
| Parent | `org_id` or `folder_id` | org `551525761061` (`varakwelfaresociety-org`) | Options: org, folder, or no parent. Offer real choices from `gcloud organizations list`. Set only one. |
| Billing account | `billing_account` | from `gcloud billing accounts list` | Required to enable Compute. |
| Environment | label `env` and state prefix | `prod` | Each environment gets its own state prefix. |
| Labels | `labels` | `app=hr`, `env=<environment>`, `owner=<ask>` | Ask for the owner. |
| Region / zone | `region`, `zone` | `us-central1` / `us-central1-a` | Always Free e2-micro regions: `us-central1`, `us-east1`, `us-west1`. Warn on others. |
| Machine type | `machine_type` | `e2-micro` | Free tier, 1 GB RAM. Warn that bigger types are billed. |
| Boot disk size (GB) | `disk_size_gb` | `30` | `pd-standard` is the free-tier type. |
| Image family | `image_family` | `hr-ubuntu-stack` | |
| Build the image now? | n/a | Yes | If No, the user must name an existing image family in the project. |
| Tomcat 8080 allowed CIDRs | `tomcat_allowed_cidrs` | none (port closed) | Ask for valid CIDRs. Refuse `0.0.0.0/0` unless the user insists, and explain the risk. |
| VM deletion protection | `deletion_protection` | on | Recommended for prod. |
| APIs to enable | `apis` | compute, iam, cloudresourcemanager, serviceusage, cloudbuild | `cloudbuild` is needed for the image. |
| State bucket | backend `bucket` | `terraform-hr-bucket` | Must already exist. |
| State prefix | backend `prefix` | match `main.tf`; offer `super-terraform` | A change migrates the state. |
| Bucket's project | ADC quota project | `project-0732d7b6-0b40-4bcb-9d6` | Must be live, not pending deletion. |

Read `variables.tf`, `terraform.tfvars` and the `backend` block first, and offer the current values as defaults.

## Step 1: Summary and approval

Print one table with every chosen value, the list of what will be created (project, APIs, service account, IAM roles, static IP, firewall rules, Cloud Build image, VM), a cost note (the static external IP is billed, about $3.65 a month), and the gates that will run. Ask "Create this?" with Yes, Change something and Cancel. Stop on Cancel. Loop on Change.

## Step 2: Write the configuration

- Write answers to `terraform.tfvars` (never commit it; no secrets in it).
- Don't hard-code answers in `.tf` files. The backend block can't use variables, so pass state at init: `terraform init -backend-config="bucket=<bucket>" -backend-config="prefix=<prefix>"`.
- `project.tf` must keep `auto_create_network = true`, because `main.tf` uses the `default` network.
- Keep one definition of each `terraform` block, provider and variable across the `.tf` files.

## Step 3: Prerequisites

```
gcloud auth application-default login
gcloud auth application-default set-quota-project <bucket's project>
```
The quota project must be live, or the backend fails with `404 The requested project was not found`. Packer isn't needed locally. Confirm the signed-in account has the roles needed (project creator, billing user, project mover for an org move).

## Step 4: Repo hygiene and state backend

Run Gate B. Then `terraform init` with the `-backend-config` flags. If the prefix changed, ask before `terraform init -migrate-state`. Review provider changes only with a deliberate `terraform init -upgrade`.

## Step 5: Create the project and APIs

Run Gates A and C with `-target=google_project.this -target=google_project_service.apis`. The targeted apply avoids creating network resources before the project exists.

## Step 6: Create the service account and network

Run Gates A and C for the whole config. This creates the service account, IAM roles, static IP and firewall rules. If the image doesn't exist yet, the VM fails here. Warn the user before applying, and say it's expected when the image is built later. Prefer excluding the VM until step 8 if the image doesn't exist (`-target` the other resources).

## Step 7: Build the image

Ask first. Tell the user this runs Cloud Build in the new project (several minutes, free build minutes), then from `../vm_images`:
```
gcloud builds submit . --project=<project> --config=cloudbuild.yaml --region=<region> \
  --substitutions=_ZONE=<zone>,_IMAGE_FAMILY=<image family>
```
Check `scripts/install.sh` and `cleanup.sh` for secrets first (Gate A, item 4). Poll `gcloud builds list --project=<project> --region=<region>` until `SUCCESS`. On `FAILURE`, read `gcloud builds log <id> --region=<region> --project=<project>`, report, and don't retry blindly. Confirm with `gcloud compute images list --project=<project> --no-standard-images`.

## Step 8: Create the VM

Run Gates A and C. The VM boots from the newest image in the family. A changed image family, machine type or boot disk shows as `-/+` in the plan, and must be explicitly approved. Note the `hr_server1_public_ip` output.

## Step 9: Org move (only when needed)

Set `org_id`, then run Gates A and C. The plan must show an in-place update with 0 to add and 0 to destroy. Needs `roles/resourcemanager.projectMover`. Never destroy and recreate a project to change its parent.

## Step 10: Verify and record

```
terraform state list
gcloud compute instances list --project=<project>
gcloud projects describe <project> --format="value(parent.id)"
gcloud storage ls gs://<bucket>/<prefix>/
```
Check services with `gcloud compute ssh hr-server1 --zone <zone> --tunnel-through-iap` (IAP-only SSH): `systemctl is-active nginx tomcat10 mysql`, listening ports, and `curl -I localhost` and `localhost:8080`. The Tomcat unit is `tomcat10`, not `tomcat9`. Then run Gate D.

## Rules

- Ask before every step that creates, changes or destroys something, and run the gates first.
- Never `terraform apply -auto-approve`, never apply without a saved, reviewed plan, and never destroy from this skill.
- A deleted project holds its ID for 30 days and takes the VM and image with it. Don't offer destroy-and-recreate unless the user insists.
- A rebuilt image only reaches a new VM. An existing VM keeps its disk.
- Never edit state by hand (use `terraform state mv/rm` and `terraform import`), and never copy state or plan files elsewhere.
- Small, reviewable changes: one concern per apply.
- Common errors:
  - `404 ... resource 'projects/<id>' was not found` while creating network resources: the project didn't exist yet. Do step 5 first.
  - `404 ... images/family/<family> not found`: do step 7.
  - `404 ... requested project was not found` from the GCS backend: fix the quota project (step 3).
  - Duplicate provider, `terraform` or variable errors: keep one definition.
