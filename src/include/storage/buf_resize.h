/*-------------------------------------------------------------------------
 *
 * buf_resize.h
 *	  Declarations for online shared buffer pool resizing.
 *
 * This module allows shared_buffers to be changed at runtime via SIGHUP
 * without requiring a server restart, provided max_shared_buffers was
 * set at startup to reserve sufficient virtual address space.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/storage/buf_resize.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef BUF_RESIZE_H
#define BUF_RESIZE_H

#include "storage/shmem.h"
#include "storage/spin.h"

/*
 * Possible states for an in-progress buffer pool resize operation.
 */
typedef enum BufPoolResizeStatus
{
	BUF_RESIZE_IDLE = 0,		/* No resize in progress */
	BUF_RESIZE_GROWING,			/* Adding new buffers */
	BUF_RESIZE_DRAINING			/* Draining condemned buffers for shrink */
} BufPoolResizeStatus;

/*
 * Shared memory state for buffer pool resize coordination.
 *
 * Non-atomic fields are protected by the mutex spinlock.  The
 * current_buffers field is accessed atomically without the lock.
 */
typedef struct BufPoolResizeCtl
{
	/* Spinlock protecting non-atomic fields */
	slock_t		mutex;

	/* Current resize state */
	BufPoolResizeStatus status;

	/* Target NBuffers for the current resize operation */
	int			target_buffers;

	/* Progress tracking for shrink drain (run by bgwriter) */
	int			drain_from;		/* start of condemned range (= new NBuffers) */
	int			drain_to;		/* end of condemned range (= old NBuffers) */
	int			condemned_remaining;
	int			condemned_pinned;
	int			condemned_dirty;

	/* Timestamp when current resize started (0 if idle) */
	TimestampTz started_at;

	/* The current authoritative NBuffers value (updated atomically) */
	pg_atomic_uint32 current_buffers;
} BufPoolResizeCtl;

/* MaxNBuffers is declared in miscadmin.h (defined in globals.c) */

/* Pointer to shared memory control structure */
extern PGDLLIMPORT BufPoolResizeCtl *BufResizeCtl;

/*
 * Functions for buffer pool resize.
 */

/* Shared memory initialization */
extern Size BufPoolResizeShmemSize(void);
extern void BufPoolResizeShmemInit(void);

/*
 * Reserve virtual address space for buffer pool arrays.
 * Called once at postmaster startup, before BufferManagerShmemInit().
 * Returns the base addresses for each array.
 */
extern void BufferPoolReserveMemory(void);

/*
 * Commit physical memory for buffers in the range [start_buf, end_buf)
 * within the previously reserved address space.
 */
extern bool BufferPoolCommitMemory(int start_buf, int end_buf);

/*
 * Decommit physical memory for buffers beyond the given count.
 */
extern void BufferPoolDecommitMemory(int old_nbufs, int new_nbufs);

/*
 * Initiate a buffer pool resize to the given target NBuffers.
 * Called from the GUC assign hook when shared_buffers changes.
 * The actual resize happens asynchronously via the postmaster.
 */
extern void RequestBufferPoolResize(int new_nbuffers);

/*
 * Execute a pending buffer pool resize.  Called from the postmaster
 * main loop or a dedicated background worker.
 */
extern void ExecuteBufferPoolResize(void);

/*
 * Drain condemned buffers after a shrink.  Called from the bgwriter
 * main loop, which has full backend infrastructure (ResourceOwner,
 * private refcounts, etc.) needed for buffer eviction.
 */
extern void BufPoolDrainCondemnedBuffers(void);

/*
 * GUC hooks for shared_buffers are declared in utils/guc_hooks.h,
 * not here, to avoid pulling guc.h into storage headers.
 */

#endif							/* BUF_RESIZE_H */
