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
     NULL_CONST = 258,
     INTEGER_CONST = 259,
     MAXINT_PLUS_ONE_CONST = 260,
     DOUBLE_CONST = 261,
     BOOLEAN_CONST = 262,
     VARIABLE = 263,
     FUNCTION = 264,
     AND_OP = 265,
     OR_OP = 266,
     NOT_OP = 267,
     NE_OP = 268,
     LE_OP = 269,
     GE_OP = 270,
     LS_OP = 271,
     RS_OP = 272,
     IS_OP = 273,
     CASE_KW = 274,
     WHEN_KW = 275,
     THEN_KW = 276,
     ELSE_KW = 277,
     END_KW = 278,
     NOTNULL_OP = 279,
     ISNULL_OP = 280,
     UNARY = 281
   };
#endif
/* Tokens.  */
#define NULL_CONST 258
#define INTEGER_CONST 259
#define MAXINT_PLUS_ONE_CONST 260
#define DOUBLE_CONST 261
#define BOOLEAN_CONST 262
#define VARIABLE 263
#define FUNCTION 264
#define AND_OP 265
#define OR_OP 266
#define NOT_OP 267
#define NE_OP 268
#define LE_OP 269
#define GE_OP 270
#define LS_OP 271
#define RS_OP 272
#define IS_OP 273
#define CASE_KW 274
#define WHEN_KW 275
#define THEN_KW 276
#define ELSE_KW 277
#define END_KW 278
#define NOTNULL_OP 279
#define ISNULL_OP 280
#define UNARY 281




#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
typedef union YYSTYPE
#line 48 "exprparse.y"
{
	int64		ival;
	double		dval;
	bool		bval;
	char	   *str;
	PgBenchExpr *expr;
	PgBenchExprList *elist;
}
/* Line 1529 of yacc.c.  */
#line 110 "exprparse.h"
	YYSTYPE;
# define yystype YYSTYPE /* obsolescent; will be withdrawn */
# define YYSTYPE_IS_DECLARED 1
# define YYSTYPE_IS_TRIVIAL 1
#endif



