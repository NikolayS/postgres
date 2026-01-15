#!/usr/bin/env python3
"""
Tool to add parameter names to PostgreSQL function documentation.

This script:
1. Parses pg_proc.dat to extract function parameter names
2. Scans SGML documentation for function signatures without parameter names
3. Updates the documentation with proper parameter names

Usage:
    python3 fix_func_param_names.py [--dry-run] [--verbose]
"""

import re
import os
import sys
import argparse
from pathlib import Path
from collections import defaultdict

# Paths relative to PostgreSQL source root
PG_PROC_DAT = "src/include/catalog/pg_proc.dat"
DOC_FUNC_DIR = "doc/src/sgml/func"

# Type to parameter name mapping for single-arg functions
TYPE_TO_PARAM_NAME = {
    'text': 'string',
    'bpchar': 'string',
    'varchar': 'string',
    'character': 'string',
    'character varying': 'string',
    'bytea': 'bytes',
    'integer': 'n',
    'int4': 'n',
    'int8': 'n',
    'int2': 'n',
    'bigint': 'n',
    'smallint': 'n',
    'numeric': 'n',
    'real': 'x',
    'float4': 'x',
    'float8': 'x',
    'double precision': 'x',
    'boolean': 'value',
    'bool': 'value',
    'timestamp': 'timestamp',
    'timestamptz': 'timestamp',
    'timestamp with time zone': 'timestamp',
    'timestamp without time zone': 'timestamp',
    'date': 'date',
    'time': 'time',
    'interval': 'interval',
    'json': 'json',
    'jsonb': 'json',
    'uuid': 'uuid',
    'inet': 'address',
    'cidr': 'network',
    'macaddr': 'address',
    'macaddr8': 'address',
    'bit': 'bits',
    'bit varying': 'bits',
    'varbit': 'bits',
    'anyelement': 'value',
    'anyarray': 'array',
    'anynonarray': 'value',
    'anyenum': 'value',
    'anyrange': 'range',
    'anymultirange': 'multirange',
    'anycompatible': 'value',
    'anycompatiblearray': 'array',
    'anycompatiblenonarray': 'value',
    'anycompatiblerange': 'range',
    'xml': 'xml',
    'pg_lsn': 'lsn',
    'regclass': 'relation',
    'regtype': 'type',
    'regproc': 'function',
    'regprocedure': 'function',
    'oid': 'oid',
    'cstring': 'string',
    'name': 'name',
    'tsquery': 'query',
    'tsvector': 'vector',
}

# Function-specific parameter name overrides
# Maps function name -> list of parameter names
FUNCTION_PARAM_OVERRIDES = {
    # String functions
    'lower': ['string'],
    'upper': ['string'],
    'length': ['string'],
    'bit_length': ['string'],
    'char_length': ['string'],
    'character_length': ['string'],
    'octet_length': ['string'],
    'reverse': ['string'],
    'initcap': ['string'],
    'casefold': ['string'],
    'ascii': ['string'],
    'chr': ['code'],
    'quote_ident': ['string'],
    'quote_literal': ['string'],
    'quote_nullable': ['string'],
    'normalize': ['string'],
    'unicode_assigned': ['string'],
    'md5': ['string'],
    'sha224': ['string'],
    'sha256': ['string'],
    'sha384': ['string'],
    'sha512': ['string'],
    # Math functions
    'abs': ['x'],
    'ceil': ['x'],
    'ceiling': ['x'],
    'floor': ['x'],
    'round': ['x'],
    'trunc': ['x'],
    'sign': ['x'],
    'sqrt': ['x'],
    'cbrt': ['x'],
    'exp': ['x'],
    'ln': ['x'],
    'log': ['x'],
    'log10': ['x'],
    'sin': ['x'],
    'cos': ['x'],
    'tan': ['x'],
    'asin': ['x'],
    'acos': ['x'],
    'atan': ['x'],
    'sinh': ['x'],
    'cosh': ['x'],
    'tanh': ['x'],
    'asinh': ['x'],
    'acosh': ['x'],
    'atanh': ['x'],
    'factorial': ['n'],
    'degrees': ['radians'],
    'radians': ['degrees'],
    # Binary string functions
    'get_bit': ['bytes', 'n'],
    'set_bit': ['bytes', 'n', 'newvalue'],
    'get_byte': ['bytes', 'n'],
    'set_byte': ['bytes', 'n', 'newvalue'],
    # Array functions
    'array_ndims': ['array'],
    'array_dims': ['array'],
    'array_length': ['array', 'dimension'],
    'array_lower': ['array', 'dimension'],
    'array_upper': ['array', 'dimension'],
    'cardinality': ['array'],
    'array_to_string': ['array', 'delimiter'],
    'unnest': ['array'],
    # Network functions
    'abbrev': ['address'],
    'broadcast': ['address'],
    'family': ['address'],
    'host': ['address'],
    'hostmask': ['address'],
    'masklen': ['address'],
    'netmask': ['address'],
    'network': ['address'],
    'set_masklen': ['address', 'length'],
    # JSON functions
    'json_array_length': ['json'],
    'jsonb_array_length': ['json'],
    'json_typeof': ['json'],
    'jsonb_typeof': ['json'],
    'json_strip_nulls': ['json'],
    'jsonb_strip_nulls': ['json'],
    'jsonb_pretty': ['json'],
    # Date/time functions
    'age': ['timestamp'],
    'date_trunc': ['field', 'source'],
    'extract': ['field', 'source'],
    'date_part': ['field', 'source'],
    'isfinite': ['value'],
    'justify_days': ['interval'],
    'justify_hours': ['interval'],
    'justify_interval': ['interval'],
    # Range functions
    'lower_inc': ['range'],
    'upper_inc': ['range'],
    'lower_inf': ['range'],
    'upper_inf': ['range'],
    'isempty': ['range'],
    'range_merge': ['range1', 'range2'],
    # Text search functions
    'numnode': ['query'],
    'querytree': ['query'],
    'plainto_tsquery': ['text'],
    'phraseto_tsquery': ['text'],
    'websearch_to_tsquery': ['text'],
    'to_tsquery': ['text'],
    'to_tsvector': ['text'],
    'strip': ['vector'],
    'ts_rank': ['vector', 'query'],
    'ts_rank_cd': ['vector', 'query'],
    # UUID functions
    'uuid_extract_version': ['uuid'],
    'uuid_extract_timestamp': ['uuid'],
    # Sequence functions
    'nextval': ['regclass'],
    'currval': ['regclass'],
    'lastval': [],
    'setval': ['regclass', 'value'],
    # System info functions
    'pg_typeof': ['value'],
    'pg_column_size': ['value'],
    'pg_database_size': ['database'],
    'pg_table_size': ['relation'],
    'pg_indexes_size': ['relation'],
    'pg_total_relation_size': ['relation'],
    'pg_relation_size': ['relation'],
    'pg_size_pretty': ['size'],
    'pg_size_bytes': ['size'],
    # Enum functions
    'enum_first': ['value'],
    'enum_last': ['value'],
    'enum_range': ['value'],
}


def parse_pg_proc_dat(pg_root):
    """Parse pg_proc.dat to extract function parameter information."""
    functions = defaultdict(list)
    dat_path = os.path.join(pg_root, PG_PROC_DAT)

    with open(dat_path, 'r') as f:
        content = f.read()

    # Match each function entry (multiline, curly-brace delimited)
    # Pattern matches entries like: { oid => '123', proname => 'func', ... }
    # Note: Can't use [^}]+ since proargnames contains {} like '{a,b,c}'
    # Instead, match from { to },\n or }] which marks end of entry
    entry_pattern = re.compile(r'\{\s*oid\s*=>(.*?)\s*\},?\s*(?=\n(?:\{|#|\[|\Z))',
                               re.MULTILINE | re.DOTALL)

    for match in entry_pattern.finditer(content):
        entry = match.group(1)

        # Extract proname
        proname_match = re.search(r"proname\s*=>\s*'([^']+)'", entry)
        if not proname_match:
            continue
        proname = proname_match.group(1)

        # Extract proargtypes
        argtypes_match = re.search(r"proargtypes\s*=>\s*'([^']*)'", entry)
        argtypes = argtypes_match.group(1).split() if argtypes_match else []

        # Extract proargnames if present
        argnames_match = re.search(r"proargnames\s*=>\s*'\{([^}]*)\}'", entry)
        if argnames_match:
            argnames = [n.strip() for n in argnames_match.group(1).split(',')]
        else:
            argnames = []

        # Extract prorettype
        rettype_match = re.search(r"prorettype\s*=>\s*'([^']+)'", entry)
        rettype = rettype_match.group(1) if rettype_match else ''

        # Extract proargmodes if present (for IN/OUT params)
        argmodes_match = re.search(r"proargmodes\s*=>\s*'\{([^}]*)\}'", entry)
        if argmodes_match:
            argmodes = [m.strip() for m in argmodes_match.group(1).split(',')]
        else:
            argmodes = []

        functions[proname].append({
            'argtypes': argtypes,
            'argnames': argnames,
            'rettype': rettype,
            'argmodes': argmodes,
        })

    return functions


def get_param_name_for_type(type_name, position=0, func_name=None, num_args=1):
    """Get a sensible parameter name for a given type."""
    # Check function-specific overrides first
    if func_name and func_name in FUNCTION_PARAM_OVERRIDES:
        override = FUNCTION_PARAM_OVERRIDES[func_name]
        if position < len(override):
            return override[position]

    # Normalize type name
    type_lower = type_name.lower().strip()
    type_lower = type_lower.replace('"', '')  # Remove quotes like "any"

    # Check type mapping
    if type_lower in TYPE_TO_PARAM_NAME:
        return TYPE_TO_PARAM_NAME[type_lower]

    # Default fallback
    return 'value'


def find_functions_without_params(sgml_content):
    """Find function signatures in SGML that lack parameter names."""
    results = []

    # Pattern to match function signatures
    # Looking for: <function>name</function> ( <type>typename</type> ... )
    # Where there's no <parameter> tag between ( and <type>

    # This pattern finds function calls with types but no parameter names
    # Matches: <function>name</function> ( <type>type</type>
    pattern = re.compile(
        r'<function>([a-z_][a-z0-9_]*)</function>\s*'
        r'\(\s*'
        r'(<type>[^<]+</type>)',
        re.IGNORECASE
    )

    for match in pattern.finditer(sgml_content):
        func_name = match.group(1)
        start = match.start()

        # Check if there's a <parameter> tag between ( and <type>
        between = sgml_content[match.start():match.end()]
        if '<parameter>' not in between:
            # This function signature is missing parameter names

            # Find the full signature (up to closing paren and returnvalue)
            sig_end = sgml_content.find('<returnvalue>', match.end())
            if sig_end == -1:
                continue

            # Check for opening paren
            paren_start = sgml_content.find('(', match.start())
            paren_end = sgml_content.rfind(')', match.start(), sig_end)

            if paren_start != -1 and paren_end != -1:
                signature = sgml_content[paren_start:paren_end+1]
                results.append({
                    'func_name': func_name,
                    'signature': signature,
                    'start': paren_start,
                    'end': paren_end + 1,
                    'line': sgml_content[:start].count('\n') + 1,
                })

    return results


def parse_signature_types(signature):
    """Extract types from a signature like ( <type>text</type>, <type>int</type> )."""
    types = []
    optional_indices = set()

    # Track if we're inside an <optional> block
    in_optional = False
    current_pos = 0

    # Find all type tags
    type_pattern = re.compile(r'<type>([^<]+)</type>')
    optional_start = re.compile(r'<optional>')
    optional_end = re.compile(r'</optional>')

    parts = re.split(r'(<optional>|</optional>|<type>[^<]+</type>)', signature)

    type_index = 0
    for part in parts:
        if '<optional>' in part:
            in_optional = True
        elif '</optional>' in part:
            in_optional = False
        elif part.startswith('<type>'):
            type_match = type_pattern.search(part)
            if type_match:
                types.append(type_match.group(1))
                if in_optional:
                    optional_indices.add(type_index)
                type_index += 1

    return types, optional_indices


def deduplicate_param_names(param_names):
    """Append numbers to duplicate parameter names.

    E.g., ['timestamp', 'timestamp'] -> ['timestamp1', 'timestamp2']
          ['array', 'value', 'value'] -> ['array', 'value1', 'value2']
    """
    from collections import Counter

    # Count occurrences of each name
    counts = Counter(param_names)

    # Find names that appear more than once
    duplicates = {name for name, count in counts.items() if count > 1}

    if not duplicates:
        return param_names

    # Track current index for each duplicate name
    indices = {name: 1 for name in duplicates}

    result = []
    for name in param_names:
        if name in duplicates:
            result.append(f"{name}{indices[name]}")
            indices[name] += 1
        else:
            result.append(name)

    return result


def build_new_signature(signature, func_name, param_names_db):
    """Build a new signature with parameter names added."""
    types, optional_indices = parse_signature_types(signature)

    if not types:
        return signature

    # Get parameter names
    param_names = []
    func_info = param_names_db.get(func_name, [])

    # Try to find matching function definition by arg count
    matching_info = None
    for info in func_info:
        if len(info['argnames']) == len(types):
            matching_info = info
            break
        # Also match if argnames covers input args only
        if info['argmodes']:
            input_count = sum(1 for m in info['argmodes'] if m in ('i', ''))
            if input_count == len(types) and len(info['argnames']) >= input_count:
                matching_info = info
                break

    if matching_info and matching_info['argnames']:
        # Use names from pg_proc.dat
        param_names = matching_info['argnames'][:len(types)]
    else:
        # Use function-specific overrides or type-based names
        param_names = []
        for i, type_name in enumerate(types):
            name = get_param_name_for_type(type_name, i, func_name, len(types))
            param_names.append(name)

    # Deduplicate parameter names by appending numbers
    param_names = deduplicate_param_names(param_names)

    # Now rebuild the signature with parameter names
    new_sig = signature

    # Replace each <type>X</type> with <parameter>name</parameter> <type>X</type>
    # But only if not already preceded by a parameter tag

    # Work backwards to preserve positions
    type_matches = list(re.finditer(r'<type>([^<]+)</type>', signature))

    for i, match in reversed(list(enumerate(type_matches))):
        if i >= len(param_names):
            continue

        type_start = match.start()

        # Check if already has parameter before this type
        before = new_sig[:type_start].rstrip()
        if before.endswith('</parameter>'):
            continue

        # Check if this is a keyword context (like PLACING, FROM, etc.)
        # by looking for literals before
        recent = before[-50:] if len(before) >= 50 else before
        if re.search(r'<literal>[A-Z]+</literal>\s*$', recent):
            # This type follows a keyword, use the param name
            pass

        # Insert parameter name
        param_name = param_names[i]
        insertion = f'<parameter>{param_name}</parameter> '
        new_sig = new_sig[:type_start] + insertion + new_sig[type_start:]

    return new_sig


def process_sgml_file(filepath, param_names_db, dry_run=False, verbose=False):
    """Process a single SGML file and add parameter names where missing."""
    with open(filepath, 'r') as f:
        content = f.read()

    original_content = content

    # Find all functions without parameter names
    functions = find_functions_without_params(content)

    if not functions:
        if verbose:
            print(f"  No changes needed: {filepath}")
        return 0

    # Sort by position in reverse order to preserve positions during replacement
    functions.sort(key=lambda x: x['start'], reverse=True)

    changes_made = 0
    for func in functions:
        func_name = func['func_name']
        old_sig = func['signature']
        new_sig = build_new_signature(old_sig, func_name, param_names_db)

        if old_sig != new_sig:
            if verbose:
                print(f"  Line {func['line']}: {func_name}")
                print(f"    Old: {old_sig[:80]}...")
                print(f"    New: {new_sig[:80]}...")

            content = content[:func['start']] + new_sig + content[func['end']:]
            changes_made += 1

    if changes_made > 0 and not dry_run:
        with open(filepath, 'w') as f:
            f.write(content)

    return changes_made


def main():
    parser = argparse.ArgumentParser(
        description='Add parameter names to PostgreSQL function documentation'
    )
    parser.add_argument('--dry-run', '-n', action='store_true',
                       help='Show what would be changed without modifying files')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Show detailed information about changes')
    parser.add_argument('--pg-root', default='.',
                       help='Path to PostgreSQL source root (default: current directory)')
    parser.add_argument('--file', '-f',
                       help='Process only a specific SGML file')
    args = parser.parse_args()

    pg_root = os.path.abspath(args.pg_root)

    # Verify we're in the right place
    if not os.path.exists(os.path.join(pg_root, PG_PROC_DAT)):
        print(f"Error: Cannot find {PG_PROC_DAT} in {pg_root}")
        print("Please run from PostgreSQL source root or specify --pg-root")
        sys.exit(1)

    print("Parsing pg_proc.dat for function parameter information...")
    param_names_db = parse_pg_proc_dat(pg_root)
    print(f"  Found {len(param_names_db)} unique function names")

    # Count functions with explicit parameter names
    with_names = sum(1 for funcs in param_names_db.values()
                     for f in funcs if f['argnames'])
    print(f"  {with_names} function entries have explicit parameter names")

    doc_dir = os.path.join(pg_root, DOC_FUNC_DIR)

    if args.file:
        files = [args.file if os.path.isabs(args.file)
                else os.path.join(doc_dir, args.file)]
    else:
        files = sorted(Path(doc_dir).glob('*.sgml'))

    print(f"\nProcessing SGML files in {doc_dir}...")

    total_changes = 0
    for filepath in files:
        filepath = str(filepath)
        if os.path.basename(filepath) in ('allfiles.sgml', 'func.sgml'):
            continue

        if args.verbose:
            print(f"\nProcessing {os.path.basename(filepath)}...")

        changes = process_sgml_file(filepath, param_names_db,
                                   dry_run=args.dry_run, verbose=args.verbose)
        total_changes += changes

        if changes > 0 and not args.verbose:
            print(f"  {os.path.basename(filepath)}: {changes} changes")

    print(f"\nTotal: {total_changes} function signatures updated")

    if args.dry_run:
        print("\n(Dry run - no files were modified)")


if __name__ == '__main__':
    main()
