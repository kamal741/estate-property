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

pipelineJob("$job_name") {
    description("""\
    Deploy EstateFlow services to GKE: checkout, test, build/push image, Helm upgrade via k8s/scripts/deploy.sh, rollout check.
    <b>ENV</b> is not a job parameter; it must be defined on the controller, folder, or agent (e.g. <code>ENV=dev</code>).
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
        choiceParam('SERVICE_NAME', ['estateflow-admin-service', 'estateflow-brokerage-agent-service', 'estateflow-client-service'], 'Service name')
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
                dir('estate-property') {
                    git branch: "${params.GIT_BRANCH_DEPLOY}",
                        changelog: false,
                        poll: false,
                        url: 'https://github.com/kamal741/estate-property.git'
                }
                dir('EstateFlow') {
                    git branch: "${params.GIT_BRANCH_SERVICE}",
                        changelog: false,
                        poll: false,
                        url: 'https://github.com/pizenith-technologies/EstateFlow.git'
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
                withCredentials([file(credentialsId: 'gcp-sa-key-estateflow', variable: 'GCP_KEY')]) {
                    sh """
                    gcloud auth activate-service-account --key-file=${env.GCP_KEY}
                    gcloud config set project ${env.PROJECT_ID}
                    gcloud auth configure-docker ${env.REGION}-docker.pkg.dev -q
                    gcloud container clusters get-credentials ${env.GKE_CLUSTER} \\
                        --zone ${env.GKE_ZONE} \\
                        --project ${env.PROJECT_ID}
                    """
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
