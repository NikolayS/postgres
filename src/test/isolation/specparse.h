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
     sqlblock = 258,
     identifier = 259,
     INTEGER = 260,
     NOTICES = 261,
     PERMUTATION = 262,
     SESSION = 263,
     SETUP = 264,
     STEP = 265,
     TEARDOWN = 266,
     TEST = 267
   };
#endif
/* Tokens.  */
#define sqlblock 258
#define identifier 259
#define INTEGER 260
#define NOTICES 261
#define PERMUTATION 262
#define SESSION 263
#define SETUP 264
#define STEP 265
#define TEARDOWN 266
#define TEST 267




#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
typedef union YYSTYPE
#line 30 "specparse.y"
{
	char	   *str;
	int			integer;
	Session	   *session;
	Step	   *step;
	Permutation *permutation;
	PermutationStep *permutationstep;
	PermutationStepBlocker *blocker;
	struct
	{
		void  **elements;
		int		nelements;
	}			ptr_list;
}
/* Line 1529 of yacc.c.  */
#line 88 "specparse.h"
	YYSTYPE;
# define yystype YYSTYPE /* obsolescent; will be withdrawn */
# define YYSTYPE_IS_DECLARED 1
# define YYSTYPE_IS_TRIVIAL 1
#endif

extern YYSTYPE spec_yylval;

