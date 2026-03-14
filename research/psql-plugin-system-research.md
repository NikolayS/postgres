# Why psql Has No Plugin System: Research Report

## Executive Summary

After 25+ years, PostgreSQL's `psql` client remains a monolithic, non-extensible C application. Despite the PostgreSQL server having 26+ hook points and a mature extension system (`CREATE EXTENSION` since 9.1), the client has zero plugin infrastructure. No formal proposal for a psql plugin/extension system has ever been submitted to pgsql-hackers. This document analyzes the technical, cultural, and strategic reasons why, and what it would take to change that.

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

Added in PostgreSQL 9.6, this was a significant effort tracked across two commitfest entries ([CF 8/372](https://commitfest.postgresql.org/8/372/) and [CF 9/521](https://commitfest.postgresql.org/9/521/)). Adding one display mode required a new file (`crosstabview.c`) and integration with the query result pipeline. It's a concrete example of how even a self-contained feature requires deep knowledge of psql internals.

### 3.4 `\watch` Enhancements — Incremental Improvements Take Years

`\watch` was added in PostgreSQL 9.3, enhanced in PostgreSQL 16 (stop after N iterations), and further enhanced in PostgreSQL 17 (minimum row count). Each improvement was a separate multi-month review cycle. The incremental pace is striking.

### 3.5 Embedded Scripting Language — Never Seriously Proposed

No thread was found proposing to embed Lua, Python, or any scripting language into psql. The community's approach has been purely incremental: `\set` variables, `\if` conditionals, backtick shell expansion. The philosophy is "do the heavy lifting on the server side."

### 3.6 Robert Haas on Difficulty of Contributing (2024)

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
| **psql wrappers** (pspg, etc.) | Various | Pager enhancements, output formatting — work around psql's limited output pipeline |
| **usql** | Go | Universal SQL client for multiple databases |

Each of these tools represents unmet demand for psql extensibility. pgcli alone has 12K+ GitHub stars.

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

### 7.1 Why It's Never Been Proposed

1. **No champion**: No PostgreSQL committer has personal motivation to sponsor this
2. **High cost, diffuse benefit**: The plugin system benefits third parties (pgcli, rpg) more than PostgreSQL core
3. **"Not broken" perception**: psql works fine for its intended purpose (interactive SQL)
4. **Security objections are easy**: "Loading arbitrary .so files" is a conversation-stopper
5. **Incremental approach preferred**: The community would rather add one feature at a time (\if, \watch, \crosstabview) than create a framework

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
- [\if/\elif/\else/\endif commit](https://www.postgresql.org/message-id/E1ctdQB-0007J0-VU@gemulon.postgresql.org) (March 2017)
- [\if discussion thread](https://postgrespro.com/list/thread-id/2301542) (2016-2017)
- [Extending PostgreSQL Protocol with Command Metadata](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg204501.html)

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

### Alternative Tools
- [pgcli](https://github.com/dbcli/pgcli) — 12K+ stars, Python, modern CLI
- [pgcli vs psql comparison](https://github.com/dbcli/pgcli/issues/110)
- [Timescale: 13 Tools That Aren't psql](https://www.timescale.com/blog/state-of-postgresql-2022-13-tools-that-arent-psql)
- [taminomara/psql-hooks](https://github.com/taminomara/psql-hooks) — Unofficial docs for server-side hooks (note: server hooks, not client hooks)
