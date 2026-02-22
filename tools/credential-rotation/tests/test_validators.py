from unittest.mock import patch, MagicMock

from credential_rotation.validators import validate_openemr_health


@patch("credential_rotation.validators.requests")
def test_health_check_skipped_when_url_is_none(mock_requests):
    validate_openemr_health(None)
    mock_requests.get.assert_not_called()


@patch("credential_rotation.validators.requests")
def test_health_check_succeeds_on_200(mock_requests):
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_requests.get.return_value = mock_response

    validate_openemr_health("http://openemr.local/interface/login/login.php")
    mock_requests.get.assert_called_once()


@patch("credential_rotation.validators.requests")
def test_health_check_survives_network_error(mock_requests):
    mock_requests.get.side_effect = ConnectionError("unreachable")
    validate_openemr_health("http://openemr.local/interface/login/login.php")
