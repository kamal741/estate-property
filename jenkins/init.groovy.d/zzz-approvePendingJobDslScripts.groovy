import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

// Job DSL registers whole scripts in ScriptApproval.pendingScripts until approved.
// preapproveAll() moves them to approved hashes (no ADMINISTER check); we must save() to persist.
//
// seedJobs.groovy schedules Jenkins-Seed_DSL as soon as Jenkins is up. The first build used to lose
// a race with this thread because we waited 45s before the first pass — "ERROR: script not yet approved for use".
// Run an immediate pass, then poll every few seconds during bootstrap, then a slow tail for late seeds.
boolean preapprovePendingScripts(ScriptApproval approval) {
  try {
    def pendingScripts = approval.pendingScripts?.size() ?: 0
    def pendingSigs = approval.pendingSignatures?.size() ?: 0
    if (pendingScripts == 0 && pendingSigs == 0) {
      return false
    }
    approval.preapproveAll()
    approval.save()
    println("job-dsl-script-approval: auto-approved ${pendingScripts} script(s), ${pendingSigs} signature(s)")
    return true
  } catch (Throwable t) {
    println("job-dsl-script-approval: ${t.class.simpleName}: ${t.message}")
    return false
  }
}

Thread.start {
  def approval = ScriptApproval.get()
  println('job-dsl-script-approval: background thread started (immediate preapprove)')
  preapprovePendingScripts(approval)

  def fastIntervalMs = 5_000L
  def fastPasses = 60
  println("job-dsl-script-approval: fast passes every ${fastIntervalMs / 1000}s × ${fastPasses}")
  fastPasses.times {
    sleep(fastIntervalMs)
    preapprovePendingScripts(approval)
  }

  def intervalMs = 30_000L
  println("job-dsl-script-approval: continuous passes every ${intervalMs / 1000}s (manual seed / Job DSL)")
  while (true) {
    sleep(intervalMs)
    preapprovePendingScripts(approval)
  }
}
