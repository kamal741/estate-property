import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

// Job DSL "Process DSL scripts" queues whole-script approvals. This runs at full privilege
// (unlike a Pipeline/Job DSL workspace script), so it can clear the pending queue without
// a separate "approval job" and without waiting for any seed job to succeed first.
//
// Two passes: first pass catches fast post-boot runs; second catches seeds triggered minutes
// after startup (a single 45s delay often misses that case).
Thread.start {
  def approval = ScriptApproval.get()
  // Absolute offsets from controller start (not chained sleeps).
  def delaysMs = [45_000L, 300_000L]
  def previous = 0L
  delaysMs.eachWithIndex { delayMs, i ->
    def wait = delayMs - previous
    previous = delayMs
    println("job-dsl-script-approval: waiting ${wait}ms (pass ${i + 1}/${delaysMs.size()}, t=${delayMs / 1000}s from start)...")
    sleep(wait)
    try {
      approval.approvePendingScripts()
      println("job-dsl-script-approval: approvePendingScripts() completed (pass ${i + 1})")
    } catch (Throwable t) {
      println("job-dsl-script-approval (pass ${i + 1}): ${t.class.simpleName}: ${t.message}")
    }
  }
}
