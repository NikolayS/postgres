/*-------------------------------------------------------------------------
 *
 * cmdtag.h
 *	  Declarations for commandtag names and enumeration.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/tcop/cmdtag.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef CMDTAG_H
#define CMDTAG_H

/* buffer size required for command completion tags */
#define COMPLETION_TAG_BUFSIZE	64

#define PG_CMDTAG(tag, name, evtrgok, rwrok, rowcnt) \
	tag,

typedef enum CommandTag
{
#include "tcop/cmdtaglist.h"
} CommandTag;

#undef PG_CMDTAG

typedef struct QueryCompletion
{
	CommandTag	commandTag;
	uint64		nprocessed;
	const char *relname;		/* relation name for verbose command tags */
	const char *nspname;		/* schema name for FQN command tags */
} QueryCompletion;


static inline void
SetQueryCompletion(QueryCompletion *qc, CommandTag commandTag,
				   uint64 nprocessed)
{
	qc->commandTag = commandTag;
	qc->nprocessed = nprocessed;
}

static inline void
CopyQueryCompletion(QueryCompletion *dst, const QueryCompletion *src)
{
	dst->commandTag = src->commandTag;
	dst->nprocessed = src->nprocessed;
}


extern void InitializeQueryCompletion(QueryCompletion *qc);
extern const char *GetCommandTagName(CommandTag commandTag);
extern const char *GetCommandTagNameAndLen(CommandTag commandTag, Size *len);
extern bool command_tag_display_rowcount(CommandTag commandTag);
extern bool command_tag_event_trigger_ok(CommandTag commandTag);
extern bool command_tag_table_rewrite_ok(CommandTag commandTag);
extern CommandTag GetCommandTagEnum(const char *commandname);

/* GUC: command tag format style */
#define COMMAND_TAG_FORMAT_LEGACY   0   /* INSERT 0 N (default, backward compat) */
#define COMMAND_TAG_FORMAT_VERBOSE  1   /* INSERT tablename N */
#define COMMAND_TAG_FORMAT_FQN      2   /* INSERT schema.tablename N */

extern int command_tag_format;
extern Size BuildQueryCompletionString(char *buff, const QueryCompletion *qc,
									   bool nameonly);

#endif							/* CMDTAG_H */
