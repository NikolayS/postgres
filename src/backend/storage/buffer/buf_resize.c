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
 *    and publishing the new NBuffers via an atomic variable.  The
 *    postmaster performs the resize then signals children via SIGHUP;
 *    each child reads current_buffers from shared memory.
 *
 * 4. On shrink: updating NBuffers immediately, then having the bgwriter
 *    asynchronously drain condemned buffers (flushing dirty pages,
 *    evicting unpinned buffers) before decommitting memory.
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
#include "storage/aio.h"
#include "storage/buf_internals.h"
#include "storage/buf_resize.h"
#include "storage/bufmgr.h"
#include "storage/condition_variable.h"
#include "storage/proc.h"
#include "storage/proclist.h"
#include "storage/shmem.h"
#include "utils/guc.h"
#include "utils/guc_hooks.h"
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

#ifdef EXEC_BACKEND
	/*
	 * On EXEC_BACKEND (Windows), child processes are started via CreateProcess
	 * rather than fork(), so they do not inherit mmap'd regions.  Online
	 * buffer pool resize requires fork() semantics for shared anonymous
	 * mappings.  Refuse to start rather than silently breaking.
	 */
	ereport(FATAL,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("max_shared_buffers is not supported on this platform"),
			 errhint("Remove the max_shared_buffers setting from postgresql.conf.")));
#endif

	/*
	 * Calculate sizes for the maximum possible buffer count.
	 */
	blocks_size = add_size(mul_size((Size) max_bufs, BLCKSZ), PG_IO_ALIGN_SIZE);
	descs_size = add_size(mul_size((Size) max_bufs, sizeof(BufferDescPadded)), PG_CACHE_LINE_SIZE);
	iocv_size = add_size(mul_size((Size) max_bufs, sizeof(ConditionVariableMinimallyPadded)), PG_CACHE_LINE_SIZE);
	ckpt_size = mul_size((Size) max_bufs, sizeof(CkptSortItem));

	/*
	 * Reserve virtual address space for each array.  MAP_NORESERVE tells
	 * the kernel not to reserve swap space for pages we haven't touched.
	 * MAP_SHARED | MAP_ANONYMOUS gives us pages visible across fork(),
	 * so child processes inherit the same mappings.
	 *
	 * Note: On Linux, MAP_NORESERVE means no physical memory or swap is
	 * consumed until pages are actually touched.
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
 * Commit physical memory for buffers in the range [start_buf, end_buf).
 *
 * When growing, this makes new pages accessible.  The memory was already
 * reserved by BufferPoolReserveMemory() using MAP_NORESERVE.  On Linux,
 * simply touching the pages will fault them in.
 *
 * We first try MADV_POPULATE_WRITE (Linux 5.14+) for efficient bulk
 * population with early OOM detection.  If unsupported, we fall back to
 * manually touching each page to fault it in.
 *
 * Only the delta range [start_buf, end_buf) is committed, not the entire
 * pool.  This avoids re-touching already-committed pages and ensures
 * rollback on failure only affects the new range (not live buffers).
 *
 * Returns true on success, false if memory could not be committed (OOM).
 */
bool
BufferPoolCommitMemory(int start_buf, int end_buf)
{
	Size		blocks_off = mul_size((Size) start_buf, BLCKSZ);
	Size		blocks_len = mul_size((Size) (end_buf - start_buf), BLCKSZ);
	Size		descs_off = mul_size((Size) start_buf, sizeof(BufferDescPadded));
	Size		descs_len = mul_size((Size) (end_buf - start_buf), sizeof(BufferDescPadded));
	Size		iocv_off = mul_size((Size) start_buf, sizeof(ConditionVariableMinimallyPadded));
	Size		iocv_len = mul_size((Size) (end_buf - start_buf), sizeof(ConditionVariableMinimallyPadded));
	Size		ckpt_off = mul_size((Size) start_buf, sizeof(CkptSortItem));
	Size		ckpt_len = mul_size((Size) (end_buf - start_buf), sizeof(CkptSortItem));
	bool		use_madvise = false;

#ifdef MADV_POPULATE_WRITE
	/*
	 * Try MADV_POPULATE_WRITE first.  This causes the kernel to allocate
	 * physical pages for the range.  If unsupported (EINVAL on older
	 * kernels), fall back to manual page touching.
	 *
	 * If population succeeds for some arrays but fails for others, we
	 * roll back by releasing only the newly-committed pages.
	 */
	if (madvise(BufferBlocks + blocks_off, blocks_len, MADV_POPULATE_WRITE) == 0)
	{
		use_madvise = true;

		if (madvise((char *) BufferDescriptors + descs_off, descs_len,
					MADV_POPULATE_WRITE) != 0)
		{
			madvise(BufferBlocks + blocks_off, blocks_len, MADV_DONTNEED);
			ereport(WARNING,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("could not commit memory for buffer descriptors: %m")));
			return false;
		}
		if (madvise((char *) BufferIOCVArray + iocv_off, iocv_len,
					MADV_POPULATE_WRITE) != 0)
		{
			madvise(BufferBlocks + blocks_off, blocks_len, MADV_DONTNEED);
			madvise((char *) BufferDescriptors + descs_off, descs_len, MADV_DONTNEED);
			ereport(WARNING,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("could not commit memory for buffer IO CVs: %m")));
			return false;
		}
		if (madvise((char *) CkptBufferIds + ckpt_off, ckpt_len,
					MADV_POPULATE_WRITE) != 0)
		{
			madvise(BufferBlocks + blocks_off, blocks_len, MADV_DONTNEED);
			madvise((char *) BufferDescriptors + descs_off, descs_len, MADV_DONTNEED);
			madvise((char *) BufferIOCVArray + iocv_off, iocv_len, MADV_DONTNEED);
			ereport(WARNING,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("could not commit memory for checkpoint buffer IDs: %m")));
			return false;
		}
	}
	else if (errno != EINVAL)
	{
		ereport(WARNING,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not commit memory for buffers %d..%d: %m",
						start_buf, end_buf)));
		return false;
	}
	/* else: EINVAL means MADV_POPULATE_WRITE not supported, fall through */
#endif

	if (!use_madvise)
	{
		volatile char *p;
		Size		page_size = sysconf(_SC_PAGESIZE);

		/*
		 * Touch one byte per OS page to fault in the physical memory.
		 * The volatile pointer prevents the compiler from optimizing this away.
		 */
		for (p = (volatile char *) BufferBlocks + blocks_off;
			 p < (volatile char *) BufferBlocks + blocks_off + blocks_len;
			 p += page_size)
			*p = *p;

		for (p = (volatile char *) BufferDescriptors + descs_off;
			 p < (volatile char *) BufferDescriptors + descs_off + descs_len;
			 p += page_size)
			*p = *p;

		for (p = (volatile char *) BufferIOCVArray + iocv_off;
			 p < (volatile char *) BufferIOCVArray + iocv_off + iocv_len;
			 p += page_size)
			*p = *p;

		for (p = (volatile char *) CkptBufferIds + ckpt_off;
			 p < (volatile char *) CkptBufferIds + ckpt_off + ckpt_len;
			 p += page_size)
			*p = *p;

		elog(DEBUG1, "committed buffer pool memory via page touching for buffers %d..%d",
			 start_buf, end_buf);
	}

	return true;
}

/*
 * Decommit physical memory for buffers beyond the given count.
 *
 * After shrinking, we release physical pages back to the OS but keep the
 * virtual address reservation intact for future growth.
 *
 * For the buffer blocks array (which is always page-aligned since
 * BLCKSZ >= page size), we use MADV_REMOVE to punch a hole in the
 * shmem backing and actually free the pages.  MADV_DONTNEED alone
 * is insufficient on MAP_SHARED mappings because it only unmaps PTEs
 * without releasing the underlying shmem pages.
 *
 * For smaller arrays (descriptors, CVs, ckpt IDs), their offsets may
 * not be page-aligned, so we use MADV_DONTNEED as a best-effort hint.
 * The memory waste from these arrays is small relative to the blocks.
 */
void
BufferPoolDecommitMemory(int old_nbufs, int new_nbufs)
{
	Size		blocks_offset = mul_size((Size) new_nbufs, BLCKSZ);
	Size		blocks_len = mul_size((Size) (old_nbufs - new_nbufs), BLCKSZ);
	Size		descs_offset = mul_size((Size) new_nbufs, sizeof(BufferDescPadded));
	Size		descs_len = mul_size((Size) (old_nbufs - new_nbufs), sizeof(BufferDescPadded));
	Size		iocv_offset = mul_size((Size) new_nbufs, sizeof(ConditionVariableMinimallyPadded));
	Size		iocv_len = mul_size((Size) (old_nbufs - new_nbufs), sizeof(ConditionVariableMinimallyPadded));
	Size		ckpt_offset = mul_size((Size) new_nbufs, sizeof(CkptSortItem));
	Size		ckpt_len = mul_size((Size) (old_nbufs - new_nbufs), sizeof(CkptSortItem));

	/*
	 * Release physical pages for buffer blocks.  MADV_REMOVE punches a hole
	 * in the shmem backing store, actually freeing the memory.  If it fails
	 * (e.g., unsupported kernel), fall back to MADV_DONTNEED.
	 */
	if (blocks_len > 0)
	{
#ifdef MADV_REMOVE
		if (madvise(BufferBlocks + blocks_offset, blocks_len, MADV_REMOVE) != 0)
#endif
			madvise(BufferBlocks + blocks_offset, blocks_len, MADV_DONTNEED);
	}

	/*
	 * For smaller arrays, use MADV_DONTNEED as a best-effort hint.
	 * These offsets may not be page-aligned, in which case madvise
	 * silently does nothing (returns EINVAL which we ignore).
	 */
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
 * This is called from the postmaster via ExecuteBufferPoolResize() after
 * processing a SIGHUP that changed shared_buffers.  new_nbuffers must be
 * > NBuffers and <= MaxNBuffers.
 *
 * After this function returns, the postmaster's NBuffers is updated and
 * the shared current_buffers atomic is set.  Child processes update their
 * local NBuffers from current_buffers when they process the SIGHUP that
 * the postmaster sends after this function returns.
 */
static bool
GrowBufferPool(int new_nbuffers)
{
	int			old_nbuffers = NBuffers;
	int			i;

	Assert(new_nbuffers > old_nbuffers);
	Assert(new_nbuffers <= GetEffectiveMaxNBuffers());

	elog(LOG, "buffer pool resize started: %d -> %d buffers (%d MB -> %d MB)",
		 old_nbuffers, new_nbuffers,
		 (int) ((Size) old_nbuffers * BLCKSZ / (1024 * 1024)),
		 (int) ((Size) new_nbuffers * BLCKSZ / (1024 * 1024)));

	/*
	 * Step 1: Commit physical memory for the new buffers.
	 */
	if (ReservedBufferBlocks != NULL)
	{
		if (!BufferPoolCommitMemory(old_nbuffers, new_nbuffers))
		{
			elog(WARNING, "buffer pool grow failed: could not commit memory");
			return false;
		}
	}

	/*
	 * Step 2: Initialize new buffer descriptors.
	 *
	 * New buffers are appended at the end, so existing buffers are not
	 * disturbed.  This is safe because no backend can access buffer IDs
	 * >= old_nbuffers yet (NBuffers hasn't been updated).
	 *
	 * However, if a previous shrink was cancelled before its drain completed,
	 * some descriptors in this range may still have BM_TAG_VALID set and
	 * could have active pins from backends.  We must NOT reinitialize those
	 * -- doing so would zero the refcount and corrupt the buffer state.
	 * Such buffers will be naturally reused by the clock sweep once NBuffers
	 * is updated to include them again.
	 */
	for (i = old_nbuffers; i < new_nbuffers; i++)
	{
		BufferDesc *buf = GetBufferDescriptor(i);
		uint64		buf_state;

		/* Skip buffers still in use from a cancelled shrink */
		buf_state = pg_atomic_read_u64(&buf->state);
		if (buf_state & BM_TAG_VALID)
			continue;

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
	 * Step 3: Write the new NBuffers to shared memory and update the
	 * postmaster's local copy.  A write barrier ensures the descriptor
	 * initializations above are visible before any backend sees the new
	 * buffer count.
	 */
	pg_write_barrier();
	pg_atomic_write_u32(&BufResizeCtl->current_buffers, (uint32) new_nbuffers);

	/* Update the postmaster's local NBuffers */
	NBuffers = new_nbuffers;

	/*
	 * Child processes will update their local NBuffers when they process
	 * the SIGHUP that the postmaster sends after this function returns.
	 * See assign_shared_buffers().
	 */
	elog(LOG, "buffer pool resize completed: %d -> %d buffers",
		 old_nbuffers, new_nbuffers);

	return true;
}

/* ----------------------------------------------------------------
 *		Buffer pool shrink operation
 * ----------------------------------------------------------------
 */

/*
 * ShrinkBufferPool - reduce the buffer pool size.
 *
 * Called from the postmaster during ExecuteBufferPoolResize().  This
 * function only updates NBuffers and records the condemned range.  The
 * actual eviction of condemned buffers is done asynchronously by the
 * bgwriter via BufPoolDrainCondemnedBuffers(), because eviction requires
 * full backend infrastructure (ResourceOwner, private refcounts, etc.)
 * that the postmaster does not have.
 *
 * After this call, no new buffer allocations will use the condemned range
 * (clock sweep respects NBuffers).  Existing pins on condemned buffers
 * will complete normally; the bgwriter will evict them once unpinned.
 */
static bool
ShrinkBufferPool(int new_nbuffers)
{
	int			old_nbuffers = NBuffers;

	Assert(new_nbuffers < old_nbuffers);
	Assert(new_nbuffers >= 16);	/* matches GUC minimum for shared_buffers */

	elog(LOG, "buffer pool shrink started: %d -> %d buffers (%d MB -> %d MB)",
		 old_nbuffers, new_nbuffers,
		 (int) ((Size) old_nbuffers * BLCKSZ / (1024 * 1024)),
		 (int) ((Size) new_nbuffers * BLCKSZ / (1024 * 1024)));

	/*
	 * Record the condemned range for the bgwriter to drain, then update
	 * NBuffers.  The order matters: we set the drain range before publishing
	 * the new NBuffers so the bgwriter knows what to clean up.
	 */
	SpinLockAcquire(&BufResizeCtl->mutex);
	BufResizeCtl->status = BUF_RESIZE_DRAINING;
	BufResizeCtl->drain_from = new_nbuffers;
	BufResizeCtl->drain_to = old_nbuffers;
	BufResizeCtl->condemned_remaining = old_nbuffers - new_nbuffers;
	SpinLockRelease(&BufResizeCtl->mutex);

	pg_write_barrier();
	pg_atomic_write_u32(&BufResizeCtl->current_buffers, (uint32) new_nbuffers);
	NBuffers = new_nbuffers;

	elog(LOG, "buffer pool shrink completed: NBuffers %d -> %d "
		 "(bgwriter will drain %d condemned buffers)",
		 old_nbuffers, new_nbuffers, old_nbuffers - new_nbuffers);

	return true;
}

/*
 * BufPoolDrainCondemnedBuffers - evict buffers in the condemned range.
 *
 * Called from the bgwriter main loop each cycle (~200ms).  The bgwriter
 * has full backend infrastructure needed for EvictUnpinnedBuffer().
 *
 * This does one pass over the condemned range per call, evicting what it
 * can.  When all condemned buffers are invalidated, it marks the drain
 * as complete and optionally decommits memory.
 */
void
BufPoolDrainCondemnedBuffers(void)
{
	int			drain_from,
				drain_to;
	int			i;
	int			remaining = 0;
	int			pinned = 0;
	int			dirty = 0;
	BufPoolResizeStatus status;

	if (BufResizeCtl == NULL)
		return;

	/* Quick check without lock */
	status = BufResizeCtl->status;
	if (status != BUF_RESIZE_DRAINING)
		return;

	SpinLockAcquire(&BufResizeCtl->mutex);
	drain_from = BufResizeCtl->drain_from;
	drain_to = BufResizeCtl->drain_to;
	SpinLockRelease(&BufResizeCtl->mutex);

	if (drain_from >= drain_to)
		return;

	/* One pass over the condemned range */
	for (i = drain_from; i < drain_to; i++)
	{
		BufferDesc *buf = GetBufferDescriptor(i);
		uint64		buf_state;

		buf_state = pg_atomic_read_u64(&buf->state);

		/* Skip already-invalidated buffers */
		if (!(buf_state & BM_TAG_VALID))
			continue;

		/* Can't touch pinned buffers */
		if (BUF_STATE_GET_REFCOUNT(buf_state) != 0)
		{
			remaining++;
			pinned++;
			continue;
		}

		/* Evict the buffer (handles dirty flush + invalidation) */
		{
			bool		flushed = false;
			bool		evicted;

			if (buf_state & BM_DIRTY)
				dirty++;
			evicted = EvictUnpinnedBuffer(BufferDescriptorGetBuffer(buf),
										  &flushed);
			if (!evicted)
				remaining++;
		}
	}

	/* Update progress under lock */
	SpinLockAcquire(&BufResizeCtl->mutex);
	BufResizeCtl->condemned_remaining = remaining;
	BufResizeCtl->condemned_pinned = pinned;
	BufResizeCtl->condemned_dirty = dirty;

	if (remaining == 0)
	{
		/*
		 * All condemned buffers drained.  Before decommitting, verify the
		 * drain hasn't been superseded by a new resize request.  A grow
		 * that overlaps the condemned range could have been initiated by
		 * the postmaster while we were iterating -- in that case, the
		 * status and/or drain range will have changed under us.
		 */
		if (BufResizeCtl->status == BUF_RESIZE_DRAINING &&
			BufResizeCtl->drain_from == drain_from &&
			BufResizeCtl->drain_to == drain_to)
		{
			BufResizeCtl->status = BUF_RESIZE_IDLE;
			BufResizeCtl->drain_from = 0;
			BufResizeCtl->drain_to = 0;
			BufResizeCtl->started_at = 0;
			BufResizeCtl->condemned_remaining = 0;
			BufResizeCtl->condemned_pinned = 0;
			BufResizeCtl->condemned_dirty = 0;
			SpinLockRelease(&BufResizeCtl->mutex);

			elog(LOG, "bgwriter: condemned buffer drain complete");

			/* Now safe to decommit memory */
			if (ReservedBufferBlocks != NULL)
				BufferPoolDecommitMemory(drain_to, drain_from);
		}
		else
		{
			/* Drain was superseded; skip decommit */
			SpinLockRelease(&BufResizeCtl->mutex);
			elog(LOG, "bgwriter: drain superseded by new resize, skipping decommit");
		}
	}
	else
	{
		SpinLockRelease(&BufResizeCtl->mutex);
	}
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

	/*
	 * If a bgwriter drain is in progress (BUF_RESIZE_DRAINING from a
	 * previous shrink), cancel it -- the new request supersedes.  The
	 * bgwriter validates the drain range before decommitting, so it's
	 * safe to change the range while it's iterating.
	 *
	 * Don't interrupt a grow (BUF_RESIZE_GROWING) since the postmaster
	 * is actively executing it.
	 */
	if (BufResizeCtl->status == BUF_RESIZE_GROWING)
	{
		SpinLockRelease(&BufResizeCtl->mutex);
		ereport(WARNING,
				(errmsg("buffer pool resize already in progress, "
						"ignoring new request")));
		return;
	}

	/* Cancel any pending drain */
	BufResizeCtl->drain_from = 0;
	BufResizeCtl->drain_to = 0;
	BufResizeCtl->condemned_remaining = 0;
	BufResizeCtl->condemned_pinned = 0;
	BufResizeCtl->condemned_dirty = 0;

	BufResizeCtl->target_buffers = new_nbuffers;
	if (new_nbuffers > NBuffers)
		BufResizeCtl->status = BUF_RESIZE_GROWING;
	else if (new_nbuffers < NBuffers)
		BufResizeCtl->status = BUF_RESIZE_DRAINING;
	else
		BufResizeCtl->status = BUF_RESIZE_IDLE;

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

	if (status == BUF_RESIZE_GROWING && target > NBuffers)
	{
		GrowBufferPool(target);

		/* Mark grow as complete immediately */
		SpinLockAcquire(&BufResizeCtl->mutex);
		BufResizeCtl->status = BUF_RESIZE_IDLE;
		BufResizeCtl->started_at = 0;
		SpinLockRelease(&BufResizeCtl->mutex);
	}
	else if (status == BUF_RESIZE_DRAINING && target < NBuffers)
	{
		/*
		 * ShrinkBufferPool updates NBuffers and keeps status as
		 * BUF_RESIZE_DRAINING.  The bgwriter will drain the condemned
		 * buffers asynchronously and set status to BUF_RESIZE_IDLE.
		 */
		ShrinkBufferPool(target);
	}
}

/* ----------------------------------------------------------------
 *		GUC hooks
 * ----------------------------------------------------------------
 */

/*
 * GUC check hook for shared_buffers.
 *
 * The GUC variable is SharedBuffersGUC, NOT NBuffers.  This is critical:
 * the GUC mechanism updates SharedBuffersGUC on SIGHUP, but NBuffers is
 * only updated by the resize code (or at startup).  This prevents NBuffers
 * from changing before the buffer pool arrays are actually resized.
 *
 * Validates that the new value is within the allowed range:
 *   - At startup: normal validation (min/max from GUC definition)
 *   - At runtime with max_shared_buffers: must be <= MaxNBuffers
 *   - At runtime without max_shared_buffers: value is accepted (for ALTER
 *     SYSTEM writes that take effect on next restart) but the assign hook
 *     will not trigger a resize
 */
bool
check_shared_buffers(int *newval, void **extra, GucSource source)
{
	/*
	 * If max_shared_buffers is configured, enforce it as an upper bound.
	 * This applies both at startup and at runtime.
	 */
	if (MaxNBuffers > 0 && *newval > MaxNBuffers)
	{
		GUC_check_errmsg("shared_buffers (%d) cannot exceed max_shared_buffers (%d)",
						 *newval, MaxNBuffers);
		return false;
	}

	return true;
}

/*
 * GUC assign hook for shared_buffers.
 *
 * The GUC variable (SharedBuffersGUC) has already been updated by the GUC
 * mechanism.  At startup, we copy the value into NBuffers.  At runtime,
 * we request an async resize if the infrastructure is available.
 *
 * If max_shared_buffers is not set, runtime changes to SharedBuffersGUC
 * are harmless -- they'll take effect on next restart when NBuffers is
 * re-initialized from SharedBuffersGUC.
 */
void
assign_shared_buffers(int newval, void *extra)
{
	/*
	 * If resize infrastructure isn't available (initial startup, standalone
	 * backend, or max_shared_buffers not configured), set NBuffers directly.
	 */
	if (BufResizeCtl == NULL || MaxNBuffers <= 0)
	{
		NBuffers = newval;
		return;
	}

	/*
	 * At runtime with max_shared_buffers configured.
	 *
	 * The postmaster (IsUnderPostmaster=false) requests a resize.  This is
	 * a no-op here because ExecuteBufferPoolResize() is called separately
	 * from process_pm_reload_request() after ProcessConfigFile returns.
	 *
	 * Child processes (IsUnderPostmaster=true) update their local NBuffers
	 * from the shared current_buffers atomic, which was set by the postmaster
	 * during ExecuteBufferPoolResize() before signaling children.
	 */
	if (!IsUnderPostmaster)
	{
		/* Postmaster: request resize (executed later by postmaster loop) */
		if (newval != NBuffers)
			RequestBufferPoolResize(newval);
	}
	else
	{
		/*
		 * Child process: read the authoritative NBuffers from shared memory.
		 * The postmaster has already performed the resize and updated
		 * current_buffers before sending us SIGHUP.
		 */
		int		current = (int) pg_atomic_read_u32(&BufResizeCtl->current_buffers);

		/*
		 * A read barrier ensures we see the fully initialized descriptor
		 * data that the postmaster wrote before publishing current_buffers.
		 * Pairs with the pg_write_barrier() in GrowBufferPool/ShrinkBufferPool.
		 */
		pg_read_barrier();

		if (current != NBuffers)
		{
			elog(DEBUG1, "backend updated NBuffers: %d -> %d",
				 NBuffers, current);
			NBuffers = current;
		}
	}
}
