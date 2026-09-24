"""Private wire helpers for Sonexis Runtime protocol v2."""

import asyncio
import struct
import uuid
from typing import Optional

from .errors import SonexisProtocolError
from .models import AudioFormat, AudioFrame, SampleFormat

PROTOCOL_VERSION = 2
MAX_CONTROL_BYTES = 64 * 1024
MAX_PCM_BYTES = 512 * 1024
PCM_MAGIC = 0x53585043
PCM_HEADER = struct.Struct(">IHHII16sQQIIHHI")
FLAG_DISCONTINUITY = 1
FLAG_EOS = 2
KNOWN_FLAGS = FLAG_DISCONTINUITY | FLAG_EOS


async def read_frame(
    reader: asyncio.StreamReader,
    expected_stream_id: uuid.UUID,
    previous_sequence: Optional[int],
) -> AudioFrame:
    try:
        raw = await reader.readexactly(PCM_HEADER.size)
    except asyncio.IncompleteReadError as error:
        raise SonexisProtocolError("truncated_pcm_stream", "Audio stream ended mid-header") from error
    (magic, version, flags, header_size, payload_size, stream_bytes, sequence,
     timestamp_ns, sample_rate, frame_count, channels, format_code,
     dropped_before) = PCM_HEADER.unpack(raw)
    if magic != PCM_MAGIC or version != 2 or header_size != PCM_HEADER.size:
        raise SonexisProtocolError("invalid_pcm_header", "Invalid PCM magic, version, or header size")
    if flags & ~KNOWN_FLAGS:
        raise SonexisProtocolError("invalid_pcm_header", "PCM frame uses unknown flags")
    stream_id = uuid.UUID(bytes=stream_bytes)
    if stream_id != expected_stream_id:
        raise SonexisProtocolError("stream_id_mismatch", "PCM frame belongs to another stream")
    formats = {1: SampleFormat.PCM_S16LE, 2: SampleFormat.FLOAT32_LE}
    if format_code not in formats:
        raise SonexisProtocolError("invalid_pcm_header", "Unknown PCM sample format")
    sample_format = formats[format_code]
    if flags & FLAG_EOS:
        if payload_size or frame_count:
            raise SonexisProtocolError("invalid_pcm_header", "EOS frame contains audio")
        return AudioFrame(str(stream_id), sequence, timestamp_ns, 0,
                          AudioFormat(0, 0, sample_format), b"")
    expected_size = frame_count * channels * sample_format.bytes_per_sample
    if not sample_rate or not frame_count or not channels or payload_size != expected_size:
        raise SonexisProtocolError("invalid_pcm_header", "PCM payload and format are inconsistent")
    if payload_size > MAX_PCM_BYTES:
        raise SonexisProtocolError("invalid_pcm_header", "PCM payload exceeds the limit")
    if previous_sequence is not None:
        if sequence <= previous_sequence:
            raise SonexisProtocolError("invalid_pcm_sequence", "PCM sequence did not advance")
        if sequence != previous_sequence + 1 and not flags & FLAG_DISCONTINUITY:
            raise SonexisProtocolError("unmarked_pcm_gap", "PCM sequence gap lacks discontinuity")
    try:
        payload = await reader.readexactly(payload_size)
    except asyncio.IncompleteReadError as error:
        raise SonexisProtocolError("truncated_pcm_stream", "Audio stream ended mid-payload") from error
    return AudioFrame(str(stream_id), sequence, timestamp_ns, frame_count,
                      AudioFormat(sample_rate, channels, sample_format), payload,
                      bool(flags & FLAG_DISCONTINUITY), dropped_before)
