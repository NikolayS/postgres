# Postgres AI Hacking Tools

A comprehensive set of subagents for AI-assisted Postgres patch development. These tools help prepare patches for human review—they don't replace the critical human elements of actual testing, architectural judgment, and community engagement.

## Available Agents

All agents are defined in `.claude/agents/` and can be invoked with `@agent-name`.

### Development & Build

| Agent | Description |
|-------|-------------|
| **@pg-build** | Build Postgres from source with debug/coverage/performance configurations |
| **@pg-test** | Run regression tests, TAP tests, and add new test coverage |
| **@pg-benchmark** | Performance testing with pgbench, before/after comparisons |
| **@pg-debug** | Debug issues using GDB, core dumps, and logging |

### Code Quality

| Agent | Description |
|-------|-------------|
| **@pg-style** | Code style, pgindent, and Postgres conventions |
| **@pg-review** | AI-assisted code review checklist (use PROACTIVELY before submission) |
| **@pg-coverage** | Test coverage analysis and gap identification |
| **@pg-docs** | Documentation in DocBook SGML format |

### Patch Management

| Agent | Description |
|-------|-------------|
| **@pg-patch-create** | Create clean patches with git format-patch |
| **@pg-patch-version** | Manage versions, rebasing, and updates during review cycle |
| **@pg-patch-apply** | Apply and test patches from others (for reviewing) |

### Community Interaction

| Agent | Description |
|-------|-------------|
| **@pg-hackers-letter** | Write effective emails to pgsql-hackers |
| **@pg-commitfest** | Navigate CommitFest workflow and status management |
| **@pg-feedback** | Address reviewer feedback systematically |

### Quality Gate

| Agent | Description |
|-------|-------------|
| **@pg-readiness** | Comprehensive patch readiness evaluation (use BEFORE submission) |

---

## Quick Start

```bash
# Set up development environment
@pg-build help me build PostgreSQL for development

# Run tests after making changes
@pg-test run regression tests and help me add coverage

# Before submitting - check readiness
@pg-readiness evaluate my patch for submission

# Create the patch
@pg-patch-create prepare my changes as a patch

# Write the email
@pg-hackers-letter draft a submission email for my patch

# After feedback arrives
@pg-feedback help me address the review comments
```

---

## The Patch Lifecycle

```
IDEATION ──► DEVELOPMENT ──► SUBMISSION ──► REVIEW CYCLE ──► COMMIT
    │              │              │              │
    ▼              ▼              ▼              ▼
 Discuss on    @pg-build      @pg-patch-create  @pg-feedback
 pgsql-hackers @pg-test       @pg-hackers-letter @pg-patch-version
 first!        @pg-style      @pg-commitfest
               @pg-docs
               @pg-review
               @pg-readiness
```

**Key Facts:**
- Expect **3+ versions** before acceptance
- Submit patches to **pgsql-hackers@lists.postgresql.org**
- Register in **CommitFest** at commitfest.postgresql.org
- **Review others' patches** (it's expected!)

---

## Critical Human Checkpoints

These CANNOT be automated—humans must:

1. **Test with real data** on real systems
2. **Verify architectural fit** with PostgreSQL design
3. **Build community consensus** on the approach
4. **Engage with reviewers** throughout the process
5. **Make final judgment calls** on trade-offs

---

## Common Pitfalls

| Pitfall | Instead |
|---------|---------|
| Code first, discuss later | Discuss approach on pgsql-hackers BEFORE major work |
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
