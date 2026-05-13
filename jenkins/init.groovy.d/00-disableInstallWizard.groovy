import jenkins.install.InstallState
import jenkins.model.Jenkins

// Run before other numbered init scripts. Complements JAVA_OPTS / JENKINS_OPTS
// (-Djenkins.install.runSetupWizard=false): persists completed install on disk.
def j = Jenkins.get()
println("00-disableInstallWizard: setting ${InstallState.INITIAL_SETUP_COMPLETED}")
j.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
j.save()
