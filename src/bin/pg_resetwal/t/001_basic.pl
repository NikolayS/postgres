
# Copyright (c) 2021-2022, PostgreSQL Global Development Group

use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run;

program_help_ok('pg_resetwal');
program_version_ok('pg_resetwal');
program_options_handling_ok('pg_resetwal');

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

command_like([ 'pg_resetwal', '-n', $node->data_dir ],
	qr/checkpoint/, 'pg_resetwal -n produces output');

# Test system identifier option help text
command_like([ 'pg_resetwal', '--help' ],
	qr/system-identifier/, 'help text includes system identifier option');

# Test invalid system identifier values
command_fails_like(
	[ 'pg_resetwal', '-s' => '0', $node->data_dir ],
	qr/system identifier must be greater than 0/,
	'zero system identifier value rejected');

command_fails_like(
	[ 'pg_resetwal', '-s' => '-1', $node->data_dir ],
	qr/invalid argument for option -s/,
	'negative system identifier value rejected');

command_fails_like(
	[ 'pg_resetwal', '-s' => 'abc', $node->data_dir ],
	qr/invalid argument for option -s/,
	'non-numeric system identifier value rejected');

# Test overflow detection
command_fails_like(
	[ 'pg_resetwal', '-s' => '99999999999999999999999999999', $node->data_dir ],
	qr/system identifier value is out of range/,
	'overflow system identifier value rejected');

# Test hexadecimal input (should fail - only decimal accepted)
command_fails_like(
	[ 'pg_resetwal', '-s' => '0x123456789ABCDEF0', $node->data_dir ],
	qr/invalid argument for option -s/,
	'hexadecimal system identifier input rejected');

# Test leading/trailing whitespace (should fail)
command_fails_like(
	[ 'pg_resetwal', '-s' => ' 123456789 ', $node->data_dir ],
	qr/invalid argument for option -s/,
	'system identifier with whitespace rejected');

# Test dry-run with system identifier
command_like(
	[ 'pg_resetwal', '-n', '-s' => '1234567890123456789', $node->data_dir ],
	qr/New system identifier: 1234567890123456789/,
	'dry-run shows new system identifier');

# Test that system identifier change requires force flag when control values are guessed
# Note: Interactive prompt testing is challenging due to stdin handling limitations
command_fails_like(
	[ 'pg_resetwal', '-s' => '1111111111111111111', $node->data_dir ],
	qr/not proceeding because control file values were guessed/,
	'system identifier change fails without force flag when control values are guessed');

# Test non-TTY stdin handling (when stdin is not interactive)
my $non_tty_test = sub {
	my ($in, $out, $err) = ('', '', '');
	my $h = IPC::Run::start(
		[ 'pg_resetwal', '-s' => '2222222222222222222', $node->data_dir ],
		'<', \$in, '>', \$out, '2>', \$err);
	$h->finish();
	return ($? >> 8, $out, $err);
};

my ($exit_code, $stdout, $stderr) = $non_tty_test->();
like($stderr, qr/standard input is not a TTY/, 'non-TTY stdin properly detected');
isnt($exit_code, 0, 'non-TTY stdin causes failure without --force');

# Test actual system identifier change with force flag
$node->stop;
command_ok(
	[ 'pg_resetwal', '-f', '-s' => '3333333333333333333', $node->data_dir ],
	'system identifier change with force flag succeeds');

# Verify the system identifier was actually changed
command_like(
	[ 'pg_resetwal', '-n', $node->data_dir ],
	qr/Database system identifier:\s+3333333333333333333/,
	'system identifier was actually changed');

# Test that PostgreSQL can start with the new system identifier
$node->start;
my $result = $node->safe_psql('postgres', 'SELECT system_identifier FROM pg_control_system()');
is($result, '3333333333333333333', 'PostgreSQL reports correct system identifier after change');
$node->stop;

# Permissions on PGDATA should be default
SKIP:
{
	skip "unix-style permissions not supported on Windows", 1
	  if ($windows_os);

	ok(check_mode_recursive($node->data_dir, 0700, 0600),
		'check PGDATA permissions');
}

done_testing();
