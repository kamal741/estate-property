# estate-property

Monorepo for **EstateFlow** infrastructure and delivery: **GCP (Terraform)**, **GKE**, **Helm** charts for **Jenkins** and **ingress**, a **custom Jenkins controller image**, **Job DSL** seeds, and shell scripts that tie Terraform outputs to Kubernetes deploys and Jenkins CI.

---

## Repository layout

| Path | Purpose |
|------|--------|
| `deployment/terraform/` | GCP infra: GKE, Cloud SQL, Redis, GCS, Secret Manager, optional VPC. One state per env under `envs/dev` and `envs/prod`. See **`deployment/terraform/README.md`** for variables, backends, and security notes. |
| `deployment/scripts/deploy-platform.sh` | Optional one-shot: **Terraform apply** → **kubeconfig** → **Helm** (Jenkins + platform-ingress only). |
| `k8s/services/charts/jenkins/` | Helm chart for the Jenkins controller (Deployment, Service, PVC, probes). |
| `k8s/services/charts/platform-ingress/` | Helm chart that renders **Ingress** objects from a shared `routes` list. |
| `k8s/env/<env>/` | Per-environment **Helm values** (`jenkins-values.yaml`, `platform-ingress-values.yaml`) and optional **`manifests/`** for raw **Kustomize** / `kubectl apply`. |
| `k8s/scripts/deploy.sh` | Deploy any chart with env values, or `kubectl apply` / `-k`; optional **GKE kubeconfig** sync from Terraform outputs. |
| `k8s/scripts/jenkins-gke-env-from-terraform.sh` | Prints **Terraform `jenkins_gke_context`** (cluster, namespaces, `gcloud get-credentials` command) for **Jenkins pipelines**—does not deploy workloads. |
| `jenkins/` | **Dockerfile** and controller config: `plugins.txt`, `init.groovy.d/`, `safeShutdown.sh`. **Build context must be the repo root** (the trailing `.` in the command): `docker build -f jenkins/Dockerfile -t <registry>/estate-property/jenkins:<tag> .` so `COPY jenkins/...` in the Dockerfile resolves. |
| `jenkins-jobs/` | Job DSL Groovy consumed by the seed job (e.g. `Jenkins_Seed_DSL.groovy`, pipeline job definitions). |

---

## Prerequisites

- **GCP**: project, billing, APIs enabled (Terraform enables required services on apply).
- **Tools**: `terraform` (≥ 1.5), `gcloud`, `kubectl`, `helm`; for scripted env exports from Terraform, **`jq`** (`jenkins-gke-env-from-terraform.sh --export` / `--json`).
- **Auth**: credentials that can run `terraform apply` and `gcloud container clusters get-credentials` (human or CI service account).

---

## Deployment flow (high level)

1. **Terraform** provisions the **GKE** cluster, **namespace** for app workloads (`<env>-estateflow`), Cloud SQL, Redis, bucket, secrets, etc.
2. **Kubeconfig** is pointed at the cluster (`gcloud container clusters get-credentials …` — exposed as Terraform output `gke_get_credentials_command`).
3. **Helm** installs **Jenkins** (often namespace `jenkins`) and **platform-ingress** (Helm release in `kube-system`, Ingress resources may target multiple namespaces).
4. **Application services** are intended to be deployed **by Jenkins** after the controller is up, using cluster/namespace/auth derived from Terraform (see **Jenkins / CI** below).

---

## 1. Terraform (GCP + GKE)

```bash
cp deployment/terraform/envs/dev/terraform.tfvars.example deployment/terraform/envs/dev/terraform.tfvars
# Edit terraform.tfvars: project_id, region, etc.

cd deployment/terraform/envs/dev
terraform init
terraform plan
terraform apply
```

Full documentation: **`deployment/terraform/README.md`** (state backend, secrets, prod vs dev, private SQL, etc.).

**Useful outputs** (after apply): `gke_cluster_name`, `gke_cluster_location`, `gke_namespace`, `gke_get_credentials_command`, `gcp_project_id`, **`jenkins_gke_context`** (single object for CI).

---

## 2. Kubernetes: Helm-only pieces (`k8s/scripts/deploy.sh`)

Run from **repository root**.

### Helm (default)

Uses chart `k8s/services/charts/<service>` and values **`k8s/env/<env>/<service>-values.yaml`**.

```bash
./k8s/scripts/deploy.sh dev jenkins
./k8s/scripts/deploy.sh prod platform-ingress
```

Optional: explicit `helm` subcommand, extra Helm args, env vars **`RELEASE`**, **`NAMESPACE`** (otherwise Jenkins → namespace `jenkins`, platform-ingress → `kube-system`).

### GKE kubeconfig from Terraform (same machine as Terraform state)

```bash
SYNC_GKE_KUBECONFIG=1 ./k8s/scripts/deploy.sh dev jenkins
```

Requires `terraform` on `PATH`, `terraform init` in `deployment/terraform/envs/<env>`, and outputs present after apply.

### Raw manifests (Kustomize / YAML)

Default directory: **`k8s/env/<env>/manifests/`** (if `kustomization.yaml` exists → `kubectl apply -k`, else `kubectl apply -f`).

```bash
./k8s/scripts/deploy.sh kubectl dev
./k8s/scripts/deploy.sh kubectl prod k8s/env/prod/manifests --dry-run=client
```

---

## 3. One-shot platform bootstrap (`deployment/scripts/deploy-platform.sh`)

Runs **Terraform apply** (unless skipped), refreshes **kubeconfig**, then **Helm** for **Jenkins** and **platform-ingress** only (no app microservices here).

```bash
./deployment/scripts/deploy-platform.sh dev
```

- **`SKIP_TERRAFORM=1`**: skip `terraform apply` (cluster already exists); still runs get-credentials + Helm.
- **`TERRAFORM_APPLY_EXTRA`**: extra arguments to `terraform apply` (e.g. targeted apply).

Helm is invoked via **`k8s/scripts/deploy.sh`** (not `jenkins-gke-env-from-terraform.sh`, which only prints CI context).

---

## 4. Jenkins / CI: cluster context from Terraform

**`k8s/scripts/jenkins-gke-env-from-terraform.sh`** reads **`jenkins_gke_context`** from state for pipeline steps (no secrets).

```bash
./k8s/scripts/jenkins-gke-env-from-terraform.sh dev          # human-readable
./k8s/scripts/jenkins-gke-env-from-terraform.sh dev --export # export VAR=... (needs jq)
./k8s/scripts/jenkins-gke-env-from-terraform.sh dev --json   # JSON (needs jq)
```

**Auth in Jenkins** (not stored in this output): use a GCP **service account key** (or Workload Identity if Jenkins runs on GKE), `gcloud auth activate-service-account`, then run the **`gcloud_get_credentials_command`** value (or equivalent `gcloud container clusters get-credentials …`). Grant roles your policy allows (e.g. Kubernetes Engine developer / deployer).

Use **`gke_app_namespace`** for Terraform-created app workloads; Jenkins controller remains in **`jenkins_helm_namespace`** unless you change Helm values.

---

## 5. Jenkins controller image and seed jobs

- Image base and tooling: **`jenkins/Dockerfile`** (align tag with `k8s/env/<env>/jenkins-values.yaml`).
- Plugins: **`jenkins/plugins.txt`**.
- Init scripts: **`jenkins/init.groovy.d/`** (e.g. wizard disabled, seed jobs, security).
- Job DSL sources: **`jenkins-jobs/`**; seed job loads external DSL paths as configured in your seed Groovy.

After the controller is running, use Jenkins to run seed jobs and application pipelines.

### Job DSL: `script not yet approved for use`

Jenkins only runs **`init.groovy.d/*.groovy`** (name must **end with `.groovy`**). Files named **`*.groovy.override` are ignored**, so script-approval init never ran.

This repo ships:

- **`97-setCSRFAndScriptSecurity.groovy`** — runs your existing `preapproveAll()` + CSRF settings (same as the old `.override` file).
- **`zzz-approvePendingJobDslScripts.groovy`** — calls **`approvePendingScripts()`** on a schedule for roughly the first hour after boot (plus early passes at 45s and 5m). That catches Job DSL whole-script approvals when the first seed run happens **after** those early windows—common in real use. Rebuild the controller image and restart the pod after changing this file.

**If the seed still fails once:** wait up to about two minutes after the failure (next bootstrap pass) and **run the seed again**, or use **Manage Jenkins → In-process Script Approval** once.

**Job DSL Groovy** under **`jenkins-jobs/`** should avoid **`Jenkins.instance`**, **`Hudson.instance.getItem`**, and similar core APIs; they stay pending until approved. **`Jenkins_Seed_DSL.groovy`** uses fixed defaults for parameters and schedule (tune values in the Jenkins UI after the first successful seed if needed).

**Without rebuilding:** **Manage Jenkins → In-process Script Approval** (or the link in the failed build log) and approve each pending script.

You also have **`permissive-script-security`** in `plugins.txt`; if your admins enable that strategy under **Configure Global Security**, fewer approvals are required (follow your org’s security policy).

---

## 6. Ingress chart notes

- **`platform-ingress`**: routes are defined in **`k8s/env/<env>/platform-ingress-values.yaml`** (`routes:` → host, namespace, backend `Service` name/port).
- **`ingressClassName`**: set in values only if your cluster defines a **`networking.k8s.io/IngressClass`**; leave empty to omit the field and rely on your platform default.

---

## 7. Typical sequences

| Goal | Command / flow |
|------|----------------|
| First full stack (infra + Jenkins + ingress) | `terraform apply` in `deployment/terraform/envs/<env>` **or** `./deployment/scripts/deploy-platform.sh <env>` |
| Update only Jenkins Helm release | `./k8s/scripts/deploy.sh <env> jenkins` (use `SYNC_GKE_KUBECONFIG=1` if kubeconfig is stale) |
| Update only ingress routes | `./k8s/scripts/deploy.sh <env> platform-ingress` |
| Apply raw Kustomize for an env | `./k8s/scripts/deploy.sh kubectl <env>` |
| Populate Jenkins job with GKE vars | `./k8s/scripts/jenkins-gke-env-from-terraform.sh <env> --export` in a pipeline or copy into credentials |

---

## Further reading

- **`deployment/terraform/README.md`** — Terraform layout, secrets, GKE sizing, prod caveats.
- **`k8s/env/dev/`** and **`k8s/env/prod/`** — concrete value files to copy for new environments.
