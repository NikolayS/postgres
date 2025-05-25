# Enhance pg_restore to track successful and failed object restoration

## Summary

This merge request adds comprehensive object status tracking to `pg_restore`, providing detailed information about which database objects were successfully restored and which failed, including dependency analysis.

## Problem Statement

Currently, when `pg_restore` encounters errors during restoration, it's difficult to get a clear picture of:
- Which specific objects succeeded vs failed
- Why objects failed (beyond scrolling through potentially long logs) 
- Which failures are due to dependency cascades vs actual errors
- Which objects might be retryable after fixing underlying issues

## Solution

This enhancement adds object status tracking that provides:

### Key Features
- **Detailed restoration status**: Track success/failure for each object, separating schema and data restoration phases
- **Error message capture**: Store specific error messages for failed objects for easier debugging
- **Dependency analysis**: Show which objects failed due to dependency failures, helping identify root causes
- **Comprehensive summary**: Display a clear summary at the end showing successful/failed objects and dependency relationships

### Example Output
```
Restoration Summary:
===================
Successfully restored objects: 145
Failed objects: 3

Failed Objects (including dependency failures):
  TABLE "public.users": Schema creation failed
  INDEX "public.idx_users_email": Schema creation failed
  CONSTRAINT "public.fk_user_profile": Schema creation failed

Objects that might need retry due to dependencies:
  INDEX "public.idx_users_email" depends on failed TABLE "public.users"
  CONSTRAINT "public.fk_user_profile" depends on failed TABLE "public.users"
```

## Technical Implementation

### Changes Made
- **Enhanced TocEntry structure** with restoration status fields:
  - `schema_attempted`, `schema_success`, `data_attempted`, `data_success` 
  - `failure_reason` for storing error messages

- **Enhanced ArchiveHandle structure** with tracking arrays:
  - Dynamic arrays for successful and failed objects
  - Counters and allocated sizes for memory management

- **New tracking functions**:
  - `init_object_tracking()` - Initialize tracking arrays
  - `record_object_success()` - Record successful restoration
  - `record_object_failure()` - Record failed restoration with error message
  - `print_restoration_summary()` - Display comprehensive summary
  - `cleanup_object_tracking()` - Clean up allocated memory

### Integration Points
- Tracking initialization in `RestoreArchive()`
- Success/failure recording after each `_printTocEntry()` call
- Summary printing and cleanup at restoration completion

## Code Quality
- **Memory efficient**: Uses dynamic arrays with minimal overhead that grow as needed
- **Parallel compatible**: Works with both single-threaded and parallel restoration modes
- **Proper memory management**: All allocated memory is properly freed
- **PostgreSQL conventions**: Follows existing coding style and patterns
- **Backward compatible**: Doesn't change existing pg_restore behavior beyond adding summary output

## Files Changed
- `src/bin/pg_dump/pg_backup_archiver.h` - Structure enhancements and function declarations
- `src/bin/pg_dump/pg_backup_archiver.c` - Implementation of tracking functions and integration

## Statistics
- **2 files changed**
- **278 insertions**
- **0 deletions**

## Testing
- ✅ Builds cleanly without warnings
- ✅ Follows PostgreSQL coding conventions
- ✅ Memory management verified (no leaks)
- ✅ Compatible with existing functionality

## Benefits for Users
- **Faster debugging**: Immediately see which objects failed and why
- **Better visibility**: Clear understanding of restoration success/failure rates
- **Dependency insight**: Identify root causes of cascading failures
- **Retry guidance**: Know which objects might succeed after fixing dependencies
- **Improved workflows**: Database administrators can more efficiently handle restoration failures

## Future Enhancements
This foundation could support:
- Command-line option to control summary verbosity
- Export of failed objects list for scripted retry attempts
- Integration with monitoring/alerting systems
- Historical tracking across multiple restoration attempts

## Ready for Review
This MR is ready for review and testing. The implementation is complete, tested, and follows PostgreSQL development practices.