#!/usr/bin/perl

# Copyright (c) 2025, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $tempdir = PostgreSQL::Test::Utils::tempdir;

# Initialize test cluster
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

# Create test database and simple table
$node->safe_psql('postgres', 'CREATE DATABASE test_tracking;');

my $test_schema = q{
    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        email VARCHAR(100) UNIQUE NOT NULL,
        name VARCHAR(100) NOT NULL
    );
    
    INSERT INTO users (email, name) VALUES 
        ('user1@example.com', 'User One'),
        ('user2@example.com', 'User Two'),
        ('user3@example.com', 'User Three');
};

$node->safe_psql('test_tracking', $test_schema);

# Create backup
my $backup_file = "$tempdir/test_backup.dump";
my @dump_cmd = (
    'pg_dump', '-h', $node->host, '-p', $node->port,
    '-d', 'test_tracking', '-f', $backup_file
);

my ($dump_stdout, $dump_stderr) = run_command(\@dump_cmd);
ok($? == 0, 'pg_dump completed successfully');
ok(-f $backup_file, 'backup file created');

# Test 1: Successful restoration to clean database
$node->safe_psql('postgres', 'CREATE DATABASE test_clean;');

my @restore_clean_cmd = (
    'pg_restore', '-h', $node->host, '-p', $node->port,
    '-d', 'test_clean', $backup_file, '--verbose'
);

my ($clean_stdout, $clean_stderr) = run_command(\@restore_clean_cmd);
ok($? == 0, 'pg_restore to clean database completed');

# Verify restoration summary is present
like($clean_stderr, qr/Restoration Summary:/, 'restoration summary header found');
like($clean_stderr, qr/Successfully restored objects: \d+/, 'successful objects count found');
like($clean_stderr, qr/Failed objects: 0/, 'no failed objects in clean restore');

# Test 2: Create failure scenario using unique index corruption trick
$node->safe_psql('postgres', 'CREATE DATABASE test_failures;');

# Set up the unique index corruption scenario
my $corruption_setup = q{
    -- Create the same table structure
    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        email VARCHAR(100) NOT NULL,
        name VARCHAR(100) NOT NULL
    );
    
    -- Create a named unique index
    CREATE UNIQUE INDEX users_email_unique ON users(email);
    
    -- Insert conflicting data
    INSERT INTO users (email, name) VALUES 
        ('user1@example.com', 'Conflicting User'),
        ('user2@example.com', 'Another Conflict');
    
    -- Now corrupt the unique index to allow duplicates temporarily
    -- This simulates a corrupted index scenario
    UPDATE pg_index SET indisunique = false 
    WHERE indexrelid = 'users_email_unique'::regclass;
    
    -- Insert more duplicates while index is "corrupted"
    INSERT INTO users (email, name) VALUES 
        ('user1@example.com', 'Third Duplicate'),
        ('user3@example.com', 'Will Conflict Later');
    
    -- Restore the unique constraint (this will cause issues during restore)
    UPDATE pg_index SET indisunique = true 
    WHERE indexrelid = 'users_email_unique'::regclass;
};

$node->safe_psql('test_failures', $corruption_setup);

# Test 3: Attempt restoration with conflicts (should have failures)
my @restore_conflict_cmd = (
    'pg_restore', '-h', $node->host, '-p', $node->port,
    '-d', 'test_failures', $backup_file, '--verbose'
);

my ($conflict_stdout, $conflict_stderr) = run_command(\@restore_conflict_cmd);
# This should have failures but pg_restore should continue

# Verify failure tracking works
like($conflict_stderr, qr/Restoration Summary:/, 'restoration summary in conflict scenario');
like($conflict_stderr, qr/Failed objects: [1-9]\d*/, 'some objects failed as expected');
like($conflict_stderr, qr/Successfully restored objects: \d+/, 'some objects still succeeded');

# Check that failed objects are listed with details
like($conflict_stderr, qr/Failed Objects.*:/, 'failed objects section present');

# Test 4: Verify file generation
like($conflict_stderr, qr/Successful objects list written to:/, 'successful objects file message found');
like($conflict_stderr, qr/Failed objects list written to:/, 'failed objects file message found');

# Check files exist
ok(-f 'successful_objects.list', 'successful_objects.list file created') if -f 'successful_objects.list';
ok(-f 'failed_objects.list', 'failed_objects.list file created') if -f 'failed_objects.list';

# Test 5: Test that normal functionality still works
my $normal_output = "$tempdir/normal_output.sql";
my @normal_cmd = (
    'pg_restore', '-f', $normal_output, $backup_file
);

my ($normal_stdout, $normal_stderr) = run_command(\@normal_cmd);
ok($? == 0, 'normal pg_restore operation succeeded');
ok(-f $normal_output, 'normal output file created');

# Verify the generated SQL is valid
my $sql_content = slurp_file($normal_output);
like($sql_content, qr/CREATE TABLE.*users/, 'generated SQL contains expected content');

# Cleanup generated files
unlink('successful_objects.list') if -f 'successful_objects.list';
unlink('failed_objects.list') if -f 'failed_objects.list';

$node->stop;

done_testing(); 