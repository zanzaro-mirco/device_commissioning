"""Genera crc.vec, frames.vec e messages.vec.

I byte attesi si calcolano qui con la libreria standard di Python (binascii.crc_hqx
per il CRC, struct per gli interi little-endian), cioè con codice che non è quello
del firmware né quello dell'app. Un vettore prodotto dallo stesso codice che deve
verificare sbaglierebbe insieme a lui, e il test resterebbe verde.

Uso:  python protocol/tool/generate_vectors.py
"""

import binascii
import pathlib
import struct

VECTORS = pathlib.Path(__file__).resolve().parent.parent / "vectors"
VERSION = 1


def crc(data: bytes) -> int:
    # crc_hqx è il CRC-CCITT senza riflessione: con valore iniziale 0xFFFF è
    # esattamente il CRC-16/IBM-3740 del protocollo.
    return binascii.crc_hqx(data, 0xFFFF)


def frame(msg_type: int, seq: int, payload: bytes, version: int = VERSION) -> bytes:
    body = bytes([version, msg_type, seq, len(payload)]) + payload
    return body + struct.pack("<H", crc(body))


def hx(data: bytes) -> str:
    return data.hex() if data else "-"


def write(name: str, header: str, lines: list[str]) -> None:
    text = header + "\n".join(lines) + "\n"
    (VECTORS / name).write_text(text, encoding="utf-8", newline="\n")


GENERATED = "# Generato da protocol/tool/generate_vectors.py: non modificare a mano.\n"


def crc_vectors() -> list[str]:
    cases = [
        b"123456789",  # il valore di controllo del catalogo: 0x29B1
        b"",
        b"\x00",
        bytes([0x01, 0x01, 0x00, 0x00]),
    ]
    return [f"crc input={hx(c)} expected={crc(c):04x}" for c in cases]


def frame_vectors() -> list[str]:
    lines = []
    get_state = frame(0x01, 7, b"")
    lines.append(f"frame name=get_state bytes={hx(get_state)} result=ok type=01 seq=07 payload=-")

    set_params = frame(0x02, 42, struct.pack("<IhB", 0, 215, 1))
    lines.append(
        f"frame name=set_params bytes={hx(set_params)} result=ok type=02 seq=2a "
        f"payload={hx(set_params[4:-2])}"
    )

    corrupted = bytearray(set_params)
    corrupted[5] ^= 0x01
    lines.append(f"frame name=payload_bit_flip bytes={hx(bytes(corrupted))} result=bad_crc")

    # Il byte di versione rovinato dal trasporto deve risultare CRC sbagliato,
    # non versione non supportata: il CRC si controlla prima.
    version_flip = bytearray(get_state)
    version_flip[0] = 2
    lines.append(f"frame name=version_bit_flip bytes={hx(bytes(version_flip))} result=bad_crc")

    # Una versione 2 vera, con il suo CRC corretto.
    lines.append(
        f"frame name=future_version bytes={hx(frame(0x01, 1, b'', version=2))} "
        f"result=unsupported_version"
    )

    truncated = set_params[:-3]
    lines.append(f"frame name=truncated bytes={hx(truncated)} result=bad_length")

    lines.append("frame name=too_short bytes=01010000 result=too_short")
    return lines


def message_vectors() -> list[str]:
    def line(name: str, msg_type: int, fields: str, payload: bytes) -> str:
        return f"message name={name} type={msg_type:02x} {fields} payload={hx(payload)}".replace("  ", " ")

    return [
        line("get_state", 0x01, "", b""),
        line("set_params", 0x02, "expected_revision=7 setpoint=215 mode=1",
             struct.pack("<IhB", 7, 215, 1)),
        line("set_params_large_revision", 0x02, "expected_revision=305419896 setpoint=50 mode=0",
             struct.pack("<IhB", 0x12345678, 50, 0)),
        line("debug_apply_then_reboot", 0x7F, "expected_revision=1 setpoint=300 mode=2",
             struct.pack("<IhB", 1, 300, 2)),
        line("state", 0x81, "status=0 revision=3 setpoint=215 mode=1",
             struct.pack("<BIhB", 0, 3, 215, 1)),
        line("set_result", 0x82, "status=2 revision=9",
             struct.pack("<BI", 2, 9)),
        line("telemetry", 0x40, "temperature=-35 uptime_s=86400",
             struct.pack("<hI", -35, 86400)),
        line("info", 0x41, "protocol_version=1 fw_major=0 fw_minor=1 fw_patch=0",
             bytes([1, 0, 1, 0])),
        line("error", 0xFF, "status=6", bytes([6])),
    ]


def main() -> None:
    assert crc(b"123456789") == 0x29B1, "crc_hqx non è il CRC-16/IBM-3740"
    write("crc.vec", GENERATED + "# crc input=<hex> expected=<hex>\n", crc_vectors())
    write("frames.vec", GENERATED + "# frame name bytes result [type seq payload]\n", frame_vectors())
    write("messages.vec", GENERATED + "# message name type <campi> payload\n", message_vectors())


if __name__ == "__main__":
    main()
