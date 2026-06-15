# Test concurrent function stats drops.
#
# A CALL can resolve a procedure OID, then observe invalidations after a
# concurrent DROP PROCEDURE commits.  With track_functions enabled this creates
# a function stats entry for the already-dropped OID and immediately drops it.
# If another backend keeps a local reference to that stats entry, the DROP
# transaction's post-commit stats cleanup used to ERROR while in COMMIT state.

setup
{
	CREATE EXTENSION injection_points;
	CREATE FUNCTION wait_for_injection_point(appname text, event text)
	RETURNS void LANGUAGE plpgsql AS $$
	DECLARE
		stop_at timestamptz := clock_timestamp() + interval '10 seconds';
	BEGIN
		LOOP
			IF EXISTS (
				SELECT FROM pg_stat_activity
				WHERE application_name = appname
				  AND wait_event_type = 'InjectionPoint'
				  AND wait_event = event
			) THEN
				RETURN;
			END IF;

			IF clock_timestamp() > stop_at THEN
				RAISE EXCEPTION 'timed out waiting for % at injection point %',
					appname, event;
			END IF;

			PERFORM pg_sleep(0.01);
		END LOOP;
	END
	$$;
	CREATE PROCEDURE proc_test() LANGUAGE plpgsql AS $$ BEGIN END $$;
	CREATE TABLE proc_test_oid AS
		SELECT 'proc_test()'::regprocedure::oid AS oid;
}

teardown
{
	DROP TABLE proc_test_oid;
	DROP FUNCTION wait_for_injection_point(text, text);
	DROP EXTENSION injection_points;
}

session call_s
setup
{
	SET application_name = 'function-stats-drop-call';
	SET track_functions = 'all';
	SELECT FROM injection_points_set_local();
	SELECT FROM injection_points_attach('function-call-before-pgstat-init', 'wait');
	SELECT FROM injection_points_attach('function-call-before-dropped-stats-drop', 'wait');
}
step call_proc	{ CALL proc_test(); }

session drop_s
setup
{
	SET application_name = 'function-stats-drop-drop';
	SELECT FROM injection_points_set_local();
	SELECT FROM injection_points_attach('pgstat-before-drop-function-stats', 'wait');
}
step drop_proc	{ DROP PROCEDURE proc_test(); }

# Hold a local reference to the transient function stats entry.
session stats_s
step fetch_stats	{
	SELECT pg_stat_get_function_calls(oid) FROM proc_test_oid;
}

session ctl_s
step wait_drop_stop	{
	SELECT wait_for_injection_point(
		'function-stats-drop-drop',
		'pgstat-before-drop-function-stats');
}
step wake_call_start	{
	SELECT FROM injection_points_wakeup('function-call-before-pgstat-init');
}
step wait_call_drop_stop	{
	SELECT wait_for_injection_point(
		'function-stats-drop-call',
		'function-call-before-dropped-stats-drop');
}
step wake_call_drop	{
	SELECT FROM injection_points_wakeup('function-call-before-dropped-stats-drop');
}
step wake_drop	{
	SELECT FROM injection_points_wakeup('pgstat-before-drop-function-stats');
}

permutation
	call_proc
	drop_proc
	wait_drop_stop
	wake_call_start
	wait_call_drop_stop
	fetch_stats
	wake_call_drop
	wake_drop