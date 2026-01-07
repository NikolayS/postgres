# PostgreSQL AI Hacking Toolkit

This directory contains subagents and guidelines for AI-assisted PostgreSQL development, designed to help contributors prepare high-quality patches that meet community standards.

## Quick Reference

| Tool | Purpose |
|------|---------|
| `pg-build` | Build and compile with proper flags |
| `pg-test` | Run regression and TAP tests |
| `pg-bench` | Performance benchmarking |
| `pg-review` | Code review for PG conventions |
| `pg-doc` | Documentation writer |
| `pg-debug` | Debugging assistance |
| `pg-patch` | Patch management (format, version, rebase) |
| `pg-letter` | Email drafting for pgsql-hackers |
| `pg-feedback` | Handle review feedback |

---

## Core Concepts

### The Commitfest Cycle

PostgreSQL uses a structured patch review process through [commitfest.postgresql.org](https://commitfest.postgresql.org/):

- **5 Commitfests per year**: July, September, November, January, March
- **Patch statuses**: Needs Review → Ready for Committer → Committed (or Returned/Rejected)
- **Reciprocity expected**: Each submitter should review at least one other patch
- **Statistics** (Jan 2025 CF): 358 patches total, 82 committed, 211 moved to next CF

### Patch Lifecycle

```
1. Development → 2. Local Testing → 3. Code Review → 4. Format Patch
       ↓                                                    ↓
5. Email to pgsql-hackers → 6. Register in Commitfest → 7. Community Review
       ↓                                                    ↓
8. Address Feedback → 9. Resubmit (v2, v3...) → 10. Ready for Committer → 11. Committed
```

---

## Subagent: pg-build

### Purpose
Build PostgreSQL with appropriate flags for development/testing.

### Build Configurations

#### Debug Build (Recommended for Development)
```bash
# Meson (PostgreSQL 16+)
meson setup build \
    --prefix=$PWD/inst \
    -Dbuildtype=debug \
    -Doptimization=0 \
    -Dcassert=true \
    -Dtap_tests=enabled

meson compile -C build
meson install -C build

# Autoconf (legacy)
./configure \
    --prefix=$PWD/inst \
    --enable-debug \
    --enable-cassert \
    --enable-tap-tests \
    CFLAGS="-O0 -g3"
make -j$(nproc)
make install
```

#### Release Build (for benchmarking)
```bash
meson setup build-release \
    --prefix=$PWD/inst-release \
    -Dbuildtype=release \
    -Doptimization=3

meson compile -C build-release
```

### Key Configure Options

| Option | Purpose |
|--------|---------|
| `--enable-cassert` / `-Dcassert=true` | Enable assertion checks (CRITICAL for development) |
| `--enable-debug` / `-Dbuildtype=debug` | Include debug symbols |
| `--enable-tap-tests` / `-Dtap_tests=enabled` | Enable TAP test framework |
| `-O0` / `-Doptimization=0` | Disable optimization (better debugging) |
| `--with-openssl` | SSL support |
| `--with-libxml` | XML support |

### Verifying Build
```bash
# Check for warnings (there should be none)
meson compile -C build 2>&1 | grep -i warning

# Verify assertions are enabled
./inst/bin/postgres --version  # Should show (debug)
```

---

## Subagent: pg-test

### Purpose
Run PostgreSQL's comprehensive test suites to validate patches.

### Test Hierarchy

```
src/test/
├── regress/          # SQL regression tests (core)
├── isolation/        # Concurrency tests
├── recovery/         # Crash recovery, replication
├── authentication/   # Auth methods
├── modules/          # Test extensions
└── subscription/     # Logical replication
```

### Running Tests

#### Core Regression Tests
```bash
# Build directory tests
cd build
meson test --suite regress

# Or with make
make check              # Uses temporary installation
make installcheck       # Uses existing installation
```

#### TAP Tests (Perl-based)
```bash
# All TAP tests
meson test --suite tap

# Specific module
cd src/bin/pg_dump
make check

# Single test file
make check PROVE_TESTS='t/002_pg_dump.pl'
```

#### Isolation Tests (Concurrency)
```bash
cd src/test/isolation
make check

# Run specific test
make check TESTNAMES="fk-contention"
```

#### Recovery Tests
```bash
cd src/test/recovery
make check

# Retain data on failure for debugging
PG_TEST_NOCLEAN=1 make check
```

### Test Development Patterns

#### Adding SQL Regression Tests
1. Create test file: `src/test/regress/sql/myfeature.sql`
2. Create expected output: `src/test/regress/expected/myfeature.out`
3. Add to schedule: `src/test/regress/parallel_schedule`

```sql
-- sql/myfeature.sql
CREATE TABLE test_table (id int);
SELECT my_new_function(42);
DROP TABLE test_table;
```

#### Adding TAP Tests
```perl
# t/001_mytest.pl
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->start;

# Test logic here
$node->safe_psql('postgres', 'SELECT 1');

ok($node->psql('postgres', 'SELECT my_function()') == 0,
   'my_function works');

$node->stop;
done_testing();
```

### Test Requirements Checklist

- [ ] Core regression tests pass: `make check`
- [ ] Full test suite passes: `make check-world`
- [ ] New functionality has test coverage
- [ ] Edge cases are tested
- [ ] Error conditions are tested
- [ ] No test regressions introduced

---

## Subagent: pg-bench

### Purpose
Performance testing and benchmarking for patches.

### Built-in Benchmarking: pgbench

```bash
# Initialize benchmark database
pgbench -i -s 100 postgres  # Scale factor 100

# Run TPC-B-like benchmark
pgbench -c 10 -j 4 -T 60 postgres  # 10 clients, 4 threads, 60 seconds

# Custom script
pgbench -f myscript.sql -c 10 -T 30 postgres
```

### EXPLAIN ANALYZE for Query Performance

```sql
-- Basic timing
EXPLAIN ANALYZE SELECT ...;

-- With buffer statistics (CRITICAL for I/O analysis)
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- Full output
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) SELECT ...;
```

#### Interpreting EXPLAIN BUFFERS
```
Buffers: shared hit=100 read=50 dirtied=10 written=5
         ↑            ↑         ↑          ↑
         Cache hits   Disk I/O  Modified   Written back
```

### Benchmarking Best Practices

1. **Establish baseline** before applying patch
2. **Use release builds** for benchmarking (not debug)
3. **Warm up caches** before measuring
4. **Multiple runs** to account for variance
5. **Disable autovacuum** for consistent results:
   ```sql
   ALTER SYSTEM SET autovacuum = off;
   SELECT pg_reload_conf();
   ```

### Benchmark Template

```bash
#!/bin/bash
# benchmark.sh

# Configuration
SCALE=100
CLIENTS=10
DURATION=60
RUNS=3

# Initialize
pgbench -i -s $SCALE postgres

# Warmup
pgbench -c $CLIENTS -T 10 postgres > /dev/null 2>&1

# Benchmark runs
for i in $(seq 1 $RUNS); do
    echo "Run $i:"
    pgbench -c $CLIENTS -T $DURATION postgres 2>&1 | grep -E "^(tps|latency)"
done
```

---

## Subagent: pg-review

### Purpose
Review code for PostgreSQL coding conventions and common issues.

### Code Style Requirements

#### Formatting (pgindent)
```bash
# Run on changed files
src/tools/pgindent/pgindent src/backend/myfile.c

# Check without modifying
src/tools/pgindent/pgindent --check src/backend/myfile.c

# Show diff
src/tools/pgindent/pgindent --diff src/backend/myfile.c
```

#### Style Rules

| Rule | Correct | Incorrect |
|------|---------|-----------|
| Indentation | Tabs (4-column) | Spaces |
| Comments | `/* ... */` | `// ...` |
| Line length | ~80 columns (flexible) | Excessively long |
| Braces | K&R style | Allman style |

#### Example Correct Style
```c
/*
 * my_function -- Brief description
 *
 * Detailed description of what this function does,
 * its parameters, and return value.
 */
int
my_function(int arg1, const char *arg2)
{
    int         result;
    ListCell   *lc;

    if (arg1 < 0)
    {
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("arg1 must be non-negative")));
    }

    foreach(lc, mylist)
    {
        MyStruct   *item = lfirst(lc);

        /* Process item */
        result += process_item(item);
    }

    return result;
}
```

### Review Checklist

#### Code Quality
- [ ] Follows PostgreSQL coding conventions
- [ ] No compiler warnings with `-Wall -Werror`
- [ ] Memory properly managed (palloc/pfree)
- [ ] Error messages use ereport() properly
- [ ] No security vulnerabilities (SQL injection, buffer overflow)

#### PostgreSQL-Specific
- [ ] Uses appropriate memory contexts
- [ ] Catalog changes have upgrade path
- [ ] WAL logging for crash safety (if applicable)
- [ ] Proper locking discipline
- [ ] Signal-safe if in signal handler context

#### Commit Hygiene
- [ ] Logical, atomic commits
- [ ] Clear commit messages
- [ ] No unrelated changes mixed in
- [ ] Whitespace-only changes separated

### Common Issues to Flag

```c
// BAD: C++ style comment
/* GOOD: C style comment */

// BAD: Magic numbers
if (count > 42)
// GOOD: Named constants
#define MAX_ITEMS 42
if (count > MAX_ITEMS)

// BAD: Raw malloc
ptr = malloc(size);
// GOOD: PostgreSQL allocator
ptr = palloc(size);

// BAD: printf for errors
printf("Error: %s\n", msg);
// GOOD: ereport
ereport(ERROR,
        (errcode(ERRCODE_INTERNAL_ERROR),
         errmsg("descriptive message: %s", msg)));
```

---

## Subagent: pg-doc

### Purpose
Write documentation following PostgreSQL conventions.

### Documentation Structure

```
doc/src/sgml/
├── ref/              # Reference pages (SQL commands, tools)
├── *.sgml            # Main documentation chapters
└── filelist.sgml     # Master file list
```

### DocBook/SGML Format

```xml
<!-- Section format -->
<sect1 id="my-feature">
 <title>My Feature</title>

 <para>
  Description of the feature with proper
  <emphasis>emphasis</emphasis> and
  <literal>literal text</literal>.
 </para>

 <variablelist>
  <varlistentry>
   <term><literal>parameter_name</literal> (<type>type</type>)</term>
   <listitem>
    <para>
     Description of the parameter.
    </para>
   </listitem>
  </varlistentry>
 </variablelist>
</sect1>
```

### Documentation Guidelines

1. **Match existing style** - Look at similar features for patterns
2. **Reference pages** for SQL commands go in `doc/src/sgml/ref/`
3. **Cross-references** use `<xref linkend="section-id"/>`
4. **Examples** should be complete and runnable
5. **Update release notes** for new features

### Building Documentation
```bash
cd doc/src/sgml
make html           # HTML output
make postgres.pdf   # PDF output
make man           # Man pages
```

### Example: GUC Documentation
```xml
<varlistentry id="guc-my-new-setting" xreflabel="my_new_setting">
 <term><varname>my_new_setting</varname> (<type>integer</type>)
 <indexterm>
  <primary><varname>my_new_setting</varname> configuration parameter</primary>
 </indexterm>
 </term>
 <listitem>
  <para>
   Specifies the number of widgets to frob.
   The default is <literal>100</literal>.
   This parameter can only be set at server start.
  </para>
 </listitem>
</varlistentry>
```

---

## Subagent: pg-debug

### Purpose
Debug PostgreSQL issues using GDB and other tools.

### Setup for Debugging

```bash
# Build with debug symbols and assertions
meson setup build-debug \
    -Dbuildtype=debug \
    -Doptimization=0 \
    -Dcassert=true

# Enable core dumps
ulimit -c unlimited
echo "core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern
```

### Attaching GDB to a Backend

```bash
# In psql, get backend PID
SELECT pg_backend_pid();
-- Returns: 12345

# In another terminal
sudo gdb -p 12345

# Or start from beginning
gdb --args ./postgres -D data_directory
```

### Essential GDB Commands for PostgreSQL

```gdb
# Break on errors
break errfinish

# Break only on ERROR/FATAL/PANIC (level >= 20)
break errfinish if errordata[errordata_stack_depth].elevel >= 20

# Print a Node structure
call pprint(node)

# Print current query
call debug_query_string

# Print a List
call pprint(list)

# Backtrace
bt
bt full

# Continue to next breakpoint
c

# Step into function
s

# Step over
n

# Print variable
p variable_name
p *pointer
```

### Using gdbpg (Enhanced PostgreSQL Debugging)

```bash
# Install: https://github.com/tvondra/gdbpg
git clone https://github.com/tvondra/gdbpg.git
echo "source /path/to/gdbpg/gdbpg.py" >> ~/.gdbinit
```

```gdb
# Pretty-print any Node
pgprint node

# Show query tree
pgprint parse_tree
```

### Debugging Crashes

```bash
# Analyze core dump
gdb ./postgres core.postgres.12345

# In GDB
bt                  # Backtrace
info locals        # Local variables
info args          # Function arguments
frame N            # Switch to frame N
```

### Log-Based Debugging

```sql
-- Enable verbose logging
SET client_min_messages = DEBUG5;
SET log_min_messages = DEBUG5;

-- Log query plans
SET debug_print_parse = on;
SET debug_print_rewritten = on;
SET debug_print_plan = on;
```

### Using rr (Record and Replay)

```bash
# Record execution
rr record ./postgres -D datadir

# Replay and debug
rr replay

# In rr/gdb - can go backwards!
reverse-continue
reverse-step
reverse-next
```

---

## Subagent: pg-patch

### Purpose
Manage patch creation, versioning, and rebasing.

### Creating Patches

#### Using git format-patch (Recommended)

```bash
# Single commit
git format-patch -1 HEAD

# All commits on feature branch since master
git format-patch master

# With version number (for resubmissions)
git format-patch -v2 master

# Output to specific directory
git format-patch -o patches/ master
```

#### Patch Naming Convention
```
v1-0001-Add-new-feature.patch        # First submission
v2-0001-Add-new-feature.patch        # Second version (after feedback)
v3-0001-Add-new-feature.patch        # Third version
```

### Multi-Part Patches

For complex features, split into logical commits:

```bash
# Creates numbered patches
git format-patch master
# 0001-Refactor-existing-code.patch
# 0002-Add-infrastructure.patch
# 0003-Implement-feature.patch
# 0004-Add-tests.patch
# 0005-Add-documentation.patch
```

### Rebasing on Latest Master

```bash
# Fetch latest
git fetch origin master

# Rebase your branch
git checkout my-feature
git rebase origin/master

# If conflicts, resolve and continue
git add resolved_file.c
git rebase --continue

# Force update your remote branch (if applicable)
git push -f origin my-feature
```

### Applying Patches

```bash
# Apply a patch series
git am v2-*.patch

# Apply with 3-way merge (handles conflicts better)
git am -3 v2-*.patch

# If conflicts during am
git am --show-current-patch     # See conflicting patch
git am --abort                  # Abort and reset
git am --skip                   # Skip this patch

# Apply without committing (for review)
git apply --check patch.patch   # Dry run
git apply patch.patch           # Apply to working tree
```

### Verifying Patches

```bash
# Check whitespace issues
git diff --check

# Verify patch applies cleanly to master
git checkout master
git checkout -b test-patch
git am v2-*.patch

# Run tests
make check
```

### Squashing Commits

```bash
# Interactive rebase to squash
git rebase -i master

# In editor, change 'pick' to 'squash' or 's'
pick abc123 First commit
squash def456 Fix typo
squash ghi789 Address review feedback

# Result: single clean commit
```

---

## Subagent: pg-letter

### Purpose
Draft emails for pgsql-hackers mailing list submissions.

### Email Format

#### Subject Line
```
[PATCH v1] Brief description of feature

# For updates:
[PATCH v2] Brief description of feature
Re: [PATCH v1] Brief description of feature
```

#### Email Structure

```
Hi hackers,

[MOTIVATION - Why is this needed?]
This patch adds support for X because Y. Currently, users who need Z
must work around this limitation by doing W, which is problematic
because...

[WHAT IT DOES - High-level description]
The patch implements:
- Feature A that does X
- Enhancement B that improves Y
- Test coverage for new functionality

[IMPLEMENTATION NOTES - Technical details]
The implementation adds a new function foo_bar() in src/backend/...
that handles... The approach was chosen over alternatives because...

[OPEN QUESTIONS - If any]
I'm uncertain about:
1. Whether approach X or Y is preferred for...
2. The naming of the new GUC...

[TESTING]
The patch includes:
- Regression tests in src/test/regress/sql/...
- TAP tests for the new pg_foo utility

All existing tests pass with: make check-world

[PERFORMANCE - If relevant]
Benchmarks show:
- 15% improvement in query X
- No regression in existing functionality

[DOCUMENTATION]
Documentation updates are included for the new feature.

Thanks for reviewing!

--
Your Name
```

### Attaching Patches

1. Use `text/x-patch` or `text/plain` content type
2. **Never** use `application/octet-stream`
3. Attach as files, don't inline large patches
4. Name files clearly: `v1-0001-Add-feature.patch`

### Response to Review

```
Hi [Reviewer],

Thanks for the review!

> [Quote their comment]

[Your response]

> [Another comment]

[Your response]

I've attached v2 of the patch addressing:
- Issue 1: Changed X to Y as suggested
- Issue 2: Added test case for edge condition Z
- Issue 3: Fixed documentation typo

Remaining open items:
- [Any unresolved discussions]

--
Your Name
```

### Common Phrases

| Situation | Phrase |
|-----------|--------|
| Agreeing with feedback | "Good point, I've updated the patch to..." |
| Explaining a choice | "I chose X over Y because..." |
| Asking for clarification | "Could you elaborate on what you mean by...?" |
| Acknowledging mistake | "You're right, I missed that. Fixed in v2." |
| Partial disagreement | "I see your point, but I think X works better here because..." |

### Mailing List Etiquette

- **Reply inline**, not top-posting
- **Trim quotes** to relevant portions
- **Be patient** - reviews take time
- **Be respectful** - even in disagreement
- **Stay on topic** - one thread per patch
- **Update commitfest** entry when posting new versions

---

## Subagent: pg-feedback

### Purpose
Process review feedback and prepare updated patches.

### Workflow

```
1. Receive feedback on mailing list
      ↓
2. Categorize feedback (bug, style, design, question)
      ↓
3. Update code to address feedback
      ↓
4. Update tests if needed
      ↓
5. Run full test suite
      ↓
6. Create new patch version
      ↓
7. Reply to thread with changes summary
      ↓
8. Update commitfest entry status
```

### Picking Up a Previous Patch

```bash
# Find the original thread in archives
# Download latest patch version

# Apply to fresh branch from master
git checkout master
git pull origin master
git checkout -b feature-v3

# Apply patches
git am v2-*.patch

# Make your changes
# ... edit files ...

# Commit changes
git add -A
git commit -m "Address review feedback

- Changed X to Y per reviewer suggestion
- Added test for edge case Z
- Fixed documentation typo"

# Create new version
git format-patch -v3 master
```

### Feedback Response Template

```markdown
## Feedback Tracker for: [Patch Name]

### v1 → v2 Changes
| Reviewer | Comment | Resolution | Status |
|----------|---------|------------|--------|
| Tom Lane | "Should use palloc0 here" | Changed to palloc0 | Done |
| Andres Freund | "Missing WAL logging" | Added WAL support | Done |
| Heikki Linnakangas | "Design question about X" | Discussed, kept as-is | Explained |

### Open Items
- [ ] Performance concern raised by reviewer X
- [ ] Alternative approach suggested by reviewer Y
```

### Commitfest Status Updates

| Status | When to Use |
|--------|-------------|
| Needs Review | Initial submission, waiting for review |
| Waiting on Author | You received feedback, working on v2 |
| Ready for Committer | All review comments addressed |
| Committed | Patch was committed (committer updates) |

### Handling Common Feedback Types

#### "The code is correct but..."
Style/formatting issues - run pgindent and update.

#### "This doesn't handle case X"
Add test case for X, then fix the code.

#### "I don't think this is the right approach"
Discuss alternatives, provide rationale, be open to redesign.

#### "Needs documentation"
Add/update docs in doc/src/sgml/.

#### "Needs tests"
Add regression tests in src/test/regress/ or TAP tests.

#### "This breaks on platform Y"
Check buildfarm results, test on that platform or ask for help.

---

## Quick Checklists

### Before Submitting v1
- [ ] Code compiles without warnings
- [ ] pgindent clean
- [ ] All tests pass (`make check-world`)
- [ ] New tests for new functionality
- [ ] Documentation updated
- [ ] Commit message is clear
- [ ] Patch applies cleanly to master

### Before Submitting vN+1
- [ ] All v(N) feedback addressed or discussed
- [ ] Rebased on current master
- [ ] Tests still pass
- [ ] Patch version incremented
- [ ] Summary of changes prepared

### Commitfest Registration
- [ ] Email sent to pgsql-hackers
- [ ] Patch added to current/next commitfest
- [ ] Correct category selected
- [ ] Message-id links are correct

---

## Resources

### Official Documentation
- [Submitting a Patch](https://wiki.postgresql.org/wiki/Submitting_a_Patch)
- [Reviewing a Patch](https://wiki.postgresql.org/wiki/Reviewing_a_Patch)
- [CommitFest](https://wiki.postgresql.org/wiki/CommitFest)
- [Source Code Formatting](https://www.postgresql.org/docs/current/source-format.html)

### Mailing Lists
- [pgsql-hackers](https://www.postgresql.org/list/pgsql-hackers/)
- [pgsql-hackers archives](https://postgrespro.com/list/pgsql-hackers)

### Tools
- [Commitfest App](https://commitfest.postgresql.org/)
- [PostgreSQL Buildfarm](https://buildfarm.postgresql.org/)
- [gdbpg](https://github.com/tvondra/gdbpg) - Enhanced GDB for PostgreSQL

---

## Example Session: End-to-End Patch Workflow

```bash
# 1. Start fresh from master
git checkout master
git pull origin master
git checkout -b add-my-feature

# 2. Make changes
vim src/backend/executor/execMain.c
vim src/test/regress/sql/myfeature.sql
vim doc/src/sgml/ref/my_command.sgml

# 3. Build and test
meson compile -C build
cd build && meson test --suite regress
cd ..

# 4. Format code
src/tools/pgindent/pgindent src/backend/executor/execMain.c

# 5. Commit
git add -A
git commit -m "Add support for frobnication

This patch adds the ability to frobnicate widgets during
query execution, which improves performance for workloads
that heavily use widget-based operations.

The implementation adds a new GUC 'enable_frobnication'
(default: on) and modifies the executor to check for
frobnication opportunities during ExecProcNode.

Tests and documentation included."

# 6. Create patch
git format-patch master

# 7. Final verification
git checkout master
git checkout -b test-apply
git am 0001-Add-support-for-frobnication.patch
make check-world

# 8. Send to pgsql-hackers and register in commitfest
```

---

*This toolkit is designed to help maintain high-quality contributions to PostgreSQL while leveraging AI assistance responsibly. Human review, testing, and judgment remain essential.*
