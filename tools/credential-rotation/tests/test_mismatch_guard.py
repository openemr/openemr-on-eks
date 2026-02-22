from credential_rotation.efs_editor import parse_sqlconf


def test_mismatch_detection():
    """Verify that sqlconf parsing detects when credentials don't match a slot."""
    sqlconf_content = """\
<?php
$host = 'db.example.com';
$port = '3306';
$login = 'openemr_a';
$pass  = 'password_a';
$dbase = 'openemr';
"""
    parsed = parse_sqlconf(sqlconf_content)

    slot_a = {"host": "db.example.com", "port": "3306", "username": "openemr_a", "password": "password_a", "dbname": "openemr"}
    slot_b = {"host": "db.example.com", "port": "3306", "username": "openemr_b", "password": "password_b", "dbname": "openemr"}

    def matches(slot, conf):
        return (
            conf.get("host") == slot["host"]
            and conf.get("username") == slot["username"]
            and conf.get("password") == slot["password"]
        )

    assert matches(slot_a, parsed) is True
    assert matches(slot_b, parsed) is False
