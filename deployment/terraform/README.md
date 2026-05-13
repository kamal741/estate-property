# EstateFlow Terraform (GCP)

This layout uses **one state per environment** under `deployment/terraform/envs/{dev,prod}/` and a shared module in `deployment/terraform/modules/core-infra/`.

## Prerequisites

- Terraform `>= 1.5`
- A GCP project with billing enabled
- A **GCS bucket** for remote state (see `envs/*/backend.tf`) — create it once per org; use separate prefixes or buckets per env
- IAM for whoever runs Terraform: ability to enable APIs, create Cloud SQL, Redis, buckets, secrets, and (for prod) VPC + private service access

## First-time setup

1. Copy variables for the environment you are applying:

   ```bash
   cp deployment/terraform/envs/dev/terraform.tfvars.example deployment/terraform/envs/dev/terraform.tfvars
   ```

2. Edit `terraform.tfvars` and set `project_id` and `region`. **Do not commit** `terraform.tfvars` (it is gitignored).

3. **Bootstrap state backend** (once per bucket):

   - The bucket name in **`envs/*/backend.tf`** must exist and be **globally unique** across all of GCS (change the name in `backend.tf` if `terraform-state-bucket` is taken).
   - Whoever runs **`terraform init`** needs object access on that bucket, including **`storage.objects.list`** (Terraform lists “workspaces” under your prefix). Grant **`roles/storage.objectAdmin`** on the bucket (narrower than project-wide Storage Admin).

   Example (replace project, bucket, and member with yours; use your Google account or a CI service account):

   ```bash
   export PROJECT_ID="your-gcp-project-id"
   export BUCKET="terraform-state-bucket"   # must match backend.tf

   gcloud config set project "$PROJECT_ID"
   gcloud storage buckets create "gs://${BUCKET}" --project="$PROJECT_ID" --location=US --uniform-bucket-level-access

   gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
     --member="user:chauhan.kamaldeep@gmail.com" \
     --role="roles/storage.objectAdmin"
   ```

   If the bucket lives in **another** GCP project, create it there and add the same **`--member`** binding on that bucket in that project.

   **If `add-iam-policy-binding` fails with `storage.buckets.getIamPolicy` denied:**

   - Confirm **`echo "$BUCKET"`** is the **same** name you passed to **`buckets create`** (GCS names are global; if `terraform-state-bucket` was never created by you, you may be targeting a bucket in another project or a stale `export`).
   - Verify the bucket is in your project: `gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID"`.
   - Changing bucket IAM requires **`storage.buckets.getIamPolicy` / `setIamPolicy`**. If org policy blocks that for your role, ask a **project Owner** to either run the **`add-iam-policy-binding`** command above **or** grant you **`roles/storage.admin`** on the project, then retry.
   - **Workaround (project Owner only):** grant Terraform state access without editing that bucket’s IAM directly — attach **`roles/storage.objectAdmin`** at the **project** level (applies to objects in all buckets in that project; use a dedicated project or dedicated bucket if you need least privilege):

     ```bash
     gcloud projects add-iam-policy-binding "$PROJECT_ID" \
       --member="user:chauhan.kamaldeep@gmail.com" \
       --role="roles/storage.objectAdmin"
     ```

4. Initialize and apply from the env directory:

   ```bash
   cd deployment/terraform/envs/dev
   terraform init
   terraform plan
   terraform apply
   ```

   From the repo root, **`deployment/scripts/deploy-platform.sh`** runs **`terraform init`** in that env directory before **`apply`**, so a fresh clone (for example Cloud Shell) does not require a manual **`init`** first. If Terraform reports a backend configuration change, run once with **`TERRAFORM_INIT_EXTRA=-reconfigure`** (see that script’s header comment).

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
