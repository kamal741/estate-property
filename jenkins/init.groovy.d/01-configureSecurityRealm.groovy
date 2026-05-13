import hudson.model.User
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.security.HudsonPrivateSecurityRealm
import jenkins.model.Jenkins

// Headless installs skip the setup wizard; without this, Jenkins often stays on "unsecured" / anonymous-full.
// Requires JENKINS_ADMIN_PASSWORD (and optionally JENKINS_ADMIN_USERNAME, default admin) from the environment,
// typically from a Kubernetes Secret wired in Helm values (see k8s/env/*/jenkins-values.yaml).

def j = Jenkins.get()

if (j.isUseSecurity()
        && j.getSecurityRealm() instanceof HudsonPrivateSecurityRealm
        && j.getAuthorizationStrategy() instanceof FullControlOnceLoggedInAuthorizationStrategy) {
    println("01-configureSecurityRealm: private realm + logged-in authorization already active; skipping")
    return
}

String pass = (System.getenv("JENKINS_ADMIN_PASSWORD") ?: "").trim()
if (!pass) {
    println("01-configureSecurityRealm: WARN — JENKINS_ADMIN_PASSWORD is not set. Jenkins may remain without login.")
    println("    Create a Secret and set security.localAdmin in Helm (see jenkins-values.yaml comments).")
    return
}

String user = (System.getenv("JENKINS_ADMIN_USERNAME") ?: "admin").trim()
println("01-configureSecurityRealm: enabling Hudson private security (user=${user})")

def realm = new HudsonPrivateSecurityRealm(false)
j.setSecurityRealm(realm)

User u = User.get(user, false)
if (u == null) {
    realm.createAccount(user, pass)
    println("01-configureSecurityRealm: created local user ${user}")
} else {
    println("01-configureSecurityRealm: user ${user} already exists; not resetting password from env")
}

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(strategy)
j.save()
println("01-configureSecurityRealm: done — anonymous access disabled; sign in required")
