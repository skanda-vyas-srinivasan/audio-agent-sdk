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
FORMAT_CODES = {SampleFormat.PCM_S16LE: 1, SampleFormat.FLOAT32_LE: 2}


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
    if previous_sequence is not None:
        if sequence <= previous_sequence:
            raise SonexisProtocolError("invalid_pcm_sequence", "PCM sequence did not advance")
        if sequence != previous_sequence + 1 and not flags & FLAG_DISCONTINUITY:
            raise SonexisProtocolError("unmarked_pcm_gap", "PCM sequence gap lacks discontinuity")
    formats = {code: sample_format for sample_format, code in FORMAT_CODES.items()}
    if format_code not in formats:
        raise SonexisProtocolError("invalid_pcm_header", "Unknown PCM sample format")
    sample_format = formats[format_code]
    if flags & FLAG_EOS:
        if payload_size or frame_count:
            raise SonexisProtocolError("invalid_pcm_header", "EOS frame contains audio")
        return AudioFrame(stream_id=str(stream_id), sequence=sequence,
                          timestamp_ns=timestamp_ns, frame_count=0,
                          format=AudioFormat(0, 0, sample_format), data=b"")
    expected_size = frame_count * channels * sample_format.bytes_per_sample
    if not sample_rate or not frame_count or not channels or payload_size != expected_size:
        raise SonexisProtocolError("invalid_pcm_header", "PCM payload and format are inconsistent")
    if payload_size > MAX_PCM_BYTES:
        raise SonexisProtocolError("invalid_pcm_header", "PCM payload exceeds the limit")
    try:
        payload = await reader.readexactly(payload_size)
    except asyncio.IncompleteReadError as error:
        raise SonexisProtocolError("truncated_pcm_stream", "Audio stream ended mid-payload") from error
    return AudioFrame(stream_id=str(stream_id), sequence=sequence,
                      timestamp_ns=timestamp_ns, frame_count=frame_count,
                      format=AudioFormat(sample_rate, channels, sample_format),
                      data=payload,
                      discontinuity=bool(flags & FLAG_DISCONTINUITY),
                      dropped_frames_before=dropped_before)


def encode_frame_header(
    *,
    stream_id: uuid.UUID,
    sequence: int,
    timestamp_ns: int,
    format: AudioFormat,
    frame_count: int,
    payload_size: int,
    discontinuity: bool = False,
    eos: bool = False,
) -> bytes:
    """Encode the shared v2 PCM header for a client-to-Runtime packet."""
    if sequence < 0 or timestamp_ns < 0:
        raise ValueError("sequence and timestamp_ns must be non-negative")
    if eos:
        if payload_size or frame_count:
            raise ValueError("EOS packets cannot contain audio")
        sample_rate = 0
        channels = 0
    else:
        if format.sample_rate <= 0 or format.channels <= 0 or frame_count <= 0:
            raise ValueError("audio packets require a positive format and frame count")
        expected_size = frame_count * format.channels * format.sample_format.bytes_per_sample
        if payload_size != expected_size or payload_size > MAX_PCM_BYTES:
            raise ValueError("PCM payload and frame count are inconsistent")
        sample_rate = format.sample_rate
        channels = format.channels
    flags = (FLAG_DISCONTINUITY if discontinuity else 0) | (FLAG_EOS if eos else 0)
    return PCM_HEADER.pack(
        PCM_MAGIC, PROTOCOL_VERSION, flags, PCM_HEADER.size, payload_size,
        stream_id.bytes, sequence, timestamp_ns, sample_rate, frame_count,
        channels, FORMAT_CODES[format.sample_format], 0,
    )
