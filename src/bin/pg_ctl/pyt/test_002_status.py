# Copyright (c) 2021-2026, PostgreSQL Global Development Group

"""Port of src/bin/pg_ctl/t/002_status.pl."""

from pypg.bins import pg_ctl


def test_status_nonexistent_directory(tmp_path):
    pg_ctl.check_all("status", "--pgdata", tmp_path / "nonexistent", exit_code=4)


def test_status_tracks_server_state(create_pg):
    node = create_pg("ctlstatus", start=False)
    pg_ctl.check_all("status", "--pgdata", node.datadir, exit_code=3)

    node.start()
    pg_ctl("status", "--pgdata", node.datadir)

    node.stop()
