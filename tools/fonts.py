import hashlib
import io
import itertools
import urllib.request
import zipfile

import uharfbuzz

from pathlib import Path

from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0, table__k_e_r_n


ARCHIVE_SHA256 = '15f066d58dcb99fb10014a49913009fdaf41e464cfb8851a44b44e593c95d3d8'
ARCHIVE_URL = 'https://github.com/vercel/geist-font/releases/download/v1.9.2/geist-font-v1.9.2.zip'
ASSETS = Path(__file__).resolve().parent.parent / 'assets'

CODEPOINTS = (
    *range(0x20, 0x7F),
    0xB7,
    *range(0xDF, 0xF7),
    *range(0xF8, 0x100),
    0x2018,
    0x2019,
    0x2026,
)

FEATURES = (('calt', False), ('clig', False), ('dlig', False), ('kern', True), ('liga', False))

FONTS = (
    ('geist-font/Geist/ttf/Geist-Medium.ttf', 'geist-medium.ttf'),
    ('geist-font/Geist/ttf/Geist-Regular.ttf', 'geist-regular.ttf'),
    ('geist-font/Geist/ttf/Geist-SemiBold.ttf', 'geist-semibold.ttf'),
)

LAYOUT_TABLES = ('GDEF', 'GPOS', 'GSUB')
LICENSE_MEMBER = 'geist-font/OFL.txt'
LICENSE_NAME = 'geist-license.txt'
PAIR_COUNT_MAX = (0xFFFF - 14) // 6
TRUETYPE_SIGNATURE = b'\x00\x01\x00\x00'


def main() -> None:
    archive = archive_download()
    stream = io.BytesIO(archive)

    with zipfile.ZipFile(stream) as bundle:
        for member, name in FONTS:
            source = bundle.read(member)
            rebuilt = font_rebuild(source)
            target = ASSETS / name

            target.write_bytes(rebuilt)

        license_text = bundle.read(LICENSE_MEMBER)
        license_target = ASSETS / LICENSE_NAME

        license_target.write_bytes(license_text)


def archive_download() -> bytes:
    with urllib.request.urlopen(ARCHIVE_URL, timeout=120) as response:
        archive = response.read()

    digest = hashlib.sha256(archive).hexdigest()

    if digest != ARCHIVE_SHA256:
        message = f'The Geist archive hashed to {digest}, not the pinned {ARCHIVE_SHA256}.'
        raise ValueError(message)

    return archive


def font_kerning(data: bytes) -> dict[str, int]:
    if not data.startswith(TRUETYPE_SIGNATURE):
        message = f'The font data opens with {data[:4]!r}, not the TrueType version tag.'
        raise ValueError(message)

    blob = uharfbuzz.Blob(data)
    face = uharfbuzz.Face(blob)
    font = uharfbuzz.Font(face)

    present = [
        chr(codepoint)
        for codepoint in CODEPOINTS
        if font.get_nominal_glyph(codepoint) is not None
    ]

    return {
        left + right: font_kerning_pair(font, left + right)
        for left, right in itertools.product(present, repeat=2)
    }


def font_kerning_pair(font: uharfbuzz.Font, pair: str) -> int:
    if len(pair) != 2:
        message = f'A kerning pair is two characters, not {pair!r}.'
        raise ValueError(message)

    if any(font.get_nominal_glyph(ord(character)) is None for character in pair):
        message = f'The font maps no glyph to a character of {pair!r}.'
        raise ValueError(message)

    buffer = uharfbuzz.Buffer()
    buffer.direction = 'ltr'
    buffer.language = 'en'
    buffer.script = 'Latn'
    features = dict(FEATURES)

    buffer.add_str(pair)
    uharfbuzz.shape(font, buffer, features)

    expected = [font.get_nominal_glyph(ord(character)) for character in pair]
    shaped = [information.codepoint for information in buffer.glyph_infos]

    if shaped != expected:
        message = f'The pair {pair!r} shaped to the glyphs {shaped}, not {expected}.'
        raise ValueError(message)

    first, second = buffer.glyph_positions
    advance_first = font.get_glyph_h_advance(shaped[0])
    advance_second = font.get_glyph_h_advance(shaped[1])
    placement = first.x_advance + second.x_offset - advance_first
    total = first.x_advance + second.x_advance - advance_first - advance_second

    if placement != total:
        message = (
            f'The pair {pair!r} moves its second glyph {placement} units '
            f'but advances {total}.'
        )

        raise ValueError(message)

    return total


def font_rebuild(data: bytes) -> bytes:
    if not data.startswith(TRUETYPE_SIGNATURE):
        message = f'The font data opens with {data[:4]!r}, not the TrueType version tag.'
        raise ValueError(message)

    kerning = font_kerning(data)
    stream = io.BytesIO(data)
    font = TTFont(stream, recalcTimestamp=False)
    glyph_names = font.getBestCmap()

    pairs = {
        (glyph_names[ord(left)], glyph_names[ord(right)]): value
        for (left, right), value in kerning.items()
        if value != 0
    }

    if len(pairs) > PAIR_COUNT_MAX:
        message = f'The font kerns {len(pairs)} pairs and one subtable holds {PAIR_COUNT_MAX}.'
        raise ValueError(message)

    for tag in LAYOUT_TABLES:
        del font[tag]

    font['kern'] = kern_table(pairs)
    output = io.BytesIO()

    font.save(output)
    rebuilt = output.getvalue()

    if font_kerning(rebuilt) != kerning:
        message = 'The kern table does not reproduce the kerning HarfBuzz reads from GPOS.'
        raise ValueError(message)

    return rebuilt


def kern_table(pairs: dict[tuple[str, str], int]) -> table__k_e_r_n:
    if not pairs:
        message = 'A kern table needs at least one kerned pair.'
        raise ValueError(message)

    if len(pairs) > PAIR_COUNT_MAX:
        message = f'A format 0 kern subtable holds {PAIR_COUNT_MAX} pairs, not {len(pairs)}.'
        raise ValueError(message)

    subtable = KernTable_format_0()
    subtable.coverage = 1
    subtable.kernTable = pairs
    table = newTable('kern')
    table.kernTables = [subtable]
    table.version = 0

    return table


if __name__ == '__main__':
    main()
