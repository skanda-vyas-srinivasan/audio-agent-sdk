"""Public AudioPlane Python SDK.

The implementation currently retains the ``sonexis`` module as a compatibility
surface. New applications should import from ``audioplane``.
"""

from sonexis import *  # noqa: F401,F403
from sonexis import Sonexis, __all__ as _sonexis_all, __version__

AudioPlane = Sonexis
AudioPlaneClient = Sonexis

__all__ = [*_sonexis_all, "AudioPlane", "AudioPlaneClient"]
