// Creates/updates the freestyle job that curls the floating IP every 5 minutes.
// Uses only Jenkins core classes - no plugins required.
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.tasks.Shell
import hudson.triggers.TimerTrigger
import hudson.tasks.LogRotator

def jobName = 'webz-floating-ip-check'
def schedule = 'H/5 * * * *'   // every 5 minutes

def j = Jenkins.get()
FreeStyleProject job = j.getItem(jobName) ?: j.createProject(FreeStyleProject, jobName)

job.setDescription('curl http://172.28.0.100:80/ (floating IP) and append run time, ' +
                   'responding container and output to /var/log/webz/curl.log')
job.setBuildDiscarder(new LogRotator(-1, 200, -1, -1))   // keep last 200 builds

job.getBuildersList().clear()
job.getBuildersList().add(new Shell(new File('/opt/webz/curl-check.sh').text))

job.getTriggers().keySet().each { job.removeTrigger(it) }
def trigger = new TimerTrigger(schedule)
job.addTrigger(trigger)
trigger.start(job, true)

job.save()
println "[init] job '${jobName}' scheduled: ${schedule}"
