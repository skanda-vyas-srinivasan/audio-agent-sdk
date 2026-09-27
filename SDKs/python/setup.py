"""Legacy editable-install shim for the system Python 3.9 pip on macOS."""

from setuptools import find_packages, setup

setup(
    name="sonexis",
    version="0.6.0",
    description="Source-aware bidirectional Python SDK for the local Sonexis audio Runtime",
    url="https://github.com/skanda-vyas-srinivasan/Sonexis",
    license="GPL-2.0-or-later",
    package_dir={"": "src"},
    packages=find_packages("src"),
    package_data={"sonexis": ["py.typed"]},
    license_files=["LICENSE"],
    python_requires=">=3.9",
    extras_require={
        "openai": ["openai[realtime]>=2; python_version >= '3.10'"],
        "gemini": ["google-genai>=1; python_version >= '3.10'"],
        "mcp": ["mcp>=2,<3; python_version >= '3.10'"],
        "ai": [
            "openai[realtime]>=2; python_version >= '3.10'",
            "google-genai>=1; python_version >= '3.10'",
        ],
    },
)
