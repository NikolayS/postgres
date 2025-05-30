/* A Bison parser, made by GNU Bison 2.3.  */

/* Skeleton interface for Bison's Yacc-like parsers in C

   Copyright (C) 1984, 1989, 1990, 2000, 2001, 2002, 2003, 2004, 2005, 2006
   Free Software Foundation, Inc.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.  */

/* As a special exception, you may create a larger work that contains
   part or all of the Bison parser skeleton and distribute that work
   under terms of your choice, so long as that work isn't itself a
   parser generator using the skeleton or a modified version thereof
   as a parser skeleton.  Alternatively, if you modify or redistribute
   the parser skeleton itself, you may (at your option) remove this
   special exception, which will cause the skeleton and the resulting
   Bison output files to be licensed under the GNU General Public
   License without this special exception.

   This special exception was added by the Free Software Foundation in
   version 2.2 of Bison.  */

/* Tokens.  */
#ifndef YYTOKENTYPE
# define YYTOKENTYPE
   /* Put the tokens into the symbol table, so that GDB and other debuggers
      know about them.  */
   enum yytokentype {
     SCONST = 258,
     IDENT = 259,
     UCONST = 260,
     RECPTR = 261,
     K_BASE_BACKUP = 262,
     K_IDENTIFY_SYSTEM = 263,
     K_READ_REPLICATION_SLOT = 264,
     K_SHOW = 265,
     K_START_REPLICATION = 266,
     K_CREATE_REPLICATION_SLOT = 267,
     K_DROP_REPLICATION_SLOT = 268,
     K_ALTER_REPLICATION_SLOT = 269,
     K_TIMELINE_HISTORY = 270,
     K_WAIT = 271,
     K_TIMELINE = 272,
     K_PHYSICAL = 273,
     K_LOGICAL = 274,
     K_SLOT = 275,
     K_RESERVE_WAL = 276,
     K_TEMPORARY = 277,
     K_TWO_PHASE = 278,
     K_EXPORT_SNAPSHOT = 279,
     K_NOEXPORT_SNAPSHOT = 280,
     K_USE_SNAPSHOT = 281,
     K_UPLOAD_MANIFEST = 282
   };
#endif
/* Tokens.  */
#define SCONST 258
#define IDENT 259
#define UCONST 260
#define RECPTR 261
#define K_BASE_BACKUP 262
#define K_IDENTIFY_SYSTEM 263
#define K_READ_REPLICATION_SLOT 264
#define K_SHOW 265
#define K_START_REPLICATION 266
#define K_CREATE_REPLICATION_SLOT 267
#define K_DROP_REPLICATION_SLOT 268
#define K_ALTER_REPLICATION_SLOT 269
#define K_TIMELINE_HISTORY 270
#define K_WAIT 271
#define K_TIMELINE 272
#define K_PHYSICAL 273
#define K_LOGICAL 274
#define K_SLOT 275
#define K_RESERVE_WAL 276
#define K_TEMPORARY 277
#define K_TWO_PHASE 278
#define K_EXPORT_SNAPSHOT 279
#define K_NOEXPORT_SNAPSHOT 280
#define K_USE_SNAPSHOT 281
#define K_UPLOAD_MANIFEST 282




#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
typedef union YYSTYPE
#line 46 "repl_gram.y"
{
	char	   *str;
	bool		boolval;
	uint32		uintval;
	XLogRecPtr	recptr;
	Node	   *node;
	List	   *list;
	DefElem	   *defelt;
}
/* Line 1529 of yacc.c.  */
#line 113 "repl_gram.h"
	YYSTYPE;
# define yystype YYSTYPE /* obsolescent; will be withdrawn */
# define YYSTYPE_IS_DECLARED 1
# define YYSTYPE_IS_TRIVIAL 1
#endif



