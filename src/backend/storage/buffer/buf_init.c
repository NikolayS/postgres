/*-------------------------------------------------------------------------
 *
 * buf_init.c
 *	  buffer manager initialization routines
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/buffer/buf_init.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "storage/aio.h"
#include "storage/buf_internals.h"
#include "storage/buf_resize.h"
#include "storage/bufmgr.h"

BufferDescPadded *BufferDescriptors;
char	   *BufferBlocks;
ConditionVariableMinimallyPadded *BufferIOCVArray;
WritebackContext BackendWritebackContext;
CkptSortItem *CkptBufferIds;


/*
 * Data Structures:
 *		buffers live in a freelist and a lookup data structure.
 *
 *
 * Buffer Lookup:
 *		Two important notes.  First, the buffer has to be
 *		available for lookup BEFORE an IO begins.  Otherwise
 *		a second process trying to read the buffer will
 *		allocate its own copy and the buffer pool will
 *		become inconsistent.
 *
 * Buffer Replacement:
 *		see freelist.c.  A buffer cannot be replaced while in
 *		use either by data manager or during IO.
 *
 *
 * Synchronization/Locking:
 *
 * IO_IN_PROGRESS -- this is a flag in the buffer descriptor.
 *		It must be set when an IO is initiated and cleared at
 *		the end of the IO.  It is there to make sure that one
 *		process doesn't start to use a buffer while another is
 *		faulting it in.  see WaitIO and related routines.
 *
 * refcount --	Counts the number of processes holding pins on a buffer.
 *		A buffer is pinned during IO and immediately after a BufferAlloc().
 *		Pins must be released before end of transaction.  For efficiency the
 *		shared refcount isn't increased if an individual backend pins a buffer
 *		multiple times. Check the PrivateRefCount infrastructure in bufmgr.c.
 */


/*
 * Initialize shared buffer pool
 *
 * This is called once during shared-memory initialization (either in the
 * postmaster, or in a standalone backend).
 *
 * When max_shared_buffers is configured, BufferPoolReserveMemory() has
 * already set up the global pointers (BufferDescriptors, BufferBlocks, etc.)
 * pointing into separately-mapped VA regions.  In that case, we skip the
 * ShmemInitStruct allocations for the buffer arrays and just initialize
 * the descriptors in the pre-allocated memory.
 *
 * When max_shared_buffers is not configured (the default), we use the
 * traditional path of allocating everything from the main shared memory
 * segment via ShmemInitStruct.
 */
void
BufferManagerShmemInit(void)
{
	bool		foundBufs,
				foundDescs,
				foundIOCV,
				foundBufCkpt;
	bool		using_reserved_memory = (MaxNBuffers > 0 &&
										 MaxNBuffers > NBuffers);

	if (using_reserved_memory)
	{
		/*
		 * Memory was already reserved by BufferPoolReserveMemory() and
		 * global pointers are already set.  Mark as "not found" so we
		 * initialize the descriptors below.
		 */
		foundDescs = false;
		foundBufs = false;
		foundIOCV = false;
		foundBufCkpt = false;
	}
	else
	{
		/* Traditional path: allocate from main shared memory segment */

		/* Align descriptors to a cacheline boundary. */
		BufferDescriptors = (BufferDescPadded *)
			ShmemInitStruct("Buffer Descriptors",
							NBuffers * sizeof(BufferDescPadded),
							&foundDescs);

		/* Align buffer pool on IO page size boundary. */
		BufferBlocks = (char *)
			TYPEALIGN(PG_IO_ALIGN_SIZE,
					  ShmemInitStruct("Buffer Blocks",
									  NBuffers * (Size) BLCKSZ + PG_IO_ALIGN_SIZE,
									  &foundBufs));

		/* Align condition variables to cacheline boundary. */
		BufferIOCVArray = (ConditionVariableMinimallyPadded *)
			ShmemInitStruct("Buffer IO Condition Variables",
							NBuffers * sizeof(ConditionVariableMinimallyPadded),
							&foundIOCV);

		/*
		 * The array used to sort to-be-checkpointed buffer ids is located in
		 * shared memory, to avoid having to allocate significant amounts of
		 * memory at runtime. As that'd be in the middle of a checkpoint, or
		 * when the checkpointer is restarted, memory allocation failures
		 * would be painful.
		 */
		CkptBufferIds = (CkptSortItem *)
			ShmemInitStruct("Checkpoint BufferIds",
							NBuffers * sizeof(CkptSortItem), &foundBufCkpt);
	}

	if (foundDescs || foundBufs || foundIOCV || foundBufCkpt)
	{
		/* should find all of these, or none of them */
		Assert(foundDescs && foundBufs && foundIOCV && foundBufCkpt);
		/* note: this path is only taken in EXEC_BACKEND case */
	}
	else
	{
		int			i;

		/*
		 * Initialize all the buffer headers.
		 */
		for (i = 0; i < NBuffers; i++)
		{
			BufferDesc *buf = GetBufferDescriptor(i);

			ClearBufferTag(&buf->tag);

			pg_atomic_init_u32(&buf->state, 0);
			buf->wait_backend_pgprocno = INVALID_PROC_NUMBER;

			buf->buf_id = i;

			pgaio_wref_clear(&buf->io_wref);

			LWLockInitialize(BufferDescriptorGetContentLock(buf),
							 LWTRANCHE_BUFFER_CONTENT);

			ConditionVariableInit(BufferDescriptorGetIOCV(buf));
		}
	}

	/* Init other shared buffer-management stuff */
	StrategyInitialize(!foundDescs);

	/* Initialize per-backend file flush context */
	WritebackContextInit(&BackendWritebackContext,
						 &backend_flush_after);
}

/*
 * BufferManagerShmemSize
 *
 * compute the size of shared memory for the buffer pool including
 * data pages, buffer descriptors, hash tables, etc.
 *
 * When max_shared_buffers is configured for online resize, the buffer
 * arrays are allocated separately (not from the main shmem segment),
 * so we only include the strategy/hash table sizes here.
 */
Size
BufferManagerShmemSize(void)
{
	Size		size = 0;
	bool		using_reserved_memory = (MaxNBuffers > 0 &&
										 MaxNBuffers > NBuffers);

	if (!using_reserved_memory)
	{
		/* Traditional path: everything in main shared memory */

		/* size of buffer descriptors */
		size = add_size(size, mul_size(NBuffers, sizeof(BufferDescPadded)));
		/* to allow aligning buffer descriptors */
		size = add_size(size, PG_CACHE_LINE_SIZE);

		/* size of data pages, plus alignment padding */
		size = add_size(size, PG_IO_ALIGN_SIZE);
		size = add_size(size, mul_size(NBuffers, BLCKSZ));

		/* size of I/O condition variables */
		size = add_size(size, mul_size(NBuffers,
									   sizeof(ConditionVariableMinimallyPadded)));
		/* to allow aligning the above */
		size = add_size(size, PG_CACHE_LINE_SIZE);

		/* size of checkpoint sort array in bufmgr.c */
		size = add_size(size, mul_size(NBuffers, sizeof(CkptSortItem)));
	}

	/* size of stuff controlled by freelist.c (always in main shmem) */
	size = add_size(size, StrategyShmemSize());

	return size;
}
