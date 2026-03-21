# Beyond Webster — Why LegacyMCP exists

## The starting point

For years, my team and I faced the same scenario: we needed to assess
an Active Directory environment — how do we get a clear picture of
what's there?

The answer was always the same: the outstanding work of Carl Webster
on PowerShell. His ADDS_Inventory.ps1 script became our reference
standard for AD documentation, giving us a structured, reliable
snapshot of any environment we touched.

Then things change. The world moves forward, driven by AI. And that
raises a question: what if that deep, battle-tested knowledge about
AD assessment could be carried into the new era?

That question is where LegacyMCP begins.

The script that Webster built is the foundation — LegacyMCP does not
replace it, it evolves it. The same scope, the same rigour, the same
respect for what Active Directory actually is under the hood. But with
a new interface: instead of a static report, a conversation. Instead
of pages to scroll, questions to ask. Instead of a snapshot to file
away, a living dataset to interrogate.

This is what changes. And this is what opens new possibilities.

---

## What stays the same

LegacyMCP is built on the same foundation that Webster established.
The functional scope of the Core layer mirrors ADDS_Inventory.ps1
directly — forest structure, domain configuration, domain controllers,
FSMO roles, sites and replication, users, groups, OUs, GPO inventory,
trust relationships, password policies, DNS, and PKI discovery.

The PowerShell collector at the heart of LegacyMCP is the direct heir
of Webster's approach: it runs with the same rights, connects to the
same sources, and collects the same data. If you have used
ADDS_Inventory for years, you will recognise every section.

This is deliberate. Webster's work earned trust over decades precisely
because it was thorough, reliable, and honest about what Active
Directory actually contains. LegacyMCP inherits that trust — and the
responsibility that comes with it.

---

## What changes

The data is the same. What you can do with it is completely different.

Webster's script produces a report — a structured, well-organised
document that captures a moment in time. It is excellent at what it
does. But a report is a destination: you read it, file it, and move
on. The knowledge it contains is locked inside pages.

LegacyMCP turns that same data into a conversation.

| Webster ADDS_Inventory | LegacyMCP |
|------------------------|-----------|
| Static report | Interactive conversation |
| Pages to scroll | Questions to ask |
| One environment at a time | Multiple forests in parallel |
| Single snapshot | Temporal comparisons |
| Finding buried in sections | Finding with severity and context |
| Read by one person | Queryable by any AI-capable tool |

The shift is not cosmetic. When data becomes queryable, the questions
you can ask change. And when the questions change, what you discover
changes too.

---

## New possibilities

Some of what LegacyMCP enables was simply not possible before — not
because the data was missing, but because there was no efficient way
to interrogate it.

Ask questions that would have taken hours to answer manually:

- "Show me all users with adminCount=1 whose password has not changed
  in over two years"
- "Which domain controllers have NTP misconfigured and are also running
  an EOL operating system?"
- "Are there any accounts with unconstrained Kerberos delegation that
  are also members of a privileged group?"

Compare environments that were previously isolated:

- Source forest vs destination forest during a migration — who exists
  in one but not the other, where are the naming conflicts, which
  SIDHistory entries are already in place
- The same environment six months apart — what changed, what was
  remediated, what got worse
- Five client environments loaded simultaneously — patterns that only
  emerge when you can see across boundaries

Enforce consistency across complex environments:

Enterprise organisations that have grown through acquisitions often
find themselves managing multiple Active Directory forests with no
common baseline. Password policies differ, privileged group membership
is inconsistent, delegation configurations vary, GPO structures are
incompatible.

LegacyMCP lets you load all forests simultaneously and ask the question
that was previously unanswerable without weeks of manual work: are we
applying the same security baseline across every environment we own?

Which forests have a lockout threshold below the corporate standard?
Which ones have accounts with unconstrained delegation that the others
have already remediated? Where is the password minimum length
inconsistent across business units?

For organisations managing post-acquisition integration, this is not
a nice-to-have. It is the difference between assuming consistency and
proving it.

Surface findings that hide in plain sight:

A static report shows you that a service account has PasswordNeverExpires
set. LegacyMCP shows you that the same account also has
TrustedForDelegation enabled, has not changed its password in 1,847
days, and is a direct member of Domain Admins — and it tells you this
in one sentence, in response to a single question.

This is the difference between data and intelligence.

---

*LegacyMCP is an open source project by Marco Lelli, Head of Identity
at Impresoft 4ward. Follow the build story on
[Legacy Things](https://legacythings.it).*
