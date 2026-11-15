// Creates the admin user (credentials from env) and requires login.
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy

def env = System.getenv()
def user = env['JENKINS_ADMIN_USER'] ?: 'admin'
def pass = env['JENKINS_ADMIN_PASSWORD'] ?: 'admin'

def j = Jenkins.get()

def realm = j.getSecurityRealm()
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    realm = new HudsonPrivateSecurityRealm(false)
    j.setSecurityRealm(realm)
}
if (realm.getUser(user) == null) {
    realm.createAccount(user, pass)
}

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(strategy)
j.save()
println "[init] admin user '${user}' ready"
