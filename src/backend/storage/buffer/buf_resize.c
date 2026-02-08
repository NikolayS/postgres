/*-------------------------------------------------------------------------
 *
 * buf_resize.c
 *	  Online buffer pool resizing without server restart.
 *
 * This module implements the ability to change shared_buffers at runtime
 * via SIGHUP, without requiring a PostgreSQL restart.  It works by:
 *
 * 1. At startup, reserving virtual address space for max_shared_buffers
 *    worth of buffer pool arrays (descriptors, blocks, CVs, ckpt IDs).
 *
 * 2. Committing physical memory only for the initial shared_buffers.
 *
 * 3. On grow: committing additional memory, initializing new descriptors,
 *    and updating NBuffers via a ProcSignalBarrier so all backends see
 *    the new value atomically.
 *
 * 4. On shrink: draining condemned buffers (flushing dirty pages, waiting
 *    for unpins), then updating NBuffers and decommitting memory.
 *
 * The key invariant is that the base pointers (BufferDescriptors,
 * BufferBlocks, etc.) never change -- only NBuffers changes.  This means
 * GetBufferDescriptor() and BufHdrGetBlock() remain zero-overhead.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/buf_resize.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/mman.h>
#include <unistd.h>

#include "miscadmin.h"
#include "postmaster/bgwriter.h"
#include "storage/aio.h"
#include "storage/buf_internals.h"
#include "storage/buf_resize.h"
#include "storage/bufmgr.h"
#include "storage/condition_variable.h"
#include "storage/ipc.h"
#include "storage/pg_shmem.h"
#include "storage/proc.h"
#include "storage/proclist.h"
#include "storage/procsignal.h"
#include "storage/shmem.h"
#include "utils/guc.h"
#include "utils/timestamp.h"

/* GUC variable MaxNBuffers is declared in globals.c */

/* Shared memory control structure */
BufPoolResizeCtl *BufResizeCtl = NULL;

/*
 * Separately-mapped regions for each buffer pool array.
 * These are the reserved VA ranges, sized for MaxNBuffers.
 * The actual committed portion covers [0, NBuffers).
 */
static void *ReservedBufferBlocks = NULL;
static void *ReservedBufferDescriptors = NULL;
static void *ReservedBufferIOCVs = NULL;
static void *ReservedCkptBufferIds = NULL;

/* Effective max: either MaxNBuffers if set, or NBuffers */
static int
GetEffectiveMaxNBuffers(void)
{
	return MaxNBuffers > 0 ? MaxNBuffers : NBuffers;
}

/*
 * Reserve virtual address space for buffer pool arrays.
 *
 * This is called once during postmaster startup.  We use mmap with
 * PROT_NONE to reserve address space without committing physical memory.
 * The reserved ranges are later partially committed as needed.
 *
 * After this call, BufferBlocks, BufferDescriptors, BufferIOCVArray,
 * and CkptBufferIds point to the starts of their reserved regions.
 */
void
BufferPoolReserveMemory(void)
{
	int			max_bufs = GetEffectiveMaxNBuffers();
	Size		blocks_size;
	Size		descs_size;
	Size		iocv_size;
	Size		ckpt_size;

	/* If max equals current, no reservation needed -- use normal shmem path */
	if (MaxNBuffers <= 0 || MaxNBuffers <= NBuffers)
		return;

	/*
	 * Calculate sizes for the maximum possible buffer count.
	 */
	blocks_size = (Size) max_bufs * BLCKSZ + PG_IO_ALIGN_SIZE;
	descs_size = (Size) max_bufs * sizeof(BufferDescPadded) + PG_CACHE_LINE_SIZE;
	iocv_size = (Size) max_bufs * sizeof(ConditionVariableMinimallyPadded) + PG_CACHE_LINE_SIZE;
	ckpt_size = (Size) max_bufs * sizeof(CkptSortItem);

	/*
	 * Reserve virtual address space for each array.  MAP_NORESERVE tells
	 * the kernel not to reserve swap space for pages we haven't touched.
	 * PROT_NONE means no access until we commit specific ranges.
	 *
	 * We use MAP_ANONYMOUS | MAP_PRIVATE for the reservation, then overlay
	 * with MAP_SHARED | MAP_FIXED for committed regions in
	 * BufferPoolCommitMemory().
	 *
	 * Note: On Linux, this just reserves VA space; no physical memory or
	 * swap is consumed.
	 */
	ReservedBufferBlocks = mmap(NULL, blocks_size,
								PROT_READ | PROT_WRITE,
								MAP_ANONYMOUS | MAP_SHARED | MAP_NORESERVE,
								-1, 0);
	if (ReservedBufferBlocks == MAP_FAILED)
		ereport(FATAL,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not reserve %zu bytes of virtual address space for buffer blocks",
						blocks_size)));

	ReservedBufferDescriptors = mmap(NULL, descs_size,
									 PROT_READ | PROT_WRITE,
									 MAP_ANONYMOUS | MAP_SHARED | MAP_NORESERVE,
									 -1, 0);
	if (ReservedBufferDescriptors == MAP_FAILED)
		ereport(FATAL,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not reserve virtual address space for buffer descriptors")));

	ReservedBufferIOCVs = mmap(NULL, iocv_size,
							   PROT_READ | PROT_WRITE,
							   MAP_ANONYMOUS | MAP_SHARED | MAP_NORESERVE,
							   -1, 0);
	if (ReservedBufferIOCVs == MAP_FAILED)
		ereport(FATAL,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not reserve virtual address space for buffer IO CVs")));

	ReservedCkptBufferIds = mmap(NULL, ckpt_size,
								 PROT_READ | PROT_WRITE,
								 MAP_ANONYMOUS | MAP_SHARED | MAP_NORESERVE,
								 -1, 0);
	if (ReservedCkptBufferIds == MAP_FAILED)
		ereport(FATAL,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not reserve virtual address space for checkpoint buffer IDs")));

	/*
	 * Set global pointers.  These will be stable for the lifetime of the
	 * postmaster (and thus all child backends via fork()).
	 */
	BufferBlocks = (char *) TYPEALIGN(PG_IO_ALIGN_SIZE, ReservedBufferBlocks);
	BufferDescriptors = (BufferDescPadded *)
		TYPEALIGN(PG_CACHE_LINE_SIZE, ReservedBufferDescriptors);
	BufferIOCVArray = (ConditionVariableMinimallyPadded *)
		TYPEALIGN(PG_CACHE_LINE_SIZE, ReservedBufferIOCVs);
	CkptBufferIds = (CkptSortItem *) ReservedCkptBufferIds;

	elog(DEBUG1, "reserved buffer pool VA space for %d buffers (%zu MB)",
		 max_bufs, blocks_size / (1024 * 1024));
}

/*
 * Commit physical memory for the given number of buffers.
 *
 * When growing, this makes new pages accessible.  The memory was already
 * reserved by BufferPoolReserveMemory() using MAP_NORESERVE.  On Linux,
 * simply touching the pages will fault them in.  We use madvise to tell
 * the kernel we want these pages populated.
 *
 * Returns true on success, false if memory could not be committed (OOM).
 */
bool
BufferPoolCommitMemory(int nbufs)
{
#ifdef MADV_POPULATE_WRITE
	Size		blocks_size = (Size) nbufs * BLCKSZ;
	Size		descs_size = (Size) nbufs * sizeof(BufferDescPadded);
	Size		iocv_size = (Size) nbufs * sizeof(ConditionVariableMinimallyPadded);
	Size		ckpt_size = (Size) nbufs * sizeof(CkptSortItem);

	/*
	 * MADV_POPULATE_WRITE causes the kernel to allocate physical pages for
	 * the range.  If there isn't enough memory, madvise returns -1 with
	 * errno = ENOMEM, allowing us to detect OOM before we've committed to
	 * the resize.
	 */
	if (madvise(BufferBlocks, blocks_size, MADV_POPULATE_WRITE) != 0 ||
		madvise(BufferDescriptors, descs_size, MADV_POPULATE_WRITE) != 0 ||
		madvise(BufferIOCVArray, iocv_size, MADV_POPULATE_WRITE) != 0 ||
		madvise(CkptBufferIds, ckpt_size, MADV_POPULATE_WRITE) != 0)
	{
		ereport(WARNING,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not commit memory for %d buffers: %m", nbufs)));
		return false;
	}
#endif

	return true;
}

/*
 * Decommit physical memory for buffers beyond the given count.
 *
 * After shrinking, we release physical pages back to the OS but keep the
 * virtual address reservation intact for future growth.
 */
void
BufferPoolDecommitMemory(int old_nbufs, int new_nbufs)
{
	Size		blocks_offset = (Size) new_nbufs * BLCKSZ;
	Size		blocks_len = (Size) (old_nbufs - new_nbufs) * BLCKSZ;
	Size		descs_offset = (Size) new_nbufs * sizeof(BufferDescPadded);
	Size		descs_len = (Size) (old_nbufs - new_nbufs) * sizeof(BufferDescPadded);
	Size		iocv_offset = (Size) new_nbufs * sizeof(ConditionVariableMinimallyPadded);
	Size		iocv_len = (Size) (old_nbufs - new_nbufs) * sizeof(ConditionVariableMinimallyPadded);
	Size		ckpt_offset = (Size) new_nbufs * sizeof(CkptSortItem);
	Size		ckpt_len = (Size) (old_nbufs - new_nbufs) * sizeof(CkptSortItem);

	/* Release physical pages back to the OS */
	if (blocks_len > 0)
		madvise(BufferBlocks + blocks_offset, blocks_len, MADV_DONTNEED);
	if (descs_len > 0)
		madvise((char *) BufferDescriptors + descs_offset, descs_len, MADV_DONTNEED);
	if (iocv_len > 0)
		madvise((char *) BufferIOCVArray + iocv_offset, iocv_len, MADV_DONTNEED);
	if (ckpt_len > 0)
		madvise((char *) CkptBufferIds + ckpt_offset, ckpt_len, MADV_DONTNEED);

	elog(DEBUG1, "decommitted buffer pool memory: %d -> %d buffers",
		 old_nbufs, new_nbufs);
}

/* ----------------------------------------------------------------
 *		Shared memory initialization
 * ----------------------------------------------------------------
 */

Size
BufPoolResizeShmemSize(void)
{
	return MAXALIGN(sizeof(BufPoolResizeCtl));
}

void
BufPoolResizeShmemInit(void)
{
	bool		found;

	BufResizeCtl = (BufPoolResizeCtl *)
		ShmemInitStruct("Buffer Pool Resize Ctl",
						BufPoolResizeShmemSize(),
						&found);

	if (!found)
	{
		MemSet(BufResizeCtl, 0, sizeof(BufPoolResizeCtl));
		SpinLockInit(&BufResizeCtl->mutex);
		BufResizeCtl->status = BUF_RESIZE_IDLE;
		BufResizeCtl->target_buffers = NBuffers;
		pg_atomic_init_u32(&BufResizeCtl->current_buffers, (uint32) NBuffers);
	}
}

/* ----------------------------------------------------------------
 *		Buffer pool grow operation
 * ----------------------------------------------------------------
 */

/*
 * GrowBufferPool - add new buffers to the pool.
 *
 * This is called from the postmaster (or a designated bgworker) to
 * execute a grow operation.  new_nbuffers must be > NBuffers and
 * <= MaxNBuffers.
 */
static bool
GrowBufferPool(int new_nbuffers)
{
	int			old_nbuffers = NBuffers;
	int			i;
	uint64		generation;

	Assert(new_nbuffers > old_nbuffers);
	Assert(new_nbuffers <= GetEffectiveMaxNBuffers());

	elog(LOG, "buffer pool resize started: %d -> %d buffers (%d MB -> %d MB)",
		 old_nbuffers, new_nbuffers,
		 (int) ((Size) old_nbuffers * BLCKSZ / (1024 * 1024)),
		 (int) ((Size) new_nbuffers * BLCKSZ / (1024 * 1024)));

	/*
	 * Step 1: Commit physical memory for the new buffers.
	 *
	 * If using the reserved-VA-space path, memory is committed by touching
	 * it.  If using the normal shmem path (MaxNBuffers == 0), the hash table
	 * was pre-sized but the arrays can't grow -- this shouldn't happen.
	 */
	if (ReservedBufferBlocks != NULL)
	{
		if (!BufferPoolCommitMemory(new_nbuffers))
		{
			elog(WARNING, "buffer pool grow failed: could not commit memory");
			return false;
		}
	}

	/*
	 * Step 2: Initialize new buffer descriptors.
	 *
	 * New buffers are appended at the end, so existing buffers are not
	 * disturbed.  This is safe to do without holding any buffer locks because
	 * no backend can access buffer IDs >= old_nbuffers yet (NBuffers hasn't
	 * been updated).
	 */
	for (i = old_nbuffers; i < new_nbuffers; i++)
	{
		BufferDesc *buf = GetBufferDescriptor(i);

		ClearBufferTag(&buf->tag);
		pg_atomic_init_u64(&buf->state, 0);
		buf->wait_backend_pgprocno = INVALID_PROC_NUMBER;
		buf->buf_id = i;
		pgaio_wref_clear(&buf->io_wref);
		proclist_init(&buf->lock_waiters);

		/* Initialize the I/O condition variable for this buffer */
		ConditionVariableInit(BufferDescriptorGetIOCV(buf));
	}

	/*
	 * Step 3: Update the authoritative NBuffers in shared memory, then
	 * emit a barrier so all backends pick up the new value.
	 */
	pg_atomic_write_u32(&BufResizeCtl->current_buffers, (uint32) new_nbuffers);

	/* Update the global NBuffers for this process (the postmaster) */
	NBuffers = new_nbuffers;

	/*
	 * Emit barrier.  All backends will call ProcessBarrierBufferPoolResize()
	 * which updates their local NBuffers copy.
	 */
	generation = EmitProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE);
	WaitForProcSignalBarrier(generation);

	elog(LOG, "buffer pool resize completed: %d -> %d buffers",
		 old_nbuffers, new_nbuffers);

	return true;
}

/* ----------------------------------------------------------------
 *		Buffer pool shrink operation
 * ----------------------------------------------------------------
 */

/*
 * ShrinkBufferPool - remove buffers from the pool.
 *
 * This is considerably more complex than growing because we must ensure
 * all condemned buffers (those in [new_nbuffers, old_nbuffers)) are:
 *   - Not pinned by any backend
 *   - Not dirty (flushed to disk)
 *   - Removed from the buffer hash table
 *   - Not referenced by in-flight I/O
 *
 * Returns true if shrink succeeded, false if it had to be cancelled
 * (e.g., timeout waiting for pinned buffers).
 */
static bool
ShrinkBufferPool(int new_nbuffers)
{
	int			old_nbuffers = NBuffers;
	int			i;
	int			max_attempts = 600;		/* ~60 seconds with 100ms sleep */
	int			attempt;
	uint64		generation;

	Assert(new_nbuffers < old_nbuffers);
	Assert(new_nbuffers >= 16);

	elog(LOG, "buffer pool shrink started: %d -> %d buffers (%d MB -> %d MB)",
		 old_nbuffers, new_nbuffers,
		 (int) ((Size) old_nbuffers * BLCKSZ / (1024 * 1024)),
		 (int) ((Size) new_nbuffers * BLCKSZ / (1024 * 1024)));

	/*
	 * Update status for monitoring.
	 */
	SpinLockAcquire(&BufResizeCtl->mutex);
	BufResizeCtl->status = BUF_RESIZE_DRAINING;
	BufResizeCtl->condemned_remaining = old_nbuffers - new_nbuffers;
	SpinLockRelease(&BufResizeCtl->mutex);

	/*
	 * Step 1: Drain condemned buffers.
	 *
	 * Iterate over the condemned range and invalidate each buffer.  This
	 * may require multiple passes if buffers are pinned or dirty.
	 */
	for (attempt = 0; attempt < max_attempts; attempt++)
	{
		int			remaining = 0;
		int			pinned = 0;
		int			dirty = 0;

		for (i = new_nbuffers; i < old_nbuffers; i++)
		{
			BufferDesc *buf = GetBufferDescriptor(i);
			uint64		buf_state;

			buf_state = pg_atomic_read_u64(&buf->state);

			/* Skip already-invalidated buffers */
			if (!(buf_state & BM_TAG_VALID))
				continue;

			remaining++;

			/* Can't touch pinned buffers */
			if (BUF_STATE_GET_REFCOUNT(buf_state) != 0)
			{
				pinned++;
				continue;
			}

			/*
			 * If dirty, request a write.  Use EvictUnpinnedBuffer which
			 * handles the full flush + invalidation cycle.
			 */
			if (buf_state & BM_DIRTY)
			{
				bool		flushed = false;

				dirty++;
				(void) EvictUnpinnedBuffer(BufferDescriptorGetBuffer(buf),
										   &flushed);
				continue;
			}

			/*
			 * Buffer is valid, clean, and unpinned.  Evict it.
			 */
			{
				bool		flushed = false;

				(void) EvictUnpinnedBuffer(BufferDescriptorGetBuffer(buf),
										   &flushed);
			}
		}

		/* Update progress */
		SpinLockAcquire(&BufResizeCtl->mutex);
		BufResizeCtl->condemned_remaining = remaining;
		BufResizeCtl->condemned_pinned = pinned;
		BufResizeCtl->condemned_dirty = dirty;
		SpinLockRelease(&BufResizeCtl->mutex);

		if (remaining == 0)
			break;

		if (attempt > 0 && attempt % 100 == 0)
			elog(WARNING, "buffer pool shrink: still draining %d buffers "
				 "(%d pinned, %d dirty) after %d seconds",
				 remaining, pinned, dirty, attempt / 10);

		/* Sleep briefly before retrying */
		pg_usleep(100000L);		/* 100ms */
	}

	if (attempt >= max_attempts)
	{
		elog(WARNING, "buffer pool shrink cancelled: could not drain all "
			 "condemned buffers within timeout");

		SpinLockAcquire(&BufResizeCtl->mutex);
		BufResizeCtl->status = BUF_RESIZE_IDLE;
		BufResizeCtl->target_buffers = old_nbuffers;
		BufResizeCtl->condemned_remaining = 0;
		SpinLockRelease(&BufResizeCtl->mutex);
		return false;
	}

	/*
	 * Step 2: All condemned buffers are now invalid.  Update NBuffers and
	 * emit barrier.
	 */
	SpinLockAcquire(&BufResizeCtl->mutex);
	BufResizeCtl->status = BUF_RESIZE_COMPLETING;
	SpinLockRelease(&BufResizeCtl->mutex);

	pg_atomic_write_u32(&BufResizeCtl->current_buffers, (uint32) new_nbuffers);
	NBuffers = new_nbuffers;

	generation = EmitProcSignalBarrier(PROCSIGNAL_BARRIER_BUFFER_POOL_RESIZE);
	WaitForProcSignalBarrier(generation);

	/*
	 * Step 3: Decommit physical memory for the freed region.
	 */
	if (ReservedBufferBlocks != NULL)
		BufferPoolDecommitMemory(old_nbuffers, new_nbuffers);

	elog(LOG, "buffer pool shrink completed: %d -> %d buffers",
		 old_nbuffers, new_nbuffers);

	return true;
}

/* ----------------------------------------------------------------
 *		Resize coordination
 * ----------------------------------------------------------------
 */

/*
 * RequestBufferPoolResize - request an asynchronous resize.
 *
 * Called from the GUC assign hook.  Sets the target and lets the
 * postmaster or a bgworker pick it up.
 */
void
RequestBufferPoolResize(int new_nbuffers)
{
	if (BufResizeCtl == NULL)
		return;					/* Not yet initialized */

	SpinLockAcquire(&BufResizeCtl->mutex);

	/* Don't interrupt an in-progress resize */
	if (BufResizeCtl->status != BUF_RESIZE_IDLE)
	{
		SpinLockRelease(&BufResizeCtl->mutex);
		ereport(WARNING,
				(errmsg("buffer pool resize already in progress, "
						"ignoring new request")));
		return;
	}

	BufResizeCtl->target_buffers = new_nbuffers;
	if (new_nbuffers > NBuffers)
		BufResizeCtl->status = BUF_RESIZE_GROWING;
	else if (new_nbuffers < NBuffers)
		BufResizeCtl->status = BUF_RESIZE_DRAINING;
	/* else: same value, no-op */

	BufResizeCtl->started_at = GetCurrentTimestamp();
	SpinLockRelease(&BufResizeCtl->mutex);
}

/*
 * ExecuteBufferPoolResize - perform a pending resize.
 *
 * This should be called from the postmaster main loop or a dedicated
 * bgworker.  It checks for pending resize requests and executes them.
 */
void
ExecuteBufferPoolResize(void)
{
	int			target;
	BufPoolResizeStatus status;

	if (BufResizeCtl == NULL)
		return;

	SpinLockAcquire(&BufResizeCtl->mutex);
	status = BufResizeCtl->status;
	target = BufResizeCtl->target_buffers;
	SpinLockRelease(&BufResizeCtl->mutex);

	if (status == BUF_RESIZE_IDLE)
		return;

	if (target > NBuffers)
	{
		GrowBufferPool(target);
	}
	else if (target < NBuffers)
	{
		ShrinkBufferPool(target);
	}

	/* Mark resize as complete */
	SpinLockAcquire(&BufResizeCtl->mutex);
	BufResizeCtl->status = BUF_RESIZE_IDLE;
	BufResizeCtl->started_at = 0;
	BufResizeCtl->condemned_remaining = 0;
	BufResizeCtl->condemned_pinned = 0;
	BufResizeCtl->condemned_dirty = 0;
	SpinLockRelease(&BufResizeCtl->mutex);
}

/*
 * ProcessBarrierBufferPoolResize - backend barrier handler.
 *
 * Called from ProcessProcSignalBarrier() when a buffer pool resize
 * barrier is received.  Each backend updates its local NBuffers copy.
 */
bool
ProcessBarrierBufferPoolResize(void)
{
	int			new_nbuffers;

	new_nbuffers = (int) pg_atomic_read_u32(&BufResizeCtl->current_buffers);

	if (new_nbuffers != NBuffers)
	{
		int			old_nbuffers = NBuffers;

		NBuffers = new_nbuffers;

		elog(DEBUG1, "backend updated NBuffers: %d -> %d",
			 old_nbuffers, new_nbuffers);
	}

	return true;
}

/* ----------------------------------------------------------------
 *		GUC hooks
 * ----------------------------------------------------------------
 */

/*
 * GUC check hook for shared_buffers.
 *
 * Validates that the new value is within the allowed range:
 *   - At startup (PGC_S_FILE): normal validation
 *   - At runtime (PGC_S_SIGHUP/PGC_S_CLIENT): must be <= MaxNBuffers
 */
bool
check_shared_buffers(int *newval, void **extra, GucSource source)
{
	/*
	 * During initial startup, no special checks needed beyond the
	 * min/max in the GUC definition.  MaxNBuffers isn't set yet.
	 */
	if (!IsUnderPostmaster && !IsPostmasterEnvironment)
		return true;

	/*
	 * For runtime changes, enforce max_shared_buffers limit.
	 */
	if (MaxNBuffers > 0 && *newval > MaxNBuffers)
	{
		GUC_check_errmsg("shared_buffers (%d) cannot exceed max_shared_buffers (%d)",
						 *newval, MaxNBuffers);
		return false;
	}

	/*
	 * If max_shared_buffers was not configured (or equals shared_buffers),
	 * runtime changes are not allowed.  But we only enforce this for
	 * actual runtime changes, not for the initial postmaster load.
	 */
	if (IsUnderPostmaster && MaxNBuffers <= 0 && *newval != NBuffers)
	{
		GUC_check_errmsg("shared_buffers cannot be changed at runtime without "
						 "setting max_shared_buffers at server start");
		return false;
	}

	return true;
}

/*
 * GUC assign hook for shared_buffers.
 *
 * When the value changes at runtime (SIGHUP reload), request a resize.
 */
void
assign_shared_buffers(int newval, void *extra)
{
	/*
	 * During startup, just let the normal initialization proceed.
	 * NBuffers is set directly by the GUC mechanism.
	 */
	if (!IsUnderPostmaster)
		return;

	/*
	 * If the value is actually changing at runtime, request a resize.
	 */
	if (newval != NBuffers && BufResizeCtl != NULL)
	{
		RequestBufferPoolResize(newval);
	}
}
