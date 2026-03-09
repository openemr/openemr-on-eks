"""Tests for warp/cli.py — CLI entry point, argument parsing, error handling."""

import logging
from unittest.mock import patch, MagicMock

import pytest

from warp.cli import main


class TestMainNoCommand:
    @patch("sys.argv", ["warp"])
    def test_no_command_exits_with_1(self):
        with pytest.raises(SystemExit) as exc:
            main()
        assert exc.value.code == 1


class TestMainCCDACommand:
    """Tests that mock CCDADataUploadCommand but let argparse register its real arguments."""

    def _run_main(self, execute_return=0, execute_side_effect=None, verbose=False):
        """Run main() with real argument parsing but a mocked execute()."""
        argv = ["warp"]
        if verbose:
            argv.append("-v")
        argv.extend(["ccda_data_upload", "--data-source", "/tmp/data", "--dry-run"])

        mock_instance = MagicMock()
        if execute_side_effect:
            mock_instance.execute.side_effect = execute_side_effect
        else:
            mock_instance.execute.return_value = execute_return

        with patch("sys.argv", argv), patch("warp.cli.CCDADataUploadCommand") as mock_cls:
            mock_cls.add_arguments = MagicMock(side_effect=lambda p: p.add_argument("--data-source"), wraps=None)
            mock_cls.add_arguments = lambda parser: __import__(
                "warp.commands.ccda_data_upload", fromlist=["CCDADataUploadCommand"]
            ).CCDADataUploadCommand.add_arguments(parser)
            mock_cls.return_value = mock_instance

            with pytest.raises(SystemExit) as exc:
                main()
            return exc.value.code, mock_instance

    def test_dispatches_to_ccda_command(self):
        code, mock_inst = self._run_main(execute_return=0)
        assert code == 0
        mock_inst.execute.assert_called_once()

    def test_nonzero_exit_code_forwarded(self):
        code, _ = self._run_main(execute_return=1)
        assert code == 1

    def test_none_return_maps_to_exit_0(self):
        code, _ = self._run_main(execute_return=None)
        assert code == 0

    def test_keyboard_interrupt_exits_130(self):
        code, _ = self._run_main(execute_side_effect=KeyboardInterrupt())
        assert code == 130

    def test_exception_exits_1(self):
        code, _ = self._run_main(execute_side_effect=RuntimeError("boom"))
        assert code == 1


class TestVerboseFlag:
    def test_verbose_enables_debug(self):
        mock_instance = MagicMock()
        mock_instance.execute.return_value = 0
        root_logger = logging.getLogger()
        original_level = root_logger.level

        try:
            with patch("sys.argv", ["warp", "-v", "ccda_data_upload", "--data-source", "/tmp/d", "--dry-run"]), patch(
                "warp.cli.CCDADataUploadCommand"
            ) as mock_cls:
                from warp.commands.ccda_data_upload import CCDADataUploadCommand as RealCmd

                mock_cls.add_arguments = RealCmd.add_arguments
                mock_cls.return_value = mock_instance

                with pytest.raises(SystemExit):
                    main()

            assert root_logger.level == logging.DEBUG
        finally:
            root_logger.setLevel(original_level)
