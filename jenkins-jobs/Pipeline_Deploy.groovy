// Job DSL reads the existing job so seed re-applies UI defaults (email, cron, git branches).
// Requires "In-process Script Approval" for Hudson.instance on a new controller until approved.
// ENV must be set by Jenkins (global properties, folder env, or agent); e.g. dev or prod.

import hudson.model.Hudson
import hudson.model.ParametersDefinitionProperty
import hudson.triggers.TimerTrigger

// Add new deployable services here only — the job UI multi-select is built from this list.
def DEPLOYABLE_SERVICES = [
    'estateflow-admin-service',
    'estateflow-brokerage-agent-service',
    'estateflow-client-service',
    'estateflow-admin-ui',
]
def JDBC_SERVICES = [
    'estateflow-admin-service',
    'estateflow-brokerage-agent-service',
    'estateflow-client-service',
]
def all_services_csv = DEPLOYABLE_SERVICES.join(',')

def job_name = 'Pipeline_Deploy'
def scriptname = this.class.getName() ?: ''

def curJob = Hudson.instance.getItem(job_name)
def pdp = curJob?.getProperty(ParametersDefinitionProperty)
def email_recipients = pdp?.getParameterDefinition('EMAIL_RECIPIENTS')?.defaultValue ?: ''
def sched = curJob?.triggers?.find { it.value instanceof TimerTrigger }?.value?.spec ?: '#0 12 * * *'
def git_brnch_deploy = pdp?.getParameterDefinition('GIT_BRANCH_DEPLOY')?.defaultValue ?: 'main'
def git_brnch_service = pdp?.getParameterDefinition('GIT_BRANCH_SERVICE')?.defaultValue ?: 'main'
def git_cred_deploy = pdp?.getParameterDefinition('GIT_CREDENTIALS_ID_DEPLOY')?.defaultValue ?: ''
def git_cred_service = pdp?.getParameterDefinition('GIT_CREDENTIALS_ID_SERVICE')?.defaultValue ?: ''
def gcp_cred_id = pdp?.getParameterDefinition('GCP_CREDENTIALS_ID')?.defaultValue ?: ''
def jenkins_k8s_sa = pdp?.getParameterDefinition('JENKINS_K8S_SERVICE_ACCOUNT')?.defaultValue ?: 'jenkins'
def deploy_platform_ingress_default = pdp?.getParameterDefinition('DEPLOY_PLATFORM_INGRESS')?.defaultValue
if (deploy_platform_ingress_default == null) {
    deploy_platform_ingress_default = true
}
def service_names_default = pdp?.getParameterDefinition('SERVICE_NAMES')?.defaultValue
    ?: pdp?.getParameterDefinition('SERVICE_NAME')?.defaultValue
    ?: DEPLOYABLE_SERVICES[0]
// Migrate defaults from old per-service boolean parameters (removed).
if (pdp?.getParameterDefinition('DEPLOY_ESTATEFLOW_ADMIN_SERVICE') != null) {
    def picked = []
    if (pdp.getParameterDefinition('DEPLOY_ESTATEFLOW_ADMIN_SERVICE')?.defaultValue) {
        picked << 'estateflow-admin-service'
    }
    if (pdp.getParameterDefinition('DEPLOY_ESTATEFLOW_BROKERAGE_AGENT_SERVICE')?.defaultValue) {
        picked << 'estateflow-brokerage-agent-service'
    }
    if (pdp.getParameterDefinition('DEPLOY_ESTATEFLOW_CLIENT_SERVICE')?.defaultValue) {
        picked << 'estateflow-client-service'
    }
    if (picked) {
        service_names_default = picked.join(',')
    }
}

pipelineJob("$job_name") {
    // HTML requires OWASP Safe HTML formatter: antisamy-markup-formatter in jenkins/plugins.txt + init 02-configureMarkupFormatter.groovy.
    description("""\
    Deploy EstateFlow services to GKE: checkout, test, build/push image, Helm upgrade via k8s/scripts/deploy.sh, rollout check, then <b>platform-ingress</b> (GCE routes). Select services with <b>SERVICE_NAMES</b> (multi-select). Add services in <code>DEPLOYABLE_SERVICES</code> in this job's .groovy file.
    <b>ENV</b> is not a job parameter; it must be defined on the controller, folder, or agent (e.g. <code>ENV=dev</code>).
    <b>GCP_AUTH_MODE</b>: <code>workload_identity</code> (default) uses the <b>pod</b> Kubernetes service account + GKE Workload Identity (no JSON key): bind the pod SA to a GCP service account and grant it Artifact Registry + GKE deploy roles; build must run <i>inside</i> the cluster. <code>secret_key</code> uses <b>GCP_CREDENTIALS_ID</b> (Secret file JSON) and <code>gcloud auth activate-service-account</code> (for agents outside the cluster or until WI is set up).
    <b>JENKINS_K8S_SERVICE_ACCOUNT</b> should match <code>k8s/services/charts/jenkins/values.yaml</code> <code>serviceAccount.name</code> (default <code>jenkins</code>) — that is the K8s identity Workload Identity annotates to your GCP service account. For <code>workload_identity</code> + <code>IMAGE_BUILD_MODE=cloud_build</code>, grant that GCP SA <code>roles/cloudbuild.builds.editor</code> (or equivalent) so <code>gcloud builds submit</code> succeeds.
    <b>Cloud Build</b>: one file <code>jenkins/cloudbuild-estateflow.yaml</code> for every EstateFlow service; the pipeline passes <code>_DOCKERFILE</code> and <code>_AR_IMAGE</code> substitutions only — no extra YAML per service.
    Update this job from the seed repo .groovy (${scriptname}) as needed.<br>
    """.stripIndent())

    logRotator(-1, 32, -1, -1)

    triggers {
        cron(sched)
    }

    parameters {
        stringParam('EMAIL_RECIPIENTS', "$email_recipients", 'Please be sure to add a comma, between every email address.<br>')
        stringParam('GIT_BRANCH_DEPLOY', git_brnch_deploy, 'Git branch (estate-property)')
        stringParam('GIT_BRANCH_SERVICE', git_brnch_service, 'Git branch (EstateFlow)')
        stringParam('GIT_CREDENTIALS_ID_DEPLOY', "$git_cred_deploy", 'Jenkins credential ID for HTTPS checkout of estate-property. Leave empty if the repo is public.')
        stringParam('GIT_CREDENTIALS_ID_SERVICE', "$git_cred_service", 'Jenkins credential ID for HTTPS checkout of pizenith-technologies/EstateFlow. Required for private repos: use Username with password (GitHub username + Personal Access Token); GitHub does not accept account passwords for Git over HTTPS.')
        choiceParam('IMAGE_BUILD_MODE', ['cloud_build', 'docker'], 'cloud_build: one shared <code>jenkins/cloudbuild-estateflow.yaml</code> + <code>gcloud builds submit</code> (substitutions pick Dockerfile + image; no Docker socket). docker: local build/push (needs <code>/var/run/docker.sock</code>).')
        choiceParam('GCP_AUTH_MODE', ['workload_identity', 'secret_key'], 'workload_identity: no JSON key; pod uses GKE Workload Identity (see job description). secret_key: use GCP_CREDENTIALS_ID JSON file + activate-service-account.')
        stringParam('GCP_CREDENTIALS_ID', "$gcp_cred_id", 'Required when <b>GCP_AUTH_MODE</b> is <code>secret_key</code>: Jenkins <b>Secret file</b> credential ID (GCP service account JSON). Ignored for <code>workload_identity</code>.')
        stringParam('JENKINS_K8S_SERVICE_ACCOUNT', "$jenkins_k8s_sa", 'Must match Jenkins Helm <code>serviceAccount.name</code> (chart values); annotate this K8s SA for Workload Identity to your GCP deploy service account.')
        booleanParam('DEPLOY_PLATFORM_INGRESS', deploy_platform_ingress_default, 'After all selected services pass health checks, deploy <code>platform-ingress</code> (k8s/env/&lt;env&gt;/platform-ingress-values.yaml). Backend Services must exist or GCE ingress will fail translation.')
    }

    properties {
        disableConcurrentBuilds()
    }
    // extended-choice-parameter (plugins.txt): one multi-select; edit DEPLOYABLE_SERVICES above to add options.
    configure { project ->
        def paramsRoot = project / 'properties' / 'hudson.model.ParametersDefinitionProperty' / 'parameterDefinitions'
        paramsRoot.children().findAll { node ->
            node.name() == 'com.cwctravel.hudson.plugins.extended__choice__parameter.ExtendedChoiceParameterDefinition' &&
                (node / 'name').text() == 'SERVICE_NAMES'
        }.each { it.replaceNode {} }
        paramsRoot << 'com.cwctravel.hudson.plugins.extended__choice__parameter.ExtendedChoiceParameterDefinition' {
            name 'SERVICE_NAMES'
            type 'PT_CHECKBOX'
            value all_services_csv
            defaultValue service_names_default
            multiSelectDelimiter ','
            quoteValue false
            saveJSONParameterToFile false
            visibleItemCount "${Math.max(DEPLOYABLE_SERVICES.size(), 5)}"
            description 'Select one or more services to test, build, and deploy (comma-separated in the build).'
        }
    }
    // Single-quoted CPS script: ${env.*} is evaluated at runtime. Inject allowed list at Job DSL seed time (not ${} in ''').
    def allowedServicesLiteral = DEPLOYABLE_SERVICES.inspect()
    def jdbcServicesLiteral = JDBC_SERVICES.inspect()
    def pipelineScript = '''\
pipeline {
    agent any
    options {
        timestamps()
    }
    environment {
        PROJECT_ID = "project-estateflow-${env.ENV}"
        REGION     = "northamerica-northeast1"
        GKE_ZONE   = "northamerica-northeast1-a"
        GKE_CLUSTER = "${env.ENV}-estateflow-cluster"
        NAMESPACE   = "${env.ENV}-estateflow"
        IMAGE_REPOSITORY = "${REGION}-docker.pkg.dev/${PROJECT_ID}/estateflow-${env.ENV}"
    }
    stages {
        stage('Validate') {
            steps {
                script {
                    def allowed = __ALLOWED_SERVICES__ as Set
                    def raw = (params.SERVICE_NAMES ?: params.SERVICE_NAME ?: '').toString()
                    def services = raw.split(',').collect { it.trim() }.findAll { it }
                    if (services.isEmpty()) {
                        error('Select at least one service in SERVICE_NAMES.')
                    }
                    def unknown = services.findAll { !allowed.contains(it) }
                    if (!unknown.isEmpty()) {
                        error("Unknown service(s): ${unknown.join(', ')}. Add them to DEPLOYABLE_SERVICES in jenkins-jobs/Pipeline_Deploy.groovy.")
                    }
                    env.SELECTED_SERVICES = services.join(',')
                    echo "Selected services: ${env.SELECTED_SERVICES}"
                    if (!env.ENV?.trim()) {
                        error('ENV is not set. Define ENV in Jenkins (global properties, folder, or agent environment), e.g. dev or prod.')
                    }
                    def authMode = (params.GCP_AUTH_MODE ?: 'workload_identity').trim()
                    if (authMode == 'secret_key' && !params.GCP_CREDENTIALS_ID?.trim()) {
                        error('GCP_AUTH_MODE is secret_key but GCP_CREDENTIALS_ID is empty. Set GCP_CREDENTIALS_ID to a Jenkins Secret file credential ID, or switch GCP_AUTH_MODE to workload_identity.')
                    }
                    if (!params.JENKINS_K8S_SERVICE_ACCOUNT?.trim()) {
                        error('JENKINS_K8S_SERVICE_ACCOUNT is empty. Set it to match k8s/services/charts/jenkins/values.yaml serviceAccount.name (default: jenkins).')
                    }
                    if (authMode == 'workload_identity') {
                        def inCluster = sh(script: 'test -r /var/run/secrets/kubernetes.io/serviceaccount/token && echo yes || echo no', returnStdout: true).trim()
                        if (inCluster != 'yes') {
                            error('GCP_AUTH_MODE=workload_identity requires an in-cluster build (Kubernetes service account token not found). Run the job on a GKE-based agent/controller, or set GCP_AUTH_MODE to secret_key and configure GCP_CREDENTIALS_ID.')
                        }
                    }
                    echo "GCP_AUTH_MODE=${authMode}; Jenkins K8s SA (chart): ${params.JENKINS_K8S_SERVICE_ACCOUNT.trim()}"
                }
            }
        }

        stage('Prepare') {
            steps {
                script {
                    env.IMAGE_TAG = sh(script: 'date +%Y%m%d%H%M%S', returnStdout: true).trim()
                }
            }
        }

        stage('Checkout') {
            steps {
                script {
                    def credDeploy = params.GIT_CREDENTIALS_ID_DEPLOY?.trim()
                    def credService = params.GIT_CREDENTIALS_ID_SERVICE?.trim()
                    dir('estate-property') {
                        if (credDeploy) {
                            git branch: "${params.GIT_BRANCH_DEPLOY}",
                                changelog: false,
                                poll: false,
                                credentialsId: credDeploy,
                                url: 'https://github.com/kamal741/estate-property.git'
                        } else {
                            git branch: "${params.GIT_BRANCH_DEPLOY}",
                                changelog: false,
                                poll: false,
                                url: 'https://github.com/kamal741/estate-property.git'
                        }
                    }
                    dir('EstateFlow') {
                        if (credService) {
                            git branch: "${params.GIT_BRANCH_SERVICE}",
                                changelog: false,
                                poll: false,
                                credentialsId: credService,
                                url: 'https://github.com/pizenith-technologies/EstateFlow.git'
                        } else {
                            git branch: "${params.GIT_BRANCH_SERVICE}",
                                changelog: false,
                                poll: false,
                                url: 'https://github.com/pizenith-technologies/EstateFlow.git'
                        }
                    }
                }
            }
        }

        stage('Pre-Verification') {
            steps {
                script {
                    def buildMode = (params.IMAGE_BUILD_MODE ?: 'cloud_build').trim()
                    if (buildMode == 'cloud_build') {
                        def cb = "${env.WORKSPACE}/estate-property/jenkins/cloudbuild-estateflow.yaml"
                        if (!fileExists(cb)) {
                            error "Cloud Build config missing: ${cb} (checkout estate-property on a branch that includes jenkins/cloudbuild-estateflow.yaml)"
                        }
                    }
                    def services = env.SELECTED_SERVICES.split(',').collect { it.trim() }
                    for (svc in services) {
                        echo "Verifying ${svc} in ${env.ENV} environment"
                        if (svc == 'estateflow-admin-ui') {
                            if (!fileExists("${env.WORKSPACE}/EstateFlow/EstateFlow-Admin-UI/Dockerfile")) {
                                error "Dockerfile missing: EstateFlow/EstateFlow-Admin-UI/Dockerfile (${env.ENV})"
                            }
                            def uiCb = "${env.WORKSPACE}/estate-property/jenkins/cloudbuild-estateflow-admin-ui.yaml"
                            if (buildMode == 'cloud_build' && !fileExists(uiCb)) {
                                error "Cloud Build config missing: ${uiCb}"
                            }
                        } else {
                            def base = "${env.WORKSPACE}/EstateFlow/EstateFlow-Service/${svc}"
                            if (!fileExists("${base}/pom.xml")) {
                                error "pom.xml missing for ${svc} (${env.ENV})"
                            }
                            if (!fileExists("${env.WORKSPACE}/EstateFlow/EstateFlow-Service/Dockerfile.${svc}")) {
                                error "Dockerfile.${svc} missing for ${svc} (${env.ENV})"
                            }
                        }
                        def chartDeploy = "${env.WORKSPACE}/estate-property/k8s/services/charts/${svc}/templates/deployment.yaml"
                        if (!fileExists(chartDeploy)) {
                            error "K8s deployment missing: ${chartDeploy} (${env.ENV})"
                        }
                    }
                }
            }
        }

        stage('Running-Tests') {
            steps {
                script {
                    def services = env.SELECTED_SERVICES.split(',').collect { it.trim() }
                    def testable = services.findAll { it != 'estateflow-admin-ui' }
                    def runModuleTests = { String svc ->
                        echo "Running tests for ${svc} in ${env.ENV} environment"
                        sh """
                        cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Service/scripts"
                        ./verify-module-jacoco-line.sh ${svc}
                        """
                        echo "Tests for ${svc} in ${env.ENV} environment completed"
                    }
                    if (testable.isEmpty()) {
                        echo 'No Spring module tests (estateflow-admin-ui only selected).'
                    } else if (testable.size() > 1) {
                        def testBranches = [:]
                        testable.each { svc ->
                            def serviceName = svc
                            testBranches["Test ${serviceName}"] = {
                                runModuleTests(serviceName)
                            }
                        }
                        parallel testBranches
                    } else {
                        testable.each { runModuleTests(it) }
                    }
                }
            }
        }

        stage('Authenticate GCP') {
            steps {
                script {
                    def authMode = (params.GCP_AUTH_MODE ?: 'workload_identity').trim()
                    def gkeCreds = """
                        export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                        gcloud config set project ${env.PROJECT_ID} --quiet
                        gcloud auth configure-docker ${env.REGION}-docker.pkg.dev -q
                        gcloud container clusters get-credentials ${env.GKE_CLUSTER} \\
                            --zone ${env.GKE_ZONE} \\
                            --project ${env.PROJECT_ID}
                    """
                    if (authMode == 'secret_key') {
                        withCredentials([file(credentialsId: params.GCP_CREDENTIALS_ID.trim(), variable: 'GCP_KEY')]) {
                            sh """
                            export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                            gcloud auth activate-service-account --key-file=${env.GCP_KEY}
                            ${gkeCreds}
                            """
                        }
                    } else {
                        sh gkeCreds
                    }
                    def jdbcServices = __JDBC_SERVICES__ as Set
                    def needsDb = env.SELECTED_SERVICES.split(',').collect { it.trim() }.any { jdbcServices.contains(it) }
                    if (needsDb && !env.DATABASE_HOST?.trim()) {
                        def dbHost = sh(
                            script: """
                            set +e
                            kubectl get secret estateflow-admin-db -n ${env.NAMESPACE} \\
                                -o jsonpath='{.data.host}' 2>/dev/null | base64 -d | tr -d '\\r\\n'
                            """,
                            returnStdout: true
                        ).trim()
                        if (!dbHost) {
                            dbHost = sh(
                                script: """
                                gcloud secrets versions access latest \\
                                    --secret=${env.ENV}-db-host \\
                                    --project=${env.PROJECT_ID} 2>/dev/null | tr -d '\\r\\n'
                                """,
                                returnStdout: true
                            ).trim()
                        }
                        if (!dbHost) {
                            dbHost = sh(
                                script: """
                                cd "${env.WORKSPACE}/estate-property/deployment/terraform/envs/${env.ENV}"
                                terraform output -raw db_host 2>/dev/null || \\
                                terraform output -raw db_private_ip 2>/dev/null || \\
                                terraform output -raw db_public_ip 2>/dev/null || true
                                """,
                                returnStdout: true
                            ).trim()
                        }
                        if (dbHost) {
                            env.DATABASE_HOST = dbHost
                            echo "DATABASE_HOST resolved: ${dbHost}"
                        }
                    }
                }
            }
        }

        stage('Build-Push-Image') {
            steps {
                echo 'Building the project...'
                script {
                    def services = env.SELECTED_SERVICES.split(',').collect { it.trim() }
                    def imageMode = (params.IMAGE_BUILD_MODE ?: 'cloud_build').trim()
                    def buildPushService = { String svc ->
                        echo "Building ${svc} in ${env.ENV} environment (IMAGE_BUILD_MODE=${imageMode})"
                        if (svc == 'estateflow-admin-ui') {
                            if (imageMode == 'docker') {
                                sh """
                                cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Admin-UI"
                                docker build -t ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG} .
                                docker push ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG}
                                """
                            } else {
                                sh """
                                export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                                cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Admin-UI"
                                gcloud builds submit . \\
                                    --config="${env.WORKSPACE}/estate-property/jenkins/cloudbuild-estateflow-admin-ui.yaml" \\
                                    --substitutions=_AR_IMAGE=${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG}
                                """
                            }
                        } else if (imageMode == 'docker') {
                            sh """
                            cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Service"
                            docker build -f Dockerfile.${svc} -t ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG} .
                            """
                            sh """
                            docker push ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG}
                            """
                        } else {
                            sh """
                            export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                            cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Service"
                            gcloud builds submit . \\
                                --config="${env.WORKSPACE}/estate-property/jenkins/cloudbuild-estateflow.yaml" \\
                                --substitutions=_DOCKERFILE=Dockerfile.${svc},_AR_IMAGE=${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG}
                            """
                        }
                    }
                    if (services.size() > 1) {
                        def buildBranches = [:]
                        services.each { svc ->
                            def serviceName = svc
                            buildBranches["Build ${serviceName}"] = {
                                buildPushService(serviceName)
                            }
                        }
                        parallel buildBranches
                    } else {
                        services.each { buildPushService(it) }
                    }
                }
            }
        }

        stage('Deploy-To-K8s') {
            steps {
                echo 'Deploying the project to K8s'
                script {
                    def services = env.SELECTED_SERVICES.split(',').collect { it.trim() }
                    def arRepo = env.IMAGE_REPOSITORY?.trim() && env.IMAGE_REPOSITORY.contains('/')
                        ? env.IMAGE_REPOSITORY.substring(env.IMAGE_REPOSITORY.lastIndexOf('/') + 1).trim()
                        : "estateflow-${env.ENV}"
                    def dbHost = env.DATABASE_HOST?.trim()
                    def jdbcServices = __JDBC_SERVICES__ as Set
                    def deployService = { String svc ->
                        echo "Deploying ${svc} in ${env.ENV} environment"
                        if (jdbcServices.contains(svc) && !dbHost) {
                            error("databaseHost unset for ${svc}: terraform apply (estateflow-admin-db key host + ${env.ENV}-db-host in Secret Manager), or set DATABASE_HOST on Jenkins. Re-run after Authenticate GCP (get-credentials).")
                        }
                        def dbHostExport = dbHost ? "export DATABASE_HOST='${dbHost}'" : ''
                        sh """
                        export NAMESPACE="${env.NAMESPACE}"
                        export GCP_PROJECT_ID="${env.PROJECT_ID}"
                        export GCP_REGION="${env.REGION}"
                        export ARTIFACT_REGISTRY_REPOSITORY="${arRepo}"
                        ${dbHostExport}
                        cd "${env.WORKSPACE}/estate-property/k8s/scripts"
                        ./deploy.sh ${env.ENV} ${svc} --set-string image.tag=${env.IMAGE_TAG}
                        """
                    }
                    if (services.size() > 1) {
                        def deployBranches = [:]
                        services.each { svc ->
                            def serviceName = svc
                            deployBranches["Deploy ${serviceName}"] = {
                                deployService(serviceName)
                            }
                        }
                        parallel deployBranches
                    } else {
                        services.each { deployService(it) }
                    }
                }
            }
        }

        stage('Pod-Health-Check') {
            steps {
                script {
                    def services = env.SELECTED_SERVICES.split(',').collect { it.trim() }
                    for (svc in services) {
                        sh """
                            echo "Waiting for rollout: deployment/${svc} in namespace: ${env.NAMESPACE}"
                            kubectl rollout status deployment/${svc} \\
                                -n ${env.NAMESPACE} \\
                                --timeout=300s
                            echo "Final pod status (${svc}):"
                            kubectl get pods -n ${env.NAMESPACE} -l "app.kubernetes.io/instance=${svc}" || kubectl get pods -n ${env.NAMESPACE}
                        """
                    }
                }
            }
        }

        stage('Deploy-Platform-Ingress') {
            when {
                expression { params.DEPLOY_PLATFORM_INGRESS }
            }
            steps {
                script {
                    def ingressValues = "${env.WORKSPACE}/estate-property/k8s/env/${env.ENV}/platform-ingress-values.yaml"
                    if (!fileExists(ingressValues)) {
                        error("platform-ingress values missing: ${ingressValues}")
                    }
                    def arRepo = env.IMAGE_REPOSITORY?.trim() && env.IMAGE_REPOSITORY.contains('/')
                        ? env.IMAGE_REPOSITORY.substring(env.IMAGE_REPOSITORY.lastIndexOf('/') + 1).trim()
                        : "estateflow-${env.ENV}"
                    echo "Deploying platform-ingress after service rollouts (routes in k8s/env/${env.ENV}/platform-ingress-values.yaml)"
                    sh """
                    export GCP_PROJECT_ID="${env.PROJECT_ID}"
                    export GCP_REGION="${env.REGION}"
                    export ARTIFACT_REGISTRY_REPOSITORY="${arRepo}"
                    cd "${env.WORKSPACE}/estate-property/k8s/scripts"
                    ./deploy.sh ${env.ENV} platform-ingress
                    """
                    sh """
                    echo "Ingress resources in app namespace ${env.NAMESPACE}:"
                    kubectl get ingress -n ${env.NAMESPACE} -o wide || true
                    """
                }
            }
        }
    }
    post {
        failure {
            script {
                if (params.EMAIL_RECIPIENTS?.trim()) {
                    emailext(
                        subject: "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.ENV})",
                        body: "Build failed: ${env.BUILD_URL}console",
                        to: params.EMAIL_RECIPIENTS
                    )
                }
            }
        }
    }
}
'''.stripIndent()
        .replace('__ALLOWED_SERVICES__', allowedServicesLiteral)
        .replace('__JDBC_SERVICES__', jdbcServicesLiteral)

    definition {
        cps {
            script(pipelineScript)
        }
    }
}
