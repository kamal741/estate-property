import hudson.security.csrf.DefaultCrumbIssuer
import jenkins.model.Jenkins

def j = Jenkins.instance
j.setCrumbIssuer(new DefaultCrumbIssuer(true))
j.getExtensionList('org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval')[0].get().preapproveAll()
j.save()
