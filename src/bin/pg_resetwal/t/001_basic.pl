
# Copyright (c) 2021-2025, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run;

program_help_ok('pg_resetwal');
program_version_ok('pg_resetwal');
program_options_handling_ok('pg_resetwal');

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', 'track_commit_timestamp = on');

command_like([ 'pg_resetwal', '-n', $node->data_dir ],
	qr/checkpoint/, 'pg_resetwal -n produces output');


# Permissions on PGDATA should be default
SKIP:
{
	skip "unix-style permissions not supported on Windows", 1
	  if ($windows_os);

	ok(check_mode_recursive($node->data_dir, 0700, 0600),
		'check PGDATA permissions');
}

command_ok([ 'pg_resetwal', '--pgdata' => $node->data_dir ],
	'pg_resetwal runs');
$node->start;
is($node->safe_psql("postgres", "SELECT 1;"),
	1, 'server running and working after reset');

command_fails_like(
	[ 'pg_resetwal', $node->data_dir ],
	qr/lock file .* exists/,
	'fails if server running');

$node->stop('immediate');
command_fails_like(
	[ 'pg_resetwal', $node->data_dir ],
	qr/database server was not shut down cleanly/,
	'does not run after immediate shutdown');
command_ok(
	[ 'pg_resetwal', '--force', $node->data_dir ],
	'runs after immediate shutdown with force');
$node->start;
is($node->safe_psql("postgres", "SELECT 1;"),
	1, 'server running and working after forced reset');

$node->stop;

# check various command-line handling

# Note: This test intends to check that a nonexistent data directory
# gives a reasonable error message.  Because of the way the code is
# currently structured, you get an error about readings permissions,
# which is perhaps suboptimal, so feel free to update this test if
# this gets improved.
command_fails_like(
	[ 'pg_resetwal', 'foo' ],
	qr/error: could not read permissions of directory/,
	'fails with nonexistent data directory');

command_fails_like(
	[ 'pg_resetwal', 'foo', 'bar' ],
	qr/too many command-line arguments/,
	'fails with too many command-line arguments');

$ENV{PGDATA} = $node->data_dir;    # not used
command_fails_like(
	['pg_resetwal'],
	qr/no data directory specified/,
	'fails with too few command-line arguments');

# error cases
# -c
command_fails_like(
	[ 'pg_resetwal', '-c' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -c/,
	'fails with incorrect -c option');
command_fails_like(
	[ 'pg_resetwal', '-c' => '10,bar', $node->data_dir ],
	qr/error: invalid argument for option -c/,
	'fails with incorrect -c option part 2');
command_fails_like(
	[ 'pg_resetwal', '-c' => '1,10', $node->data_dir ],
	qr/greater than/,
	'fails with -c ids value 1 part 1');
command_fails_like(
	[ 'pg_resetwal', '-c' => '10,1', $node->data_dir ],
	qr/greater than/,
	'fails with -c value 1 part 2');
# -e
command_fails_like(
	[ 'pg_resetwal', '-e' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -e/,
	'fails with incorrect -e option');
command_fails_like(
	[ 'pg_resetwal', '-e' => '-1', $node->data_dir ],
	qr/must not be -1/,
	'fails with -e value -1');
# -l
command_fails_like(
	[ 'pg_resetwal', '-l' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -l/,
	'fails with incorrect -l option');
# -m
command_fails_like(
	[ 'pg_resetwal', '-m' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -m/,
	'fails with incorrect -m option');
command_fails_like(
	[ 'pg_resetwal', '-m' => '10,bar', $node->data_dir ],
	qr/error: invalid argument for option -m/,
	'fails with incorrect -m option part 2');
command_fails_like(
	[ 'pg_resetwal', '-m' => '0,10', $node->data_dir ],
	qr/must not be 0/,
	'fails with -m value 0 part 1');
command_fails_like(
	[ 'pg_resetwal', '-m' => '10,0', $node->data_dir ],
	qr/must not be 0/,
	'fails with -m value 0 part 2');
# -o
command_fails_like(
	[ 'pg_resetwal', '-o' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -o/,
	'fails with incorrect -o option');
command_fails_like(
	[ 'pg_resetwal', '-o' => '0', $node->data_dir ],
	qr/must not be 0/,
	'fails with -o value 0');
# -O
command_fails_like(
	[ 'pg_resetwal', '-O' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -O/,
	'fails with incorrect -O option');
command_fails_like(
	[ 'pg_resetwal', '-O' => '-1', $node->data_dir ],
	qr/must not be -1/,
	'fails with -O value -1');
# --wal-segsize
command_fails_like(
	[ 'pg_resetwal', '--wal-segsize' => 'foo', $node->data_dir ],
	qr/error: invalid value/,
	'fails with incorrect --wal-segsize option');
command_fails_like(
	[ 'pg_resetwal', '--wal-segsize' => '13', $node->data_dir ],
	qr/must be a power/,
	'fails with invalid --wal-segsize value');
# -u
command_fails_like(
	[ 'pg_resetwal', '-u' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -u/,
	'fails with incorrect -u option');
command_fails_like(
	[ 'pg_resetwal', '-u' => '1', $node->data_dir ],
	qr/must be greater than/,
	'fails with -u value too small');
# -x
command_fails_like(
	[ 'pg_resetwal', '-x' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -x/,
	'fails with incorrect -x option');
command_fails_like(
	[ 'pg_resetwal', '-x' => '1', $node->data_dir ],
	qr/must be greater than/,
	'fails with -x value too small');

# --char-signedness
command_fails_like(
	[ 'pg_resetwal', '--char-signedness', 'foo', $node->data_dir ],
	qr/error: invalid argument for option --char-signedness/,
	'fails with incorrect --char-signedness option');

# -s / --system-identifier
command_fails_like(
	[ 'pg_resetwal', '-s' => 'foo', $node->data_dir ],
	qr/error: invalid argument for option -s/,
	'fails with incorrect -s option');
command_fails_like(
	[ 'pg_resetwal', '--system-identifier' => 'bar', $node->data_dir ],
	qr/error: invalid argument for option -s/,
	'fails with incorrect --system-identifier option');
command_fails_like(
	[ 'pg_resetwal', '-s' => '0', $node->data_dir ],
	qr/error: system identifier must be greater than 0/,
	'fails with zero system identifier');
command_fails_like(
	[ 'pg_resetwal', '-s' => '-123', $node->data_dir ],
	qr/error: system identifier must be greater than 0/,
	'fails with negative system identifier');

# Test system identifier change with dry-run
command_like(
	[ 'pg_resetwal', '-s' => '1234567890123456789', '--dry-run', $node->data_dir ],
	qr/System identifier:\s+1234567890123456789/,
	'system identifier change shows in dry-run output');

# Test actual system identifier change with force flag
$node->stop;
my $new_sysid = '9876543210987654321';
command_ok(
	[ 'pg_resetwal', '-f', '-s' => $new_sysid, $node->data_dir ],
	'pg_resetwal -s with force flag succeeds');

# Verify the change was applied by checking pg_control
$node->start;
my $controldata_output = $node->safe_psql('postgres', 
	"SELECT system_identifier FROM pg_control_system()");
is($controldata_output, $new_sysid, 'system identifier was changed correctly');

# Test that the server works normally after system identifier change
is($node->safe_psql("postgres", "SELECT 1;"),
	1, 'server running and working after system identifier change');

$node->stop;

# Test that system identifier change requires force flag when control values are guessed
# Note: Interactive prompt testing is challenging due to stdin handling limitations
command_fails_like(
	[ 'pg_resetwal', '-s' => '1111111111111111111', $node->data_dir ],
	qr/not proceeding because control file values were guessed/,
	'system identifier change fails without force flag when control values are guessed');

# Test non-TTY stdin handling (when stdin is not interactive)
my $non_tty_test_node = PostgreSQL::Test::Cluster->new('non_tty_test');
$non_tty_test_node->init;
$non_tty_test_node->stop;

# Test with stdin redirected from /dev/null (non-TTY)
my ($stdin_null, $stdout_null, $stderr_null) = ('', '', '');
my $null_harness = IPC::Run::start(
	[ 'pg_resetwal', '-s', '3333333333333333333', $non_tty_test_node->data_dir ],
	'<', '/dev/null', '>', \$stdout_null, '2>', \$stderr_null
);
$null_harness->finish();

like($stderr_null, qr/standard input is not a TTY and --force was not specified/, 
	'non-TTY stdin properly detected and rejected without --force');

# Test that --force works with non-TTY stdin
command_ok(
	[ 'pg_resetwal', '-f', '-s', '4444444444444444444', $non_tty_test_node->data_dir ],
	'system identifier change with --force works in non-TTY environment');

# Verify the change was applied in non-TTY test
$non_tty_test_node->start;
my $non_tty_sysid = $non_tty_test_node->safe_psql('postgres', 
	"SELECT system_identifier FROM pg_control_system()");
is($non_tty_sysid, '4444444444444444444', 
	'system identifier changed correctly with --force in non-TTY environment');
$non_tty_test_node->stop;

# Test interactive confirmation with 'n' response (cancellation)
# We can test this by providing 'n' as input to stdin
my $interactive_test_node = PostgreSQL::Test::Cluster->new('interactive_test');
$interactive_test_node->init;
$interactive_test_node->stop;

# Create a test that simulates user saying 'n' to the confirmation prompt
my ($stdin, $stdout, $stderr);
my $harness = IPC::Run::start(
	[ 'pg_resetwal', '-s', '7777777777777777777', $interactive_test_node->data_dir ],
	'<', \$stdin, '>', \$stdout, '2>', \$stderr
);

# Send 'n' to decline the confirmation
$stdin = "n\n";
$harness->finish();

like($stderr, qr/System identifier change cancelled/, 
	'interactive confirmation properly cancels on n response');

# Test interactive confirmation with 'y' response (acceptance)
($stdin, $stdout, $stderr) = ('', '', '');
$harness = IPC::Run::start(
	[ 'pg_resetwal', '-s', '8888888888888888888', $interactive_test_node->data_dir ],
	'<', \$stdin, '>', \$stdout, '2>', \$stderr
);

# Send 'y' to accept the confirmation
$stdin = "y\n";
$harness->finish();

like($stdout, qr/Changing system identifier/, 
	'interactive confirmation proceeds on y response');

# Verify the change was applied
$interactive_test_node->start;
my $interactive_sysid = $interactive_test_node->safe_psql('postgres', 
	"SELECT system_identifier FROM pg_control_system()");
is($interactive_sysid, '8888888888888888888', 
	'system identifier changed via interactive confirmation');
$interactive_test_node->stop;

# Test maximum valid 64-bit value
my $max_sysid = '18446744073709551615';  # 2^64 - 1
command_like(
	[ 'pg_resetwal', '-s' => $max_sysid, '-f', '--dry-run', $node->data_dir ],
	qr/System identifier:\s+18446744073709551615/,
	'maximum 64-bit system identifier value accepted');

# Test overflow detection
command_fails_like(
	[ 'pg_resetwal', '-s' => '99999999999999999999999999999', $node->data_dir ],
	qr/error: system identifier value is out of range/,
	'overflow system identifier value rejected');

# Test hexadecimal input (should fail - only decimal accepted)
command_fails_like(
	[ 'pg_resetwal', '-s' => '0x123456789ABCDEF0', $node->data_dir ],
	qr/error: invalid argument for option -s/,
	'hexadecimal system identifier input rejected');

# Test leading/trailing whitespace (should fail)
command_fails_like(
	[ 'pg_resetwal', '-s' => ' 123456789 ', $node->data_dir ],
	qr/error: invalid argument for option -s/,
	'system identifier with whitespace rejected');

# Test empty string
command_fails_like(
	[ 'pg_resetwal', '-s' => '', $node->data_dir ],
	qr/error: invalid argument for option -s/,
	'empty system identifier rejected');

# Test boundary values
command_like(
	[ 'pg_resetwal', '-s' => '1', '-f', '--dry-run', $node->data_dir ],
	qr/System identifier:\s+1/,
	'minimum valid system identifier (1) accepted');

# Test very large but valid value
command_like(
	[ 'pg_resetwal', '-s' => '9223372036854775807', '-f', '--dry-run', $node->data_dir ],
	qr/System identifier:\s+9223372036854775807/,
	'large valid system identifier accepted');

# Test another system identifier change to verify functionality
my $another_sysid = '5555555555555555555';
command_ok(
	[ 'pg_resetwal', '-f', '-s' => $another_sysid, $node->data_dir ],
	'second system identifier change succeeds');

# Verify the second change
$node->start;
my $second_controldata = $node->safe_psql('postgres', 
	"SELECT system_identifier FROM pg_control_system()");
is($second_controldata, $another_sysid, 'second system identifier change verified');

$node->stop;

# run with control override options

my $out = (run_command([ 'pg_resetwal', '--dry-run', $node->data_dir ]))[0];
$out =~ /^Database block size: *(\d+)$/m or die;
my $blcksz = $1;

my @cmd = ('pg_resetwal', '--pgdata' => $node->data_dir);

# some not-so-critical hardcoded values
push @cmd, '--epoch' => 1;
push @cmd, '--next-wal-file' => '00000001000000320000004B';
push @cmd, '--next-oid' => 100_000;
push @cmd, '--wal-segsize' => 1;

# these use the guidance from the documentation

sub get_slru_files
{
	opendir(my $dh, $node->data_dir . '/' . $_[0]) or die $!;
	my @files = sort grep { /[0-9A-F]+/ } readdir $dh;
	closedir $dh;
	return @files;
}

my (@files, $mult);

@files = get_slru_files('pg_commit_ts');
# XXX: Should there be a multiplier, similar to the other options?
# -c argument is "old,new"
push @cmd,
  '--commit-timestamp-ids' =>
  sprintf("%d,%d", hex($files[0]) == 0 ? 3 : hex($files[0]), hex($files[-1]));

@files = get_slru_files('pg_multixact/offsets');
$mult = 32 * $blcksz / 4;
# --multixact-ids argument is "new,old"
push @cmd,
  '--multixact-ids' => sprintf("%d,%d",
	(hex($files[-1]) + 1) * $mult,
	hex($files[0]) == 0 ? 1 : hex($files[0] * $mult));

@files = get_slru_files('pg_multixact/members');
$mult = 32 * int($blcksz / 20) * 4;
push @cmd, '--multixact-offset' => (hex($files[-1]) + 1) * $mult;

@files = get_slru_files('pg_xact');
$mult = 32 * $blcksz * 4;
push @cmd,
  '--oldest-transaction-id' =>
  (hex($files[0]) == 0 ? 3 : hex($files[0]) * $mult),
  '--next-transaction-id' => ((hex($files[-1]) + 1) * $mult);

command_ok([ @cmd, '--dry-run' ],
	'runs with control override options, dry run');
command_ok(\@cmd, 'runs with control override options');
command_like(
	[ 'pg_resetwal', '--dry-run', $node->data_dir ],
	qr/^Latest checkpoint's NextOID: *100000$/m,
	'spot check that control changes were applied');

$node->start;
ok(1, 'server started after reset');

done_testing();
