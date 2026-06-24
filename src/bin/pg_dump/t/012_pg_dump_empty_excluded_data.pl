
# Copyright (c) 2026, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $tempdir = PostgreSQL::Test::Utils::tempdir;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

my $src_db = 'empty_excl_src';
my $dst_db = 'empty_excl_dst';
my $dumpdir = "$tempdir/empty_excl_dump";

$node->safe_psql(
	'postgres',
	qq{CREATE DATABASE $src_db;
	   \\c $src_db
	   CREATE TABLE keep_data(id int);
	   CREATE TABLE skip_data(id int);
	   INSERT INTO keep_data VALUES (1), (2);
	   INSERT INTO skip_data VALUES (10), (20), (30);});

# Flag without --exclude-table-data must fail.
$node->command_fails(
	[
		'pg_dump',
		'--no-sync',
		'--format' => 'directory',
		'--file' => "$tempdir/bad_dump",
		'--create-empty-files-for-excluded-data',
		$node->connstr($src_db),
	],
	'create-empty-files-for-excluded-data requires exclude-table-data');

# Flag requires directory output format.
$node->command_fails_like(
	[
		'pg_dump',
		'--no-sync',
		'--format' => 'custom',
		'--file' => "$tempdir/bad_custom.dump",
		'--exclude-table-data' => 'skip_data',
		'--create-empty-files-for-excluded-data',
		$node->connstr($src_db),
	],
	qr/create-empty-files-for-excluded-data.*only supported by the directory format/,
	'create-empty-files-for-excluded-data requires directory format');

# Flag requires COPY-format data, not INSERT output.
my @incompatible_opts = (
	{ label => 'inserts', extra => [ '--inserts' ] },
	{ label => 'column-inserts', extra => [ '--column-inserts' ] },
	{ label => 'rows-per-insert', extra => [ '--rows-per-insert' => 10 ] },
);
for my $case (@incompatible_opts)
{
	$node->command_fails_like(
		[
			'pg_dump',
			'--no-sync',
			'--format' => 'directory',
			'--file' => "$tempdir/bad_$case->{label}",
			'--exclude-table-data' => 'skip_data',
			'--create-empty-files-for-excluded-data',
			@{ $case->{extra} },
			$node->connstr($src_db),
		],
		qr/create-empty-files-for-excluded-data.*cannot be used with/,
		"create-empty-files-for-excluded-data rejects $case->{label}");
}

$node->command_ok(
	[
		'pg_dump',
		'--no-sync',
		'--format' => 'directory',
		'--compress' => 'none',
		'--file' => $dumpdir,
		'--exclude-table-data' => 'skip_data',
		'--create-empty-files-for-excluded-data',
		$node->connstr($src_db),
	],
	'directory dump with empty excluded table data files');

$node->command_like(
	[ 'pg_restore', '--list', $dumpdir ],
	qr/TABLE DATA public skip_data/,
	'TOC lists TABLE DATA for excluded table');

my ($stdout, $stderr) = run_command([ 'pg_restore', '--list', $dumpdir ]);
my $skip_dumpid;
foreach my $line (split /\n/, $stdout)
{
	if ($line =~ /TABLE DATA public skip_data/ && $line =~ /^(\d+);/)
	{
		$skip_dumpid = $1;
		last;
	}
}
ok(defined $skip_dumpid, 'found dump ID for excluded table');
like(
	slurp_file("$dumpdir/${skip_dumpid}.dat"),
	qr/^\\\.\n/,
	'excluded table data file contains COPY end marker only')
  if defined $skip_dumpid;

my @datfiles = grep { $_ !~ /\/toc\.dat$/ } glob("$dumpdir/*.dat");
cmp_ok(scalar(@datfiles), '==', 2, 'two table data files in dump');

my ($keep_dat) = grep { $_ ne "$dumpdir/${skip_dumpid}.dat" } @datfiles;
ok(defined $keep_dat && -s $keep_dat > 0,
	'included table has a non-empty data file')
  if defined $skip_dumpid;

$node->safe_psql('postgres', "CREATE DATABASE $dst_db");

$node->command_ok(
	[
		'pg_restore',
		'--dbname' => $node->connstr($dst_db),
		$dumpdir,
	],
	'restore dump with empty excluded data file');

is(
	$node->safe_psql($dst_db, 'SELECT count(*) FROM keep_data'),
	'2',
	'included table data restored');
is(
	$node->safe_psql($dst_db, 'SELECT count(*) FROM skip_data'),
	'0',
	'excluded table restored with no rows');

done_testing();
