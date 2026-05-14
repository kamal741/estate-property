// Job DSL reads the existing job so seed re-applies UI defaults (email, cron, git branches).
// Requires "In-process Script Approval" for Hudson.instance on a new controller until approved.
// ENV must be set by Jenkins (global properties, folder env, or agent); e.g. dev or prod.

import hudson.model.Hudson
import hudson.model.ParametersDefinitionProperty
import hudson.triggers.TimerTrigger

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

pipelineJob("$job_name") {
    description("""\
    Deploy EstateFlow services to GKE: checkout, test, build/push image, Helm upgrade via k8s/scripts/deploy.sh, rollout check.
    <b>ENV</b> is not a job parameter; it must be defined on the controller, folder, or agent (e.g. <code>ENV=dev</code>).
    <b>GCP_AUTH_MODE</b>: <code>workload_identity</code> (default) uses the <b>pod</b> Kubernetes service account + GKE Workload Identity (no JSON key): bind the pod SA to a GCP service account and grant it Artifact Registry + GKE deploy roles; build must run <i>inside</i> the cluster. <code>secret_key</code> uses <b>GCP_CREDENTIALS_ID</b> (Secret file JSON) and <code>gcloud auth activate-service-account</code> (for agents outside the cluster or until WI is set up).
    <b>JENKINS_K8S_SERVICE_ACCOUNT</b> should match <code>k8s/services/charts/jenkins/values.yaml</code> <code>serviceAccount.name</code> (default <code>jenkins</code>) — that is the K8s identity Workload Identity annotates to your GCP service account.
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
        choiceParam('SERVICE_NAME', ['estateflow-admin-service', 'estateflow-brokerage-agent-service', 'estateflow-client-service'], 'Service name')
        choiceParam('GCP_AUTH_MODE', ['workload_identity', 'secret_key'], 'workload_identity: no JSON key; pod uses GKE Workload Identity (see job description). secret_key: use GCP_CREDENTIALS_ID JSON file + activate-service-account.')
        stringParam('GCP_CREDENTIALS_ID', "$gcp_cred_id", 'Required when <b>GCP_AUTH_MODE</b> is <code>secret_key</code>: Jenkins <b>Secret file</b> credential ID (GCP service account JSON). Ignored for <code>workload_identity</code>.')
        stringParam('JENKINS_K8S_SERVICE_ACCOUNT', "$jenkins_k8s_sa", 'Must match Jenkins Helm <code>serviceAccount.name</code> (chart values); annotate this K8s SA for Workload Identity to your GCP deploy service account.')
    }

    properties {
        disableConcurrentBuilds()
    }
    definition {
        cps {
            script('''\
pipeline {
    agent any
    options {
        timestamps()
    }
    environment {
        PROJECT_ID = "project-cd7b56f0-4325-4b25-88a"
        REGION     = "us-central1"
        GKE_ZONE   = "us-central1-a"
        GKE_CLUSTER = "${env.ENV}-estateflow-cluster"
        NAMESPACE   = "${env.ENV}-estateflow"
        IMAGE_REPOSITORY = "${REGION}-docker.pkg.dev/${PROJECT_ID}/estateflow-${env.ENV}"
    }
    stages {
        stage('Validate') {
            steps {
                script {
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
                    def services = [params.SERVICE_NAME]
                    for (svc in services) {
                        echo "Verifying ${svc} in ${env.ENV} environment"
                        def base = "${env.WORKSPACE}/EstateFlow/EstateFlow-Service/${svc}"
                        if (!fileExists("${base}/pom.xml")) {
                            error "pom.xml missing for ${svc} (${env.ENV})"
                        }
                        if (!fileExists("${base}/Dockerfile.${svc}")) {
                            error "Dockerfile.${svc} missing for ${svc} (${env.ENV})"
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
                    def services = [params.SERVICE_NAME]
                    for (svc in services) {
                        echo "Running tests for ${svc} in ${env.ENV} environment"
                        sh """
                        cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Service/scripts"
                        ./verify-module-jacoco-line.sh ${svc}
                        """
                        echo "Tests for ${svc} in ${env.ENV} environment completed"
                    }
                }
            }
        }

        stage('Authenticate GCP') {
            steps {
                script {
                    def authMode = (params.GCP_AUTH_MODE ?: 'workload_identity').trim()
                    if (authMode == 'secret_key') {
                        withCredentials([file(credentialsId: params.GCP_CREDENTIALS_ID.trim(), variable: 'GCP_KEY')]) {
                            sh """
                            export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                            gcloud auth activate-service-account --key-file=${env.GCP_KEY}
                            gcloud config set project ${env.PROJECT_ID} --quiet
                            gcloud auth configure-docker ${env.REGION}-docker.pkg.dev -q
                            gcloud container clusters get-credentials ${env.GKE_CLUSTER} \\
                                --zone ${env.GKE_ZONE} \\
                                --project ${env.PROJECT_ID}
                            """
                        }
                    } else {
                        sh """
                        export CLOUDSDK_CORE_DISABLE_PROMPTS=1
                        gcloud config set project ${env.PROJECT_ID} --quiet
                        gcloud auth configure-docker ${env.REGION}-docker.pkg.dev -q
                        """
                    }
                }
            }
        }

        stage('Build-Push-Image') {
            steps {
                echo 'Building the project...'
                script {
                    def services = [params.SERVICE_NAME]
                    for (svc in services) {
                        echo "Building ${svc} in ${env.ENV} environment"
                        sh """
                        cd "${env.WORKSPACE}/EstateFlow/EstateFlow-Service"
                        docker build -f Dockerfile.${svc} -t ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG} .
                        """
                        sh """
                        docker push ${env.IMAGE_REPOSITORY}/${svc}:${env.IMAGE_TAG}
                        """
                    }
                }
            }
        }

        stage('Deploy-To-K8s') {
            steps {
                echo 'Deploying the project to K8s'
                script {
                    def services = [params.SERVICE_NAME]
                    for (svc in services) {
                        echo "Deploying ${svc} in ${env.ENV} environment"
                        sh """
                        export NAMESPACE="${env.NAMESPACE}"
                        cd "${env.WORKSPACE}/estate-property/k8s/scripts"
                        ./deploy.sh ${env.ENV} ${svc} --set-string image.tag=${env.IMAGE_TAG}
                        """
                    }
                }
            }
        }

        stage('Pod-Health-Check') {
            steps {
                sh """
                    echo "Waiting for rollout: deployment/${params.SERVICE_NAME} in namespace: ${env.NAMESPACE}"
                    kubectl rollout status deployment/${params.SERVICE_NAME} \\
                        -n ${env.NAMESPACE} \\
                        --timeout=300s
                    echo "Final pod status:"
                    kubectl get pods -n ${env.NAMESPACE} -l "app.kubernetes.io/instance=${params.SERVICE_NAME}" || kubectl get pods -n ${env.NAMESPACE}
                """
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
'''.stripIndent())
        }
    }
}
