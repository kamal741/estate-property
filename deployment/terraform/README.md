# EstateFlow Terraform (GCP)

This layout uses **one state per environment** under `deployment/terraform/envs/{dev,prod}/` and a shared module in `deployment/terraform/modules/core-infra/`.

## Prerequisites

- Terraform `>= 1.5`
- A GCP project with billing enabled
- A **GCS bucket** for remote state — the bucket name is **not** hard-coded in `backend.tf`; **`deployment/scripts/deploy-platform.sh`** can create it and passes it to **`terraform init -backend-config=bucket=...`**. You can also create the bucket yourself and set **`TERRAFORM_STATE_BUCKET`** / **`SKIP_GCLOUD_BOOTSTRAP=1`**.
- IAM for whoever runs Terraform: ability to enable APIs, create Cloud SQL, Redis, buckets, secrets, and (for prod) VPC + private service access

## First-time setup

1. Copy variables for the environment you are applying:

   ```bash
   cp deployment/terraform/envs/dev/terraform.tfvars.example deployment/terraform/envs/dev/terraform.tfvars
   ```

2. Edit `terraform.tfvars` and set `project_id` and `region`. **Do not commit** `terraform.tfvars` (it is gitignored).

3. **Remote state (GCS)** — `envs/*/backend.tf` only sets the **`prefix`** (`dev` / `prod`). The **bucket name** is supplied at **`terraform init`** (see **`deployment/scripts/deploy-platform.sh`**), which by default:

   - Enables **`cloudresourcemanager.googleapis.com`** and **`serviceusage.googleapis.com`** (idempotent).
   - Creates **`gs://estateflow-bucket-<env>`** in **`GCS_STATE_BUCKET_LOCATION`** if unset (defaults to **`region`** from `terraform.tfvars`).
   - Runs **`terraform init -backend-config="bucket=..."`**.

   Override defaults:

   ```bash
   ./deployment/scripts/deploy-platform.sh dev                                  # bucket estateflow-bucket-dev, location = region in tfvars
   ./deployment/scripts/deploy-platform.sh dev my-project-tf-state us-east1     # explicit bucket + GCS location
   TERRAFORM_STATE_BUCKET=my-bucket GCS_STATE_BUCKET_LOCATION=us-central1 ./deployment/scripts/deploy-platform.sh dev
   ```

   GCS bucket names are **global**; if `estateflow-bucket-dev` is taken, pass a unique name as the second argument or set **`TERRAFORM_STATE_BUCKET`**.

   Grant your principal **`roles/storage.objectAdmin`** on that bucket (or project-level if your org requires it). See troubleshooting below if **`getIamPolicy`** is denied.

   **Migrating from an older backend** that had `bucket` inside `backend.tf`: run once with **`TERRAFORM_INIT_EXTRA=-reconfigure`** (or **`-migrate-state`** if Terraform prompts).

4. Initialize and apply manually (optional if you use **`deploy-platform.sh`**):

   ```bash
   cd deployment/terraform/envs/dev
   terraform init -backend-config="bucket=YOUR_BUCKET_NAME"
   terraform plan
   terraform apply
   ```

   From the repo root, **`deployment/scripts/deploy-platform.sh`** performs bootstrap, **`init`**, **`apply`**, kubeconfig sync, and Helm for Jenkins + ingress.

### Remote state IAM troubleshooting

If **`add-iam-policy-binding`** fails with **`storage.buckets.getIamPolicy`** denied:

- Confirm the bucket name matches the one you created and **`gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT_ID"`** succeeds.
- Ask a **project Owner** to run the binding or grant **`roles/storage.admin`**, or use project-level **`roles/storage.objectAdmin`** (see previous examples with **`gcloud projects add-iam-policy-binding`**).

## Secrets and passwords

- The **database password is generated** by Terraform (`random_password`) and stored in **Secret Manager** (`{env}-db-password`). Applications and operators should read it from Secret Manager, not from Terraform state, though state is still sensitive — protect the state bucket.
- **Redis AUTH** is stored in `{env}-redis-auth`; the host in `{env}-redis-host`.
- For **prod** with private SQL, apps typically use the **`db_connection_name` output** with [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/postgres/connect-auth-proxy) (or Private Service Connect) plus the password from Secret Manager — not the public IP (it is absent when private IP is enabled).

## Environment differences

| Setting | dev | prod |
|--------|-----|------|
| Cloud SQL deletion protection | off | on |
| Private IP only for Cloud SQL | no (public IP; connections must use TLS — `ssl_mode` is `ENCRYPTED_ONLY` on the instance) | yes (VPC + private service access) |
| GCS bucket `force_destroy` | on | off |
| Redis tier | BASIC | STANDARD_HA (in-transit TLS when tier is not BASIC) |
| Redis memory (GB) | 1 | 5 (sensible default for HA) |
| GKE cluster | `dev-estateflow-cluster` (zonal `us-central1-a`) | `prod-estateflow-cluster` (zonal `us-central1-a`) |
| GKE node pool | `e2-standard-2` × 1 | `e2-standard-4` × 3 |
| GKE deletion protection | off | on |
| Application namespace | `dev-estateflow` | `prod-estateflow` |

## GKE cluster + namespace

Each env creates a zonal `${env}-estateflow-cluster` with a managed node pool and a `${env}-estateflow` Kubernetes namespace (via the `kubernetes` provider, authenticated with the GCP access token from `data.google_client_config`). Workload Identity is enabled by default. Override the machine type / size per env:

```hcl
module "infra" {
  # ...
  gke_machine_type        = "e2-standard-4"
  gke_node_count          = 3
  gke_zone                = "us-central1-a"
  gke_release_channel     = "REGULAR"
  gke_deletion_protection = true
}
```

After `terraform apply`, point `kubectl` / `helm` at the cluster (same command as Terraform output `gke_get_credentials_command`):

```bash
cd deployment/terraform/envs/dev
terraform output -raw gke_get_credentials_command | bash
```

From the **estate-property** repo root you can also use `k8s/scripts/deploy.sh` with kubeconfig sync (requires `terraform init` in that env directory and GCP auth):

```bash
SYNC_GKE_KUBECONFIG=1 ./k8s/scripts/deploy.sh kubectl dev
SYNC_GKE_KUBECONFIG=1 ./k8s/scripts/deploy.sh dev jenkins
```

**Bootstrap Jenkins + ingress after Terraform** (Terraform apply, then Helm for Jenkins and platform-ingress only):

```bash
./deployment/scripts/deploy-platform.sh dev
# Skip Terraform if infra is already applied:
SKIP_TERRAFORM=1 ./deployment/scripts/deploy-platform.sh prod
```

**Jenkins pipelines** (cluster name, namespaces, `gcloud get-credentials` string from state):

```bash
./k8s/scripts/jenkins-gke-env-from-terraform.sh dev --export   # shell exports; requires jq
./k8s/scripts/jenkins-gke-env-from-terraform.sh dev              # human-readable; no jq
```

Terraform creates the workload namespace `gke_namespace` (e.g. `dev-estateflow`, `prod-estateflow`) for app manifests; Helm charts that use their own namespace (e.g. Jenkins in `jenkins`) are configured separately under `k8s/env/<env>/`.

### Prod: private SQL and peering

Private Cloud SQL is created after VPC peering is established. If the first `terraform apply` fails on the SQL instance with an error about the private connection or peering, wait one to two minutes and run **`terraform apply` again** (this is a known ordering quirk when `depends_on` cannot chain the peering connection to SQL in a single static list).

## CI

GitHub Actions workflow `.github/workflows/terraform.yml` runs `terraform fmt -check`, `init -backend=false`, and `validate` for both `dev` and `prod` roots when files under `terraform/` change.

## Optional: tfsec / checkov

Install [tfsec](https://github.com/aquasecurity/tfsec) or [checkov](https://www.checkov.io/) locally and run them against `terraform/` before merge; they are not bundled in CI to keep the workflow fast and credential-free.
