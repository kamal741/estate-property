// Job DSL runs in a Groovy sandbox: do not use Jenkins.instance / Hudson.instance.getItem here
// (they require "In-process Script Approval" on every fresh controller).
// Whole-script approval: init hook jenkins/init.groovy.d/zzz-approvePendingJobDslScripts.groovy auto-approves
// pending Job DSL scripts during bootstrap. If you still see "script not yet approved for use", approve in
// Manage Jenkins → In-process Script Approval, rebuild Jenkins-Seed_DSL, or run Jenkins-Security_Approvals.
// Defaults below apply on first run; update EMAIL_RECIPIENTS, GIT_BRANCH, and cron in the UI as needed.

def job_name = 'Jenkins-Seed_DSL'
def email_recipients = ''
def sched = '#0 7 * * *'
def git_brnch = 'main'

job(job_name) {
    description('''\
GIT Project for .groovy files <a href="https://github.com/kamal741/estate-property">URL</a><br/>
''')

    logRotator(-1, 15, -1, -1)

    parameters {
        stringParam('EMAIL_RECIPIENTS', email_recipients, 'Please be sure to add a comma, between every email address.<br>')
        stringParam('GIT_BRANCH', git_brnch, 'Git branch')
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
        cron(sched)
    }

    steps {
        dsl {
            // Explicit order (not *.groovy): Security_Approvals first, then pipelines. Avoids Hudson.instance scripts blocking seed.
            external('jenkins-jobs/Jenkins_Security_Approvals.groovy')
            external('jenkins-jobs/Pipeline_Deploy.groovy')
            external('jenkins-jobs/TestPrintPipeline.groovy')
            removeAction('DELETE')
        }
    }

    publishers {
        downstream('Jenkins-Security_Approvals', 'SUCCESS')
        extendedEmail {
            recipientList('$EMAIL_RECIPIENTS')
            triggers {
                failure {
                    sendTo {
                        recipientList()
                        subject('Env: $ENVHOST - $PROJECT_DEFAULT_SUBJECT')
                    }
                    recipientList('$EMAIL_RECIPIENTS')
                    content('''\
                      $PROJECT_DEFAULT_CONTENT

                      Please contact DSRE with any questions.'''.stripIndent())
                }
            }
        }
    }
}
