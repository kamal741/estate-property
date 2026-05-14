import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

// Job DSL registers whole scripts in ScriptApproval.pendingScripts until approved.
// preapproveAll() moves them to approved hashes (no ADMINISTER check); we must save() to persist.
//
// seedJobs.groovy schedules Jenkins-Seed_DSL as soon as Jenkins is up. The first build used to lose
// a race with this thread because we waited 45s before the first pass — "ERROR: script not yet approved for use".
// Run an immediate pass, then poll every few seconds during bootstrap, then a slow tail for late seeds.
void preapprovePendingScripts(ScriptApproval approval) {
  try {
    approval.preapproveAll()
    approval.save()
  } catch (Throwable t) {
    println("job-dsl-script-approval: ${t.class.simpleName}: ${t.message}")
  }
}

Thread.start {
  def approval = ScriptApproval.get()
  println('job-dsl-script-approval: bootstrap thread started (immediate preapprove)')
  preapprovePendingScripts(approval)

  def fastIntervalMs = 5_000L
  def fastPasses = 60
  println("job-dsl-script-approval: fast passes every ${fastIntervalMs / 1000}s × ${fastPasses} (~${fastPasses * fastIntervalMs / 60_000} min)")
  fastPasses.times {
    sleep(fastIntervalMs)
    preapprovePendingScripts(approval)
  }

  def intervalMs = 120_000L
  def iterations = 25
  println("job-dsl-script-approval: slow passes every ${intervalMs / 1000}s × ${iterations}")
  iterations.times {
    sleep(intervalMs)
    preapprovePendingScripts(approval)
  }
  println('job-dsl-script-approval: bootstrap window finished')
}
