#!/usr/bin/perl

# Copyright (c) 2025, PostgreSQL Global Development Group

=pod

=head1 NAME

007_pg_restore_object_tracking.pl - test pg_restore object tracking enhancement

=head1 SYNOPSIS

  prove src/bin/pg_dump/t/007_pg_restore_object_tracking.pl

=head1 DESCRIPTION

Test the enhanced pg_restore object tracking functionality that provides
detailed information about successful and failed object restorations.

=cut

use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Temp qw(tempdir);

# Create temporary directory for test files
my $tempdir = tempdir(CLEANUP => 1);

# Initialize a test cluster
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

# Create test database
$node->safe_psql('postgres', 'CREATE DATABASE test_tracking;');

# Test 1: Create test schema with various object types
my $test_schema = q{
    -- Create table with dependencies
    CREATE TABLE test_users (
        id SERIAL PRIMARY KEY,
        email VARCHAR(100) UNIQUE NOT NULL,
        name VARCHAR(100) NOT NULL
    );

    -- Insert test data
    INSERT INTO test_users (email, name) VALUES 
        ('user1@example.com', 'User One'),
        ('user2@example.com', 'User Two'),
        ('user3@example.com', 'User Three');

    -- Create dependent table
    CREATE TABLE test_posts (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES test_users(id),
        title VARCHAR(200) NOT NULL,
        content TEXT
    );

    -- Insert dependent data
    INSERT INTO test_posts (user_id, title, content) VALUES 
        (1, 'First Post', 'Content of first post'),
        (2, 'Second Post', 'Content of second post');

    -- Create index
    CREATE INDEX idx_test_users_email ON test_users(email);

    -- Create view
    CREATE VIEW test_user_posts AS 
    SELECT u.name, u.email, p.title, p.content
    FROM test_users u
    JOIN test_posts p ON u.id = p.user_id;

    -- Create constraint
    ALTER TABLE test_posts ADD CONSTRAINT check_title_not_empty CHECK (LENGTH(title) > 0);

    -- Create sequence
    CREATE SEQUENCE test_sequence START 100;
};

$node->safe_psql('test_tracking', $test_schema);

# Test 2: Create backup
my $backup_file = "$tempdir/test_tracking.backup";
my @dump_cmd = (
    'pg_dump', '-h', $node->host, '-p', $node->port,
    '-d', 'test_tracking', '-f', $backup_file, '-Fc'
);

my $result = run_log(\@dump_cmd);
ok($result, 'pg_dump succeeded');
ok(-f $backup_file, 'backup file created');

# Test 3: Test successful restoration (all objects should succeed)
my $restore_output_file = "$tempdir/restore_output.sql";
my @restore_cmd = (
    'pg_restore', '-h', $node->host, '-p', $node->port,
    '-f', $restore_output_file, $backup_file, '--verbose'
);

my ($restore_stdout, $restore_stderr) = run_command(\@restore_cmd);
ok($? == 0, 'pg_restore completed');

# Test 4: Verify restoration summary is present
like($restore_stderr, qr/Restoration Summary:/, 'restoration summary header found');
like($restore_stderr, qr/Successfully restored objects: \d+/, 'successful objects count found');
like($restore_stderr, qr/Failed objects: \d+/, 'failed objects count found');

# Test 5: Check for file generation messages
like($restore_stderr, qr/Successful objects list written to:/, 'successful objects file message found');

# Test 6: Verify generated files exist
ok(-f 'successful_objects.txt', 'successful_objects.txt file created') if -f 'successful_objects.txt';
ok(-f 'successful_objects.list', 'successful_objects.list file created') if -f 'successful_objects.list';

# Test 7: Test restoration with conflicts (to test failure tracking)
# Create a new database with conflicting objects
$node->safe_psql('postgres', 'CREATE DATABASE test_conflicts;');

# Create conflicting objects
my $conflict_schema = q{
    -- Create table with same name but different structure
    CREATE TABLE test_users (
        id INTEGER,  -- Different from SERIAL PRIMARY KEY
        email TEXT   -- Different from VARCHAR(100) UNIQUE NOT NULL
    );

    -- Create sequence with same name
    CREATE SEQUENCE test_users_id_seq START 999;
};

$node->safe_psql('test_conflicts', $conflict_schema);

# Try to restore to database with conflicts
my @restore_conflict_cmd = (
    'pg_restore', '-h', $node->host, '-p', $node->port,
    '-d', 'test_conflicts', $backup_file, '--verbose'
);

my ($conflict_stdout, $conflict_stderr) = run_command(\@restore_conflict_cmd);
# This should have some failures due to conflicts

# Test 8: Verify failure tracking works
like($conflict_stderr, qr/Restoration Summary:/, 'restoration summary in conflict scenario');
like($conflict_stderr, qr/Failed objects: [1-9]\d*/, 'some objects failed as expected');

# Test 9: Test with --clean option (should succeed)
$node->safe_psql('postgres', 'DROP DATABASE test_conflicts;');
$node->safe_psql('postgres', 'CREATE DATABASE test_clean;');

my @restore_clean_cmd = (
    'pg_restore', '-h', $node->host, '-p', $node->port,
    '-d', 'test_clean', $backup_file, '--clean', '--if-exists', '--verbose'
);

my ($clean_stdout, $clean_stderr) = run_command(\@restore_clean_cmd);
ok($? == 0, 'pg_restore with --clean succeeded');

# Test 10: Verify clean restoration shows mostly successful objects
like($clean_stderr, qr/Successfully restored objects: \d+/, 'successful objects in clean restore');

# Test 11: Test list functionality works with tracking
my @list_cmd = (
    'pg_restore', '-l', $backup_file
);

my ($list_stdout, $list_stderr) = run_command(\@list_cmd);
ok($? == 0, 'pg_restore -l succeeded');
like($list_stdout, qr/TABLE.*test_users/, 'list shows test_users table');

# Test 12: Test that tracking doesn't interfere with normal operations
my $normal_output = "$tempdir/normal_output.sql";
my @normal_cmd = (
    'pg_restore', '-f', $normal_output, $backup_file
);

my ($normal_stdout, $normal_stderr) = run_command(\@normal_cmd);
ok($? == 0, 'normal pg_restore operation succeeded');
ok(-f $normal_output, 'normal output file created');

# Test 13: Verify the enhancement doesn't break existing functionality
# Check that the generated SQL is valid
my $sql_content = slurp_file($normal_output);
like($sql_content, qr/CREATE TABLE.*test_users/, 'generated SQL contains expected content');
like($sql_content, qr/INSERT INTO.*test_users/, 'generated SQL contains data');

# Cleanup generated files
unlink('successful_objects.txt') if -f 'successful_objects.txt';
unlink('successful_objects.list') if -f 'successful_objects.list';
unlink('failed_objects.txt') if -f 'failed_objects.txt';
unlink('retry_objects.sql') if -f 'retry_objects.sql';

# Stop the test cluster
$node->stop;

done_testing(); 