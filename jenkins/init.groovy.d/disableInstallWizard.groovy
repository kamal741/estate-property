import jenkins.model.*;
import jenkins.install.*;

Thread.start {
    println("I Need to let jenkins complete startup before running this command")
    sleep 15000
    Jenkins.getInstance().setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
}
