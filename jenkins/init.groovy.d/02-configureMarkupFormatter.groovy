import hudson.markup.EscapedMarkupFormatter
import hudson.markup.RawHtmlMarkupFormatter
import jenkins.model.Jenkins

// antisamy-markup-formatter is in plugins.txt; installing it does not switch the global formatter.
// Default Jenkins uses EscapedMarkupFormatter (HTML shown as literal in job descriptions). Switch once to OWASP Safe HTML.

def j = Jenkins.instance
def fmt = j.getMarkupFormatter()

if (fmt instanceof RawHtmlMarkupFormatter) {
    println("02-configureMarkupFormatter: OWASP Safe HTML already active; skipping")
    return
}
if (!(fmt instanceof EscapedMarkupFormatter)) {
    println("02-configureMarkupFormatter: markup formatter is ${fmt?.class?.name}; leaving unchanged (only auto-replace default escaped)")
    return
}

j.setMarkupFormatter(RawHtmlMarkupFormatter.INSTANCE)
j.save()
println("02-configureMarkupFormatter: set OWASP Safe HTML (RawHtmlMarkupFormatter)")
