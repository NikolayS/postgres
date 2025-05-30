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
     ID = 258,
     COMMA = 259,
     EQUALS = 260,
     LPAREN = 261,
     RPAREN = 262,
     NULLVAL = 263,
     OPEN = 264,
     XCLOSE = 265,
     XCREATE = 266,
     INSERT_TUPLE = 267,
     XDECLARE = 268,
     INDEX = 269,
     ON = 270,
     USING = 271,
     XBUILD = 272,
     INDICES = 273,
     UNIQUE = 274,
     XTOAST = 275,
     OBJ_ID = 276,
     XBOOTSTRAP = 277,
     XSHARED_RELATION = 278,
     XROWTYPE_OID = 279,
     XFORCE = 280,
     XNOT = 281,
     XNULL = 282
   };
#endif
/* Tokens.  */
#define ID 258
#define COMMA 259
#define EQUALS 260
#define LPAREN 261
#define RPAREN 262
#define NULLVAL 263
#define OPEN 264
#define XCLOSE 265
#define XCREATE 266
#define INSERT_TUPLE 267
#define XDECLARE 268
#define INDEX 269
#define ON 270
#define USING 271
#define XBUILD 272
#define INDICES 273
#define UNIQUE 274
#define XTOAST 275
#define OBJ_ID 276
#define XBOOTSTRAP 277
#define XSHARED_RELATION 278
#define XROWTYPE_OID 279
#define XFORCE 280
#define XNOT 281
#define XNULL 282




#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
typedef union YYSTYPE
#line 87 "bootparse.y"
{
	List		*list;
	IndexElem	*ielem;
	char		*str;
	const char	*kw;
	int			ival;
	Oid			oidval;
}
/* Line 1529 of yacc.c.  */
#line 112 "bootparse.h"
	YYSTYPE;
# define yystype YYSTYPE /* obsolescent; will be withdrawn */
# define YYSTYPE_IS_DECLARED 1
# define YYSTYPE_IS_TRIVIAL 1
#endif



