# PostgreSQL Source Code Security Audit Report

- **Date:** 2026-04-04
- **Scope:** PostgreSQL server and libpq client source code
- **Methodology:** Manual source code review of security-critical subsystems, multi-pass with independent peer review
- **Auditors:** Multi-team audit covering Authentication/Crypto, Network/Input, Memory Safety/Privilege Escalation, plus independent deep-dive review

---

## Executive Summary

This audit combined a broad initial pass with a focused deep-dive into complex code paths. The PostgreSQL codebase is mature and well-engineered -- wire protocol parsing is robust, memory contexts prevent many common C bugs, and privilege checks are consistently applied.

The initial pass identified mostly **well-known design trade-offs** (timing attacks, MD5 deprecation, lo_import/lo_export). The deep-dive review found **genuinely novel, actionable bugs** including SQL injection in contrib modules, an uninterruptible DoS in COPY BINARY, a client SCRAM parser bug, and a RADIUS bounds check error. The privilege escalation audit confirmed that **core backend access control is extremely well-hardened** -- no exploitable privesc was found in the core.

### SQL Injection in Contrib Modules (Deep-Dive, Highest Severity)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| S-1 | `refint.c`: unquoted identifiers in trigger SQL | High | User with TRIGGER privilege + refint extension |
| S-2 | `refint.c`: unescaped column values in cascade UPDATE SQL | **Critical** | Any user who can INSERT/UPDATE on a table with cascade trigger |
| S-3 | `tablefunc.c`: `connectby()` unquoted function args in SQL | High | Any user with EXECUTE + tablefunc extension |
| S-4 | `xml2/xpath.c`: `xpath_table()` unquoted params in SQL | High | Any user with EXECUTE + xml2 extension |
| S-5 | `postgres_fdw`: `IMPORT FOREIGN SCHEMA` injects unquoted type names from remote | Medium | User connecting to malicious foreign server |

### Logical Replication & Exotic Attack Vectors (Wave 3 Deep-Dive)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| X-1 | Logical replication: heap buffer over-read from malicious publisher (Assert-only bounds check) | **High** | Attacker controls a publisher |
| X-2 | Search-path operator hijacking via `public` schema | Medium | Regular user with CREATE on `public` |
| X-3 | Advisory lock table exhaustion -- complete database DoS | Medium | Any unprivileged user |
| X-4 | NOTIFY queue saturation DoS | Medium | Any user with a connection |

### Client Tools (Wave 3 Deep-Dive)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| C-1 | pg_dump: subscription `suboriginremotelsn` SQL injection in binary-upgrade mode | Low | Superuser + `--binary-upgrade` |
| C-2 | pg_restore: signed/unsigned confusion causes DoS with crafted archives | Low | Crafted `.dump` file |
| C-3 | pg_restore: `ReadInt` UB with large `intSize` from crafted archive | Low | Crafted `.dump` file |

### Novel Findings -- Protocol & Implementation Bugs (Deep-Dive)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| N-1 | COPY BINARY header loop: uninterruptible DoS | Medium | Any authenticated user |
| N-2 | SCRAM client accepts trailing garbage in server messages | Medium | Malicious server / MITM |
| N-3 | RADIUS response source IP not validated | Medium | Network attacker |
| N-4 | RADIUS attribute bounds check off-by-two | Low-Medium | Latent bug |
| N-5 | Missing `check_stack_depth()` in binary recv functions | Low-Medium | Authenticated user |
| N-6 | TOAST decompression memory bomb | Low | Requires disk corruption |
| N-7 | Deferred triggers lack `RestrictSearchPath()` | Low | Authenticated user |

### Memory Safety (Deep-Dive)

| ID | Finding | Severity | Notes |
|----|---------|----------|-------|
| M-1 | `array_cat()` signed integer overflow (UB) | Low-Medium | Any user; downstream check may be optimized away |
| M-2 | JSONB/multirange/array on-disk headers trusted without validation | Medium | Requires corrupted data; systemic issue |
| M-3 | `array_set_slice()` size computation overflow | Low | DoS only |

### Access Control Observations (Deep-Dive)

| ID | Finding | Severity | Notes |
|----|---------|----------|-------|
| A-1 | MERGE with RLS produces errors instead of silent filtering | Low | Information disclosure by design, acknowledged in code |
| A-2 | `GUC_SAFE_SEARCH_PATH` includes `pg_temp` | Very Low | Mitigated by `SECURITY_RESTRICTED_OPERATION` |

### Pattern Scan, New Features & Remaining Contrib (Wave 4)

| ID | Finding | Severity | Exploitability |
|----|---------|----------|----------------|
| P-1 | ECPG strncpy buffer overflow from malicious server | Medium | Rogue server -> ECPG client |
| P-2 | DecodeMultiInsert Assert-only bounds in WAL decoding | Medium | Compromised WAL stream |
| P-3 | OAuth has no built-in JWT token validation | Medium | Buggy validator module |
| P-4 | OAuth `PGOAUTHDEBUG=UNSAFE` downgrades HTTPS | Medium | Shared hosting env var manipulation |
| P-5 | Temp files without O_EXCL (symlink attack) | Medium | Misconfigured data dir permissions |
| P-6 | dblink loopback bypasses session-level RLS | Medium | User who knows their own password |

### Known Issues (Initial Pass, Reassessed)

| ID | Finding | Severity | Notes |
|----|---------|----------|-------|
| K-1 | SCRAM iteration count GUC minimum is 1 | Medium | Trivial one-line fix |
| K-2 | XML Billion Laughs via `XML_PARSE_NOENT` | Medium | Most exploitable known issue |
| K-3 | `system()` without shell escaping in archive commands | Medium | Low effort fix |
| K-4 | `numeric_recv()` unbounded allocation | Medium | Authenticated DoS |
| K-5 | Client doesn't enforce SCRAM iteration minimum | Medium | Downgrade attack |
| K-6 | SCRAM `scram_verify_plain_password()` timing | Low-Medium | Network jitter limits exploitability |
| K-7 | SCRAM `verify_client_proof()` timing | Low | Nonce prevents exploitation |
| K-8 | MD5 `strcmp()` timing | Low | MD5 already deprecated |
| K-9 | RADIUS `memcmp()` timing | Low | Requires MITM position |
| K-10 | Trusted extension privilege escalation surface | Medium | Requires OS-level filesystem compromise |
| K-11 | No memory clearing for SCRAM key material | Low | Memory forensics scenario |
| K-12 | PAM password not zeroed | Low | Memory forensics scenario |
| K-13 | LDAP plaintext bind | Low | Configuration-dependent |
| K-14 | MD5 auth still supported | Low | On deprecation path |
| K-15 | Unbounded `sprintf()` systemic pattern | Low | Long-term migration |

---

## Part 1: SQL Injection in Contrib Modules

**Key observation:** Core backend code (`ri_triggers.c`, replication, `xml.c`) consistently uses `quote_identifier()`, `quote_literal_cstr()`, and parameterized queries. Contrib modules have historically received less security scrutiny, and this is where the most severe bugs were found.

### S-1: SQL Injection via Unquoted Identifiers in `refint.c`

- **Severity:** High
- **File:** `contrib/spi/refint.c`, lines 180-188 (`check_primary_key`), lines 448-521 (`check_foreign_key`)
- **Privileges required:** TRIGGER privilege on a table + refint extension installed

**Description:** `check_primary_key()` and `check_foreign_key()` build SQL queries using trigger arguments (table names, column names) via `snprintf` with `%s` -- no `quote_identifier()` quoting at all. These arguments are user-supplied in the `CREATE TRIGGER` statement.

**Vulnerable code:**
```c
snprintf(sql, sizeof(sql), "select 1 from %s where ", relname);
// ...
snprintf(sql + strlen(sql), sizeof(sql) - strlen(sql), "%s = $%d %s",
         args[i + nkeys + 1], i + 1, (i < nkeys - 1) ? "and " : "");
```

**Exploitation:**
```sql
CREATE TRIGGER test BEFORE INSERT ON mytable
FOR EACH ROW EXECUTE PROCEDURE
  check_primary_key('col1', 'pg_authid; DROP TABLE important--', 'col1');
```

The table name `pg_authid; DROP TABLE important--` is spliced directly into the SELECT.

---

### S-2: SQL Injection via Unescaped Column Values in `refint.c` Cascade

- **Severity: Critical**
- **File:** `contrib/spi/refint.c`, lines 501-504 (`check_foreign_key`)
- **Privileges required:** INSERT/UPDATE on a table with a `check_foreign_key` cascade trigger

**Description:** During cascade UPDATE operations, `check_foreign_key()` retrieves column values from the NEW tuple via `SPI_getvalue()` and interpolates them into SQL. For "char types", single quotes are wrapped around the value but **embedded single quotes are not escaped**. For non-char types, values are inserted completely raw.

**Vulnerable code:**
```c
snprintf(sql + strlen(sql), sizeof(sql) - strlen(sql),
         " %s = %s%s%s %s ",
         args2[k], (is_char_type > 0) ? "'" : "",
         nv, (is_char_type > 0) ? "'" : "", (k < nkeys) ? ", " : "");
```

**Exploitation:** A user updates a text column that is part of a foreign key with cascade action:
```sql
UPDATE parent_table SET fk_col = $$'; DROP TABLE important; --$$
  WHERE id = 1;
```

The value `'; DROP TABLE important; --` is injected directly into the cascade UPDATE SQL executed on the child table.

**This is the most severe finding in the entire audit** -- it requires only INSERT/UPDATE privileges on data, not DDL privileges.

---

### S-3: SQL Injection via Unquoted Identifiers in `tablefunc.c` `connectby()`

- **Severity:** High
- **File:** `contrib/tablefunc/tablefunc.c`, lines 1226-1244 (`build_tuplestore_recursively`)
- **Privileges required:** EXECUTE on `connectby()` + tablefunc extension installed

**Description:** `connectby()` builds SQL from function arguments (`relname`, `key_fld`, `parent_key_fld`, `orderby_fld`) using raw `%s` substitution. Only `start_with` is properly quoted via `quote_literal_cstr()`.

**Vulnerable code:**
```c
appendStringInfo(&sql, "SELECT %s, %s FROM %s WHERE %s = %s AND %s IS NOT NULL",
                 key_fld,
                 parent_key_fld,
                 relname,            // <-- unquoted user input
                 parent_key_fld,
                 quote_literal_cstr(start_with),  // only this one is quoted!
                 key_fld);
```

**Exploitation:**
```sql
SELECT * FROM connectby(
  'pg_class; DROP TABLE important; --',
  'oid', 'relnamespace', '1', 5
) AS t(keyid text, parent_keyid text, level int, branch text);
```

---

### S-4: SQL Injection via Unquoted Parameters in `xml2/xpath.c` `xpath_table()`

- **Severity:** High
- **File:** `contrib/xml2/xpath.c`, lines 682-690 (`xpath_table`)
- **Privileges required:** EXECUTE on `xpath_table()` + xml2 extension installed

**Description:** All four SQL-building parameters (`pkeyfield`, `xmlfield`, `relname`, `condition`) from `PG_GETARG_TEXT_PP()` are interpolated raw into SQL executed via `SPI_exec()`.

**Vulnerable code:**
```c
appendStringInfo(&query_buf, "SELECT %s, %s FROM %s WHERE %s",
                 pkeyfield,
                 xmlfield,
                 relname,
                 condition);
```

---

### S-5: SQL Injection via Malicious Foreign Server in `postgres_fdw` `IMPORT FOREIGN SCHEMA`

- **Severity:** Medium
- **File:** `contrib/postgres_fdw/postgres_fdw.c`, lines 5591-5621 (`postgresImportForeignSchema`)
- **Privileges required:** CREATE in local schema + USAGE on foreign server pointing to malicious remote

**Description:** When importing a foreign schema, `typename` (from remote `format_type()`) and `attdefault` (from remote `pg_get_expr()`) are interpolated directly into the `CREATE FOREIGN TABLE` DDL without quoting. Note that `attname` IS properly quoted via `quote_identifier()`, making the inconsistency evident.

**Vulnerable code:**
```c
appendStringInfo(&buf, "  %s %s",
                 quote_identifier(attname),  // attname is quoted
                 typename);                   // typename is NOT quoted
// ...
appendStringInfo(&buf, " DEFAULT %s", attdefault);  // also NOT quoted
```

A malicious remote server can return `int; DROP TABLE important; --` as a type name.

---

## Part 2: Logical Replication, Exotic Vectors & Client Tools

### X-1: Heap Buffer Over-Read in Logical Replication from Malicious Publisher

- **Severity: High**
- **File:** `src/backend/replication/logical/worker.c`, lines 1042, 1153, 2872
- **Privileges required:** Attacker controls a PostgreSQL publisher that the victim subscribes to

**Description:** Three locations in the logical replication apply worker use `Assert()` as the **only** bounds check when accessing tuple data arrays. In production builds (compiled without `USE_ASSERT_CHECKING`), these Asserts are compiled out, leaving **no runtime validation**.

**Vulnerable code** (`slot_store_data`, line 1040-1042):
```c
StringInfo colvalue = &tupleData->colvalues[remoteattnum];
Assert(remoteattnum < tupleData->ncols);  // ONLY checked in debug builds!
```

Same pattern in `slot_modify_data` (line 1153) and `apply_handle_update` (line 2872).

**Attack chain:**
- Attacker controls a malicious PostgreSQL publisher
- Publisher sends a RELATION message declaring N columns (`proto.c` line 1023 sets `rel->natts = N`)
- Subscriber builds an `attrmap` mapping local columns to remote indices 0..N-1
- Publisher later sends INSERT/UPDATE tuples with `ncols < N` (`proto.c` line 875: `tuple->ncols = natts` comes directly from the wire with no cross-validation)
- `slot_store_data` iterates local columns, maps to remote indices, and accesses `tupleData->colvalues[remoteattnum]` out of bounds

**Impact:** Heap buffer over-read on the subscriber. If the out-of-bounds `colstatus` byte happens to match `LOGICALREP_COLUMN_TEXT`, the code calls type input functions on garbage data, causing crashes or worse. Realistic in cross-organization replication.

**Remediation:** Convert the three `Assert()` calls to runtime `if` checks with `ereport(ERROR, ...)`.

---

### X-2: Search-Path Operator Hijacking via `public` Schema

- **Severity:** Medium
- **File:** `src/backend/parser/parse_oper.c`, lines 401-427; `src/backend/catalog/namespace.c`, lines 1946-2045
- **Privileges required:** Regular user with CREATE privilege on `public` schema

**Description:** Operator resolution walks the `search_path` and selects the first matching operator. A user with CREATE on any schema in another user's search_path can create a trojan operator.

**Attack chain:**
- Attacker creates `CREATE OPERATOR public.= (leftarg=integer, rightarg=integer, procedure=evil_eq)`
- Victim's query `SELECT * FROM t WHERE id = 5` resolves `=` via search_path
- If victim has `public` before `pg_catalog` in search_path, attacker's operator wins
- Operator function runs with victim's privileges

**Mitigation:** `pg_catalog` is implicitly first unless explicitly placed elsewhere. Since PostgreSQL 15, CREATE on `public` is revoked by default. But remains exploitable in upgraded databases or when `public` CREATE is re-granted.

---

### X-3: Advisory Lock Table Exhaustion -- Complete Database DoS

- **Severity:** Medium
- **File:** `src/backend/storage/lmgr/lock.c`, line 3375
- **Privileges required:** Any unprivileged user

**Description:** Any regular user can acquire unlimited advisory locks, competing for entries in the shared lock table. Advisory locks share the same table as regular object locks.

**Exploitation:**
```sql
SELECT pg_advisory_lock(generate_series(1, 1000000));
```

This exhausts the lock table, causing **all other backends** to fail when acquiring ANY lock (including basic relation locks for SELECT). The code at line 1043 confirms: `ereport(ERROR, errmsg("out of shared memory"))`.

**Impact:** Complete database-wide denial of service from a single unprivileged connection.

**Remediation:** Add a per-user or per-session limit on advisory locks, or use a separate pool for advisory locks.

---

### X-4: NOTIFY Queue Saturation DoS

- **Severity:** Medium
- **File:** `src/backend/commands/async.c`, lines 570, 926, 1355
- **Privileges required:** Any user with a connection

**Description:** The notification queue is bounded by `max_notify_queue_pages` (default ~8GB). A user starts a LISTEN, then rapidly sends NOTIFY in large transactions from a separate session. The queue tail can't advance past the attacker's listening position. Other users' NOTIFY-ing transactions fail with `ERROR: too many notifications in the NOTIFY queue`.

**Remediation:** Add per-user queue usage limits or rate limiting.

---

### C-1: pg_dump Subscription `suboriginremotelsn` SQL Injection in Binary-Upgrade Mode

- **Severity:** Low
- **File:** `src/bin/pg_dump/pg_dump.c`, line 5682 (`dumpSubscription`)
- **Privileges required:** Superuser + `--binary-upgrade` mode

**Description:** The `suboriginremotelsn` value is interpolated inside single quotes using `%s` without `appendStringLiteralAH()`. A value like `'); DROP TABLE important; --` breaks out.

**Vulnerable code:**
```c
appendPQExpBuffer(query, ", '%s');\n", subinfo->suboriginremotelsn);
```

**Mitigating factors:** Only executes during `--binary-upgrade` (used by `pg_upgrade`). The value comes from system-maintained `pg_replication_origin_status.remote_lsn`. Requires superuser catalog corruption to exploit.

---

### C-2: pg_restore Signed/Unsigned Confusion in `ReadInt` -> `size_t`

- **Severity:** Low (DoS only)
- **File:** `src/bin/pg_dump/pg_backup_custom.c`, line 1016 (`_CustomReadFunc`)

**Description:** `ReadInt()` returns signed `int`, assigned to `size_t blkLen`. A negative value in a crafted archive becomes a huge `size_t`, and `pg_malloc(blkLen)` tries to allocate ~2^64 bytes, causing OOM exit.

**Remediation:** Check `blkLen` for negative/unreasonable values before allocation.

---

### C-3: pg_restore `ReadInt` Undefined Behavior with Large `intSize`

- **Severity:** Low
- **File:** `src/bin/pg_dump/pg_backup_archiver.c`, lines 2199-2203

**Description:** When `intSize > 4` (from a crafted archive header), `bitShift` reaches 32+. Left-shifting an `int` by 32+ bits is undefined behavior in C. The archive header `intSize` check at line 4234 allows values up to 32.

**Remediation:** Clamp `intSize` to `sizeof(int)` or use `int64` for the accumulator.

---

## Part 3: Wave 4 -- Pattern Scan, New Features & Remaining Contrib

### P-1: ECPG Client Buffer Overflow via strncpy Without Null Termination

- **Severity:** Medium
- **File:** `src/interfaces/ecpg/ecpglib/descriptor.c`, line 201; `src/interfaces/ecpg/ecpglib/data.c`, lines 209, 614, 639
- **Privileges required:** Malicious server sending long column values to ECPG client

**Description:** ECPG's data retrieval uses `strncpy(var, value, varcharsize)` which does not null-terminate if `value` is longer than `varcharsize`. The buffer is then used as a C string. Worse, at `data.c` line 209, when `varcharsize == 0`, an unbounded `memcpy(variable->arr, value, strlen(value))` occurs.

**Vulnerable code:**
```c
// descriptor.c:201
strncpy(var, value, varcharsize);  // no null termination if value >= varcharsize

// data.c:209
if (varcharsize == 0)
    memcpy(variable->arr, value, strlen(value));  // unbounded heap write
```

**Impact:** Stack/heap buffer overflow in ECPG client applications. Exploitable by a rogue server.

**Remediation:** Use `strlcpy()` instead of `strncpy()`. Add bounds check before the `varcharsize == 0` memcpy.

---

### P-2: DecodeMultiInsert Assert-Only Bounds Check in WAL Decoding

- **Severity:** Medium
- **File:** `src/backend/replication/logical/decode.c`, lines 1142-1200 (`DecodeMultiInsert`)
- **Privileges required:** Compromised upstream server or MITM on replication stream

**Description:** The loop trusts `xlrec->ntuples` and each `xlhdr->datalen` from WAL records without runtime validation against the actual data block size. Only an `Assert(data == tupledata + tuplelen)` at line 1200 catches inconsistency -- compiled out in production.

**Vulnerable code:**
```c
for (i = 0; i < xlrec->ntuples; i++)
{
    xlhdr = (xl_multi_insert_tuple *) SHORTALIGN(data);
    datalen = xlhdr->datalen;    // No bounds check against tuplelen!
    memcpy((char *) tuple->t_data + SizeofHeapTupleHeader, data, datalen);
    data += datalen;
}
Assert(data == tupledata + tuplelen);  // Assert only!
```

**Impact:** Out-of-bounds read from WAL record buffer, crash or info disclosure in logical decoding worker. Same class of bug as X-1.

---

### P-3: OAuth Authentication Has No Built-in Token Validation

- **Severity:** Medium (architectural)
- **File:** `src/backend/libpq/auth-oauth.c`, lines 637-727 (`validate`)

**Description:** The server-side OAuth implementation delegates ALL token validation to an external loadable module via `ValidatorCallbacks->validate_cb()`. There is zero built-in enforcement of JWT security properties: no signature verification, no expiration checking, no audience validation, no issuer verification. A buggy validator module could accept any string as a valid token.

**Impact:** Security depends entirely on third-party validator correctness, with no safety net from the core server.

---

### P-4: OAuth Client `PGOAUTHDEBUG=UNSAFE` Downgrades HTTPS to HTTP

- **Severity:** Medium
- **File:** `src/interfaces/libpq/fe-auth-oauth.c`, lines 382-391

**Description:** Setting the environment variable `PGOAUTHDEBUG=UNSAFE` causes the client to accept HTTP (non-TLS) OAuth discovery URIs. In shared hosting environments, another process running as the same user could set this, enabling MITM attacks on the OAuth token exchange.

---

### P-5: Temporary Files Created Without O_EXCL (Symlink Attack Surface)

- **Severity:** Medium (defense-in-depth)
- **File:** `src/backend/storage/file/fd.c`, lines 1807-1812 (`OpenTemporaryFileInTablespace`)

**Description:** Temp files use `O_CREAT | O_TRUNC` without `O_EXCL`. The comment acknowledges this is intentional for orphaned file reuse. The temp file path `base/pgsql_tmp/pgsql_tmpPID.COUNTER` is predictable. An attacker who can write to `pgsql_tmp` could create a symlink causing truncation of arbitrary files (e.g., `pg_hba.conf`).

**Mitigation:** The `pgsql_tmp` directory is inside the data directory (0700 permissions). Exploitable only if permissions are misconfigured.

---

### P-6: dblink Loopback Can Bypass Session-Level RLS Settings

- **Severity:** Medium
- **File:** `contrib/dblink/dblink.c`, lines 196-250

**Description:** dblink connecting back to `localhost` creates a wholly new session where session-level `SET ROLE`, `ALTER ROLE ... SET row_security`, and other session settings don't apply. A user who knows their own password can connect back to bypass session-level RLS configuration.

**Mitigation:** Non-superusers must provide a password explicitly in the connection string (line 2760-2779).

---

## Part 4: Protocol & Implementation Bugs (Waves 2-3)

### N-1: COPY BINARY Header Extension -- Uninterruptible DoS Loop

- **Severity:** Medium
- **File:** `src/backend/commands/copyfromparse.c`, lines 219-232
- **Privileges required:** Any authenticated user with COPY privilege (default for table owners)

**Description:** When parsing a COPY BINARY header, the extension length is read as an `int32`. The code then reads the extension data one byte at a time in a tight loop with **no `CHECK_FOR_INTERRUPTS()` call**. The entire `copyfromparse.c` header parsing path contains zero interrupt checks -- the only one is in the per-row loop in `copyfrom.c:1119`, which runs *after* header parsing completes.

**Vulnerable code:**
```c
/* Header extension length */
if (!CopyGetInt32(cstate, &tmp) || tmp < 0)
    ereport(ERROR, ...);
/* Skip extension header, if present */
while (tmp-- > 0)
{
    if (CopyReadBinaryData(cstate, readSig, 1) != 1)
        ereport(ERROR, ...);
}
```

**Exploitation scenario:** An attacker executes `COPY table FROM STDIN (FORMAT binary)`, sends a valid header with `extension_length = INT_MAX` (2,147,483,647), then slowly feeds bytes. The backend is pinned in this tight loop and **cannot be cancelled** by `pg_cancel_backend()` or `statement_timeout`. Only `pg_terminate_backend()` (SIGKILL) can stop it. This can be used to exhaust backend connection slots.

**Remediation:** Add `CHECK_FOR_INTERRUPTS()` inside the `while` loop, or read the extension in bulk via a single `CopyReadBinaryData(cstate, buf, tmp)` call.

---

### N-2: Client SCRAM Parser Accepts Trailing Garbage in Server Messages

- **Severity:** Medium (protocol conformance bug)
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 683-686 and 732-733

**Description:** In both `read_server_first_message()` and `read_server_final_message()`, the client detects trailing garbage in the server's SCRAM response, appends an error message, but **does not return `false`**. Authentication proceeds as if the message were valid. This is clearly an intended-to-be-fatal check where someone forgot the `return false`.

**Vulnerable code:**
```c
// In read_server_first_message(), line 683:
if (*input != '\0')
    libpq_append_conn_error(conn,
        "malformed SCRAM message (garbage at end of server-first-message)");
return true;  // BUG: continues authentication despite detecting garbage

// In read_server_final_message(), line 732:
if (*input != '\0')
    libpq_append_conn_error(conn,
        "malformed SCRAM message (garbage at end of server-final-message)");
// falls through to return true
```

**Exploitation scenario:** A malicious server or MITM can inject arbitrary trailing data in SCRAM messages and the client silently accepts it. While it doesn't affect the cryptographic proof (fields are already parsed), it violates strict protocol parsing and could mask injection of future protocol extensions.

**Remediation:** Add `return false;` after each `libpq_append_conn_error` call in both locations.

---

### N-3: RADIUS Response Source IP Address Not Validated

- **Severity:** Medium (defense-in-depth gap)
- **File:** `src/backend/libpq/auth.c`, lines 3173-3190

**Description:** The RADIUS UDP socket is unconnected (`sendto()` at line 3092 instead of `connect()` + `send()`), so `recvfrom()` accepts packets from **any source IP**. The MD5 response authenticator check (line 3232-3244) provides cryptographic verification, but if the shared secret is weak, an attacker on the local network can send spoofed `ACCESS_ACCEPT` packets to bypass authentication.

**Remediation:** Use `connect()` on the UDP socket to restrict incoming packets to the configured RADIUS server address.

---

### N-4: RADIUS Attribute Bounds Check Off-by-Two

- **Severity:** Low-Medium (latent buffer overwrite)
- **File:** `src/backend/libpq/auth.c`, line 2832

**Description:** The bounds check in `radius_add_attribute()` accounts for `len` data bytes but **not the 2-byte attribute header** (type + length fields). Each attribute actually consumes `len + 2` bytes.

**Vulnerable code:**
```c
static void
radius_add_attribute(radius_packet *packet, uint8 type,
                     const unsigned char *data, int len)
{
    if (packet->length + len > RADIUS_BUFFER_SIZE)  // BUG: should be len + 2
    {
        elog(WARNING, ...);
        return;
    }
    attr->attribute = type;
    attr->length = len + 2;   /* type (1) + length (1) + data (len) */
    memcpy(attr->data, data, len);
    packet->length += attr->length;  // adds len + 2, not len
}
```

**Current mitigation:** The `radius_packet` struct has a `pad` field providing ~4 bytes of slack beyond what the check guards. The off-by-2 cannot currently exceed this margin, but this is fragile -- any future struct layout change could make it exploitable as a stack buffer overwrite.

**Remediation:** Change the check to `packet->length + len + 2 > RADIUS_BUFFER_SIZE`.

---

### N-5: Missing `check_stack_depth()` in Binary Receive Functions

- **Severity:** Low-Medium
- **Files:**
  - `src/backend/utils/adt/arrayfuncs.c` -- `array_recv()` (line 1275)
  - `src/backend/utils/adt/multirangetypes.c` -- `multirange_recv()` (line 337)
  - `src/backend/utils/adt/domains.c` -- `domain_recv()` (line 287)

**Description:** These binary receive functions can recurse through composite types (e.g., `array_recv -> record_recv -> array_recv -> ...`) but lack `check_stack_depth()` calls. Peer functions like `record_recv()` and `range_recv()` correctly include them.

`domain_recv()` is particularly concerning: domains can chain arbitrarily deep (domain over domain over domain...) with no system-level limit on nesting depth. A deeply nested domain chain exercised via binary protocol could overflow the stack before any check fires.

**Remediation:** Add `check_stack_depth()` at the top of `array_recv()`, `multirange_recv()`, and `domain_recv()`.

---

### N-6: TOAST Decompression Memory Bomb

- **Severity:** Low (requires on-disk corruption or superuser)
- **File:** `src/backend/access/common/toast_compression.c`, lines 82 and 182

**Description:** The claimed decompressed size is read from the datum's header (30-bit field, max ~1GB). A tiny compressed datum with a corrupted header claiming 1GB decompressed size causes a 1GB `palloc` before decompression begins. The decompressors themselves (`LZ4_decompress_safe`, `pglz_decompress`) are safe, so this is memory exhaustion only, not a buffer overflow.

**Remediation:** Validate that the claimed decompressed size is reasonable relative to the compressed size before allocating.

---

### N-7: Deferred Triggers Lack `RestrictSearchPath()`

- **Severity:** Low (defense-in-depth gap)
- **File:** `src/backend/commands/trigger.c`, lines 4551-4572

**Description:** Deferred constraint triggers fire at commit time using the triggering role's identity (`SetUserIdAndSecContext`), but there is **no `RestrictSearchPath()` call**. This is inconsistent with index builds (`catalog/index.c:3055`), materialized view refresh (`commands/matview.c:194`), and VACUUM/ANALYZE, which all call `RestrictSearchPath()`.

If a deferred trigger function uses unqualified names and `search_path` is modified between the triggering statement and commit, the trigger could resolve names differently than intended.

**Remediation:** Add `RestrictSearchPath()` call before deferred trigger execution, consistent with other protected contexts.

---

### N-8: Memory Leak via Recursive Domain Constraint + CoerceViaIO in PL/pgSQL

- **Severity:** Low-Medium
- **File:** `src/pl/plpgsql/src/pl_exec.c`, lines 8207-8214 (`get_cast_hashentry`)
- **Privileges required:** CREATE FUNCTION (regular user)

**Description:** PL/pgSQL's type coercion uses I/O coercion (CoerceViaIO) as fallback. When `cast_in_use` is true (reentrant cast), a new `ExprState` is allocated per recursion level in `es_query_cxt`. A domain with a CHECK constraint that triggers the same cast creates deep recursion. Each level allocates a new ExprState before `check_stack_depth()` fires.

**PoC Concept:**
```sql
CREATE DOMAIN evil_domain AS text CHECK (check_func(VALUE));
CREATE FUNCTION check_func(text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v evil_domain;
BEGIN v := $1; RETURN true; EXCEPTION WHEN OTHERS THEN RETURN true; END $$;
```

**Impact:** Transient memory consumption / DoS. Bounded by stack depth limit. Memory freed at transaction end.

---

## Part 5: Memory Safety & Data Structure Integrity

**Key observation:** No exploitable code execution paths were found through normal SQL input. The binary protocol `_recv` functions are generally well-audited. However, integer overflow in array operations uses undefined behavior, and on-disk data structures trust their headers without runtime validation.

### M-1: Signed Integer Overflow (UB) in `array_cat()` Dimension Summation

- **Severity:** Low-Medium
- **File:** `src/backend/utils/adt/array_userfuncs.c`, line 439
- **Privileges required:** Any authenticated user

**Description:** When concatenating two arrays, `dims[0] = dims1[0] + dims2[0]` performs signed integer addition without overflow checking. If both dimensions are near `INT_MAX/2`, the sum overflows. The subsequent `ArrayGetNItems()` catches negative results, but this relies on **undefined behavior** -- a sufficiently aggressive compiler could optimize away the downstream check.

**Vulnerable code:**
```c
dims[0] = dims1[0] + dims2[0];  // signed overflow = UB
// ...
nitems = ArrayGetNItems(ndim, dims);  // catches negative, but UB already happened
```

**Remediation:** Use `pg_add_s32_overflow()` before the addition, consistent with other overflow-protected paths in the codebase.

---

### M-2: On-Disk JSONB Headers Trusted Without Bounds Validation (Systemic)

- **Severity:** Medium (requires corrupted data)
- **File:** `src/backend/utils/adt/jsonb_util.c`, lines 1126-1152 (`iteratorFromContainer`), line 513 (`fillJsonbValue`)

**Description:** `JsonContainerSize()` reads `nElems` directly from the JSONB binary header. There is no validation that `nElems` is consistent with the actual varlena size. If JSONB data on disk is corrupted (e.g., `nElems` set larger than actual data):
- `it->dataProper` points beyond the actual data
- `container->children[index]` in `fillJsonbValue` is an out-of-bounds read
- String/numeric data pointers computed from JEntry offsets can point anywhere

**Vulnerable code:**
```c
it->nElems = JsonContainerSize(container);    // from disk header, unchecked
it->children = container->children;
it->dataProper = (char *) it->children + it->nElems * sizeof(JEntry);  // OOB if corrupted
```

This also affects multirange types (`multirangetypes.c:831-844` -- `rangeCount` trusted from disk) and arrays (`arrayfuncs.c:3662-3683` -- data pointer walks without bounds check).

**Impact:** Out-of-bounds read leading to crash or information disclosure. Requires corrupted on-disk data (not triggerable through normal SQL input).

**Remediation:** Add consistency checks between header metadata (element counts) and actual varlena size when deserializing.

---

### M-3: `array_set_slice()` Size Computation Overflow

- **Severity:** Low
- **File:** `src/backend/utils/adt/arrayfuncs.c`, line 3088

**Description:** `newsize = overheadlen + olddatasize - olditemsize + newitemsize` -- all `int` without overflow check. When extending a large array with another large slice, the sum can exceed `INT_MAX`. The resulting negative value becomes a huge `Size` rejected by palloc (DoS, not code execution).

**Remediation:** Use overflow-checked arithmetic.

---

## Part 6: Access Control Observations

### A-1: MERGE with RLS Produces Errors Instead of Silent Filtering

- **Severity:** Low (information disclosure by design)
- **File:** `src/backend/rewrite/rowsecurity.c`, lines 407-418; `src/backend/executor/execMain.c`, lines 2357-2368

**Description:** When a MERGE targets a row visible via SELECT RLS policy but blocked by UPDATE/DELETE RLS policy, the user gets an explicit error (naming the policy) instead of silent filtering. A normal UPDATE/DELETE would silently skip the row. The code has an `XXX` comment acknowledging this divergence.

**Impact:** Can confirm whether specific rows exist that match a condition, but only for rows already visible via the SELECT policy.

---

### A-2: `GUC_SAFE_SEARCH_PATH` Includes `pg_temp`

- **Severity:** Very Low
- **File:** `src/backend/utils/misc/guc.c`, line 76

**Description:** `RestrictSearchPath()` sets `search_path = 'pg_catalog, pg_temp'`. Pre-existing temp objects could be found for names not in `pg_catalog`. However, `SECURITY_RESTRICTED_OPERATION` blocks creating new temp objects during maintenance, and `pg_catalog` priority prevents shadowing standard functions.

---

## Part 7: Known Issues (Reassessed Severity)

### K-1: SCRAM Iteration Count GUC Minimum is 1

- **Severity:** Medium
- **File:** `src/backend/utils/misc/guc_parameters.dat`

**Description:** The `scram_iterations` GUC allows values as low as 1. RFC 7677 mandates minimum 4096. Additionally, `parse_scram_secret()` in `auth-scram.c` (line 640-643) accepts iterations=0 or negative values from stored secrets. With `iterations=0`, `scram_SaltedPassword()` reduces PBKDF2 to a single HMAC pass.

**Remediation:** Set GUC minimum to 4096. Add validation in `parse_scram_secret()` to reject `iterations < 1`.

---

### K-2: XML Billion Laughs via `XML_PARSE_NOENT` (Enhanced Analysis)

- **Severity:** Medium
- **File:** `src/backend/utils/adt/xml.c`, lines 1851-1888

**Description:** Beyond the basic `XML_PARSE_NOENT` issue, there is a **DOCTYPE promotion mechanism**: when `xmloption = CONTENT` (the default), PostgreSQL's `xml_parse()` silently promotes any input containing a DOCTYPE declaration to DOCUMENT-mode parsing, which enables `XML_PARSE_NOENT`. This means DBAs who believe CONTENT-mode is safer get no protection -- any authenticated user can force entity expansion by including `<!DOCTYPE ...>` in their XML.

**Exploitation scenario:** `SELECT '<xml/>'::xml` is safe, but `SELECT '<!DOCTYPE d [<!ENTITY x "...">]><d>&x;</d>'::xml` triggers DOCUMENT-mode with entity expansion even when `xmloption = CONTENT`.

**Remediation:** Set `xmlCtxtSetMaxAmplification()` or equivalent libxml2 limits.

---

### K-3: `system()` Without Shell Escaping in Archive Commands

- **Severity:** Medium (configuration-dependent)
- **File:** `src/backend/archive/shell_archive.c`, line 81; `src/backend/access/transam/xlogarchive.c`, line 178

**Description:** Archive/restore commands interpolate `%p` (path) without shell escaping. A data directory path containing shell metacharacters could cause command injection. Requires superuser to configure, but the escaping gap is a bad pattern.

**Remediation:** Apply shell escaping to substitution values.

---

### K-4: `numeric_recv()` Unbounded Allocation

- **Severity:** Medium
- **File:** `src/backend/utils/adt/numeric.c`, lines 1076-1078

**Description:** Binary receive reads `uint16` digit count and allocates proportionally. Via COPY BINARY, a client can send many 65535-digit values to exhaust backend memory.

**Remediation:** Add reasonableness check on `ndigits`.

---

### K-5: Client Doesn't Enforce SCRAM Iteration Minimum

- **Severity:** Medium
- **File:** `src/interfaces/libpq/fe-auth-scram.c`, lines 676-681

**Description:** libpq accepts `i=1` from server, enabling password recovery by a rogue server. No maximum is enforced either, enabling CPU DoS.

**Remediation:** Enforce minimum 4096, maximum ~100M.

---

### K-6 through K-9: Timing Attacks in Authentication (Consolidated)

- **Severity:** Low-Medium (K-6), Low (K-7, K-8, K-9)
- **Files:** `src/backend/libpq/auth-scram.c` (lines 582, 1189), `src/backend/libpq/crypt.c` (lines 296, 375), `src/backend/libpq/auth.c` (line 3244)

**Description:** Non-constant-time `memcmp()`/`strcmp()` in password and SCRAM verification. Real but low practical exploitability over network connections due to jitter, buffering, and TLS overhead. The MD5 timing attack (K-8) is on a deprecated mechanism. The RADIUS timing attack (K-9) requires MITM between PG and RADIUS server.

**Remediation:** Replace with constant-time comparisons. Low effort, good defense-in-depth.

---

### K-10: Trusted Extension Privilege Escalation

- **Severity:** Medium
- **File:** `src/backend/commands/extension.c`, lines 1266-1304

**Description:** Non-superuser with CREATE privilege can trigger superuser execution if `extension_control_path` includes a writable directory. `extension_control_path` is properly `PGC_SUSET` + `GUC_SUPERUSER_ONLY`, so exploitation requires OS-level filesystem compromise of a directory a superuser added to the path.

---

### K-11 through K-15: Lower-Priority Known Issues

- **K-11 (Low):** SCRAM key material not zeroed before free -- `src/interfaces/libpq/fe-auth-scram.c:181-203`
- **K-12 (Low):** PAM password in static global not zeroed -- `src/backend/libpq/auth.c:114`
- **K-13 (Low):** LDAP plaintext bind when LDAPS/StartTLS not configured -- `src/backend/libpq/auth.c:2643`
- **K-14 (Low):** MD5 authentication still supported, on deprecation path -- `src/backend/libpq/auth.c:859`
- **K-15 (Low):** Systemic unbounded `sprintf()` usage -- `src/port/snprintf.c:213-227`

---

## Part 8: Areas Audited and Found Clean

The following areas were thoroughly reviewed and found well-implemented:

- **Wire protocol message parsing** (`src/backend/tcop/postgres.c`): Robust length validation, proper bounds checking in all `pq_getmsg*` functions
- **StringInfo API** (`src/common/stringinfo.c`): Overflow guards in `enlargeStringInfo()`, proper negative-value handling
- **Core SQL construction** (`src/backend/utils/adt/ri_triggers.c`): Consistently uses `quoteOneName()`/`quoteRelationName()` -- **contrast with contrib modules**
- **Extension system quoting** (`src/backend/commands/extension.c`): `quoting_relevant_chars` validation is sound for `@extschema@` and `@extowner@`
- **SECURITY DEFINER functions** (`src/backend/utils/fmgr/fmgr.c`): proconfig GUC validation at DDL-time is correct; error-path cleanup relies on transaction abort properly; no elevated context leaks
- **RLS enforcement**: Correctly applied to COPY, logical replication, CREATE MATERIALIZED VIEW AS; `ExecBuildSlotValueDescription` returns NULL when RLS is enabled, preventing data leakage in error messages
- **LEAKPROOF checks**: Properly enforced for both CREATE and ALTER FUNCTION; only superusers can set
- **`SECURITY_RESTRICTED_OPERATION` enforcement**: Consistently blocks temp table creation, SET ROLE, GUC changes, and deferred trigger firing during maintenance operations
- **`local_preload_libraries` path restriction** (`src/backend/utils/fmgr/dfmgr.c:520-529`): `check_restricted_library_name` correctly prevents directory traversal
- **Logical replication privilege model** (`src/backend/replication/logical/worker.c`): `SwitchToUntrustedUser` properly limits privileges
- **`validate_option_array_item`**: Correctly validates GUC permissions at DDL time, preventing non-superusers from storing SUSET values in proconfig
- **SSL buffered data MITM detection** (`src/backend/tcop/backend_startup.c:626-630`): Correctly rejects pre-handshake data
- **Extended query error handling** (`src/backend/tcop/postgres.c:4789`): `ignore_till_sync` correctly prevents desync
- **No `alloca()` or VLA usage** found in backend code; PostgreSQL consistently uses `palloc()`
- **Binary protocol `_recv` functions**: `array_recv`, `record_recv`, `range_recv`, `numeric_recv`, `inet_recv`, etc. are systematically well-audited with proper length/bounds validation
- **`palloc` MaxAllocSize safety net**: Acts as a backstop for many potential integer overflow issues, preventing small-allocation-then-large-write scenarios
- **Overflow-checked arithmetic**: `pg_mul_s32_overflow` / `pg_add_s32_overflow` used consistently in `repeat()`, `lpad()`, `ArrayGetNItems()` and other high-risk paths
- **Regex engine**: DFA-based execution -- NOT vulnerable to classic ReDoS catastrophic backtracking. Has compilation space limits (`REG_MAX_COMPILE_SPACE`), stack depth checks, and `CHECK_FOR_INTERRUPTS()` during execution
- **pg_dump identifier quoting**: `fmtId()` and `appendStringLiteralAH()` used consistently across the vast majority of object dumping code. Server-decompiled expressions trusted by design (known trust boundary)
- **Encoding conversion**: `pg_any_to_server()` / `pg_server_to_any()` have proper integer overflow checks
- **Parallel query shared memory**: DSM segments have OS-level access controls (same user); plan deserialization not externally reachable
- **Virtual generated column security**: `check_virtual_generated_security_walker` properly blocks user-defined functions and types via `FirstUnpinnedObjectId` boundary
- **PL/pgSQL exception handling**: `CopyErrorData()` does complete deep copy into `stmt_mcontext` before subtransaction rollback; `eval_econtext` properly restored; `eval_tuptable` correctly set to NULL
- **PL/pgSQL EXECUTE ... INTO**: Query string passes through type output function then to `SPI_execute_extended` -- no format string injection possible
- **PL/pgSQL RAISE**: Uses `errmsg_internal("%s", err_message)` -- `%s` prevents format string attacks
- **PL/Perl Safe sandbox**: Opmask properly set, DynaLoader deleted, `require`/`dofile` replaced with safe versions, `entereval` is safe due to permanent opmask. No known escape vector
- **PL/Perl recursive structures**: `plperl_sv_to_datum` calls `check_stack_depth()` at entry
- **SPI stack integrity**: Properly saves/restores `SPI_processed`, `SPI_tuptable`, `SPI_result` at each nesting level; `AtEOSubXact_SPI`/`AtEOXact_SPI` clean up properly
- **PL/pgSQL FOREACH ARRAY**: Array properly copied, slice dimension validated, safe iteration via `array_create_iterator`
- **PL/pgSQL expanded object transfer**
- **No format string injection anywhere**: Entire codebase consistently uses `errmsg("...%s...", user_data)` never `errmsg(user_data)`
- **dblink SQL builder functions**: `get_sql_insert/delete/update` properly use `quote_ident_cstr()` and `quote_literal_cstr()`
- **dblink connection string escaping**: `escape_param_str` properly escapes backslash and single-quote
- **pgcrypto key material zeroing**: Uses `px_memset()` (separate compilation unit) to prevent compiler optimization
- **hstore binary format**: `hstore_recv` validates all bounds, key lengths, value lengths
- **pg_trgm complexity limits**: `MAX_EXPANDED_STATES=128`, `MAX_TRGM_COUNT=256` prevent unbounded work
- **Error message ACL gating**: `BuildIndexValueDescription` checks RLS + column SELECT before including key values; FK violations similarly gated
- **postgres_fdw connection isolation**: Cache keyed by user mapping OID; no credential leakage between users
- **file_fdw privilege checks**: `pg_read_server_files` / `pg_execute_server_program` enforced at validator time: `plpgsql_param_eval_var_transfer` properly transfers ownership and NULLs the variable to prevent double-free

---

## Part 9: Priority Recommendations

### Fix Immediately (Critical/High severity)

1. **`refint.c` cascade value injection** (S-2): Use `quote_literal_cstr()` for all interpolated values, `quote_identifier()` for identifiers. **Critical** -- exploitable by any user with INSERT/UPDATE.
2. **Logical replication Assert-only bounds check** (X-1): Convert 3 `Assert()` calls in `worker.c` to runtime checks. **High** -- malicious publisher can read subscriber heap memory.
3. **`refint.c` identifier injection** (S-1): Use `quote_identifier()` for all table/column names from trigger args.
4. **`tablefunc.c` `connectby()` injection** (S-3): Use `quote_identifier()` for relname, key_fld, parent_key_fld, orderby_fld.
5. **`xml2/xpath.c` `xpath_table()` injection** (S-4): Use `quote_identifier()` for pkeyfield, xmlfield, relname; sanitize condition.

### Fix Now (low effort, real impact)

6. **COPY BINARY header loop** (N-1): Add `CHECK_FOR_INTERRUPTS()`. One-line fix, prevents authenticated DoS.
7. **SCRAM client garbage acceptance** (N-2): Add `return false` in two locations. Obvious bug.
8. **RADIUS bounds check** (N-4): Change `len` to `len + 2`. One-line fix.
9. **SCRAM iteration minimum** (K-1): Set GUC min to 4096. One-line fix.
10. **Advisory lock table exhaustion** (X-3): Add per-session advisory lock limit or separate pool.

### Fix Soon (moderate effort, defense-in-depth)

9. **ECPG strncpy buffer overflow** (P-1): Replace `strncpy` with `strlcpy`, add bounds check for `varcharsize == 0`.
10. **DecodeMultiInsert bounds check** (P-2): Convert Assert to runtime validation of `ntuples`/`datalen` against `tuplelen`.
11. **`postgres_fdw` IMPORT FOREIGN SCHEMA** (S-5): Quote `typename` and sanitize `attdefault` from remote server.
10. **RADIUS source IP validation** (N-3): Switch to `connect()` on UDP socket.
11. **XML entity expansion limits** (K-2): Set `xmlCtxtSetMaxAmplification()` or equivalent.
12. **Missing `check_stack_depth()`** (N-5): Add calls to `array_recv`, `multirange_recv`, `domain_recv`.
13. **Server-side SCRAM iteration validation** (K-1 extension): Validate `iterations > 0` in `parse_scram_secret()`.
14. **Client SCRAM iteration bounds** (K-5): Enforce min/max on client side.

### Backlog (known trade-offs, long-term)

15. **Integer overflow UB in `array_cat()`** (M-1): Use `pg_add_s32_overflow()`.
16. **On-disk header validation** (M-2): Add consistency checks for JSONB, multirange, array deserialization.
17. Shell escaping in archive commands (K-3)
18. Memory zeroing for key material (K-11, K-12)
19. Constant-time comparisons in auth (K-6 through K-9)
20. MD5 deprecation completion (K-14)
21. `numeric_recv()` bounds check (K-4)
22. `sprintf` -> `snprintf` migration (K-15)

### Not Worth Fixing

- **lo_import/lo_export directory restrictions**: Working as designed, role-gated behind near-superuser privileges
- **Fastpath RLS bypass**: Fastpath is essentially deprecated
- **Superuser cache staleness**: Documented, expected behavior
- **TOCTOU in pg_signal_backend**: Theoretical on modern systems, acknowledged in code

---

*End of report*
