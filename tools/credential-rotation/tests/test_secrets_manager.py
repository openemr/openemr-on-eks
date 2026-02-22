import string

import pytest

from credential_rotation.secrets_manager import SecretsManagerSlots, SlotSecretState, generate_password


def test_standby_slot_a_returns_b():
    assert SecretsManagerSlots.standby_slot("A") == "B"


def test_standby_slot_b_returns_a():
    assert SecretsManagerSlots.standby_slot("B") == "A"


def test_standby_slot_invalid_raises():
    with pytest.raises(ValueError, match="Invalid active slot"):
        SecretsManagerSlots.standby_slot("C")


def test_slot_secret_state_active_slot():
    state = SlotSecretState(secret_arn="arn:test", payload={"active_slot": "A", "A": {}, "B": {}})
    assert state.active_slot == "A"


def test_slot_secret_state_invalid_active_slot():
    state = SlotSecretState(secret_arn="arn:test", payload={"active_slot": "X"})
    with pytest.raises(ValueError, match="Invalid or missing active_slot"):
        _ = state.active_slot


def test_slot_secret_state_missing_slot():
    state = SlotSecretState(secret_arn="arn:test", payload={"active_slot": "A"})
    with pytest.raises(ValueError, match="Slot A missing"):
        state.slot("A")


def test_slot_secret_state_returns_slot_data():
    data = {"username": "openemr_a", "password": "pass"}
    state = SlotSecretState(secret_arn="arn:test", payload={"active_slot": "A", "A": data, "B": {}})
    assert state.slot("A") == data


def test_generate_password_length():
    pw = generate_password(40)
    assert len(pw) == 40


def test_generate_password_characters():
    pw = generate_password()
    allowed = set(string.ascii_letters + string.digits)
    assert all(c in allowed for c in pw)


def test_generate_password_uniqueness():
    passwords = {generate_password() for _ in range(50)}
    assert len(passwords) == 50
