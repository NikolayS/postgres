# PostgreSQL AI Hacking Tools

A comprehensive set of subagents and workflows for developing, testing, reviewing, and submitting PostgreSQL patches using AI assistance.

> **Philosophy**: AI-assisted PostgreSQL development means combining the thoroughness and consistency of automated analysis with the judgment and testing that only humans can provide. These tools help prepare patches for human review—they don't replace the critical human elements of actual testing, architectural judgment, and community engagement.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [The PostgreSQL Patch Lifecycle](#the-postgresql-patch-lifecycle)
3. [Subagents](#subagents)
   - [pg-build](#pg-build) - Building and compiling PostgreSQL
   - [pg-test](#pg-test) - Running regression and TAP tests
   - [pg-benchmark](#pg-benchmark) - Performance testing with pgbench
   - [pg-docs](#pg-docs) - Documentation authoring
   - [pg-style](#pg-style) - Code style and pgindent
   - [pg-review](#pg-review) - AI-assisted code review
   - [pg-debug](#pg-debug) - Debugging techniques
   - [pg-patch-create](#pg-patch-create) - Creating clean patches
   - [pg-patch-version](#pg-patch-version) - Managing patch versions and rebasing
   - [pg-patch-apply](#pg-patch-apply) - Applying and testing existing patches
   - [pg-hackers-letter](#pg-hackers-letter) - Writing emails to pgsql-hackers
   - [pg-commitfest](#pg-commitfest) - CommitFest workflow management
   - [pg-feedback](#pg-feedback) - Responding to reviewer feedback
   - [pg-coverage](#pg-coverage) - Test coverage analysis
   - [pg-readiness](#pg-readiness) - Patch readiness evaluation
4. [Workflows](#workflows)
5. [Critical Human Checkpoints](#critical-human-checkpoints)
6. [Common Pitfalls](#common-pitfalls)
7. [References](#references)

---

## Quick Start

```
# Evaluate if a patch is ready for submission
Use @pg-readiness to evaluate my patch for <feature>

# Prepare a patch for pgsql-hackers
Use @pg-patch-create to prepare my changes for submission

# Write the cover letter email
Use @pg-hackers-letter to draft an email for my <feature> patch

# After receiving feedback, address it
Use @pg-feedback to help me address the review comments on <thread>
```

---

## The PostgreSQL Patch Lifecycle

Understanding the full lifecycle is critical for success:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. IDEATION                                                                 │
│     - Search pgsql-hackers archives for prior discussions                   │
│     - Discuss idea on pgsql-hackers BEFORE coding (for non-trivial work)    │
│     - Get early feedback on approach                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  2. DEVELOPMENT                                                              │
│     - Implement on a clean branch from master                               │
│     - Write tests (regression tests, TAP tests as appropriate)              │
│     - Add/update documentation                                               │
│     - Run full test suite locally                                            │
│     - Run pgindent on modified files                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  3. SUBMISSION                                                               │
│     - Generate patch with git format-patch                                  │
│     - Write clear cover letter email                                         │
│     - Submit to pgsql-hackers mailing list                                  │
│     - Register in CommitFest (commitfest.postgresql.org)                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  4. REVIEW CYCLE (expect 3+ iterations)                                     │
│     - Respond to feedback promptly                                           │
│     - Rebase if master has changed significantly                            │
│     - Submit updated versions (v2, v3, ...)                                 │
│     - Address all reviewer concerns                                          │
│     - Be patient—quality takes time                                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  5. COMMIT                                                                   │
│     - "Ready for Committer" status in CommitFest                            │
│     - Committer reviews and potentially requests final changes              │
│     - Patch is committed (or returned with feedback)                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Statistics**:
- Very few patches are committed exactly as originally submitted
- Plan for **at least 3 versions** before final acceptance
- CommitFests run 5 times per year (July, September, November, January, March)
- Each patch submitter is expected to review at least one other patch

---

## Subagents

### pg-build

**Purpose**: Build and compile PostgreSQL from source with various configurations.

**When to use**: Setting up development environment, testing compilation, preparing for testing.

```markdown
## Building PostgreSQL for Development

### Quick Development Build
```bash
# Configure with debugging enabled
./configure \
  --enable-cassert \
  --enable-debug \
  --enable-tap-tests \
  --prefix=$HOME/pg-dev \
  CFLAGS="-O0 -g3 -fno-omit-frame-pointer"

# Build (adjust -j for your CPU cores)
make -j$(nproc) -s

# Install
make install
```

### Build with Coverage (for test coverage analysis)
```bash
./configure \
  --enable-cassert \
  --enable-debug \
  --enable-tap-tests \
  --enable-coverage \
  --prefix=$HOME/pg-dev

make -j$(nproc)
make install
```

### Using Meson (modern alternative)
```bash
meson setup \
  -Dcassert=true \
  -Ddebug=true \
  -Dtap_tests=enabled \
  -Dprefix=$HOME/pg-dev \
  builddir

cd builddir
ninja
ninja install
```

### Speed Optimizations
```bash
# Use ccache for faster rebuilds
export CC="ccache gcc"
export CXX="ccache g++"

# Use gold linker on Linux
export CFLAGS="-fuse-ld=gold"
```

### Initialize and Start
```bash
export PGDATA=$HOME/pg-dev/data
export PATH=$HOME/pg-dev/bin:$PATH

initdb -D $PGDATA
pg_ctl -D $PGDATA -l logfile start
```

### Common Build Issues
- Missing dependencies: Install `libreadline-dev`, `zlib1g-dev`, `libssl-dev`
- TAP tests require Perl `IPC::Run` module
- Coverage requires `gcov` and `lcov`
```

---

### pg-test

**Purpose**: Run PostgreSQL regression tests and TAP tests.

**When to use**: After making code changes, before submitting patches, verifying fixes.

```markdown
## PostgreSQL Testing Guide

### Quick Test Commands
```bash
# Run main regression tests (starts fresh server)
make check

# Run tests against existing server (faster)
make installcheck

# Run parallel tests against existing server (fastest)
make installcheck-parallel

# Run all tests including contrib
make check-world
```

### TAP Tests
```bash
# Run all TAP tests
make check PROVE_TESTS=''

# Run specific TAP test
make check PROVE_TESTS='t/001_basic.pl'

# Run TAP tests in a specific directory
cd src/bin/psql
make check
```

### Testing Specific Subsystems
```bash
# Test only src/backend
cd src/backend && make check

# Test contrib modules
cd contrib/pgcrypto && make check

# Test isolation tests (for concurrency)
make isolation-check
```

### Regression Test Files
- Test definitions: `src/test/regress/sql/*.sql`
- Expected output: `src/test/regress/expected/*.out`
- Schedule: `src/test/regress/parallel_schedule`

### Adding New Regression Tests
1. Create `src/test/regress/sql/my_test.sql`
2. Run and capture output: `psql -f sql/my_test.sql > expected/my_test.out 2>&1`
3. Review and edit expected output
4. Add to `parallel_schedule` or `serial_schedule`

### Adding TAP Tests
1. Create test in `t/` directory (e.g., `t/010_my_test.pl`)
2. Use PostgreSQL::Test::Cluster module
3. Follow existing test patterns

Example TAP test structure:
```perl
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->start;

# Your tests here
$node->safe_psql('postgres', 'SELECT 1');
is($result, '1', 'basic query works');

$node->stop;
done_testing();
```

### Test Failures
- Check `regression.diffs` for differences
- Review `regression.out` for actual output
- Use `diff -u expected/foo.out results/foo.out` for detailed comparison
```

---

### pg-benchmark

**Purpose**: Performance testing and benchmarking with pgbench.

**When to use**: Evaluating performance impact of changes, comparing before/after.

```markdown
## PostgreSQL Benchmarking Guide

### Basic pgbench Usage
```bash
# Initialize benchmark database (scale factor 10 = ~160MB)
pgbench -i -s 10 benchdb

# Run standard TPC-B-like benchmark
pgbench -c 10 -j 2 -T 60 benchdb
# -c: clients, -j: threads, -T: duration in seconds
```

### Before/After Performance Comparison
```bash
# 1. Build and test baseline (master)
git checkout master
make clean && make -j$(nproc) && make install
pgbench -i -s 100 benchdb
pgbench -c 20 -j 4 -T 300 -P 10 benchdb > baseline.txt

# 2. Build and test with patch
git checkout my-feature-branch
make clean && make -j$(nproc) && make install
dropdb benchdb && createdb benchdb
pgbench -i -s 100 benchdb
pgbench -c 20 -j 4 -T 300 -P 10 benchdb > patched.txt

# 3. Compare results
diff baseline.txt patched.txt
```

### Custom Benchmark Scripts
```bash
# Create custom script (custom.sql)
cat > custom.sql << 'EOF'
\set aid random(1, 100000 * :scale)
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
EOF

# Run with custom script
pgbench -f custom.sql -c 10 -T 60 benchdb
```

### Benchmark Best Practices
- **Scale factor**: Should be >= number of clients
- **Duration**: At least 60 seconds for stable results
- **Warmup**: Run a short benchmark first to warm caches
- **Multiple runs**: Average 3-5 runs for reliability
- **Disable autovacuum**: Can cause unpredictable variations
- **Dedicated machine**: Avoid noisy neighbor effects

### Key Metrics to Report
- TPS (transactions per second)
- Latency average and stddev
- Connection time
- Before/after comparison with percentage change

### Advanced: Using pgbent
```bash
# pgbent provides more sophisticated benchmarking
# https://github.com/gregs1104/pgbent
git clone https://github.com/gregs1104/pgbent
cd pgbent
# Follow pgbent documentation for setup
```
```

---

### pg-docs

**Purpose**: Write and update PostgreSQL documentation.

**When to use**: Adding documentation for new features, updating existing docs.

```markdown
## PostgreSQL Documentation Guide

### Documentation Location
- Main docs: `doc/src/sgml/`
- Reference pages: `doc/src/sgml/ref/`

### Documentation Format
PostgreSQL uses DocBook SGML/XML. Key rules:
- Use semantic markup, not formatting markup
- Follow existing patterns in nearby documentation
- Keep line lengths reasonable (80 chars preferred)

### Common DocBook Elements
```xml
<!-- Paragraphs -->
<para>
 Your paragraph text here.
</para>

<!-- Code blocks -->
<programlisting>
SELECT * FROM foo;
</programlisting>

<!-- Inline code -->
<command>pg_dump</command>
<literal>NULL</literal>
<varname>my_variable</varname>
<function>pg_backend_pid()</function>

<!-- Lists -->
<itemizedlist>
 <listitem><para>Item one</para></listitem>
 <listitem><para>Item two</para></listitem>
</itemizedlist>

<!-- Tables -->
<table>
 <title>My Table</title>
 <tgroup cols="2">
  <thead>
   <row><entry>Column 1</entry><entry>Column 2</entry></row>
  </thead>
  <tbody>
   <row><entry>Data 1</entry><entry>Data 2</entry></row>
  </tbody>
 </tgroup>
</table>

<!-- Cross-references -->
<xref linkend="section-id"/>

<!-- Notes and warnings -->
<note><para>Important note here.</para></note>
<warning><para>Warning message here.</para></warning>
```

### Building Documentation
```bash
cd doc/src/sgml

# Build HTML (requires jade/openjade)
make html

# Build single HTML file
make postgres.html

# Build man pages
make man
```

### Documentation Checklist for New Features
1. [ ] Add to appropriate chapter in `doc/src/sgml/`
2. [ ] Update release notes in `doc/src/sgml/release-*.sgml`
3. [ ] Add reference page if adding new command/function
4. [ ] Cross-reference from related sections
5. [ ] Include examples showing typical usage
6. [ ] Document error messages and edge cases

### Style Guidelines
- Write for users, not developers
- Lead with the most common use case
- Include working examples
- Explain "why" not just "what"
- Be concise but complete
```

---

### pg-style

**Purpose**: Ensure code follows PostgreSQL coding conventions.

**When to use**: Before submitting patches, after making code changes.

```markdown
## PostgreSQL Code Style Guide

### Core Formatting Rules
- **Indentation**: 4-space tabs (actual tab characters)
- **Line length**: 80 columns preferred (flexible for readability)
- **Braces**: BSD style (on their own lines)
- **Comments**: C-style only (`/* */`), no C++ style (`//`)

### Running pgindent
```bash
# From PostgreSQL source root
src/tools/pgindent/pgindent src/backend/path/to/modified_file.c

# Run on all modified files
git diff --name-only HEAD~1 | grep '\.[ch]$' | xargs src/tools/pgindent/pgindent
```

### Code Style Examples

```c
/* Function declarations */
static int
my_function(int arg1, const char *arg2)
{
    int         result;

    if (arg1 < 0)
    {
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("arg1 must be non-negative")));
    }

    /*
     * Multi-line comments should be formatted
     * like this, with asterisks aligned.
     */
    for (int i = 0; i < arg1; i++)
    {
        /* Single line comment */
        result += process_item(i);
    }

    return result;
}
```

### Variable Naming
- Use lowercase with underscores: `my_variable`
- Global variables: prefix with module name
- Struct members: descriptive names
- Loop counters: `i`, `j`, `k` are fine for simple loops

### Header Files
```c
/* Include guard */
#ifndef MY_HEADER_H
#define MY_HEADER_H

/* System includes first */
#include <stdio.h>

/* PostgreSQL includes */
#include "postgres.h"
#include "fmgr.h"

/* Function declarations */
extern int my_function(int arg1);

#endif /* MY_HEADER_H */
```

### Error Messages
```c
ereport(ERROR,
        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
         errmsg("invalid value for parameter \"%s\": %d",
                param_name, param_value),
         errdetail("Value must be between %d and %d.",
                   min_value, max_value),
         errhint("Check your configuration settings.")));
```

### Editor Setup
```bash
# Vim settings (add to .vimrc)
autocmd FileType c setlocal tabstop=4 shiftwidth=4 noexpandtab

# Emacs - use settings from src/tools/editors/emacs.samples
```

### Pre-submission Checklist
1. [ ] Run pgindent on all modified .c and .h files
2. [ ] No trailing whitespace
3. [ ] No C++ style comments
4. [ ] Braces on their own lines
5. [ ] Line length reasonable (mostly ≤80 chars)
6. [ ] Error messages use ereport() properly
```

---

### pg-review

**Purpose**: AI-assisted code review to catch common issues before submission.

**When to use**: Before submitting patches, as self-review checklist.

```markdown
## AI-Assisted Code Review Checklist

### Phase 1: Submission Review (Does it apply cleanly?)
- [ ] Patch applies to current master without conflicts
- [ ] No unintended whitespace changes
- [ ] No debug code left in (printf, elog(DEBUG), #if 0 blocks)
- [ ] No unrelated changes mixed in

### Phase 2: Functional Review
- [ ] Code does what the commit message says
- [ ] All code paths are reachable and tested
- [ ] Edge cases handled (NULL, empty, max values)
- [ ] Backwards compatibility maintained (or break documented)

### Phase 3: Code Quality Review
- [ ] Follows PostgreSQL coding style (run pgindent)
- [ ] Comments explain "why", not "what"
- [ ] Variable names are clear and consistent
- [ ] No memory leaks (palloc balanced with pfree where appropriate)
- [ ] Error messages are clear and actionable
- [ ] Uses appropriate error codes (ERRCODE_*)

### Phase 4: Security Review
- [ ] No SQL injection vulnerabilities
- [ ] No buffer overflows (use strlcpy, snprintf)
- [ ] Privileges checked appropriately
- [ ] Input validation present where needed

### Phase 5: Performance Review
- [ ] No O(n²) algorithms for large n
- [ ] Appropriate use of indexes and caching
- [ ] No unnecessary memory allocations in loops
- [ ] Consider catalog cache implications

### Phase 6: Documentation Review
- [ ] User-facing changes documented
- [ ] Release notes updated
- [ ] Error messages documented if new
- [ ] Examples provided for new features

### Phase 7: Test Coverage Review
- [ ] Regression tests added for new functionality
- [ ] Edge cases tested
- [ ] Error paths tested
- [ ] TAP tests for client tools/utilities

### Common Issues AI Can Catch
1. **Style violations** - Wrong indent, C++ comments
2. **Missing error handling** - Unchecked return values
3. **Memory issues** - Leaks, use after free patterns
4. **Copy-paste errors** - Wrong variable names
5. **Incomplete changes** - Function renamed but not all callers
6. **Debug leftovers** - Printf statements, #if 0 blocks

### Questions for Human Review
After AI review, humans should verify:
1. Is this the right approach architecturally?
2. Does this integrate well with existing code?
3. Are there simpler alternatives?
4. What are the implications for future development?
5. Does this work correctly under concurrent access?
```

---

### pg-debug

**Purpose**: Debug PostgreSQL issues using GDB and other tools.

**When to use**: Investigating crashes, hangs, unexpected behavior.

```markdown
## PostgreSQL Debugging Guide

### Build for Debugging
```bash
./configure \
  --enable-cassert \
  --enable-debug \
  CFLAGS="-O0 -g3 -fno-omit-frame-pointer"

make -j$(nproc)
make install
```

### Attaching GDB to Running Backend
```bash
# Find backend PID
psql -c "SELECT pg_backend_pid();"
# Returns: 12345

# Attach GDB
gdb -p 12345

# Or attach to specific backend
gdb /path/to/postgres 12345
```

### Useful GDB Commands
```gdb
# Breakpoints
break errfinish                    # Break on errors
break ExecProcNode                 # Break in executor
break ereport                      # Break on ereport calls

# Stack trace
bt                                 # Basic backtrace
bt full                            # With local variables
thread apply all bt                # All threads

# Examining data
print *node                        # Print structure
print nodeToString(node)           # Pretty print node tree
ptype MyStruct                     # Show structure definition

# Continuing
continue                           # Continue execution
next                               # Step over
step                               # Step into
finish                             # Run until function returns

# PostgreSQL-specific
call elog_node_display(DEBUG1, "mynode", node, true)
```

### Core Dump Analysis
```bash
# Enable core dumps
ulimit -c unlimited

# Configure systemd (if needed)
# Add LimitCORE=infinity to postgresql.service

# Analyze core dump
gdb /path/to/postgres /path/to/core

# Quick backtrace
gdb -q /path/to/postgres /path/to/core \
    -ex "thread apply all bt" \
    -ex "quit"
```

### Debugging Specific Issues

#### Query Hangs
```bash
# Attach to backend
gdb -p <backend_pid>

# Get backtrace
bt

# Check locks
SELECT * FROM pg_locks WHERE pid = <backend_pid>;
SELECT * FROM pg_stat_activity WHERE pid = <backend_pid>;
```

#### Memory Issues (Valgrind)
```bash
# Run postgres under valgrind
valgrind --leak-check=full \
         --track-origins=yes \
         --log-file=valgrind.log \
         postgres -D $PGDATA

# Or run regression tests
make installcheck VALGRIND=1
```

#### Logging for Debug
```sql
-- Increase logging temporarily
SET log_statement = 'all';
SET log_lock_waits = on;
SET log_min_messages = debug5;
SET debug_print_plan = on;
SET debug_print_parse = on;
SET debug_print_rewritten = on;
```

### Postmortem Debugging
```bash
# Ensure postgres built with debug symbols
# In postgresql.conf, enable:
# log_line_prefix = '%m [%p] '

# When crash occurs:
# 1. Find core file in $PGDATA
# 2. Load in GDB
gdb /path/to/postgres core

# 3. Get backtrace
bt full
info locals
info args
```

### Common Breakpoints
```gdb
# Error handling
break errfinish
break elog_start

# Executor
break ExecutorStart
break ExecutorRun
break ExecProcNode

# Parser
break raw_parser
break parse_analyze

# Planner
break planner
break standard_planner

# Memory
break MemoryContextAlloc
break pfree
```
```

---

### pg-patch-create

**Purpose**: Create clean, properly formatted patches for submission.

**When to use**: When ready to submit changes to pgsql-hackers.

```markdown
## Creating PostgreSQL Patches

### Basic Workflow
```bash
# 1. Ensure you're on a feature branch
git checkout -b my-feature

# 2. Make your changes and commit
git add -A
git commit -m "Add feature X

This patch adds feature X which allows Y.

Detailed description of the change..."

# 3. Generate patch
git format-patch master --base=master
# Creates: 0001-Add-feature-X.patch
```

### Multi-Part Patches
```bash
# For logically separate commits
git format-patch master --base=master
# Creates:
# 0001-Refactor-existing-code.patch
# 0002-Add-new-feature.patch
# 0003-Add-tests.patch
# 0004-Add-documentation.patch
```

### Updating Patches (New Versions)
```bash
# After addressing feedback
git commit --amend  # or rebase -i for multiple commits

# Create v2
git format-patch -v2 master --base=master
# Creates: v2-0001-Add-feature-X.patch

# Create v3, v4, etc.
git format-patch -v3 master --base=master
```

### Patch Quality Checklist
Before generating the final patch:

```bash
# 1. Rebase on latest master
git fetch origin
git rebase origin/master

# 2. Run pgindent on modified files
git diff --name-only origin/master | grep '\.[ch]$' | \
    xargs src/tools/pgindent/pgindent

# 3. Run all tests
make check-world

# 4. Verify patch applies cleanly
git stash
git format-patch master
git apply --check 0001-*.patch
git stash pop

# 5. Review your own patch
git diff master...HEAD
git log --oneline master..HEAD
```

### Commit Message Format
```
Short summary (50 chars or less)

Longer description wrapped at 72 characters. Explain:
- What the patch does
- Why it's needed
- Any caveats or limitations

Include motivation and contrast with previous behavior
when applicable.

Discussion: https://postgr.es/m/<message-id>
Reviewed-by: Name <email> (after review)
```

### Patch Organization Best Practices
1. **Single logical change per patch** - Don't mix refactoring with features
2. **Tests with implementation** - Include tests in same patch as feature
3. **Documentation last** - Separate patch for docs is often cleaner
4. **Bisectable** - Each patch should compile and pass tests

### Avoiding Common Issues
- Don't include unrelated whitespace changes
- Remove debug code and #if 0 blocks
- Check for accidentally committed backup files
- Ensure consistent line endings (LF only)

### Generating a Squashed Patch
```bash
# If you need a single patch from multiple commits
git checkout -b temp-branch master
git merge --squash my-feature
git commit -m "Description of all changes"
git format-patch master
git checkout my-feature
git branch -D temp-branch
```
```

---

### pg-patch-version

**Purpose**: Manage patch versions, rebasing, and updates.

**When to use**: When maintaining patches over time, responding to feedback.

```markdown
## Patch Version Management

### Version Numbering Convention
```
0001-Add-feature.patch      # Initial submission
v2-0001-Add-feature.patch   # After first round of feedback
v3-0001-Add-feature.patch   # After second round
```

### Rebasing on Updated Master
```bash
# 1. Fetch latest master
git fetch origin

# 2. Rebase your branch
git rebase origin/master

# 3. Handle conflicts
# Edit files to resolve conflicts
git add <resolved-files>
git rebase --continue

# 4. Generate new patch version
git format-patch -v<N> master --base=master
```

### Safe Rebasing Workflow
```bash
# Always save your work before rebasing
git format-patch master -o ~/backup-patches/

# Create backup branch
git branch backup-before-rebase

# Now rebase
git rebase origin/master

# If something goes wrong:
git rebase --abort
# Or restore from backup:
git reset --hard backup-before-rebase
```

### Squashing Commits During Update
```bash
# Interactive rebase to clean up history
git rebase -i master

# In editor, change 'pick' to 'squash' or 'fixup'
# for commits you want to combine

# Example:
pick abc1234 Main implementation
squash def5678 Fix typo
squash ghi9012 Address review comment

# Save and edit combined commit message
```

### Tracking Feedback Changes
```bash
# Create fixup commits for easy tracking
git commit --fixup=<original-commit-hash>

# Later, squash fixups automatically
git rebase -i --autosquash master
```

### Version Control Tips
1. **Tag before rebase**: `git tag v1-submitted` before major changes
2. **Document changes**: Keep notes on what changed between versions
3. **Message-ID tracking**: Reference original pgsql-hackers thread

### Changelog Between Versions
When submitting updated patches, document changes:
```
Changes from v1:
- Fixed memory leak reported by reviewer
- Added missing test case for NULL handling
- Updated documentation per style feedback
- Rebased on current master
```

### Recovering Lost Work
```bash
# Find lost commits
git reflog

# Restore specific commit
git cherry-pick <commit-hash>

# Or reset to previous state
git reset --hard HEAD@{5}  # 5 operations ago
```
```

---

### pg-patch-apply

**Purpose**: Apply and test existing patches from pgsql-hackers or CommitFest.

**When to use**: Reviewing others' patches, testing proposed features.

```markdown
## Applying PostgreSQL Patches

### Applying format-patch Patches
```bash
# Clean checkout of master
git checkout master
git pull

# Create test branch
git checkout -b test-patch-xyz

# Apply patch
git am 0001-Feature-description.patch

# Or apply with 3-way merge (helps with conflicts)
git am -3 0001-Feature-description.patch
```

### Applying Plain Diff Patches
```bash
# Check if patch applies
patch -p1 --dry-run < feature.patch

# Apply the patch
patch -p1 < feature.patch

# Or using git apply
git apply --check feature.patch
git apply feature.patch
```

### Handling Apply Failures
```bash
# If git am fails
git am --abort  # Cancel

# Try with more context
git am -3 patch.patch

# Or apply manually
git apply --reject patch.patch
# Fix rejected hunks in *.rej files
git add -A
git am --continue
```

### Applying Patch Series
```bash
# Multiple patches in order
git am 0001-*.patch 0002-*.patch 0003-*.patch

# Or all patches in directory
git am /path/to/patches/*.patch
```

### Testing Applied Patch
```bash
# 1. Build
make -j$(nproc)

# 2. Run tests
make check

# 3. Install and test manually
make install
pg_ctl restart
psql -c "SELECT new_feature();"
```

### Applying to Specific Version
```bash
# Checkout specific release
git checkout REL_16_STABLE

# Create test branch
git checkout -b test-patch-on-16

# Apply patch (may need manual adjustments)
git am -3 patch.patch
```

### Patch from Mailing List Archive
```bash
# Download raw email
curl -o patch.mbox 'https://www.postgresql.org/message-id/raw/<message-id>'

# Apply from mbox
git am patch.mbox
```

### Creating Review Notes
After testing, document:
1. Applied cleanly? Any conflicts?
2. Compiles without warnings?
3. All tests pass?
4. Manual testing results
5. Performance impact (if applicable)
6. Documentation adequate?
7. Code style correct?
```

---

### pg-hackers-letter

**Purpose**: Draft effective emails to pgsql-hackers mailing list.

**When to use**: Submitting patches, responding to discussions, proposing ideas.

```markdown
## Writing to pgsql-hackers

### Email Format Basics
- Plain text only (no HTML)
- Bottom-post or inline replies (not top-posting)
- Wrap lines at ~72 characters
- Use Reply-All to keep thread intact

### Initial Patch Submission Template
```
Subject: [PATCH] Brief description of feature

Hi hackers,

This patch adds <feature> which <brief explanation of what it does>.

Motivation:
<Why is this needed? What problem does it solve?>

Implementation:
<Brief description of approach taken>

Testing:
<What testing was performed>

Open questions:
<Any decisions you'd like input on>

Example usage:
<If applicable, show how to use the feature>

The patch is also registered in the <Month> CommitFest:
https://commitfest.postgresql.org/XX/YYYY/

--
Your Name
```

### Updated Patch Submission Template
```
Subject: Re: [PATCH v2] Brief description

Hi,

Attached is v2 of the patch. Changes from v1:

- Fixed memory leak in foo() [per Tom's review]
- Added test case for NULL handling [per Andres' suggestion]
- Updated documentation to clarify usage
- Rebased on current master

<Any additional notes or remaining questions>

--
Your Name
```

### Discussion Etiquette
- Be concise and specific
- Quote only relevant parts
- Use standard abbreviations: IMO, FWIW, IIUC, LGTM
- Accept feedback graciously
- Disagree respectfully with technical arguments

### Common Mistakes to Avoid
1. HTML formatting (gets rejected/mangled)
2. Top-posting (reply at top, quoted text below)
3. Missing In-Reply-To header (breaks threading)
4. Attachments over 100KB (use external hosting)
5. Sending during active CommitFest (wait for quiet period)

### Good Subject Lines
```
[PATCH] Add support for feature X
[PATCH v3] Improve performance of Y by Z
[RFC] Proposal for new approach to W
Re: [PATCH] Fix typo  (simple reply)
```

### Handling No Response
- Wait at least 1-2 weeks
- Bump thread politely:
  "Friendly ping on this patch - any feedback?"
- Consider if timing is bad (CommitFest, holidays)
- Ask on IRC #postgresql-dev for visibility

### Replying to Feedback
```
On <date>, <Reviewer> wrote:
> Quoted feedback here

Good point. I've updated the patch to address this by <explanation>.

> Another point

I considered this, but <technical reasoning>. Do you think
the current approach is still problematic?

Updated patch attached.
```
```

---

### pg-commitfest

**Purpose**: Navigate the CommitFest workflow for patch management.

**When to use**: Registering patches, tracking status, managing through review.

```markdown
## CommitFest Workflow Guide

### CommitFest Schedule
- **5 CommitFests per year**: July, September, November, January, March
- **Submission period**: Prior month
- **Review period**: CommitFest month

### Registering a Patch
1. Go to https://commitfest.postgresql.org
2. Log in (create account if needed)
3. Click "New Patch"
4. Fill in:
   - **Name**: Brief, descriptive title
   - **Topic**: Appropriate category
   - **Message-ID**: From pgsql-hackers archive
   - **Authors**: Your name/email

### Patch States
```
Needs Review    → Initial state, awaiting reviewer
Waiting on Author → Reviewer requested changes
Ready for Committer → Reviewer approves, awaiting commit
Committed       → Patch accepted and committed
Returned with Feedback → Not ready, try next CF
Rejected        → Not accepted (rare)
```

### State Transitions
```
Needs Review ──► Waiting on Author ──► Needs Review
      │                                      │
      │                                      ▼
      │              Ready for Committer ──► Committed
      │                     │
      │                     ▼
      └──────────► Returned with Feedback
                           │
                           ▼
                        Rejected
```

### Your Responsibilities as Author
1. Submit patch to pgsql-hackers FIRST
2. Register in CommitFest after email archived
3. Respond promptly to feedback (<1 week ideal)
4. Update patch versions with clear changelogs
5. **Review someone else's patch** (expected!)

### cfbot Integration
- cfbot automatically tests patches
- Check cfbot status for your patch
- Fix any build/test failures promptly
- cfbot results at: https://cfbot.cputube.org/

### Tips for Success
1. **Submit early** in submission period
2. **Small, focused patches** review faster
3. **Test thoroughly** before submission
4. **Document clearly** what the patch does
5. **Be responsive** during review
6. **Review others** - it's expected and helps you learn

### When Returned with Feedback
- Don't be discouraged - this is normal
- Address feedback thoroughly
- Resubmit to next CommitFest
- Reference previous discussion

### Checking Patch Status
```bash
# cfbot provides automated testing
# Check status at commitfest.postgresql.org

# Or use Peter Eisentraut's tools
# https://github.com/petere/commitfest-tools
```
```

---

### pg-feedback

**Purpose**: Address reviewer feedback and prepare updated patches.

**When to use**: After receiving review comments on pgsql-hackers.

```markdown
## Addressing Reviewer Feedback

### General Approach
1. **Thank the reviewer** - they volunteered their time
2. **Address every point** - don't ignore anything
3. **Explain your decisions** - especially if disagreeing
4. **Update systematically** - track changes

### Organizing Feedback Response

```markdown
## Feedback from [Reviewer Name] - [Date]

### Point 1: [Summary]
Status: Fixed | Discussed | Deferred
Action: [What you did]
Location: [File:line if applicable]

### Point 2: [Summary]
Status: Fixed
Action: Added NULL check in foo()
Location: src/backend/commands/foo.c:234

### Point 3: [Summary]
Status: Discussed (see email response)
Reasoning: [Why you chose different approach]
```

### Tracking Changes Across Versions
```bash
# Create fixup commits for each feedback item
git commit -m "fixup: address review - add NULL check"
git commit -m "fixup: address review - improve error message"
git commit -m "fixup: address review - add test case"

# Before submission, squash into main commits
git rebase -i --autosquash master
```

### Common Feedback Categories

#### 1. Code Style Issues
```bash
# Easy fix - run pgindent
src/tools/pgindent/pgindent file.c

# Commit message format
git commit --amend  # Fix message
```

#### 2. Missing Tests
```bash
# Add regression test
# src/test/regress/sql/new_test.sql

# Add TAP test for tool
# src/bin/tool/t/001_new_test.pl
```

#### 3. Documentation Gaps
```bash
# Update docs
# doc/src/sgml/relevant-section.sgml

# Update release notes
# doc/src/sgml/release-XX.sgml
```

#### 4. Performance Concerns
```bash
# Run benchmarks, provide data
pgbench -c 10 -T 60 > results.txt

# Compare before/after
diff baseline.txt patched.txt
```

#### 5. Architectural Concerns
- May require significant rework
- Discuss approach before re-implementing
- Consider if feedback suggests rejection

### When You Disagree
```
Thank you for the feedback. I considered <alternative> but
chose the current approach because:

1. <Technical reason 1>
2. <Technical reason 2>

However, I'm open to other perspectives. Do you think
<specific concern> outweighs these considerations?
```

### Preparing Updated Patch Email
```
Subject: Re: [PATCH v2] Feature description

Hi,

Thank you for the detailed review, [Reviewer Name].

Attached is v2 addressing your feedback:

> Point 1 about foo
Fixed in v2, added NULL check at line 234.

> Point 2 about bar
Good catch! Added test case in new_test.sql.

> Point 3 about approach
I kept the current approach because [reason], but
added a comment explaining the design decision.
Would this address your concern?

> Point 4 about docs
Updated documentation in section X.Y.

All regression tests pass. cfbot should pick this up shortly.

--
Your Name
```
```

---

### pg-coverage

**Purpose**: Analyze test coverage for patches.

**When to use**: Ensuring adequate test coverage before submission.

```markdown
## Test Coverage Analysis

### Building with Coverage
```bash
# Autoconf
./configure --enable-coverage \
            --enable-cassert \
            --enable-debug \
            --enable-tap-tests
make -j$(nproc)
make install

# Meson
meson setup -Db_coverage=true builddir
cd builddir
ninja
```

### Running Tests with Coverage
```bash
# Run tests
make check

# Generate coverage report
make coverage-html

# View report
xdg-open coverage/index.html
```

### Coverage for Specific Subsystem
```bash
# Build everything first
make -j$(nproc)

# Run tests for specific directory
cd src/backend/commands
make check

# Generate coverage for that directory only
make coverage-html
```

### Interpreting Coverage Reports
- **Line coverage**: % of lines executed
- **Branch coverage**: % of branches taken
- **Function coverage**: % of functions called

Target for new code:
- Line coverage: >80%
- Branch coverage: >70%
- All error paths should be tested

### Finding Untested Code
```bash
# Look for files with low coverage
grep -l "0%" coverage/*.gcov

# Check specific file
less coverage/myfile.c.gcov
# Lines starting with ##### were not executed
```

### Adding Tests for Coverage Gaps

#### Regression Test for SQL Features
```sql
-- src/test/regress/sql/my_feature.sql
-- Test normal case
SELECT my_new_function(1);

-- Test edge cases
SELECT my_new_function(NULL);
SELECT my_new_function(-1);

-- Test error cases
SELECT my_new_function('invalid');  -- expect error
```

#### TAP Test for Utilities
```perl
# src/bin/my_tool/t/001_coverage.pl
use PostgreSQL::Test::Cluster;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

# Test normal operation
my $result = $node->safe_psql('postgres', 'SELECT 1');
is($result, '1', 'basic operation');

# Test error handling
my ($ret, $stdout, $stderr) = $node->psql('postgres',
    'SELECT invalid_query(');
isnt($ret, 0, 'error returns non-zero');
like($stderr, qr/syntax error/, 'error message present');

done_testing();
```

### Coverage Checklist
- [ ] Happy path covered
- [ ] Error conditions tested
- [ ] NULL handling verified
- [ ] Boundary conditions tested
- [ ] Permission checks exercised
- [ ] Concurrent access scenarios (if applicable)
```

---

### pg-readiness

**Purpose**: Evaluate if a patch is ready for submission.

**When to use**: Final check before sending to pgsql-hackers.

```markdown
## Patch Readiness Evaluation

### Comprehensive Checklist

#### 1. Code Quality
- [ ] Compiles without warnings (`-Wall -Werror`)
- [ ] pgindent run on all modified files
- [ ] No debug code remaining
- [ ] No #if 0 blocks
- [ ] No unrelated changes
- [ ] Comments are accurate and helpful

#### 2. Testing
- [ ] All existing tests pass (`make check-world`)
- [ ] New tests added for new functionality
- [ ] Error paths tested
- [ ] Edge cases covered
- [ ] No intermittent failures

#### 3. Documentation
- [ ] User-facing changes documented
- [ ] Release notes entry added
- [ ] Examples provided
- [ ] Error messages clear and documented

#### 4. Git/Patch Hygiene
- [ ] Clean commit history
- [ ] Meaningful commit messages
- [ ] Rebased on current master
- [ ] `git format-patch` used
- [ ] Patch applies cleanly

#### 5. Performance (if applicable)
- [ ] Benchmarked before/after
- [ ] No regressions
- [ ] Performance claims verified

#### 6. Security (if applicable)
- [ ] No injection vulnerabilities
- [ ] Privilege checks correct
- [ ] Input validation present

### Quick Evaluation Commands
```bash
# 1. Check compilation
make clean && make -j$(nproc) 2>&1 | grep -E 'warning:|error:'

# 2. Run tests
make check-world

# 3. Verify patch
git format-patch master --base=master
git stash && git apply --check *.patch && git stash pop

# 4. Check style
git diff --name-only master | grep '\.[ch]$' | \
    xargs -I {} sh -c 'diff -q {} <(src/tools/pgindent/pgindent {})'

# 5. Check for debug code
git diff master | grep -E 'printf|elog.*DEBUG|#if 0'
```

### Readiness Scoring

Score your patch (aim for 90%+ before submission):

```
Category               Weight   Score (0-100)
─────────────────────────────────────────────
Code compiles clean      15%    ___
Tests pass               20%    ___
New tests adequate       15%    ___
Documentation            15%    ___
Code style               10%    ___
Commit message           10%    ___
Patch format             10%    ___
No debug code            5%     ___
─────────────────────────────────────────────
Total                   100%    ___
```

### Red Flags - Do Not Submit If:
- Any test failures
- Compilation warnings in new code
- Missing documentation for user-visible changes
- Debug output remaining
- Patch doesn't apply to current master

### Green Lights - Ready to Submit:
- All tests pass including new ones
- Documentation complete
- Reviewable commit history
- Clear motivation explained
- Similar patches have been accepted before

### Final Steps Before Submission
1. Sleep on it - review tomorrow with fresh eyes
2. Read your own patch as if reviewing someone else's
3. Test one more time on clean checkout
4. Draft cover letter email
5. Submit to pgsql-hackers
6. Register in CommitFest
```

---

## Workflows

### Workflow 1: New Feature Development

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Research & Discussion                                      │
│    - Search archives for prior art                           │
│    - Post RFC to pgsql-hackers                               │
│    - Get consensus on approach                               │
│    Use: @pg-hackers-letter for RFC email                     │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Implementation                                             │
│    - Code the feature                                        │
│    - Add tests                                               │
│    - Add documentation                                       │
│    Use: @pg-build, @pg-test, @pg-docs                        │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Self-Review & Polish                                       │
│    - Run pgindent                                            │
│    - Check coverage                                          │
│    - Evaluate readiness                                      │
│    Use: @pg-style, @pg-coverage, @pg-review, @pg-readiness   │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Submission                                                 │
│    - Create clean patches                                    │
│    - Write cover letter                                      │
│    - Submit to pgsql-hackers                                 │
│    - Register in CommitFest                                  │
│    Use: @pg-patch-create, @pg-hackers-letter, @pg-commitfest │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Review Cycle (repeat 3+ times)                            │
│    - Receive feedback                                        │
│    - Address comments                                        │
│    - Rebase and update                                       │
│    - Submit new version                                      │
│    Use: @pg-feedback, @pg-patch-version                      │
└──────────────────────────────────────────────────────────────┘
```

### Workflow 2: Bug Fix

```bash
# 1. Reproduce and understand
git bisect start
git bisect bad HEAD
git bisect good <known-good-commit>
# ... identify breaking commit

# 2. Create fix
git checkout -b fix-issue-xyz master
# ... make minimal fix

# 3. Test
make check
# Add specific regression test for bug

# 4. Submit
# Use @pg-patch-create and @pg-hackers-letter
```

### Workflow 3: Reviewing Someone Else's Patch

```bash
# 1. Get patch
# Use @pg-patch-apply

# 2. Build and test
# Use @pg-build and @pg-test

# 3. Review code
# Use @pg-review checklist

# 4. Write review email
# Use @pg-hackers-letter for response format
```

---

## Critical Human Checkpoints

These steps **cannot be automated** and require human judgment:

### 1. Architectural Decisions
- Is this the right approach?
- Does it fit PostgreSQL's design philosophy?
- Are there simpler alternatives?

### 2. Community Consensus
- Has the feature been discussed?
- Is there agreement on the need?
- Who are the stakeholders?

### 3. Real-World Testing
- Test with production-like data
- Test on different platforms
- Test upgrade scenarios
- Test concurrent access

### 4. Performance Verification
- Run meaningful benchmarks
- Compare with real workloads
- Verify no regressions

### 5. Security Review
- Expert review for security-sensitive code
- Consider attack vectors
- Validate privilege checks

### 6. Final Sign-Off
- Human reviews AI-generated analysis
- Human runs actual tests
- Human sends the email
- Human engages with reviewers

---

## Common Pitfalls

### Pitfall 1: Skipping Discussion
**Wrong**: Write code first, ask questions later
**Right**: Discuss approach on pgsql-hackers before major work

### Pitfall 2: Too Much in One Patch
**Wrong**: 5000-line patch touching 50 files
**Right**: Separate into logical, reviewable chunks

### Pitfall 3: Ignoring Feedback
**Wrong**: Resubmit without addressing comments
**Right**: Address every point, explain disagreements

### Pitfall 4: Debug Code Left In
**Wrong**: `printf("DEBUG: value=%d\n", x);`
**Right**: Remove all debug code before submission

### Pitfall 5: Missing Tests
**Wrong**: "It works on my machine"
**Right**: Regression tests proving correctness

### Pitfall 6: Outdated Patch
**Wrong**: Patch from 6 months ago that doesn't apply
**Right**: Rebased on current master

### Pitfall 7: Poor Timing
**Wrong**: Submit during active CommitFest when reviewers are busy
**Right**: Submit during quiet periods or early in submission window

### Pitfall 8: Not Reviewing Others
**Wrong**: Only submit patches, never review
**Right**: Review at least one patch per submission

---

## References

### Official Resources
- [Submitting a Patch](https://wiki.postgresql.org/wiki/Submitting_a_Patch)
- [Reviewing a Patch](https://wiki.postgresql.org/wiki/Reviewing_a_Patch)
- [CommitFest](https://wiki.postgresql.org/wiki/CommitFest)
- [Creating Clean Patches](https://wiki.postgresql.org/wiki/Creating_Clean_Patches)
- [PostgreSQL Coding Conventions](https://www.postgresql.org/docs/current/source.html)
- [Regression Tests](https://www.postgresql.org/docs/current/regress.html)
- [TAP Tests](https://www.postgresql.org/docs/current/regress-tap.html)

### Community Resources
- [pgsql-hackers Archives](https://www.postgresql.org/list/pgsql-hackers/)
- [CommitFest Application](https://commitfest.postgresql.org/)
- [cfbot Status](https://cfbot.cputube.org/)
- [Understanding pgsql-hackers](https://www.crunchydata.com/blog/understanding-the-postgres-hackers-mailing-list)
- [The Missing Manual for Hacking Postgres](https://brandur.org/postgres-hacking)

### Tools
- [commitfest-tools](https://github.com/petere/commitfest-tools)
- [pgbent](https://github.com/gregs1104/pgbent)
- [pgTAP](https://pgtap.org/)

---

## Version History

- **v1.0** - Initial release with core subagents and workflows

---

*Remember: AI assistance is a tool to help prepare quality patches, but the PostgreSQL community values human engagement, testing, and judgment above all. Use these tools to be more thorough, not to shortcut the process.*
