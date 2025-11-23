"""
Performance benchmarks for Warp operations
"""

import pytest
import tempfile
import os

# Skip benchmarks if pytest-benchmark is not installed
try:
    import pytest_benchmark
    BENCHMARK_AVAILABLE = True
except ImportError:
    BENCHMARK_AVAILABLE = False

from warp.core.omop_to_ccda import OMOPToCCDAConverter


@pytest.mark.skipif(not BENCHMARK_AVAILABLE, reason="pytest-benchmark not installed")
@pytest.mark.benchmark
def test_ccda_conversion_speed(benchmark):
    """Benchmark CCDA conversion speed"""
    # Use temporary local path for testing
    temp_dir = tempfile.mkdtemp()
    os.makedirs(temp_dir, exist_ok=True)

    try:
        converter = OMOPToCCDAConverter(
            data_source=temp_dir,
            dataset_size="1k"
        )

        person_data = {
            'person_id': '123',
            'first_name': 'John',
            'last_name': 'Doe',
            'gender_concept_id': '8507',
            'birth_datetime': '1980-01-15 00:00:00'
        }

        result = benchmark(
            converter.convert_to_ccda,
            person_data,
            [],
            [],
            []
        )

        assert 'ClinicalDocument' in result
    finally:
        import shutil
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)


@pytest.mark.skipif(not BENCHMARK_AVAILABLE, reason="pytest-benchmark not installed")
@pytest.mark.benchmark
def test_csv_parsing_speed(benchmark):
    """Benchmark CSV parsing speed"""
    # Use temporary local path for testing
    temp_dir = tempfile.mkdtemp()
    os.makedirs(temp_dir, exist_ok=True)

    try:
        converter = OMOPToCCDAConverter(
            data_source=temp_dir,
            dataset_size="1k"
        )

        csv_content = "person_id,first_name,last_name\n" + \
                      "\n".join([f"{i},Name{i},Last{i}" for i in range(1000)])

        result = benchmark(converter._parse_csv, csv_content)

        assert len(result) == 1000
    finally:
        import shutil
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)

