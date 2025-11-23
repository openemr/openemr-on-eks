# Warp Developer Guide

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Code Structure](#code-structure)
- [Adding New Commands](#adding-new-commands)
- [Database Schema Details](#database-schema-details)
- [OMOP to CCDA Conversion](#omop-to-ccda-conversion)
- [Performance Optimization](#performance-optimization)
- [Testing](#testing)
- [Contributing](#contributing)

## Architecture Overview

Warp uses a modular architecture with clear separation of concerns:

```
warp/
├── cli.py                      # CLI entry point and argument parsing
├── commands/                   # Command implementations
│   └── ccda_data_upload.py     # CCDA data upload command
└── core/                       # Core functionality
    ├── omop_to_ccda.py         # OMOP CDM data loader (for reference)
    ├── db_importer.py          # Direct database import
    ├── uploader.py             # Parallel processing coordinator
    └── credential_discovery.py # Auto-discovery of database credentials
```

### Key Components

1. **CLI (`cli.py`)**: Entry point, argument parsing, command routing
2. **Commands (`commands/`)**: High-level command implementations
3. **Core Modules (`core/`)**: Reusable core functionality
4. **DB Importer (`db_importer.py`)**: Direct database writes (only method)
5. **Uploader (`uploader.py`)**: Parallel processing coordinator
6. **Credential Discovery (`credential_discovery.py`)**: Auto-discovery of database credentials

### Kubernetes Deployment Architecture

Warp uses a **build-inside-pod** architecture for Kubernetes deployments:

**Design Decision**: Instead of building and maintaining custom Docker images, warp uses:
- **Base Image**: `python:3.14-slim` (off-the-shelf, maintained by Python team)
- **Code Distribution**: Kubernetes ConfigMap containing a tarball of warp code
- **Build Process**: Code is extracted and installed inside the pod at runtime

**Benefits**:
- No custom Docker image maintenance
- No container registry dependencies
- Easy code updates (just update ConfigMap)
- Works with private repositories (no git clone needed)
- Uses latest Python 3.14 features

**Process Flow**:
1. Warp code is packaged: `tar czf warp-code.tar.gz warp/ setup.py requirements.txt README.md`
2. ConfigMap created: `kubectl create configmap warp-code --from-file=warp-code.tar.gz=...`
3. Job pod starts with `python:3.14-slim` image
4. Pod extracts code from ConfigMap volume
5. Pod installs dependencies and warp package
6. Warp executes with direct database access

This architecture is documented in `k8s-job-test.yaml` and is the recommended approach for production deployments.

## Code Structure

### Command Pattern

Commands follow a consistent pattern:

```python
class CCDADataUploadCommand:
    """Command for uploading CCDA data to OpenEMR"""
    
    @staticmethod
    def add_arguments(parser):
        """Add command-specific arguments"""
        parser.add_argument('--data-source', required=True)
        # ... more arguments
    
    def execute(self, args):
        """Execute the command"""
        # 1. Discover database credentials
        # 2. Initialize database importer
        # 3. Initialize converter (for data loading)
        # 4. Initialize uploader
        # 5. Process and upload
        # 6. Return exit code
```

### Core Module Pattern

Core modules provide reusable functionality:

```python
class OpenEMRDBImporter:
    """Direct database importer for OpenEMR"""
    
    def __init__(self, db_host, db_user, db_password, db_name):
        """Initialize with database credentials"""
    
    def connect(self) -> bool:
        """Establish database connection"""
    
    def import_patient(self, person_data, conditions, medications, observations):
        """Import a patient directly into OpenEMR database"""
```

## Adding New Commands

### Step 1: Create Command File

Create `warp/commands/new_command.py`:

```python
"""New command implementation"""

import argparse
import logging
from warp.core.credential_discovery import CredentialDiscovery

logger = logging.getLogger(__name__)


class NewCommand:
    """Description of the new command"""
    
    @staticmethod
    def add_arguments(parser):
        """Add command-specific arguments"""
        parser.add_argument(
            '--option',
            help='Description of option'
        )
    
    def execute(self, args):
        """Execute the command"""
        try:
            # Command implementation
            logger.info("Executing new command...")
            # ...
            return 0
        except Exception as e:
            logger.error(f"Command failed: {e}")
            return 1
```

### Step 2: Register Command

Add to `warp/cli.py`:

```python
from warp.commands.new_command import NewCommand

# In main() function:
if args.command == 'new_command':
    command = NewCommand()
    exit_code = command.execute(args)
    sys.exit(exit_code or 0)
```

### Step 3: Add Tests

Create `tests/test_new_command.py`:

```python
import unittest
from warp.commands.new_command import NewCommand

class TestNewCommand(unittest.TestCase):
    def test_execute_success(self):
        # Test implementation
        pass
```

## Database Schema Details

### Patient Data Table

Warp writes to `patient_data` table matching OpenEMR's structure:

```sql
CREATE TABLE patient_data (
    uuid BINARY(16) PRIMARY KEY,
    pid INT AUTO_INCREMENT UNIQUE,
    title VARCHAR(255),
    fname VARCHAR(255),
    lname VARCHAR(255),
    mname VARCHAR(255),
    sex VARCHAR(255),
    DOB DATE,
    street VARCHAR(255),
    postal_code VARCHAR(255),
    city VARCHAR(255),
    state VARCHAR(255),
    country_code VARCHAR(255),
    phone_home VARCHAR(255),
    phone_biz VARCHAR(255),
    phone_contact VARCHAR(255),
    phone_cell VARCHAR(255),
    status VARCHAR(255),
    date DATETIME,
    regdate DATE,
    pubpid VARCHAR(255),
    language VARCHAR(255),
    financial VARCHAR(255),
    pricelevel VARCHAR(255)
);
```

### Lists Table (Conditions/Medications)

Conditions and medications are stored in `lists` table:

```sql
CREATE TABLE lists (
    id INT AUTO_INCREMENT PRIMARY KEY,
    pid INT,
    type VARCHAR(255),
    title VARCHAR(255),
    begdate DATE,
    enddate DATE,
    diagnosis VARCHAR(255),
    activity TINYINT
);
```

### Field Mapping

| OMOP Field | OpenEMR Field | Notes |
|------------|---------------|-------|
| person_id | pid | Auto-generated, unique |
| gender_concept_id | sex | Mapped: 8507→M, 8532→F |
| year_of_birth | DOB | Combined with month/day |
| condition_concept_id | diagnosis | Stored in lists table |
| drug_concept_id | diagnosis | Stored in lists table |

## OMOP to CCDA Conversion

The `OMOPToCCDAConverter` class converts OMOP CDM format to CCDA XML:

### Conversion Process

1. **Load OMOP Data**: Reads PERSON, CONDITION_OCCURRENCE, DRUG_EXPOSURE, OBSERVATION tables
2. **Map Fields**: Converts OMOP field names to CCDA structure
3. **Generate XML**: Creates CCDA-compliant XML document
4. **Format Dates**: Converts dates to HL7 format (YYYYMMDD)

### Key Methods

```python
class OMOPToCCDAConverter:
    def load_data(self, max_records=None, start_from=0):
        """Load OMOP data from source"""
    
    def convert_to_ccda(self, person_data, conditions, observations, medications):
        """Convert OMOP data to CCDA XML"""
    
    def _map_gender(self, gender_concept_id):
        """Map OMOP gender concept ID to HL7 gender code"""
    
    def _format_date(self, date_str):
        """Format date to HL7 format (YYYYMMDD)"""
```

## Performance Optimization

### Batch Processing

Warp processes records in batches for optimal performance:

```python
# Optimal batch size calculation
def _calculate_optimal_batch_size(self):
    """Calculate optimal batch size based on available resources"""
    cpu_count = os.cpu_count() or 1
    memory_gb = psutil.virtual_memory().total / (1024**3)
    
    # Batch size based on CPU and memory
    batch_size = min(cpu_count * 50, int(memory_gb * 10))
    return max(100, min(batch_size, 1000))  # Clamp between 100-1000
```

### Parallel Processing

Uses `ThreadPoolExecutor` for parallel processing:

```python
with ThreadPoolExecutor(max_workers=self.workers) as executor:
    futures = []
    for i in range(0, total_records, self.batch_size):
        batch = data['persons'][i:i + self.batch_size]
        future = executor.submit(self._process_batch, batch, data, dry_run)
        futures.append(future)
    
    # Collect results
    for future in as_completed(futures):
        batch_stats = future.result()
        # Aggregate statistics
```

### Database Connection Pooling

Uses connection pooling for efficient database access:

```python
self.connection = pymysql.connect(
    host=self.db_host,
    user=self.db_user,
    password=self.db_password,
    database=self.db_name,
    charset='utf8mb4',
    cursorclass=pymysql.cursors.DictCursor,
    autocommit=False  # Use transactions
)
```

## Testing

### Test Structure

```
tests/
├── test_omop_to_ccda.py       # Converter/data loader tests
├── test_uploader.py           # Uploader tests
└── benchmarks/
    └── test_performance.py    # Performance benchmarks
```

### Running Tests

```bash
# All tests
pytest tests/ -v

# With coverage
pytest tests/ -v --cov=warp --cov-report=html

# Specific test
pytest tests/test_omop_to_ccda.py::TestOMOPToCCDAConverter::test_convert_to_ccda -v

# Benchmarks (requires pytest-benchmark)
pytest tests/benchmarks/ --benchmark-only
```

### Writing Tests

Follow unittest pattern:

```python
import unittest
from unittest.mock import Mock, patch
from warp.core.module import ClassName

class TestClassName(unittest.TestCase):
    def setUp(self):
        """Set up test fixtures"""
        self.instance = ClassName(...)
    
    def test_method(self):
        """Test specific method"""
        result = self.instance.method()
        self.assertEqual(result, expected_value)
```

## Contributing

### Development Workflow

1. **Fork and Clone**: Fork the repository and clone locally
2. **Create Branch**: Create a feature branch (`git checkout -b feature/new-feature`)
3. **Make Changes**: Implement your changes with tests
4. **Run Tests**: Ensure all tests pass (`pytest tests/`)
5. **Code Quality**: Run linting and formatting (`flake8`, `black`)
6. **Commit**: Commit with descriptive messages
7. **Push**: Push to your fork
8. **Pull Request**: Create a pull request

### Code Style

- **Formatting**: Use `black` with line length 127
- **Linting**: Follow `flake8` rules (E203 ignored for black compatibility)
- **Type Hints**: Use type hints where possible
- **Docstrings**: Include docstrings for all public functions/classes

### Performance Guidelines

- Use parallel processing where possible
- Batch operations for efficiency
- Cache data when appropriate
- Direct database/filesystem writes only (no API overhead)

### Testing Requirements

- Unit tests for all core functionality
- Integration tests for end-to-end flows
- Performance benchmarks for critical paths
- Maintain or improve code coverage

## License

MIT License
