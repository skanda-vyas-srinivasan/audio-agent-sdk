#!/usr/bin/env python3
"""Run the packaged AudioPlane reference agent."""

# Compatibility re-export: older examples/tests imported these helpers from
# this file. The implementation now lives in the installed package.
from audioplane.agent import *  # noqa: F401,F403
from audioplane.agent import cli_main


if __name__ == "__main__":
    cli_main()
