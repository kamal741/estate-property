import jenkins.*
import hudson.*

// Define variables and some with default values
def job_name = 'Jenkins-Security_Approvals'
def scriptname = this.class.getName() ?: ''

// Grab the old job if it exists
def curJob = hudson.model.Hudson.instance.getItem("$job_name")

// Grab values we want to persist if job exists
def email_recipients = curJob?.getProperty('hudson.model.ParametersDefinitionProperty')?.getParameterDefinition('EMAIL_RECIPIENTS')?.defaultValue ?: ''
def sched = curJob?.triggers.find { it.value instanceof hudson.triggers.TimerTrigger }?.value?.spec ?: '#0 12 * * *'

job("$job_name") {
    description("""\
    Use this job to approve the list of Java methods/classes/signatures that get flagged by Jenkins security as needing approval<br><br>
    If you need to add a new approval please update this job in <a href="https://github.com/kamal741/estate-property">Git</a>.<br>
    Update the "knownsigs" array.<br><br>

    This job is generated/updated via the "Jenkins Seed Job". Any changes that need made can be updated via this job's <a href="https://gitlab.com/anfcorp/eCommWebEng/jenkins-jobs">.groovy file</a> (${scriptname}).<br><br>""".stripIndent())

    logRotator(-1, 32, -1, -1)

    triggers {
        cron("$sched")
    }//closing triggers

    parameters {
        stringParam('EMAIL_RECIPIENTS', "$email_recipients", 'Please be sure to add a comma, between every email address.<br>')
    }//closing parameters section

    wrappers {
        timestamps()
        preBuildCleanup()
    }//closing wrappers

    steps {
        //Remember to escape any backslashes \ with another backslash \\
        dsl('''\
        import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

        //defining our list of known signatures
        String[] knownsigs = [
        "method groovy.json.JsonSlurperClassic parseText java.lang.String",
        "method hudson.model.ItemGroup getItem java.lang.String",
        "method hudson.model.Job isBuildable",
        "method hudson.model.Job isBuilding",
        "method io.jenkins.plugins.casc.ConfigurationAsCode configure",
        "method jenkins.model.Jenkins getItemByFullName java.lang.String",
        "new groovy.json.JsonSlurperClassic",
        "new java.lang.Integer java.lang.String",
        "staticMethod jenkins.model.Jenkins getInstance",
        "staticMethod java.lang.System getenv java.lang.String",
        "method java.util.logging.Logger info java.lang.String",
        "staticMethod groovy.time.TimeCategory minus java.util.Date java.util.Date",
        "staticMethod java.util.logging.Logger getLogger java.lang.String",
        "staticMethod org.codehaus.groovy.runtime.DefaultGroovyMethods toFloat java.lang.Number",
        "staticMethod io.jenkins.plugins.casc.ConfigurationAsCode get",
        "method jenkins.model.Jenkins getComputers",
        "method hudson.model.Computer getExecutors",
        "method hudson.model.Executor isBusy",
        "method jenkins.model.IExecutor getElapsedTime"
        ]

        //file that will be created if anything new needs approved
        def newFile = new File("${WORKSPACE}/approve.flg")

        //Instantiating the ScriptApproval object
        ScriptApproval scriptApproval = ScriptApproval.get()

        //looping through the knownsigs array and approving
        println "\\n"
        knownsigs.each { sig ->
           println "Auto approving known signature: ${sig}"
           scriptApproval.approveSignature(sig)
        }

        if (scriptApproval.pendingSignatures) {
            println "Proceeding to auto-approve any signatures in pending status"
            scriptApproval.pendingSignatures.each {
                println "Approving: ${it.signature}"
                scriptApproval.approveSignature(it.signature)
            }

            //creating flag file
            newFile.createNewFile()

        } else {
            println "\\n"
            println "Nothing found in pending state to approve"
        }

        println "\\n"
        scriptApproval.save()'''.stripIndent()) //closing DSL

        //Remember to escape any backslashes \ with another backslash \\
        dsl('''\
        import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

        println "Running additional approval script"
        println "\\n"

        ScriptApproval scriptApproval = ScriptApproval.get()
        scriptApproval.pendingScripts.each {
            scriptApproval.approveScript(it.hash)
        }

        println "\\n" '''.stripIndent()) //closing DSL

        shell {
            command('''\
        #!/bin/bash
        echo ""
        if [ -f $WORKSPACE/approve.flg ]; then
            echo "##### Flag file found, something needed approving. Please be sure to update this job in Git. #####"
            exit 10
        fi'''.stripIndent())
            unstableReturn(10)
      }//closing shell
    } //closing steps
} //closing jobs
