import hudson.model.Cause
import hudson.model.FreeStyleProject
import hudson.model.ParametersAction
import hudson.model.ParametersDefinitionProperty
import hudson.model.StringParameterDefinition
import hudson.model.StringParameterValue
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import hudson.plugins.git.SubmoduleConfig
import hudson.triggers.TimerTrigger
import hudson.tasks.LogRotator
import javaposse.jobdsl.plugin.ExecuteDslScripts
import javaposse.jobdsl.plugin.LookupStrategy
import javaposse.jobdsl.plugin.RemovedJobAction
import javaposse.jobdsl.plugin.RemovedViewAction
import jenkins.model.Jenkins
import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

import java.util.Collections

def jenkinsInstance = Jenkins.getInstance()
def jobName = 'Jenkins-Seed_DSL'

if (jenkinsInstance.getItem(jobName) != null) {
  println("seedJobs: ${jobName} already exists, skipping create")
  return
}

def project = new FreeStyleProject(jenkinsInstance, jobName)
project.setBlockBuildWhenDownstreamBuilding(false)
project.setBlockBuildWhenUpstreamBuilding(false)
project.setConcurrentBuild(false)
project.addTrigger(new TimerTrigger('0 8 * * *'))

project.addProperty(new ParametersDefinitionProperty(
  new StringParameterDefinition('EMAIL_RECIPIENTS', ''),
  new StringParameterDefinition('GIT_BRANCH', 'main')
))

def scm = new GitSCM(
  GitSCM.createRepoList('https://github.com/kamal741/estate-property.git', null),
  Collections.singletonList(new BranchSpec('remotes/origin/$GIT_BRANCH')),
  false,
  Collections.<SubmoduleConfig>emptyList(),
  null,
  null,
  Collections.<hudson.plugins.git.extensions.GitSCMExtension>emptyList()
)
project.setScm(scm)

def dslBuilder = new ExecuteDslScripts()
dslBuilder.setTargets('jenkins-jobs/Jenkins_Seed_DSL.groovy')
dslBuilder.setUseScriptText(false)
dslBuilder.setIgnoreExisting(false)
dslBuilder.setRemovedJobAction(RemovedJobAction.DELETE)
dslBuilder.setRemovedViewAction(RemovedViewAction.DELETE)
dslBuilder.setLookupStrategy(LookupStrategy.JENKINS_ROOT)
project.getBuildersList().add(dslBuilder)

project.setLogRotator(new LogRotator(-1, 10, -1, -1))

jenkinsInstance.add(project, jobName)

def job = jenkinsInstance.getItem(jobName) as FreeStyleProject
println('seedJobs: pre-approving pending Job DSL scripts before first seed build')
def scriptApproval = ScriptApproval.get()
scriptApproval.preapproveAll()
scriptApproval.save()
println('seedJobs: scheduling first Jenkins-Seed_DSL build with default parameters')
job.scheduleBuild2(
  0,
  new Cause.UserIdCause(),
  new ParametersAction(
    new StringParameterValue('GIT_BRANCH', 'main'),
    new StringParameterValue('EMAIL_RECIPIENTS', '')
  )
)
