"""
Unit tests for uploader
"""

import unittest
from unittest.mock import Mock
from warp.core.uploader import Uploader
from warp.core.db_importer import OpenEMRDBImporter


class TestUploader(unittest.TestCase):
    """Test uploader functionality"""
    
    def setUp(self):
        """Set up test fixtures"""
        self.converter = Mock()
        self.db_importer = Mock(spec=OpenEMRDBImporter)
        
        self.uploader = Uploader(
            converter=self.converter,
            db_importer=self.db_importer,
            batch_size=10,
            workers=2
        )
    
    def test_initialization(self):
        """Test uploader initialization"""
        self.assertEqual(self.uploader.batch_size, 10)
        self.assertEqual(self.uploader.workers, 2)
    
    def test_process_and_upload_dry_run(self):
        """Test parallel processing in dry run mode"""
        # Mock data
        self.converter.load_data.return_value = {
            'persons': [{'person_id': str(i)} for i in range(5)],
            'conditions': [],
            'medications': [],
            'observations': []
        }
        
        # Run in dry run mode
        stats = self.uploader.process_and_upload(max_records=5, dry_run=True)
        
        # Verify stats
        self.assertEqual(stats['processed'], 5)
        self.assertEqual(stats['uploaded'], 5)
        self.assertEqual(stats['failed'], 0)
        self.assertIn('duration', stats)


if __name__ == '__main__':
    unittest.main()

