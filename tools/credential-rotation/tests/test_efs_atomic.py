from credential_rotation.efs_editor import parse_sqlconf, render_sqlconf

_SAMPLE_SQLCONF = """\
<?php
$host = 'old-host.example.com';
$port = '3306';
$login = 'old_user';
$pass  = 'old_pass';
$dbase = 'openemr';
"""


def test_parse_sqlconf():
    parsed = parse_sqlconf(_SAMPLE_SQLCONF)
    assert parsed["host"] == "old-host.example.com"
    assert parsed["port"] == "3306"
    assert parsed["username"] == "old_user"
    assert parsed["password"] == "old_pass"
    assert parsed["dbname"] == "openemr"


def test_render_sqlconf():
    new_slot = {
        "host": "new-host.example.com",
        "port": "3306",
        "username": "openemr_b",
        "password": "new_secret",
        "dbname": "openemr",
    }
    updated = render_sqlconf(_SAMPLE_SQLCONF, new_slot)
    parsed = parse_sqlconf(updated)
    assert parsed["host"] == "new-host.example.com"
    assert parsed["username"] == "openemr_b"
    assert parsed["password"] == "new_secret"
