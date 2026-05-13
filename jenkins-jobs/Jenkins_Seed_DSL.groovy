import jenkins.*
import jenkins.model.*
import hudson.*
import hudson.model.*

// Define variables and some with default values
def job_name = 'Jenkins-Seed_DSL'

// Grab the old job if it exists
def curJob = hudson.model.Hudson.instance.getItem("$job_name")

// Grab values we want to persist if job exists
def email_recipients = curJob?.getProperty('hudson.model.ParametersDefinitionProperty')?.getParameterDefinition('EMAIL_RECIPIENTS')?.defaultValue ?: ''
def sched = curJob?.triggers.find { it.value instanceof hudson.triggers.TimerTrigger }?.value?.spec ?: '#0 7 * * *'
def git_brnch = curJob?.getProperty('hudson.model.ParametersDefinitionProperty')?.getParameterDefinition('GIT_BRANCH')?.defaultValue ?: 'main'

job("$job_name") {
    description('''\
GIT Project for .groovy files <a href="https://github.com/kamal741/estate-property">URL</a><br/>
''')

    logRotator(-1, 15, -1, -1)

    parameters {
        stringParam('EMAIL_RECIPIENTS', "$email_recipients", 'Please be sure to add a comma, between every email address.<br>')
        stringParam('GIT_BRANCH', "$git_brnch", 'Git branch')
    }

    scm {
        git {
            remote {
                url('https://github.com/kamal741/estate-property.git')
            }
            branch('remotes/origin/$GIT_BRANCH')
        }
    }

    triggers {
        cron("$sched")
    } // closing triggers

    steps {
        dsl {
            external("jenkins-jobs/*.groovy")
            removeAction('DELETE')
        } // closing dsl
    } // closing steps

    publishers {
        extendedEmail {
            recipientList('$EMAIL_RECIPIENTS')
            triggers {
                failure {
                    sendTo {
                        recipientList()
                        subject('Env: $ENVHOST - $PROJECT_DEFAULT_SUBJECT')
                    } // closing sendTo
                    recipientList('$EMAIL_RECIPIENTS')
                    content('''\
                      $PROJECT_DEFAULT_CONTENT

                      Please contact DSRE with any questions.'''.stripIndent())
                } // closing failure
            } // closing triggers
        } // closing extendedEmail
    } // closing publishers
} // closing job
