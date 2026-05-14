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
    String ns = (System.getenv("POD_NAMESPACE") ?: "YOUR_NAMESPACE").trim()
    String secret = (System.getenv("JENKINS_ADMIN_SECRET_NAME") ?: "jenkins-admin").trim()
    String deploy = (System.getenv("JENKINS_K8S_DEPLOYMENT_NAME") ?: "jenkins").trim()
    println("01-configureSecurityRealm: WARN — JENKINS_ADMIN_PASSWORD is not set (Secret missing or Helm security.localAdmin.optionalSecret).")
    println("    Jenkins stays without local login until the Secret exists and this init runs again (restart pod).")
    println("    kubectl create secret generic ${secret} -n ${ns} --from-literal=password='YOUR_STRONG_PASSWORD'")
    println("    kubectl rollout restart deployment/${deploy} -n ${ns}")
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
