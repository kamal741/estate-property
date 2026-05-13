import jenkins.*
import jenkins.model.*
import hudson.*
import hudson.model.*
import java.util.*
import hudson.EnvVars.*

// Define variables with default values
def job_name = 'TestPrintPipeline'

// If there is an existing job, grab the current settings
def curJob = hudson.model.Hudson.instance.getItem("$job_name")

pipelineJob("$job_name") {
    logRotator(32, -1, -1, -1)

    definition {
        cps {
            script('''\
#!groovy

pipeline {
    agent any
    stages {
        stage('Test') {
            steps {
                echo 'Hello, World!'
            }
        }
    }
}'''.stripIndent()))
        }
    }
}