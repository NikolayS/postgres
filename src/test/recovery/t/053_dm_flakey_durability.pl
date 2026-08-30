
# Copyright (c) 2026, PostgreSQL Global Development Group

#
# Test Postgres crash recovery against a storage layer that silently
# discards non-FUA writes.
#
# Motivation (see NikolayS/postgres issue #31): simulating crashes with
# `kill -9` does not actually exercise Postgres's fsync contract because
# the kernel page cache survives the signal -- the server comes back up
# and sees its own "fsync'd" writes even if fsync did nothing useful.
# The experiment "Exp C -- dm-flakey drop_writes" showed that Linux's
# device-mapper `flakey` target, switched into `drop_writes` mode, is a
# cheap and effective way to simulate a disk that silently loses writes
# which were not explicitly durable.  This test codifies that experiment.
#
# What it does:
#   1. Builds a sparse-backed loopback block device.
#   2. Stacks a dm-flakey device on top (initially pass-through).
#   3. Formats ext4 and mounts it; the node's PGDATA lives there.
#   4. Runs a small pgbench workload + a sentinel table; records pre-crash
#      invariants (row count, TPC-B three-sum).
#   5. Flips the flakey target into drop_writes mode -- from this moment
#      on, any write that is not flushed+FUA to the backing device is
#      silently discarded.
#   6. Lets a brief amount of extra WAL flow, then stops the node with
#      mode "immediate" (hard kill, no shutdown checkpoint).
#   7. Restores the pass-through mapping, remounts (running e2fsck first
#      and logging its output -- part of the point is showing that ext4
#      itself survives the write loss, so any remaining damage is at the
#      Postgres durability layer).
#   8. Restarts the node and verifies crash recovery completed, the
#      post-crash row count matches pre-crash, the TPC-B three-sum
#      invariant still holds, and amcheck reports no corruption on the
#      pgbench primary-key index.
#
# How to run (Linux, root required):
#
#   PG_TEST_EXTRA=dm_flakey sudo -E \
#       prove -v src/test/recovery/t/053_dm_flakey_durability.pl
#
# The test skips unconditionally on non-Linux, when not running as root,
# when dmsetup/losetup/mkfs.ext4/e2fsck are missing, when the dm-flakey
# kernel module cannot be loaded, or when PG_TEST_EXTRA does not contain
# the token `dm_flakey` (upstream gating convention for privileged
# tests; compare kerberos/ssl/ldap test suites).
#
# This test is intentionally different from
# src/test/recovery/t/013_crash_restart.pl: 013 kills a backend to drive
# the postmaster through a crash-and-restart cycle (tests the
# server-process supervision logic).  This test targets the *storage
# durability contract* -- it simulates a disk that lost writes which
# Postgres believed were durable, and checks that WAL + full-page-writes
# + checksums can reconstruct a consistent state.
#

use strict;
use warnings FATAL => 'all';

use Config;
use File::Path qw(make_path);
use File::Spec;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# ---------------------------------------------------------------------------
# Gating
# ---------------------------------------------------------------------------

if ($^O ne 'linux')
{
	plan skip_all => 'dm-flakey durability test runs only on Linux';
}

if ($> != 0)
{
	plan skip_all =>
	  'dm-flakey durability test requires root (EUID 0) to manage loop/dm devices';
}

if (!$ENV{PG_TEST_EXTRA} || $ENV{PG_TEST_EXTRA} !~ /\bdm_flakey\b/)
{
	plan skip_all =>
	  'Potentially unsafe test dm_flakey not enabled in PG_TEST_EXTRA';
}

# Verify required userspace tools.
sub _which
{
	my ($prog) = @_;
	for my $dir (split /:/, ($ENV{PATH} // ''))
	{
		my $p = "$dir/$prog";
		return $p if -x $p;
	}
	return undef;
}

for my $tool (qw(dmsetup losetup mkfs.ext4 e2fsck mount umount))
{
	if (!_which($tool))
	{
		plan skip_all => "required tool '$tool' not found in PATH";
	}
}

# Try to load dm-flakey.  If modprobe fails, dm-flakey is unavailable.
{
	my $rc = system('modprobe', 'dm-flakey');
	if ($rc != 0)
	{
		plan skip_all =>
		  'could not load dm-flakey kernel module (modprobe dm-flakey failed)';
	}
}

# ---------------------------------------------------------------------------
# Cleanup state + mandatory END block
# ---------------------------------------------------------------------------

# Everything created here is tracked in these package-level vars so the
# END block can tear down in reverse order, regardless of where the test
# died.
our $NODE;
our $DM_NAME;
our $MOUNT_POINT;
our $LOOP_DEV;
our $BACKING_FILE;

END
{
	# $? is the script's exit code; preserve it across external commands
	# we run for cleanup.
	my $saved_exit = $?;

	# Best-effort: ignore failures here, but log them.
	if (defined $NODE)
	{
		eval {
			# 'immediate' is fine even if the node is already down; stop()
			# returns early if no pid file.
			$NODE->stop('immediate', fail_ok => 1);
		};
		diag("cleanup: node stop failed: $@") if $@;
	}

	if (defined $MOUNT_POINT && -d $MOUNT_POINT)
	{
		# umount may fail if nothing is mounted; that's OK.
		system('umount', $MOUNT_POINT);
	}

	if (defined $DM_NAME)
	{
		# Best effort: if the table is still in drop_writes mode, it may
		# refuse removal without a suspend/resume cycle first.
		system('dmsetup', 'remove', '--force', $DM_NAME);
	}

	if (defined $LOOP_DEV)
	{
		system('losetup', '-d', $LOOP_DEV);
	}

	# Backing file lives in the Cluster tmp dir, which the framework
	# cleans up automatically.  But on failure paths the tmp dir may be
	# retained (PG_TEST_NOCLEAN) -- either way we don't need to unlink.

	$? = $saved_exit;
}

# ---------------------------------------------------------------------------
# Phase 1: set up the loop + dm-flakey + ext4 stack
# ---------------------------------------------------------------------------

# A fresh tempdir under tmp_check; the Cluster basedir will be placed
# inside the mounted FS below.
my $stage_dir = PostgreSQL::Test::Utils::tempdir('dm_flakey');
diag("staging dir: $stage_dir");

# 1.2 GiB sparse backing file -- large enough for pgbench scale 3 plus
# some WAL churn, small enough to stay well under typical tmp quotas.
my $backing_size_bytes = 1_200 * 1024 * 1024;
my $sector_size        = 512;
my $size_sectors       = int($backing_size_bytes / $sector_size);

$BACKING_FILE = "$stage_dir/backing.img";
diag("creating sparse backing file $BACKING_FILE (${backing_size_bytes}B)");
{
	open(my $fh, '>', $BACKING_FILE)
	  or die "cannot create $BACKING_FILE: $!";
	truncate($fh, $backing_size_bytes)
	  or die "cannot truncate $BACKING_FILE: $!";
	close($fh);
}

# Allocate a loop device for the file.
my $losetup_out = '';
{
	my $rc = IPC::Run::run(
		[ 'losetup', '--show', '-f', $BACKING_FILE ],
		'>'  => \$losetup_out,
		'2>' => \my $err);
	die "losetup -f failed: $err" unless $rc;
}
chomp($losetup_out);
$LOOP_DEV = $losetup_out;
die "losetup returned empty loop device path" unless $LOOP_DEV;
diag("loop device: $LOOP_DEV");

# Create the dm-flakey pass-through mapping.  Flakey table format:
#   <logical_start> <length> flakey <dev> <offset> <up_interval> <down_interval> [<num_features> feature_args...]
# Pass-through: up forever => up_interval=3600, down_interval=0, no features.
$DM_NAME = "pgflakey_$$";
my $dm_table_passthrough = "0 $size_sectors flakey $LOOP_DEV 0 3600 0";
diag("dmsetup create $DM_NAME -> $dm_table_passthrough");
PostgreSQL::Test::Utils::run_log(
	[ 'dmsetup', 'create', $DM_NAME ],
	'<' => \$dm_table_passthrough)
  or die "dmsetup create $DM_NAME failed";

my $dm_dev = "/dev/mapper/$DM_NAME";

# Format ext4 on the flakey device.  '-F' forces creation on a device
# that might look suspicious (e.g., re-running on a dirty file).
PostgreSQL::Test::Utils::system_or_bail('mkfs.ext4', '-F', '-q', $dm_dev);

# Mount.
$MOUNT_POINT = "$stage_dir/mnt";
make_path($MOUNT_POINT);
PostgreSQL::Test::Utils::system_or_bail('mount', $dm_dev, $MOUNT_POINT);
diag("mounted $dm_dev at $MOUNT_POINT");

# ---------------------------------------------------------------------------
# Phase 2: initdb + start on the flakey FS
# ---------------------------------------------------------------------------

# Create the cluster object normally, then redirect its basedir onto the
# flakey-backed mount so initdb writes PGDATA there.  basedir points to
# the parent dir; data_dir is "$basedir/pgdata".
$NODE = PostgreSQL::Test::Cluster->new('flakey');

my $target_basedir = "$MOUNT_POINT/pgbase";
make_path($target_basedir);
$NODE->{_basedir} = $target_basedir;
diag("redirecting node basedir to $target_basedir (data_dir = "
	  . $NODE->data_dir . ")");

$NODE->init(extra => [ '--data-checksums' ]);

$NODE->append_conf(
	'postgresql.conf', qq(
fsync = on
full_page_writes = on
synchronous_commit = on
# keep checkpoints small so the test exercises WAL replay
checkpoint_timeout = 30s
max_wal_size = 256MB
));

$NODE->start;

# ---------------------------------------------------------------------------
# Phase 3: workload + record pre-crash invariants
# ---------------------------------------------------------------------------

diag('creating sentinel table durable_test and running pgbench -i -s 2');

$NODE->safe_psql('postgres',
	q(CREATE TABLE durable_test(id int primary key, v text)));

# Use scale 2 -> 2 * 100_000 = 200_000 rows in pgbench_accounts.  Small
# enough to finish init in a few seconds, large enough to generate
# interesting I/O.
my $scale = 2;
PostgreSQL::Test::Utils::system_or_bail('pgbench', '-i',
	'-s' => $scale,
	'-q',
	'-p' => $NODE->port,
	'-h' => $NODE->host,
	'postgres');

# Short tpc-b workload to dirty pages + generate WAL.
diag('running brief pgbench TPC-B workload (5s)');
PostgreSQL::Test::Utils::run_log(
	[
		'pgbench',
		'-n',
		'-c' => 2,
		'-j' => 2,
		'-T' => 5,
		'-p' => $NODE->port,
		'-h' => $NODE->host,
		'postgres'
	]);

# Insert ~1000 rows into the sentinel.
$NODE->safe_psql(
	'postgres',
	q(INSERT INTO durable_test
      SELECT g, 'row-' || g FROM generate_series(1, 1000) g));

# Force a checkpoint so we have a stable pre-crash snapshot on disk.
$NODE->safe_psql('postgres', 'CHECKPOINT');

my $pre_accounts_count =
  $NODE->safe_psql('postgres', 'SELECT count(*) FROM pgbench_accounts');
my $pre_accounts_sum =
  $NODE->safe_psql('postgres', 'SELECT sum(abalance) FROM pgbench_accounts');
my $pre_durable_count =
  $NODE->safe_psql('postgres', 'SELECT count(*) FROM durable_test');

diag("pre-crash: pgbench_accounts count=$pre_accounts_count "
	  . "sum(abalance)=$pre_accounts_sum durable_test count=$pre_durable_count"
);

is($pre_accounts_count, $scale * 100_000,
	'pre-crash pgbench_accounts row count matches scale');

# ---------------------------------------------------------------------------
# Phase 4: flip flakey into drop_writes and dirty some more WAL
# ---------------------------------------------------------------------------

my $dm_table_drop =
  "0 $size_sectors flakey $LOOP_DEV 0 0 3600 1 drop_writes";
diag('switching dm-flakey to drop_writes mode: ' . $dm_table_drop);

PostgreSQL::Test::Utils::system_or_bail('dmsetup', 'suspend', $DM_NAME);
PostgreSQL::Test::Utils::run_log(
	[ 'dmsetup', 'load', $DM_NAME ],
	'<' => \$dm_table_drop)
  or die "dmsetup load (drop_writes) failed";
PostgreSQL::Test::Utils::system_or_bail('dmsetup', 'resume', $DM_NAME);

# Brief post-flip activity -- commits here may or may not survive the
# crash; the point is to make sure WAL replay handles whatever state the
# "disk" ends up in.
diag('running 3s of post-flip pgbench (these writes may be lost)');
PostgreSQL::Test::Utils::run_log(
	[
		'pgbench',
		'-n',
		'-c' => 2,
		'-j' => 2,
		'-T' => 3,
		'-p' => $NODE->port,
		'-h' => $NODE->host,
		'postgres'
	]);

# ---------------------------------------------------------------------------
# Phase 5: simulate crash
# ---------------------------------------------------------------------------

diag('stopping node in immediate mode (simulated crash)');
$NODE->stop('immediate');

# ---------------------------------------------------------------------------
# Phase 6: restore pass-through, fsck, remount
# ---------------------------------------------------------------------------

PostgreSQL::Test::Utils::system_or_bail('dmsetup', 'suspend', $DM_NAME);
PostgreSQL::Test::Utils::run_log(
	[ 'dmsetup', 'load', $DM_NAME ],
	'<' => \$dm_table_passthrough)
  or die "dmsetup load (passthrough restore) failed";
PostgreSQL::Test::Utils::system_or_bail('dmsetup', 'resume', $DM_NAME);

PostgreSQL::Test::Utils::system_or_bail('umount', $MOUNT_POINT);

# e2fsck -fy: force, answer yes to all prompts.  Log the output because a
# clean result is itself a useful signal -- if the FS needed real repairs
# that would be interesting.
diag("running e2fsck -fy $dm_dev");
{
	my ($out, $err);
	my $ok = IPC::Run::run([ 'e2fsck', '-fy', $dm_dev ],
		'>' => \$out, '2>' => \$err);
	diag("e2fsck stdout:\n$out") if defined $out && length $out;
	diag("e2fsck stderr:\n$err") if defined $err && length $err;
	# e2fsck exit 0=clean, 1=fixes applied.  Either is acceptable.
	my $rc = $? >> 8;
	ok($rc <= 1, "e2fsck exited cleanly (rc=$rc)");
}

PostgreSQL::Test::Utils::system_or_bail('mount', $dm_dev, $MOUNT_POINT);

# ---------------------------------------------------------------------------
# Phase 7: restart node, verify crash recovery ran
# ---------------------------------------------------------------------------

diag('restarting node; expecting crash recovery');
$NODE->start;

ok( $NODE->log_contains(
		qr/database system was not properly shut down; automatic recovery in progress/
	),
	'crash-recovery path taken on restart');

ok($NODE->log_contains(qr/database system is ready to accept connections/),
	'node reached ready state after recovery');

# ---------------------------------------------------------------------------
# Phase 8: verify invariants
# ---------------------------------------------------------------------------

my $post_accounts_count =
  $NODE->safe_psql('postgres', 'SELECT count(*) FROM pgbench_accounts');
is( $post_accounts_count,
	$pre_accounts_count,
	'pgbench_accounts row count matches pre-crash');

# TPC-B three-sum invariant: sum(abalance) over all accounts equals
# sum(bbalance) over all branches equals sum(tbalance) over all tellers.
# pgbench maintains this by construction in each transaction; if any
# partial transaction survived it would break the invariant.
my $three_sum = $NODE->safe_psql(
	'postgres',
	q(
        SELECT (SELECT sum(abalance) FROM pgbench_accounts)
             = (SELECT sum(bbalance) FROM pgbench_branches)
           AND (SELECT sum(bbalance) FROM pgbench_branches)
             = (SELECT sum(tbalance) FROM pgbench_tellers)
    ));
is($three_sum, 't', 'TPC-B three-sum invariant holds after recovery');

my $post_durable_count =
  $NODE->safe_psql('postgres', 'SELECT count(*) FROM durable_test');
diag("post-crash durable_test count=$post_durable_count "
	  . "(pre=$pre_durable_count)");
cmp_ok( $post_durable_count, '>=', $pre_durable_count,
	'durable_test survived at least the pre-crash committed rows');

# amcheck on pgbench_accounts_pkey.  If the extension is not installed
# in this build, report it and carry on -- the data checks above are the
# primary assertion of this test.
my ($amcheck_installed, $stderr);
$NODE->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS amcheck',
	stderr => \$stderr);
if (defined $stderr && $stderr =~ /could not open extension control file/)
{
	diag("amcheck extension not installed; skipping bt_index_check");
}
else
{
	my $amcheck_out = $NODE->safe_psql('postgres',
		q(SELECT bt_index_check('pgbench_accounts_pkey'::regclass)));
	is($amcheck_out, '',
		'bt_index_check reports no corruption on pgbench_accounts_pkey');
}

# Ordered stop before END-block cleanup kicks in -- gives a clean shutdown
# checkpoint and exercises the normal stop path.
$NODE->stop;

done_testing();
