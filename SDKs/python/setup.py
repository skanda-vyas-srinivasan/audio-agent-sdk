"""Legacy editable-install shim for the system Python 3.9 pip on macOS."""

from setuptools import find_packages, setup

setup(
    name="sonexis",
    version="0.2.0",
    description="Async Python client for the local Sonexis audio Runtime",
    package_dir={"": "src"},
    packages=find_packages("src"),
    package_data={"sonexis": ["py.typed"]},
    python_requires=">=3.9",
)
