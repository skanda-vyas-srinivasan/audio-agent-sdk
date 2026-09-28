"""Legacy editable-install shim for the system Python 3.9 pip on macOS."""

from setuptools import find_packages, setup

setup(
    name="audioplane",
    version="1.0.0",
    description="Source-aware bidirectional audio I/O SDK for macOS",
    author="AudioPlane contributors",
    url="https://github.com/skanda-vyas-srinivasan/audioplane",
    project_urls={
        "Repository": "https://github.com/skanda-vyas-srinivasan/audioplane",
        "Issues": "https://github.com/skanda-vyas-srinivasan/audioplane/issues",
    },
    license="GPL-2.0-or-later",
    package_dir={"": "src"},
    packages=find_packages("src"),
    package_data={"sonexis": ["py.typed"], "audioplane": ["py.typed"]},
    license_files=["LICENSE"],
    python_requires=">=3.9",
    keywords=["audio", "coreaudio", "macos", "realtime", "sdk"],
    classifiers=[
        "Development Status :: 5 - Production/Stable",
        "Intended Audience :: Developers",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Operating System :: MacOS",
        "Topic :: Multimedia :: Sound/Audio",
        "Topic :: Software Development :: Libraries",
        "Typing :: Typed",
    ],
    extras_require={
        "openai": ["openai[realtime]>=2; python_version >= '3.10'"],
        "gemini": ["google-genai>=1; python_version >= '3.10'"],
        "mcp": ["mcp>=2,<3; python_version >= '3.10'"],
        "ai": [
            "openai[realtime]>=2; python_version >= '3.10'",
            "google-genai>=1; python_version >= '3.10'",
        ],
    },
    entry_points={
        "console_scripts": [
            "audioplane=audioplane.cli:main",
            "audioplane-mcp=sonexis.mcp_server:main",
        ],
    },
)
