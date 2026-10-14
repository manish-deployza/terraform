# Terraform Best Practices

Standards for writing quality Terraform in this project. Review changes against this list before running `apply`.

## 1. Project structure

- Keep a consistent layout: `main.tf` (resources), `variables.tf`, `outputs.tf`, `versions.tf` or the `terraform {}` block (providers), `README`/`PROGRESS.md`.
- Split `main.tf` by concern (`network.tf`, `compute.tf`, `iam.tf`) once it grows past ~200 lines.
- Move repeated patterns into **modules** with a clear input/output contract. Don't create a module for a single resource.
- Keep large scripts in separate files (`startup.sh`) loaded with `file()` or `templatefile()`, not inline heredocs.

## 2. Naming and style

- Resource names: `snake_case`, descriptive, and without the type repeated (`google_compute_instance.hr_server1`, not `...hr_server1_instance`).
- GCP resource names: lowercase with hyphens, with a consistent prefix (`hr-...`).
- Run `terraform fmt` before every commit and `terraform validate` before every plan.
- Comment on **why**, not what. Don't restate obvious attributes.

## 3. Variables and outputs

- Every variable has a `description` and a `type`. Add `validation` blocks for values that must be constrained.
- Give defaults only for values that are safe and non-environment-specific. No default means the value is required.
- Mark secrets `sensitive = true`; never give them defaults.
- No hardcoded project IDs, regions or CIDRs inside resources. Use variables or `locals`.
- Use `locals` for computed or repeated values (names, labels, tags).
- Outputs get a `description`; mark sensitive outputs `sensitive = true`.

```hcl
variable "tomcat_allowed_cidrs" {
  description = "CIDRs allowed to reach Tomcat on 8080"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.tomcat_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "Each entry must be a valid CIDR, e.g. 203.0.113.5/32."
  }
}
```

## 4. Providers and versions

- Pin the provider with a pessimistic constraint (`~> 5.0`) and set `required_version` for Terraform itself.
- **Commit** `.terraform.lock.hcl`. Don't commit the `.terraform/` directory.
- Upgrade providers deliberately (`terraform init -upgrade`), then review the plan.

## 5. State management

- Use a **remote backend** (GCS bucket) for anything shared or long-lived. Enable bucket versioning, uniform bucket-level access and restricted IAM.
- State contains sensitive values. Treat it like a secret. Never commit `*.tfstate` or `*.tfstate.backup`.
- Never edit state by hand. Use `terraform state mv/rm` and `terraform import` when needed.
- One state per environment (dev/staging/prod); don't mix them.

## 6. Security

- **Least privilege** IAM: dedicated service accounts with minimal roles, no `roles/owner` or `roles/editor`, and no default compute SA.
- **Firewall:** deny by default, open only the ports you need, restrict sources, and use specific network tags. Never expose SSH, databases or admin ports to `0.0.0.0/0`.
- **No secrets in code**, `.tfvars` in git, or `metadata_startup_script`. Use Secret Manager and reference it at runtime.
- Prefer Shielded VM, OS Login, private IPs/IAP, and encryption with CMEK for sensitive data.
- Enable logging on firewall rules and audit logs on the project.
- Scan configs before applying with `tfsec`, `trivy config` or `checkov`.

## 7. Resource design

- Use `for_each` over `count` for collections so items are keyed by name, not index. Use `count` only for on/off toggles (`count = var.enabled ? 1 : 0`).
- Reference other resources by attribute (`google_compute_address.x.address`) so Terraform builds the dependency graph. Use `depends_on` only when the dependency is hidden.
- Use `lifecycle` carefully: `prevent_destroy` on stateful resources (databases, disks), `ignore_changes` only for fields managed outside Terraform.
- Set `deletion_protection = true` for production VMs and databases.
- Add `labels` (env, owner, app) to everything that supports them for cost tracking.
- Avoid `provisioner` blocks. Prefer startup scripts, images (Packer) or config management.
- Startup scripts must be **idempotent**, since they run on every boot.

## 7a. Cost awareness

- Right-size machine types and disks; check `e2-micro` limits (1 GB RAM) against the workload.
- Release unused static IPs. Reserved but unattached addresses are billed.
- Review the plan for unexpected create/destroy of billable resources.

## 8. Workflow

1. `terraform fmt -recursive`
2. `terraform validate`
3. `terraform plan -out=tfplan` and **read the whole plan**: check for `destroy` and `replace` (`-/+`)
4. `terraform apply tfplan` (applying the saved plan guarantees it matches what you reviewed)
5. Update `PROGRESS.md`

- Pay special attention to `# forces replacement`: a replace can destroy a VM or lose data.
- Never run `apply -auto-approve` against production by hand.
- Make small, reviewable changes. One concern per change.
- Use version control (git) with code review for all infrastructure changes. This folder isn't a git repository yet, so run `git init` and add a `.gitignore`.

## 9. Recommended `.gitignore`

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
tfplan
crash.log
override.tf
override.tf.json
```

Keep `.terraform.lock.hcl` committed.

## 10. Pre-apply checklist

- [ ] `fmt` and `validate` pass
- [ ] Plan reviewed; no unexpected destroys or replacements
- [ ] No secrets in code, variables defaults or startup scripts
- [ ] No resource open to `0.0.0.0/0` except intentional web ports
- [ ] Variables have descriptions, types and validation
- [ ] State is stored remotely and backed up
- [ ] Labels and descriptive names applied
- [ ] `PROGRESS.md` updated
