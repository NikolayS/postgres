# Postgres AI Hacking Tools

A comprehensive set of subagents for AI-assisted Postgres patch development. These tools help prepare patches for human review—they don't replace the critical human elements of actual testing, architectural judgment, and community engagement.

## Available Agents

Agents are defined in `.claude/agents/` and invoked via natural language:
> "Use the **pg-review** subagent to check my patch"

### Development & Build

| Agent | Description |
|-------|-------------|
| **pg-build** | Build Postgres from source with debug/coverage/performance configurations |
| **pg-test** | Run regression tests, TAP tests, and add new test coverage |
| **pg-benchmark** | Performance testing with pgbench, before/after comparisons |
| **pg-debug** | Debug issues using GDB, core dumps, and logging |

### Code Quality

| Agent | Description |
|-------|-------------|
| **pg-style** | Code style, pgindent, and Postgres conventions |
| **pg-review** | AI-assisted code review checklist (use PROACTIVELY before submission) |
| **pg-coverage** | Test coverage analysis and gap identification |
| **pg-docs** | Documentation in DocBook SGML format |

### Patch Management

| Agent | Description |
|-------|-------------|
| **pg-patch-create** | Create clean patches with git format-patch |
| **pg-patch-version** | Manage versions, rebasing, and updates during review cycle |
| **pg-patch-apply** | Apply and test patches from others (for reviewing) |

### Community Interaction

| Agent | Description |
|-------|-------------|
| **pg-hackers-letter** | Write effective emails to pgsql-hackers |
| **pg-commitfest** | Navigate CommitFest workflow and status management |
| **pg-feedback** | Address reviewer feedback systematically |

### Quality Gate

| Agent | Description |
|-------|-------------|
| **pg-readiness** | Comprehensive patch readiness evaluation (use BEFORE submission) |

---

## Slash Commands

Quick actions defined in `.claude/commands/`:

| Command | Description |
|---------|-------------|
| `/pg-ready` | Check if patch is ready for submission |
| `/pg-submit` | Prepare patch and draft submission email |
| `/pg-respond` | Help respond to reviewer feedback |

---

## Quick Start

```
/pg-ready      # Check if patch is ready
/pg-submit     # Prepare patch + draft email
/pg-respond    # Address reviewer feedback
```

For detailed help, invoke agents via natural language:
> "Use the pg-build subagent to help me configure a debug build"

---

## The Patch Lifecycle (AI Era)

In the AI era, **come to pgsql-hackers with a patch**, not just an idea. Drafting code is now fast—a working prototype speaks louder than abstract discussion.

```
DEVELOP ──► SUBMIT WITH PATCH ──► REVIEW CYCLE ──► COMMIT
    │              │                    │
    ▼              ▼                    ▼
 pg-build      pg-patch-create      pg-feedback
 pg-test       pg-hackers-letter    pg-patch-version
 pg-style      pg-commitfest
 pg-docs
 pg-review
 pg-readiness
```

**Key Facts:**
- Expect **3+ versions** before acceptance
- Submit patches to **pgsql-hackers@lists.postgresql.org**
- Register in **CommitFest** at commitfest.postgresql.org
- **Review others' patches** (it's expected!)

---

## Human + AI Collaboration

| Task | Human | AI Assists |
|------|:-----:|------------|
| **Test with real data** | Required | - |
| **Evaluate architectural fit** | Final call | pg-review analyzes patterns and fit |
| **Build community consensus** | Owns relationships | pg-hackers-letter crafts reasoning |
| **Engage with reviewers** | Required | pg-feedback structures responses |
| **Final judgment calls** | Required | - |

---

## Common Pitfalls

| Pitfall | Instead |
|---------|---------|
| Discuss without code | Come to pgsql-hackers with a working patch—code talks |
| Giant patch touching 50 files | Split into reviewable, logical chunks |
| Ignoring feedback | Address every point, explain disagreements |
| Debug code left in | Remove all printf, #if 0, DEBUG elog |
| "It works on my machine" | Add regression tests proving correctness |
| Outdated patch | Keep rebased on current master |
| Submit during CommitFest | Submit during quiet periods |
| Only submit, never review | Review at least one patch per submission |

---

## References

### Official
- [Submitting a Patch](https://wiki.postgresql.org/wiki/Submitting_a_Patch)
- [Reviewing a Patch](https://wiki.postgresql.org/wiki/Reviewing_a_Patch)
- [CommitFest](https://wiki.postgresql.org/wiki/CommitFest)
- [Postgres Coding Conventions](https://www.postgresql.org/docs/current/source.html)

### Community
- [pgsql-hackers Archives](https://www.postgresql.org/list/pgsql-hackers/)
- [CommitFest App](https://commitfest.postgresql.org/)
- [Understanding pgsql-hackers](https://www.crunchydata.com/blog/understanding-the-postgres-hackers-mailing-list)

---

*Remember: AI assistance helps you be more thorough—it doesn't replace the human judgment, testing, and community engagement that make Postgres great.*
