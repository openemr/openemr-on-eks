"""
Unit tests for OMOP to CCDA converter
"""

import unittest
import tempfile
import os
import shutil
from warp.core.omop_to_ccda import OMOPToCCDAConverter


class TestOMOPToCCDAConverter(unittest.TestCase):
    """Test OMOP to CCDA conversion"""
    
    def setUp(self):
        """Set up test fixtures"""
        # Use a temporary local path for testing (avoids boto3 initialization)
        self.temp_dir = tempfile.mkdtemp()
        # Create a dummy file so the path exists
        os.makedirs(self.temp_dir, exist_ok=True)
        
        # Create converter with local path
        self.converter = OMOPToCCDAConverter(
            data_source=self.temp_dir,
            dataset_size="1k"
        )
    
    def tearDown(self):
        """Clean up test fixtures"""
        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)
    
    def test_parse_csv(self):
        """Test CSV parsing"""
        csv_content = "person_id,first_name,last_name\n1,John,Doe\n2,Jane,Smith"
        result = self.converter._parse_csv(csv_content)
        
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['person_id'], '1')
        self.assertEqual(result[0]['first_name'], 'John')
    
    def test_map_gender(self):
        """Test gender mapping"""
        self.assertEqual(self.converter._map_gender(8507), 'M')
        self.assertEqual(self.converter._map_gender(8532), 'F')
        self.assertEqual(self.converter._map_gender(8570), 'UN')
        self.assertIsNone(self.converter._map_gender(9999))
        # Test with string input (as might come from CSV)
        self.assertEqual(self.converter._map_gender('8507'), 'M')
        self.assertEqual(self.converter._map_gender('8532'), 'F')
    
    def test_format_date(self):
        """Test date formatting"""
        self.assertEqual(self.converter._format_date('2023-01-15'), '20230115')
        self.assertEqual(self.converter._format_date('2023-01-15 10:30:00'), '20230115')
        self.assertEqual(self.converter._format_date('invalid'), '')
    
    def test_format_datetime(self):
        """Test datetime formatting"""
        self.assertEqual(
            self.converter._format_datetime('2023-01-15 10:30:00'),
            '20230115103000'
        )
        self.assertEqual(self.converter._format_datetime('invalid'), '')
    
    def test_convert_to_ccda(self):
        """Test CCDA document creation"""
        # Use OMOP CDM field names that match the converter expectations
        # Converter checks for first_name/last_name fields
        person_data = {
            'person_id': '123',
            'first_name': 'Test',
            'last_name': 'Patient',
            'gender_concept_id': '8507',
            'birth_datetime': '1980-01-15 00:00:00'
        }
        
        ccda_xml = self.converter.convert_to_ccda(
            person_data,
            [],
            [],
            []
        )
        
        self.assertIn('ClinicalDocument', ccda_xml)
        self.assertIn('123', ccda_xml)


if __name__ == '__main__':
    unittest.main()
