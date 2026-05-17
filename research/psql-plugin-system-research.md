# Why psql Has No Plugin System: Research Report

## Executive Summary

After 25+ years, PostgreSQL's `psql` client remains a monolithic, non-extensible C application. Despite the PostgreSQL server having 26+ hook points and a mature extension system (`CREATE EXTENSION` since 9.1), the client has zero plugin infrastructure. No formal RFC, patch, or commitfest entry for a psql plugin/extension system has been found on pgsql-hackers — though related client-side extensibility ideas surfaced in 2008 (libpq object hooks by Merlin Moncure) and people have worked around the limitation via `\set`-based aliasing hacks, the pspg pager pattern, and by building entirely separate tools (pgcli, rpg). The absence of a formal proposal likely reflects community self-censorship given PostgreSQL's conservative culture more than lack of interest. This document analyzes the technical, cultural, and strategic reasons why, and what it would take to change that.

---

## 1. Architectural Barriers in the psql Codebase

### 1.1 The Monolithic Command Dispatch

The heart of psql is a giant if/else chain in `src/bin/psql/command.c` (6,560 lines). The `exec_command()` function at line 315 dispatches backslash commands through ~50 sequential `strcmp()` calls:

```c
if (strcmp(cmd, "a") == 0)
    status = exec_command_a(scan_state, active_branch);
else if (strcmp(cmd, "bind") == 0)
    status = exec_command_bind(scan_state, active_branch);
else if (strcmp(cmd, "bind_named") == 0)
    status = exec_command_bind_named(scan_state, active_branch, cmd);
// ... 47 more else-if branches ...
else
    status = PSQL_CMD_UNKNOWN;
```

There is **no command registry**, no function pointer table, no hash map lookup. Every command is hardcoded. Adding a new command requires modifying this file directly. There is no "unknown command" hook — an unrecognized command simply prints an error.

This was refactored in 2017 (as part of the `\if` commit by Corey Huinker / Tom Lane) from a 1,500-line monstrosity into separate `exec_command_*` functions, but the dispatch mechanism itself remained a static if/else chain.

### 1.2 The Main Loop (`mainloop.c`)

The main loop is 662 lines of tightly coupled logic:

- Line scanning via `psql_scan()` (a flex-based lexer)
- Query accumulation into `query_buf`
- Backslash command handling via `HandleSlashCmds()`
- Query execution via `SendQuery()`
- Signal handling via `sigsetjmp`/`longjmp`

There are **zero hook points** in the main loop. No pre-query hook, no post-query hook, no on-error hook, no on-connect hook. The loop is a single function with `volatile` variables and `longjmp` for Ctrl-C handling — an architecture hostile to callbacks.

### 1.3 Query Execution (`common.c:SendQuery`)

`SendQuery()` (starting at line 1118) is 200+ lines of inline logic:

1. Check connection exists
2. Single-step mode confirmation
3. Log query if logging enabled
4. Set up cancel handler
5. Handle autocommit/savepoints
6. Call `ExecQueryAndProcessResults()` → `PQsendQuery()` → `PQgetResult()`
7. Handle error rollback
8. Print timing

Every step is inline with direct `pset` global access. There's no abstraction layer, no event system, no callback chain. A plugin wanting to intercept queries would need to patch this function directly.

### 1.4 Tab Completion (`tab-complete.in.c`)

At **7,227 lines**, this is the largest single file in psql. It's a massive hand-coded completion engine with hardcoded SQL keyword lists, catalog queries, and command-specific logic. There is no completion provider interface — extending tab completion requires modifying this file directly.

### 1.5 Global State (`settings.h`)

psql uses a single global struct `PsqlSettings pset` containing ~50 fields: the database connection, output settings, format options, echo mode, error handling preferences, etc. Every subsystem accesses `pset` directly. There is no abstraction layer that could serve as a stable plugin API.

### 1.6 Variable Hooks — The Closest Thing to Extensibility

The one extensibility mechanism in psql is variable hooks (`variables.c`), which allow callback functions on variable changes:

```c
typedef bool (*VariableAssignHook)(const char *newval);
typedef char *(*VariableSubstituteHook)(char *newval);
```

These are used internally for ~20 built-in variables (AUTOCOMMIT, ECHO, PROMPT1, etc.) but there is no API for external code to register new hooked variables. They demonstrate that the codebase has the concept of hooks — it just never exposed them externally.

### 1.7 No Dynamic Loading Infrastructure

psql has zero `dlopen()`, `dlsym()`, or `LoadLibrary()` calls. Compare this to the PostgreSQL server which has a sophisticated shared library loading system (`src/backend/utils/fmgr/dfmgr.c`) with `_PG_init()` entry points. The client simply never developed this infrastructure.

---

## 2. The Server-Side Contrast: 26+ Hooks and Growing

The PostgreSQL **server** has a rich hook ecosystem, documented at the [PostgresServerExtensionPoints wiki page](https://wiki.postgresql.org/wiki/PostgresServerExtensionPoints):

| Category | Hooks |
|----------|-------|
| Query Planning | `planner_hook`, `set_rel_pathlist_hook`, `set_join_pathlist_hook`, `join_search_hook`, `create_upper_paths_hook`, `post_parse_analyze_hook` |
| Query Execution | `ExecutorStart_hook`, `ExecutorRun_hook`, `ExecutorFinish_hook`, `ExecutorEnd_hook`, `ExecutorCheckPerms_hook` |
| Utility Commands | `ProcessUtility_hook` |
| Security | `object_access_hook`, `check_password_hook`, `ClientAuthentication_hook`, `row_security_policy_hook_*` |
| Explain/Stats | `ExplainOneQuery_hook`, `explain_get_index_name_hook`, `get_relation_stats_hook`, `get_index_stats_hook` |
| Functions | `needs_fmgr_hook`, `fmgr_hook` |
| Logging | `emit_log_hook` |
| Shared Memory | `shmem_startup_hook` |

Extensions like `pg_stat_statements`, `auto_explain`, `pg_hint_plan`, and hundreds more use these hooks. The extension system is PostgreSQL's greatest architectural strength.

**The client has none of this.** The asymmetry is striking — PostgreSQL invested heavily in server extensibility while treating the client as a throwaway utility.

---

## 3. Previous Discussions and Proposals on pgsql-hackers

### 3.1 No Direct Plugin System Proposal Found

After extensive searching of pgsql-hackers archives, the PostgreSQL wiki, commitfest entries, and related resources: **no formal proposal for a psql plugin/extension system has been submitted.** This is itself a significant finding — it means either:

- Nobody has thought to propose it (unlikely given pgcli, rpg, etc.)
- People have thought about it but self-censored knowing the community's conservatism
- The idea has been floated informally but never reached a formal RFC

The closest thread on postgresql.org mentioning "psql plugin" is a [2012 discussion](https://www.postgresql.org/message-id/CA+OCxoyfTFeAgsLzKruq_TL2F-UtAKVSHk0bLZCo5Jb=JPNAtA@mail.gmail.com) about embedding a psql terminal *inside pgAdmin3* as a plugin — not about making psql itself extensible. Dave Page clarified: "The SQL window isn't intended to replicate the features of psql — it has its own feature set."

The **PostgreSQL TODO wiki** has no extensibility items for psql. All 9 current psql TODOs are incremental improvements (whitespace wrapping, tab completion speed, Unicode grapheme clusters). The closest item — "Move psql backslash database information into the backend" — would actually *reduce* psql's responsibilities rather than extend them.

### 3.2a libpq Object Hooks (2008) — The Closest Client-Side Extensibility Proposal

In May 2008, **Merlin Moncure** proposed [`PQhookData(conn, hookname)`](https://www.postgresql.org/message-id/482C77E5.1060500@esilo.com) and `PQresultHookData(result, hookName)` functions for libpq — letting third-party libraries attach private state to connection and result objects. This is the closest thing to a "client-side plugin" proposal in PostgreSQL's history.

**Tom Lane responded** that the hook-name-based approach was "broken-by-design" because independent libraries could choose conflicting names. He proposed using the address of the hook callback function as a key instead.

In the same year, **Andrew Chernow** proposed [changes to libpq adding Object Hook registration](https://postgrespro.com/list/thread-id/2015631) and custom PGresult creation. Neither proposal was adopted into core.

These were about libpq (used by all clients), not psql specifically, and both were narrow in scope. But they show that client-side extensibility was at least *considered* in 2008 and went nowhere.

### 3.2 The `\if` Saga — How Hard It Is to Add Anything to psql

The most instructive precedent is the addition of `\if`/`\elif`/`\else`/`\endif` in PostgreSQL 10 (2017). This relatively simple feature:

- **Thread origin**: Started as a `\quit_if` / `\quit_unless` proposal
- **Duration**: Multi-month discussion on pgsql-hackers
- **Key participants**: Corey Huinker (author), Fabien Coelho (reviewer), Tom Lane (committer who did "further hacking")
- **Scope**: Touched 17 files with 2,172 insertions / 270 deletions
- **Side effects**: Required refactoring `exec_command()` from a 1,500-line monstrosity into separate functions; fixing variable expansion in untaken branches; redesigning how `previous_buf` was handled
- **Philosophy**: Tom Lane noted boolean expressions were "pretty primitive" but "that's enough for many purposes, since you can always do the heavy lifting on the server side; and we can extend it later"
- **References**:
  - [Commit message](https://www.postgresql.org/message-id/E1ctdQB-0007J0-VU@gemulon.postgresql.org)
  - [Thread on postgrespro.com](https://postgrespro.com/list/thread-id/2301542)
  - [depesz blog](https://www.depesz.com/2017/04/03/waiting-for-postgresql-10-support-if-elif-else-endif-in-psql-scripting/)

This shows that even adding conditional branching — a standard scripting feature — was a major undertaking. A plugin system would be orders of magnitude more complex.

### 3.3 `\crosstabview` — Adding a Single Display Mode

Added in PostgreSQL 9.6 by Daniel Verite, tracked across two commitfest entries ([CF 8/372](https://commitfest.postgresql.org/8/372/) and [CF 9/521](https://commitfest.postgresql.org/9/521/)). Pavel Stehule noted Daniel "accepted and fixed all his objections." The patch modified `command.c`, `common.c`, and added entirely new files `crosstabview.c` and `crosstabview.h`. Demonstrates tight coupling: adding one display mode required touching the command dispatcher, the execution layer, documentation, and creating new source files compiled into the binary.

### 3.4 `\watch` Enhancements — Incremental Improvements Take Years

`\watch` was added in PostgreSQL 9.3 (Tom Lane, patch by Will Leinweber, reviewed by Peter Eisentraut and Daniel Farina), enhanced in PostgreSQL 16 (stop after N iterations), PostgreSQL 17 (minimum row count), and PostgreSQL 18 (default interval setting). Each improvement was a separate multi-month review cycle spanning **5 major releases over 12 years**.

### 3.5 Pipeline Mode — 4 Years from libpq API to psql Commands

PostgreSQL 18 (2025) added `\startpipeline`, `\endpipeline`, `\syncpipeline`, and `\getresults`. The libpq pipeline API existed since PostgreSQL 14 (2021). It took **4 years** for it to surface as psql commands — illustrating the gap between what libpq can do programmatically and what psql exposes.

### 3.6 psql Variable Hooks (2017) — Internal Only

The [most relevant thread about "hooks" in psql](https://postgrespro.com/list/thread-id/2157116) (Tom Lane, Daniel Verite, Stephen Frost, Rahila Syed) was about internal C function-pointer hooks for variable assignment validation — **not** an extensibility mechanism for external code. Tom Lane discovered the change broke RedisFDW's test script, noting: "If it's just that script I would be okay with saying 'well, it's a bug in that script' ... but I'm a bit worried that this may be the tip of the iceberg."

### 3.7 Embedded Scripting Language — Never Seriously Proposed

No thread was found proposing to embed Lua, Python, or any scripting language into psql. The community's approach has been purely incremental: `\set` variables, `\if` conditionals, backtick shell expansion. The philosophy is "do the heavy lifting on the server side."

### 3.8 `.psqlrc` — The Extent of Client Customization

A [2008 thread](http://postgresqlorg.blogspot.com/2008/07/re-hackers-psqlrc-output-for-pset.html) (Bruce Momjian, Gregory Stark) about `.psqlrc` output behavior illustrates the limited customization surface. `.psqlrc` can only run existing backslash commands sequentially — there is no way to define new commands, register callbacks, or load modules. This is all that's ever been sanctioned for psql customization.

### 3.9 Robert Haas on Difficulty of Contributing (2024)

Robert Haas's blog post "[Hacking on PostgreSQL is Really Hard](http://rhaas.blogspot.com/2024/05/hacking-on-postgresql-is-really-hard.html)" (May 2024) describes the structural challenge:

- "Committing other people's patches is not primarily about the time it takes to type git commit and git push, but about all of the review you do beforehand, and the potential unfunded liability of having to be responsible for it afterward."
- He spent "weeks and weeks reviewing" a moderately complex feature (incremental backup) and then "lost most of the next six to nine months fixing things I hadn't caught during review."
- A commenter noted the existential risk: if the pool of "10,000 hours" committers shrinks, quality or velocity must suffer.

A psql plugin system would be far more architecturally significant than incremental backup. The review burden alone could consume a committer for a year+.

---

## 4. Cultural and Community Factors

### 4.1 "The Client Is Not the Project"

PostgreSQL's identity is as a database engine. The server is the product. psql is a convenience tool — important, but not the focus of innovation. This is evident in:

- The [official roadmap](https://www.postgresql.org/developer/roadmap/) focuses on server capabilities
- The [TODO wiki](https://wiki.postgresql.org/wiki/Todo) has only 9 psql items vs. hundreds of server items
- No company has a public roadmap for psql improvements (Postgres Professional, Fujitsu, EDB all focus on server extensions)

### 4.2 Conservative Process

PostgreSQL's development process is famously conservative:
- All changes go through [CommitFest](https://commitfest.postgresql.org/) review
- Patches often require 3-5 review cycles
- A single committer objection can block a feature indefinitely
- The community defaults to "no" and requires strong justification for "yes"
- There are ~38 committers total; ~10 are actively reviewing new features

### 4.3 "You Can Always Use an External Tool"

The standing response to "psql should do X" is often: write a wrapper, use pgcli, use your own tool. This is rational for the project's core mission but has created the ecosystem gap that pgcli, DBeaver, pgAdmin, and rpg fill.

### 4.4 Security Concerns

Loading arbitrary shared libraries in a client tool raises supply chain security concerns. The server mitigates this with `shared_preload_libraries` requiring superuser/config file access. A client plugin system would need an equivalent trust model. This concern, while solvable, provides easy grounds for objection.

---

## 5. Tools That Exist Because psql Can't Be Extended

| Tool | Language | Why It Exists |
|------|----------|---------------|
| **pgcli** | Python | Auto-completion, syntax highlighting, multi-line editing. Uses prompt_toolkit, psycopg, sqlparse. No plugin system of its own, but modular Python architecture. |
| **pgAdmin** | Python/JS | Full GUI because psql can't render visual query plans, ERDs, dashboards |
| **DBeaver** | Java | Universal database client because psql is Postgres-only and non-extensible |
| **rpg** | Rust | AI integration, DBA diagnostics, skill connectors — features that require lifecycle hooks psql doesn't have |
| **pspg** | C | Pavel Stehule's pager (2017) — frozen rows/columns, color themes, searching, clipboard. The most successful example of extending psql *externally* via `PSQL_PAGER` env var |
| **usql** | Go | Universal SQL client for multiple databases |

Each of these tools represents unmet demand for psql extensibility. pgcli alone has 12K+ GitHub stars.

The **pspg** case is especially instructive: it exemplifies the only real "plugin" pattern available for psql — external tools connected via Unix pipes and environment variables (`PSQL_PAGER`, `PSQL_WATCH_PAGER`, `\o |command`, `\! command`). Pavel Stehule [announced it in 2017](http://okbob.blogspot.com/2017/07/i-hope-so-every-who-uses-psql-uses-less.html).

### 5.1 MySQL Has a Client Plugin System — PostgreSQL Does Not

For contrast: MySQL has a formal client plugin architecture supporting authentication plugins, protocol trace plugins, and connection attribute plugins via `dlopen`-style loading. PostgreSQL's psql has no equivalent. The PostgreSQL project chose to invest exclusively in server-side extensibility.

---

## 6. What a Plugin System Would Require

### 6.1 Minimum Viable Plugin API

Based on the codebase analysis, a minimal plugin system would need:

1. **Dynamic loading infrastructure**: `dlopen()`/`dlsym()` support, analogous to the server's `dfmgr.c`
2. **Plugin discovery**: `$PGPLUGINDIR` or `~/.local/lib/psql/plugins/`, loaded via `plugin_preload_libraries` in `.psqlrc`
3. **Command registry**: Replace the if/else chain in `exec_command()` with a hash table lookup, allowing plugins to register new backslash commands
4. **Lifecycle hooks**: At minimum:
   - `on_connect(PGconn *conn)` — after connection established
   - `pre_query(const char *query)` — before `SendQuery()`
   - `post_query(const char *query, PGresult *result)` — after result received
   - `on_error(const char *query, PGresult *result)` — on error
5. **Stable API surface**: A `psql_plugin.h` header that abstracts away `pset` internals
6. **Completer extension**: A way to register additional tab-completion providers

### 6.2 The Async Problem

psql is single-threaded with blocking I/O. Any plugin doing network calls (HTTP for AI, REST APIs for connectors) would freeze the terminal. Solutions:

- **Thread pool within plugin**: Plugin manages its own threading (simplest for psql core, but complex for plugin authors)
- **Async event loop**: Integrate libevent/libuv into psql's main loop (invasive change)
- **Fork/exec model**: Plugin runs as a subprocess, communicates via pipes (safest, but limited integration)

### 6.3 Estimated Effort

| Component | Difficulty | Lines of Code | Review Cycles |
|-----------|-----------|---------------|---------------|
| Dynamic loading | Medium | ~500 | 2-3 |
| Command registry | Medium | ~300 | 2-3 |
| Plugin API header | High | ~200 | 5+ (API design debates) |
| Lifecycle hooks | High | ~800 | 4-6 |
| Tab-complete extension | Very High | ~400 | 4-6 |
| Documentation | Medium | ~500 | 2-3 |
| **Total** | **Very High** | **~2,700** | **15-20** |

At PostgreSQL's pace, this is a **2-4 release cycle effort** (PG 20-22, ~2027-2029).

---

## 7. Strategic Assessment

### 7.1 Why No Formal Proposal Has Appeared

1. **Self-censorship**: People who want extensibility build separate tools (pgcli, rpg, pspg) rather than fight the uphill battle on pgsql-hackers. Multiple community members have noted that "getting stuff into forks/plugins of PG is orders of magnitude easier than the kernel itself"
2. **No champion**: No PostgreSQL committer has personal motivation to sponsor this
3. **High cost, diffuse benefit**: The plugin system benefits third parties (pgcli, rpg) more than PostgreSQL core
4. **"Not broken" perception**: psql works fine for its intended purpose (interactive SQL)
5. **Security objections are easy**: "Loading arbitrary .so files" is a conversation-stopper
6. **Incremental approach preferred**: The community would rather add one feature at a time (\if, \watch, \crosstabview) than create a framework
7. **The 2008 libpq hooks precedent**: Even narrow client-side extensibility proposals (Moncure's libpq object hooks) were not adopted — discouraging broader proposals

### 7.2 What Would Make It Succeed

1. **Start small**: Propose only the command registry (replace if/else with hash table) — no hooks, no dynamic loading. Frame it as a code quality improvement.
2. **Proven demand**: Ship rpg's features as psql patches first. If they're rejected ("too specialized"), that creates the argument for a plugin system.
3. **Find a champion**: Identify a committer sympathetic to client tooling (Tom Lane has shown willingness to do "further hacking" on psql features)
4. **Conference talks**: Present at PGCon / PGConf EU to build awareness
5. **Fork demonstration**: A `psql-plugins` fork that proves the concept would be more persuasive than any RFC

### 7.3 The Alternative: Don't Wait

Given the 3-5 year minimum timeline for upstream acceptance, the pragmatic path is:

- **rpg serves users who want these features today**
- The plugin system RFC establishes authority and shapes the conversation
- Even if rejected, the discussion positions DBLab as the thought leader on Postgres client tooling
- If accepted years later, rpg's features become reference implementations for the plugin API

---

## References

### PostgreSQL Mailing List Threads
- [libpq Object Hooks proposal](https://www.postgresql.org/message-id/482C77E5.1060500@esilo.com) (May 2008, Merlin Moncure / Tom Lane — closest to client-side extensibility)
- [libpq pqtypes Hook API](https://postgrespro.com/list/thread-id/2015631) (2008, Andrew Chernow)
- [\if/\elif/\else/\endif commit](https://www.postgresql.org/message-id/E1ctdQB-0007J0-VU@gemulon.postgresql.org) (March 2017)
- [\if discussion thread](https://postgrespro.com/list/thread-id/2301542) (2016-2017)
- [psql variable hooks discussion](https://postgrespro.com/list/thread-id/2157116) (2017)
- [\gexec proposal](https://www.postgresql.org/message-id/CADkLM=exRzVQu31kjaBPzpbu_rGUTtWDTNELNysg1ChEPSpDMQ@mail.gmail.com) (2016, Corey Huinker)
- ["Plugin For Console" thread](https://www.postgresql.org/message-id/CA+OCxoyfTFeAgsLzKruq_TL2F-UtAKVSHk0bLZCo5Jb=JPNAtA@mail.gmail.com) (2012, about embedding psql in pgAdmin, not psql extensibility)
- [Extending PostgreSQL Protocol with Command Metadata](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg204501.html) (2024)
- [Per-connection auth hooks in libpq](http://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg221307.html) (Feb 2026, Andreas Karlsson / Jacob Champion — "global is bad, per-connection is what we would ideally allow")
- [.psqlrc output behavior](http://postgresqlorg.blogspot.com/2008/07/re-hackers-psqlrc-output-for-pset.html) (2008, Bruce Momjian)

### Blog Posts
- [Robert Haas: Hacking on PostgreSQL is Really Hard](http://rhaas.blogspot.com/2024/05/hacking-on-postgresql-is-really-hard.html) (May 2024)
- [Robert Haas: Posting Your Patch on pgsql-hackers](http://rhaas.blogspot.com/2024/08/posting-your-patch-on-pgsql-hackers.html) (Aug 2024)
- [depesz: Waiting for PostgreSQL 10 - \if support](https://www.depesz.com/2017/04/03/waiting-for-postgresql-10-support-if-elif-else-endif-in-psql-scripting/)

### Wiki Pages
- [PostgreSQL TODO](https://wiki.postgresql.org/wiki/Todo) — only 9 psql items
- [PostgresServerExtensionPoints](https://wiki.postgresql.org/wiki/PostgresServerExtensionPoints) — 26+ server hooks
- [Extensions](https://wiki.postgresql.org/wiki/Extensions) — server extension system
- [Crosstabview](https://wiki.postgresql.org/wiki/Crosstabview) — case study in adding a psql feature

### Source Code (PostgreSQL HEAD)
- `src/bin/psql/command.c:315` — exec_command() dispatch chain (50+ if/else branches)
- `src/bin/psql/mainloop.c:33` — MainLoop() (zero hook points)
- `src/bin/psql/common.c:1118` — SendQuery() (inline, no callbacks)
- `src/bin/psql/tab-complete.in.c` — 7,227 lines, no completion provider interface
- `src/bin/psql/settings.h:101` — PsqlSettings global struct (~50 fields, no abstraction)
- `src/bin/psql/variables.c:384` — SetVariableHooks() (internal-only hook mechanism)
- `src/bin/psql/startup.c:852` — Variable hook functions (20+ internal hooks, none external)

### Conference Talks and Presentations
- [FOSDEM '21: Getting on a Hook — PostgreSQL Extensibility](https://archive.fosdem.org/2021/schedule/event/postgresql_extensibility/) — covers server hooks, notes community resistance to ad-hoc extension points
- [Hooks in PostgreSQL (wiki PDF)](https://wiki.postgresql.org/images/e/e3/Hooks_in_postgresql.pdf)
- [Corey Huinker: "Getting By With Just psql" — PGConf EU 2017](https://www.postgresql.eu/events/pgconfeu2017/sessions/session/1592/slides/11/Getting%20By%20With%20Just%20psql.pdf) — demonstrated \gexec and \if but did not propose a plugin system
- [Stephen Frost: "Hacking PostgreSQL" — PGConf EU 2018](https://www.postgresql.eu/events/pgconfeu2018/sessions/session/2058/slides/96/hackingpg-present.pdf) — reinforced that adding psql functionality requires modifying and recompiling C source

### Alternative Tools
- [pgcli](https://github.com/dbcli/pgcli) — 12K+ stars, Python, modern CLI
- [pgcli vs psql comparison](https://github.com/dbcli/pgcli/issues/110)
- [Timescale: 13 Tools That Aren't psql](https://www.timescale.com/blog/state-of-postgresql-2022-13-tools-that-arent-psql)
- [PostgreSQL Clients wiki page](https://wiki.postgresql.org/wiki/PostgreSQL_Clients)
- [taminomara/psql-hooks](https://github.com/taminomara/psql-hooks) — Unofficial docs for server-side hooks (note: server hooks, not client hooks)
- [Psqlrc wiki page](https://wiki.postgresql.org/wiki/Psqlrc) — the only sanctioned customization mechanism
- [ExtensionPackaging wiki](https://wiki.postgresql.org/wiki/ExtensionPackaging) — server-side extension design discussion (no client equivalent exists)

### psql Feature Commit History
- `\watch` (PG 9.3, 2013): Tom Lane / Will Leinweber — [blog](https://paquier.xyz/postgresql-2/postgres-9-3-feature-highlight-watch-in-psql/)
- `\crosstabview` (PG 9.6, 2016): Daniel Verite — [wiki](https://wiki.postgresql.org/wiki/Crosstabview)
- `\if`/`\elif`/`\else`/`\endif` (PG 10, 2017): Corey Huinker / Tom Lane — [commit](https://www.postgresql.org/message-id/E1ctdQB-0007J0-VU@gemulon.postgresql.org)
- Pipeline mode (PG 18, 2025): `\startpipeline`, `\endpipeline`, etc. — [blog](https://postgresql.verite.pro/blog/2025/10/01/psql-pipeline.html)

### Key Community Members for psql
- **Tom Lane**: Primary committer for psql features, did "further hacking" on `\if`
- **Fabien Coelho**: Key psql reviewer, [describes interest in "client-side applications"](https://postgresql.life/post/fabien_coelho/)
- **Corey Huinker**: Author of `\if` conditional scripting
- **Daniel Verite**: Author of `\crosstabview`
- **Pavel Stehule**: Frequent psql patch reviewer, author of pspg pager
- **Merlin Moncure**: Proposed libpq object hooks (2008) — the closest client-side extensibility proposal
