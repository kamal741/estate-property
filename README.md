# estate-property

Monorepo for **EstateFlow** infrastructure and delivery: **GCP (Terraform)**, **GKE**, **Helm** charts for **Jenkins** and **ingress**, a **custom Jenkins controller image**, **Job DSL** seeds, and shell scripts that tie Terraform outputs to Kubernetes deploys and Jenkins CI.

---

## Repository layout

| Path | Purpose |
|------|--------|
| `deployment/terraform/` | GCP infra: GKE, **Artifact Registry** (Docker), Cloud SQL, Redis, GCS, Secret Manager, optional VPC. One state per env under `envs/dev` and `envs/prod`. See **`deployment/terraform/README.md`** for variables, backends, and security notes. |
| `deployment/scripts/terraform-deploy.sh` | **Terraform only**: GCS state bootstrap, `terraform init`/`apply`, kubeconfig sync. No Helm. |
| `deployment/scripts/deploy-k8s-jenkins.sh` | **Jenkins + ingress**: optional **`gcloud builds submit`** (Cloud Build) or **`JENKINS_BUILD_WITH_DOCKER=1`** + local Docker push to AR, then Helm. Needs `kubectl` context. |
| `deployment/scripts/deploy-platform.sh` | Wrapper: runs **`terraform-deploy.sh`** then **`deploy-k8s-jenkins.sh`** (same env vars as before). |
| `k8s/services/charts/jenkins/` | Helm chart for the Jenkins controller (Deployment, Service, PVC, probes). |
| `k8s/services/charts/platform-ingress/` | Helm chart that renders **Ingress** objects from a shared `routes` list. |
| `k8s/env/<env>/` | Per-environment **Helm values** (`jenkins-values.yaml`, `platform-ingress-values.yaml`) and optional **`manifests/`** for raw **Kustomize** / `kubectl apply`. |
| `k8s/scripts/deploy.sh` | Deploy any chart with env values, or `kubectl apply` / `-k`; optional **GKE kubeconfig** sync from Terraform outputs. |
| `k8s/scripts/docker-build-push-gcp-ar.sh` | Build any Dockerfile from the repo and **push to Google Artifact Registry** (`REGION-docker.pkg.dev/...`). Used standalone or from **`deploy-platform.sh`** when **`BUILD_PUSH_JENKINS_IMAGE=1`**. |
| `k8s/scripts/jenkins-gke-env-from-terraform.sh` | Prints **Terraform `jenkins_gke_context`** (cluster, namespaces, `gcloud get-credentials` command) for **Jenkins pipelines**—does not deploy workloads. |
| `jenkins/` | **Dockerfile** and controller config: `plugins.txt`, `init.groovy.d/`, `safeShutdown.sh`. **Build context must be the repo root** (the trailing `.` in the command): `docker build -f jenkins/Dockerfile -t <registry>/estate-property/jenkins:<tag> .` so `COPY jenkins/...` in the Dockerfile resolves. |
| `jenkins-jobs/` | Job DSL Groovy consumed by the seed job (e.g. `Jenkins_Seed_DSL.groovy`, pipeline job definitions). |

---

## Prerequisites

- **GCP**: project, billing, APIs enabled (Terraform enables required services on apply).
- **Tools**: `terraform` (≥ 1.5), `gcloud`, `kubectl`, `helm`; for scripted env exports from Terraform, **`jq`**. Jenkins image to AR: **`deploy-k8s-jenkins.sh`** uses **Cloud Build** by default (no local Docker); use **`JENKINS_BUILD_WITH_DOCKER=1`** with **`BUILD_PUSH_JENKINS_IMAGE=1`** for **`docker-build-push-gcp-ar.sh`**.
- **Auth**: credentials that can run `terraform apply` and `gcloud container clusters get-credentials` (human or CI service account).

---

## Deployment flow (high level)

1. **Terraform** provisions the **GKE** cluster, **namespace** for app workloads (`<env>-estateflow`), a regional **Artifact Registry** Docker repository (default id `estateflow-<env>`), Cloud SQL, Redis, bucket, secrets, etc.
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

## 3. Platform bootstrap (Terraform + Jenkins + ingress)

Split scripts (from repo root):

- **`./deployment/scripts/terraform-deploy.sh <dev|prod> [state_bucket] [gcs_location]`** — GCS state bucket (optional), APIs, `terraform init`/`apply`, kubeconfig sync. Same **`SKIP_*`** / **`TERRAFORM_*`** / **`GCP_*`** env vars as before for the Terraform half.
- **`./deployment/scripts/deploy-k8s-jenkins.sh <dev|prod>`** — Optional **`BUILD_PUSH_JENKINS_IMAGE=1`** + **`ARTIFACT_REGISTRY_REPOSITORY`** → **`gcloud builds submit`** using **`jenkins/cloudbuild.yaml`** (no local Docker unless **`JENKINS_BUILD_WITH_DOCKER=1`**), then Helm for Jenkins + platform-ingress.

One-shot wrapper (unchanged entrypoint for CI):

```bash
./deployment/scripts/deploy-platform.sh dev
./deployment/scripts/deploy-platform.sh dev my-unique-state-bucket us-central1
HELM_ONLY=1 ./deployment/scripts/deploy-platform.sh dev   # only deploy-k8s-jenkins.sh (kubecontext must be correct)
```

- **`HELM_ONLY=1`**: run **only** **`deploy-k8s-jenkins.sh`** (no Terraform, no gcloud bootstrap, no `terraform init`, no kubeconfig sync). You can still set **`BUILD_PUSH_JENKINS_IMAGE=1`** to build via Cloud Build (or Docker with **`JENKINS_BUILD_WITH_DOCKER=1`**) before Helm.
- **`SKIP_TERRAFORM=1`**: skip **`terraform apply`** only; still runs bootstrap, **`terraform init`**, kubeconfig sync, then Helm.
- **`SKIP_KUBECONFIG_SYNC=1`**: skip **`gcloud … get-credentials`** (pair with **`SKIP_TERRAFORM=1`** when kubeconfig is already valid).
- **`SKIP_GCLOUD_BOOTSTRAP=1`**: skip `gcloud services enable` and state bucket create (bucket must already exist; you still need IAM).
- **`TERRAFORM_STATE_BUCKET`** / **`GCS_STATE_BUCKET_LOCATION`**: override default state bucket name and GCS location (or pass as 2nd and 3rd CLI args).
- **`TERRAFORM_APPLY_EXTRA`**: extra arguments to `terraform apply` (e.g. targeted apply).
- **`TERRAFORM_INIT_EXTRA`**: e.g. **`-reconfigure`** after changing backend settings.
- **`BUILD_PUSH_JENKINS_IMAGE=1`**: after kube sync, build and push Jenkins (**Cloud Build** / `gcloud builds submit` by default; **`JENKINS_BUILD_WITH_DOCKER=1`** uses local **`docker-build-push-gcp-ar.sh`**). Set **`ARTIFACT_REGISTRY_REPOSITORY`**. Optional **`JENKINS_IMAGE_TAG`**. With **`HELM_ONLY=1`**, only **`deploy-k8s-jenkins.sh`** runs (same build options). When **`ARTIFACT_REGISTRY_REPOSITORY`** is set, **`JENKINS_IMAGE_REPOSITORY`** is exported for Helm.

Helm is invoked via **`k8s/scripts/deploy.sh`** (not `jenkins-gke-env-from-terraform.sh`, which only prints CI context).

Example (Terraform + push Jenkins to AR + Helm):

```bash
export ARTIFACT_REGISTRY_REPOSITORY="$(cd deployment/terraform/envs/dev && terraform output -raw artifact_registry_repository_id)"
BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-platform.sh dev
```

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

### Build and push images (Artifact Registry)

**Default for Jenkins in this repo:** **`jenkins/cloudbuild.yaml`** + **`gcloud builds submit`** from **`deploy-k8s-jenkins.sh`** when **`BUILD_PUSH_JENKINS_IMAGE=1`** (no local Docker unless **`JENKINS_BUILD_WITH_DOCKER=1`**).

Use **`k8s/scripts/docker-build-push-gcp-ar.sh`** for any service image (Jenkins or others) from your machine. Terraform creates a **Docker** repository per environment (override id with module input **`artifact_registry_repository_id`** if needed).

```bash
./k8s/scripts/docker-build-push-gcp-ar.sh \
  --project YOUR_GCP_PROJECT \
  --region us-central1 \
  --repository "$(terraform output -raw artifact_registry_repository_id)" \
  --image jenkins \
  --tag dev \
  --dockerfile jenkins/Dockerfile
```

(Run **`terraform output …`** from **`deployment/terraform/envs/<env>`** after apply.) **`k8s/scripts/deploy.sh`** sets **`image.repository`** on the Helm command when **`JENKINS_IMAGE_REPOSITORY`** is set, or when **`GCP_PROJECT_ID`**, **`GCP_REGION`**, and **`ARTIFACT_REGISTRY_REPOSITORY`** are all set, or (by default) from **`terraform output -raw jenkins_image_repository`** — see **`./k8s/scripts/deploy.sh --help`**. Set **`JENKINS_IMAGE_TAG`** to override **`image.tag`** for Helm (otherwise values file **`image.tag`** applies). When building only with **`docker-build-push-gcp-ar.sh`**, keep values in sync or export **`JENKINS_IMAGE_TAG`**. GKE nodes get **`roles/artifactregistry.reader`** on that repository via Terraform; see **`imagePullSecrets`** in values only if you use a different pull identity.

### Job DSL: `script not yet approved for use`

Jenkins only runs **`init.groovy.d/*.groovy`** (name must **end with `.groovy`**). Files named **`*.groovy.override` are ignored** by Jenkins.

This repo ships:

- **`00-disableInstallWizard.groovy`** — runs first (before **`97-...`**): sets **`InstallState.INITIAL_SETUP_COMPLETED`** and **`save()`**. Use together with **`-Djenkins.install.runSetupWizard=false`** on the JVM (see image **`ENV JAVA_OPTS`**, Helm **`javaOpts`** / **`jenkinsOpts`**).
- **`97-setCSRFAndScriptSecurity.groovy`** — runs your existing **`preapproveAll()`** + CSRF-related settings.
- **`seedJobs.groovy`** — creates **`Jenkins-Seed_DSL`** with **`GIT_BRANCH`** and **`EMAIL_RECIPIENTS`** parameters and starts the first build via **`scheduleBuild2`** with defaults (`main` / empty). If an old seed job exists without parameters, delete the job or wipe the controller PVC once so init can recreate it.
- **`zzz-approvePendingJobDslScripts.groovy`** — periodically runs **`ScriptApproval.preapproveAll()`** plus **`save()`** (there is no `approvePendingScripts()` API). That clears pending whole-script entries after Job DSL runs, including when the first seed happens long after boot. Rebuild the controller image and restart the pod after changing this file.

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
| Full stack + push Jenkins (Cloud Build) then Helm | `ARTIFACT_REGISTRY_REPOSITORY=... BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-platform.sh <env>` (optional **`JENKINS_IMAGE_TAG=v…`** — passed to Helm as **`image.tag`**) |
| Terraform only | `./deployment/scripts/terraform-deploy.sh <env> [state_bucket] [location]` |
| Jenkins + ingress only (after kubeconfig) | `ARTIFACT_REGISTRY_REPOSITORY=... BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh <env>` |
| Build/push Jenkins locally (Docker) | `JENKINS_BUILD_WITH_DOCKER=1 ARTIFACT_REGISTRY_REPOSITORY=... BUILD_PUSH_JENKINS_IMAGE=1 ./deployment/scripts/deploy-k8s-jenkins.sh <env>` |
| Build/push Jenkins only (no deploy-platform) | `./k8s/scripts/docker-build-push-gcp-ar.sh --project ... --region ... --repository ... --image jenkins --tag dev --dockerfile jenkins/Dockerfile` |
| Update only Jenkins Helm release | `./k8s/scripts/deploy.sh <env> jenkins` (use `SYNC_GKE_KUBECONFIG=1` if kubeconfig is stale) |
| Update only ingress routes | `./k8s/scripts/deploy.sh <env> platform-ingress` |
| Apply raw Kustomize for an env | `./k8s/scripts/deploy.sh kubectl <env>` |
| Populate Jenkins job with GKE vars | `./k8s/scripts/jenkins-gke-env-from-terraform.sh <env> --export` in a pipeline or copy into credentials |

---

## Further reading

- **`deployment/terraform/README.md`** — Terraform layout, secrets, GKE sizing, prod caveats.
- **`k8s/env/dev/`** and **`k8s/env/prod/`** — concrete value files to copy for new environments.
