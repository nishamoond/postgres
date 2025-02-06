# Copyright (c) 2025, PostgreSQL Global Development Group

# Test for replication slots invalidation due to idle_timeout
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Utils;
use PostgreSQL::Test::Cluster;
use Test::More;

# This test depends on injection point that forces slot invalidation
# due to idle_timeout. Enabling injections points requires
# --enable-injection-points with configure or
# -Dinjection_points=true with Meson.
if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

# Wait for slot to first become idle and then get invalidated
sub wait_for_slot_invalidation
{
	my ($node, $slot_name, $offset) = @_;
	my $node_name = $node->name;

	# The slot's invalidation should be logged
	$node->wait_for_log(
		qr/invalidating obsolete replication slot \"$slot_name\"/, $offset);

	# Check that the invalidation reason is 'idle_timeout'
	$node->poll_query_until(
		'postgres', qq[
		SELECT COUNT(slot_name) = 1 FROM pg_replication_slots
			WHERE slot_name = '$slot_name' AND
			invalidation_reason = 'idle_timeout';
	])
	  or die
	  "Timed out while waiting for invalidation reason of slot $slot_name to be set on node $node_name";
}

# ========================================================================
# Testcase start
#
# Test invalidation of streaming standby slot and logical slot due to idle
# timeout.

# Initialize the node
my $node = PostgreSQL::Test::Cluster->new('node');
$node->init(allows_streaming => 'logical');

# Avoid unpredictability
$node->append_conf(
	'postgresql.conf', qq{
checkpoint_timeout = 1h
idle_replication_slot_timeout = 1min
});
$node->start;

# Create both streaming standby and logical slot
$node->safe_psql(
	'postgres', qq[
    SELECT pg_create_physical_replication_slot(slot_name := 'physical_slot', immediately_reserve := true);
]);
$node->safe_psql('postgres',
	q{SELECT pg_create_logical_replication_slot('logical_slot', 'test_decoding');}
);

my $log_offset = -s $node->logfile;

# Register an injection point on the node to forcibly cause a slot
# invalidation due to idle_timeout
$node->safe_psql('postgres', 'CREATE EXTENSION injection_points;');

# Check if the 'injection_points' extension is available, as it may be
# possible that this script is run with installcheck, where the module
# would not be installed by default.
if (!$node->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node->safe_psql('postgres',
	"SELECT injection_points_attach('slot-timeout-inval', 'error');");

# Idle timeout slot invalidation occurs during a checkpoint, so run a
# checkpoint to invalidate the slots.
$node->safe_psql('postgres', "CHECKPOINT");

# Wait for slots to become inactive. Note that since nobody has acquired the
# slot yet, then if it has been invalidated that can only be due to the idle
# timeout mechanism.
wait_for_slot_invalidation($node, 'physical_slot', $log_offset);
wait_for_slot_invalidation($node, 'logical_slot', $log_offset);

# Check that the invalidated slot cannot be acquired
my $node_name = $node->name;
my ($result, $stdout, $stderr);
($result, $stdout, $stderr) = $node->psql(
	'postgres', qq[
		SELECT pg_replication_slot_advance('logical_slot', '0/1');
]);
ok( $stderr =~ /can no longer access replication slot "logical_slot"/,
	"detected error upon trying to acquire invalidated slot on node")
  or die
  "could not detect error upon trying to acquire invalidated slot \"logical_slot\" on node";

# Testcase end
# =============================================================================

done_testing();
