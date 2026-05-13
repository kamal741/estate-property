import jenkins.install.InstallState
import jenkins.model.Jenkins

// Skip the plugin/setup wizard without spawning a background thread. On Jenkins 2.555+,
// setInstallState(INITIAL_SETUP_COMPLETED) ends up in SetupWizard.completeSetup(), which
// requires Overall/Administer — anonymous threads from Thread.start() lose that context and
// throw AccessDeniedException3 (see controller log).
println("disableInstallWizard: setting install state to ${InstallState.INITIAL_SETUP_COMPLETED}")
Jenkins.get().setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
