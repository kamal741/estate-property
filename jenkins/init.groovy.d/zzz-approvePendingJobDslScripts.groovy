import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

// Job DSL "Process DSL scripts" submits whole Groovy files to Script Security. Until they are
// approved, the seed fails with "script not yet approved for use". This init runs with full
// privilege and periodically calls approvePendingScripts() so a first seed run that happens
// long after controller boot (common) still gets cleared without opening Manage Jenkins.
//
// Two fixed early passes still help cold-start races; the loop covers "human ran seed at +20m".
Thread.start {
  def approval = ScriptApproval.get()
  def delaysMs = [45_000L, 300_000L]
  def previous = 0L
  delaysMs.eachWithIndex { delayMs, i ->
    def wait = delayMs - previous
    previous = delayMs
    println("job-dsl-script-approval: waiting ${wait}ms (early pass ${i + 1}/${delaysMs.size()}, t=${delayMs / 1000}s from start)...")
    sleep(wait)
    try {
      approval.approvePendingScripts()
      println("job-dsl-script-approval: approvePendingScripts() completed (early pass ${i + 1})")
    } catch (Throwable t) {
      println("job-dsl-script-approval (early pass ${i + 1}): ${t.class.simpleName}: ${t.message}")
    }
  }

  // ~50 minutes of coverage: failed seed queues pending scripts whenever; next iteration clears.
  def intervalMs = 120_000L
  def iterations = 25
  println("job-dsl-script-approval: starting ${iterations} extra passes every ${intervalMs / 1000}s")
  iterations.times { n ->
    sleep(intervalMs)
    try {
      approval.approvePendingScripts()
      println("job-dsl-script-approval: approvePendingScripts() completed (bootstrap ${n + 1}/${iterations})")
    } catch (Throwable t) {
      println("job-dsl-script-approval (bootstrap ${n + 1}): ${t.class.simpleName}: ${t.message}")
    }
  }
  println("job-dsl-script-approval: bootstrap window finished")
}
