# HR Server VM: Build Tracker

Terraform setup for the HR application VM on GCP.

- **Project:** `hr-deployment-prod` (created by Terraform in `project.tf`; replaces the deleted `emp-management-511409`)
- **Region / zone:** `us-central1` / `us-central1-a` (Always Free e2-micro region)
- **Last updated:** 2026-10-14

## Files

Terraform files live in the parent folder (`terraform/`); run all `terraform` commands from there. Docs are in `terraform/docs/`.

| File | Purpose |
|---|---|
| `main.tf` | GCS backend, provider, service account, IAM, static IP, VM, firewall rules |
| `project.tf` | Creates the GCP project (billing, labels) and enables the APIs |
| `variables.tf` | Project ID, region, zone, machine type, disk size, `tomcat_allowed_cidrs` |
| `outputs.tf` | `hr_server1_public_ip` |
| `startup.sh` | Legacy provisioning script. Not used by `main.tf` any more (no `metadata_startup_script`); the VM is provisioned by the Packer image |
| `../vm_images/` | Packer template, `scripts/install.sh`, `scripts/cleanup.sh`, `cloudbuild.yaml` for the image |

## Architecture

- **VM:** `hr-server1`, `e2-micro`, boot disk from the Packer image family `hr-ubuntu-stack` (Ubuntu 24.04, built from `../vm_images/` via Cloud Build), 30 GB `pd-standard` (free-tier eligible)
- **State:** GCS backend `gs://terraform-hr-bucket/terraform/state` (bucket lives in `project-0732d7b6-0b40-4bcb-9d6`, versioning on)
- **IP:** static external IP `hr-server1-external-ip`
- **Network:** `default` VPC, tags `hr-web` and `hr-ssh-iap`
- **Request path:** Internet → nginx (80) → Tomcat 10 on port 8080 (proxy target `127.0.0.1:8080`)
- **Database:** MySQL, bound to `127.0.0.1` only

## Installed software

nginx 1.24, OpenJDK 21 (JDK), Tomcat 10 (`tomcat10` and `tomcat10-admin`), MySQL server, Python 3 (pip, venv, dev, build-essential), git, vim, htop, curl, unzip. Installed by `vm_images/scripts/install.sh`; services are enabled on boot.
`cat` ships with coreutils.

## Firewall

| Rule | Ports | Source | Target tag |
|---|---|---|---|
| `hr-allow-web` | 80, 443 | `0.0.0.0/0` | `hr-web` |
| `hr-allow-ssh-iap` | 22 | `35.235.240.0/20` (IAP) | `hr-ssh-iap` |
| `hr-allow-tomcat` (optional) | 8080 | `tomcat_allowed_cidrs` (default empty = no rule) | `hr-web` |

All rules have firewall logging enabled.

## Security hardening

- [x] SSH only via IAP tunnel
- [x] OS Login on, project-wide SSH keys blocked
- [x] Dedicated service account `hr-server1-sa` (log + metric writer only)
- [x] Shielded VM (Secure Boot, vTPM, integrity monitoring)
- [x] VM `deletion_protection = true` (variable `deletion_protection`). Set it to `false` and apply before any destroy or VM replacement (new image family, machine type, boot disk change), then set it back to `true`
- [x] Labels `app=hr`, `env=prod` on the project, VM and static IP (`labels` variable). `owner` label not set yet
- [x] Input validation on `project`, `region`, `zone`, `disk_size_gb` (10-30 GB) and `tomcat_allowed_cidrs` (valid CIDRs, `0.0.0.0/0` refused)
- [x] Tomcat 8080 closed to the internet by default (firewall only; Tomcat itself listens on all interfaces, `*:8080`)
- [x] MySQL bound to localhost
- [ ] nginx hardening: the image's nginx is a plain reverse proxy. The `Server: nginx/1.24.0` header is visible, and no security headers or dotfile blocking are configured (the old `startup.sh` did that)
- [ ] Automatic security updates (not in the image build script; unverified on the VM)

## Status

- [x] `terraform init` (google provider v5.45.2)
- [x] `terraform validate` passes
- [x] `terraform plan`: 7 to add, 0 to change, 0 to destroy
- [x] `terraform apply` done 2026-10-14 in `hr-deployment-prod`; public IP 34.27.229.172

## Open items / TODO

- [x] Run `terraform apply`
- [ ] Delete the legacy `default-allow-ssh` rule (open to the internet, not managed by Terraform) after confirming IAP SSH works:
  `gcloud compute firewall-rules delete default-allow-ssh`
- [ ] Grant the users who need SSH `roles/iap.tunnelResourceAccessor` and `roles/compute.osLogin`
- [ ] HTTPS: needs a domain pointed at the static IP; then add certbot, an HTTP→HTTPS redirect and HSTS
- [ ] Secure MySQL (`mysql_secure_installation`, dedicated app user instead of root)
- [x] Move Terraform state to a remote GCS backend (versioned; still to do: restrict IAM on the bucket)
- [ ] Deploy the HR app to Tomcat
- [ ] Consider Cloud Armor and a load balancer if the app is public
- [x] ADC quota project set to `project-0732d7b6-0b40-4bcb-9d6` (the old project is pending deletion). Rerun `gcloud auth application-default set-quota-project project-0732d7b6-0b40-4bcb-9d6` if API 404 errors appear
- [x] Verified on the VM (2026-10-14): nginx, `tomcat10` and MySQL active; ports 80 and 8080 listening, MySQL on `127.0.0.1:3306` only; `curl localhost` and `localhost:8080` return HTTP 200. Port 443 not listening (no HTTPS yet). Not yet tested from the public IP
- [ ] Re-apply nginx hardening in `vm_images/scripts/install.sh` (hide version, security headers, block dotfiles) and bind Tomcat to `127.0.0.1`; needs an image rebuild and VM replacement
- [ ] Check whether unattended-upgrades is enabled on the image (not in `install.sh`)

## Useful commands

```
terraform plan
terraform apply
gcloud compute ssh hr-server1 --zone us-central1-a --tunnel-through-iap
```

## Best-practice gaps still open

Measured against `TERRAFORM_BEST_PRACTICES.md`:

- [ ] Security scan (`trivy config .`, `tfsec` or `checkov`): none installed, so the scan gate is waived until one is. `brew install trivy`
- [ ] Folder is not a git repo: run `git init` and add the `.gitignore` from the best-practices doc (state, `*.tfvars`, `tfplan`, `.terraform/`); commit `.terraform.lock.hcl`
- [ ] `owner` label missing (needs a value)
- [ ] Default compute service account has `roles/editor` (the VM itself uses the dedicated `hr-server1-sa`)
- [ ] State bucket checks not yet confirmed: uniform bucket-level access, public access prevention, restricted IAM (versioning is on)
- [ ] Add `prevent_destroy` lifecycle on stateful resources if disks or databases are added later

## Change log

- **2026-10-13:** Installed Terraform and the gcloud CLI, ran `init`, authenticated with ADC.
- **2026-10-13:** Fixed the Tomcat install (universe repo, JDK 17), added git and vim, and made the startup script run once.
- **2026-10-13:** Restricted 8080 behind the `tomcat_allowed_cidrs` variable.
- **2026-10-13:** Hardened the setup: IAP-only SSH, OS Login, service account, Shielded VM, firewall logging, nginx reverse proxy, MySQL localhost bind, unattended-upgrades.
- **2026-10-13:** Moved from `asia-south1` (Mumbai) to `us-central1` / `us-central1-a` to use the Always Free `e2-micro`; boot disk changed to `pd-standard`. Trade-off: higher latency from India. Free tier covers 1 e2-micro, 30 GB standard PD and 1 GB egress/month; the external IP is still billed (~$3.65/month).
- **2026-10-13:** Applied: 7 resources created in us-central1. Public IP 136.71.203.2.
- **2026-10-13:** Moved all Terraform files (including local state and `.terraform/`) from `vm_image/` to `hr-deployment files/terraform/`. Plan unchanged after the move. Pending, not yet applied: startup script edits (headless JDK, Tomcat bound to 127.0.0.1) and disk 10→20 GB; both force a VM replacement.
- **2026-10-13:** Moved `docs/` into `terraform/docs/` and removed the empty `vm_image/` folder.
- **2026-10-14:** Detached from `emp-management-511409` (pending deletion). Terraform now creates project `hr-deployment-prod` (billing account attached, auto-created default network), enables the APIs (compute, iam, resourcemanager, serviceusage, cloudbuild) and creates the `hr-server1-sa` service account. Added `depends_on` the API enablement for network resources.
- **2026-10-14:** State moved to the GCS backend `gs://terraform-hr-bucket`; versioning enabled.
- **2026-10-14:** Built the `hr-ubuntu-stack` image in the new project with Cloud Build (`vm_images/cloudbuild.yaml`), then applied: VM `hr-server1` created, public IP 34.27.229.172.
- **2026-10-14:** Verified the running VM over IAP SSH and corrected this doc: the image has Ubuntu 24.04, OpenJDK 21 and Tomcat 10 (unit `tomcat10.service`), not the Ubuntu 22.04 / JDK 17 / Tomcat 9 described earlier. `startup.sh` is no longer used; nginx hardening and unattended-upgrades from the old script are not in the image.
- **2026-10-14:** Added the `terraform-gcs-state` and `hr-gcp-deployment` skills in `.claude/skills/` (confirm-before-create flow with best-practice gates: fmt, validate, security scan, saved plan, no `-auto-approve`).
- **2026-10-14:** Applied a saved plan (0 add, 2 change, 0 destroy): VM `deletion_protection = true`, `app`/`env` labels on the VM and static IP. VM stayed `RUNNING`, IP unchanged, follow-up plan showed no drift. Added input validation to `variables.tf`.
- **2026-10-15:** Added `cloudbuild.tf`: bucket `hr-deployment-prod-war-bucket` (versioned, private), build SA `hr-cloudbuild-sa` (log writer + bucket objectAdmin), Secret Manager secret `hr-github-pat` (value added out-of-band), GitHub connection `hr-github` (Cloud Build GitHub App installation 171658031 on `manish-deployza`), repo links and triggers `build-war-hr-server` / `build-war-hr-ui` (push to `main`, `mvn clean package -DskipTests` on JDK 21, `hr-server` builds from `backend/`). Enabled the Secret Manager and Storage APIs. Applied in two stages (8 + 5 resources, then 2 in-place trigger fixes). Test builds succeeded: `hr-server/<sha>/leave-backend.war` and `hr-ui/<sha>/leave-management.war`.
- [ ] Rotate the GitHub PAT (it was pasted into a chat): create a new token, add it as a new `hr-github-pat` version, disable version 1
- [ ] Add a lifecycle rule to age out old WARs so the bucket stays under the 5 GB free tier
- **2026-10-15:** Added `loadbalancer.tf` and `recaptcha.tf` (14 resources applied): global external Application Load Balancer (static IP `136.68.195.204`, unmanaged instance group for `hr-server1`, HTTP health check on 80, managed cert for `drdoxy.in`, HTTP→HTTPS redirect), `hr-allow-lb` firewall rule for Google LB ranges, and a score-based reCAPTCHA Enterprise key limited to `drdoxy.in`. DNS A record `@` set in GoDaddy; cert was still `PROVISIONING`. New variables `domain` (in `terraform.tfvars`) and `restrict_web_to_lb` (default false). Cost about $40/month, covered by trial credits.
- [ ] Set `restrict_web_to_lb = true` once the cert is `ACTIVE` and HTTPS is verified
- [ ] Grant `hr-server1-sa` `roles/recaptchaenterprise.agent` so hr-server can verify tokens; hr-ui must load the widget with the site key
- **2026-10-15/16:** Deployed the apps with Terraform: `deploy.sh.tftpl` (VM startup script) creates the MySQL schema/user, pulls the newest WARs from the bucket, installs `hr-ui` as ROOT and `hr-server` as `/leave-backend`, writes root-only `/etc/hr/app.env` for Tomcat and configures nginx (`/` -> `/login.html`, `/api/` -> backend, `/config.json` served from `/etc/hr`). Added `app.tf` (DB password and JWT secret generated by Terraform into Secret Manager, VM read access, empty slots for Mailjet/Razorpay secrets, `recaptchaenterprise.agent` for `hr-server1-sa`), VM scope `cloud-platform`, health check path `/login.html`. Signup 403 was backend CORS (only `localhost:8080` allowed); fixed with `APP_CORS_ALLOWED_ORIGINS=https://drdoxy.in` and https link bases. Mailjet and Razorpay (test) values added to Secret Manager by hand, never in code. Added `ansible/` (`deploy.yml`, `inventory.yml`) doing the same secrets/WAR/properties work without a reboot.
- [ ] Rotate the Mailjet keys, Razorpay secret and GitHub PAT (all were pasted into a chat); add the new values as new secret versions
- [ ] Add `hr-razorpay-webhook-secret` (no value yet) and confirm `SMTP_FROM` is a validated Mailjet sender
- [ ] CAPTCHA is disabled in the backend (`CAPTCHA_ENABLED` unset); needs a reCAPTCHA key and UI widget for `drdoxy.in`
- [ ] Ops Agent is not running, so Tomcat/nginx logs stay on the VM only
- [ ] `restrict_web_to_lb` is still false (VM ports 80/443 open to the internet)
- [ ] VM is 1 GB (swap in use); consider `e2-small` if it struggles
- **2026-10-16:** Added `media.tf`: private bucket `hr-deployment-prod-media-bucket` (versioned, public access blocked, CORS for the site, `prevent_destroy`), `roles/storage.objectUser` and signed-URL rights for `hr-server1-sa`. `MEDIA_BUCKET` is passed to the backend via `app.tf` / `ansible/inventory.yml`. The backend (`hr-server`, merged to `main`) now stores profile photos in the bucket when `MEDIA_BUCKET` is set; `employee_photo.bytes` was made nullable by hand (`docs/sql/2026-10-16-photo-object-storage.sql` in that repo). Ran `ansible/deploy.yml` against the VM: deployed `hr-server/c11551e`, 0 failures, second run 0 changed. Fixed the playbook (OS Login key, SHA-1 checksum, masking regex, output format).
- [ ] Apply the pending Terraform plan (`MEDIA_BUCKET` in the VM startup script); the VM already has it through Ansible
- [ ] Upload a photo in the app and confirm an object appears under `photos/<userId>/` in the media bucket; the existing photo stays in MySQL until replaced
- [ ] Delete the stray `feature/photos-in-gcs` branch pushed by mistake to `deployza/ziniapps-hr-server`
