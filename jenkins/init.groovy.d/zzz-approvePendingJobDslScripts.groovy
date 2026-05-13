import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

// Job DSL queues whole scripts as "pending" until approved. There is no approvePendingScripts()
// on ScriptApproval — use preapproveAll() then save() (same as 97-setCSRF..., but 97 runs
// before any Job DSL has executed; this thread repeats so a later first seed is cleared).
void preapprovePendingScripts(ScriptApproval approval) {
  try {
    approval.preapproveAll()
    approval.save()
    println("job-dsl-script-approval: preapproveAll()+save() completed")
  } catch (Throwable t) {
    println("job-dsl-script-approval: ${t.class.simpleName}: ${t.message}")
  }
}

Thread.start {
  def approval = ScriptApproval.get()
  def delaysMs = [45_000L, 300_000L]
  def previous = 0L
  delaysMs.eachWithIndex { delayMs, i ->
    def wait = delayMs - previous
    previous = delayMs
    println("job-dsl-script-approval: waiting ${wait}ms (early pass ${i + 1}/${delaysMs.size()}, t=${delayMs / 1000}s from start)...")
    sleep(wait)
    preapprovePendingScripts(approval)
  }

  def intervalMs = 120_000L
  def iterations = 25
  println("job-dsl-script-approval: starting ${iterations} extra passes every ${intervalMs / 1000}s")
  iterations.times { n ->
    sleep(intervalMs)
    preapprovePendingScripts(approval)
  }
  println("job-dsl-script-approval: bootstrap window finished")
}
