"""
Setup configuration for Warp
"""

from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as fh:
    long_description = fh.read()

setup(
    name="warp",
    version="0.1.2",
    author="OpenEMR on EKS",
    description="Warp - OpenEMR Data Upload Accelerator",
    long_description=long_description,
    long_description_content_type="text/markdown",
    packages=find_packages(),
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Healthcare Industry",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Programming Language :: Python :: 3.14",
    ],
    python_requires=">=3.8",
    install_requires=[
        "pymysql==1.1.2",  # Pinned to match versions.yaml
        "boto3==1.42.21",   # Pinned to match versions.yaml
    ],
    entry_points={
        "console_scripts": [
            "warp=warp.cli:main",
        ],
    },
)

