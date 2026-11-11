from __future__ import annotations

import base64
import math
import re
import shutil
import subprocess
import tempfile
import xml.dom.minidom
import zipfile

from dataclasses import dataclass
from pathlib import Path


ASSETS = Path(__file__).resolve().parent.parent / 'assets'
BROWSERS = ('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')
CANVAS_SIZE = 256
COLOR_PATTERN = re.compile(r'#[0-9A-F]{6}')
DISC_CENTER = 128
DISC_COLOR_END = '#0564E3'
DISC_COLOR_START = '#7940E7'
DISC_RADIUS = 120
EDGE_TOLERANCE_PIXELS = 1
GLYPH_COLOR = '#FFFFFF'
GRADIENT_ID = 'solopass-disc'
GROUNDS = (('dark', '#FFFFFF'), ('light', '#0A0A0A'))
INK_PATTERN = re.compile(r'#[0-9A-F]{6}|currentColor')
LABEL = 'solopass'

LADDER = (
    (16, 'compact'),
    (24, 'small'),
    (32, 'regular'),
    (48, 'regular'),
    (64, 'regular'),
    (128, 'regular'),
    (256, 'regular'),
    (512, 'regular'),
)

LADDER_SIZES = frozenset(size for size, _ in LADDER)
LEVELS = frozenset(level for _, level in LADDER)
LOCKUP_DISC_DIAMETER = 860
LOCKUP_GAP = 300
MAGICK = ('magick',)
NOMINAL_SCALE = 0.1
PACK = ASSETS / 'solopass-asset-pack.zip'
PACK_DATE = (1980, 1, 1, 0, 0, 0)
PROBE_TOLERANCE = 3
PROGRAM_TIMEOUT_SECONDS = 120
RASTER_SCALE = 0.5
REFERENCE_RMSE_MAX = 0.01
REFERENCE_SIZE = 512
STACK_DISC_DIAMETER = 1600
STACK_GAP = 320
SVG_NAMESPACE = 'http://www.w3.org/2000/svg'
TRAY = (('busy', '#F59E0B'), ('connected', '#10B981'), ('disconnected', '#71717A'))
TRAY_SIZE = 32
WORDMARK_BASELINE_Y = 710
WORDMARK_MEANLINE_Y = 178
WORDMARK_SOURCE = ASSETS / 'solopass-wordmark-mono-outline.svg'


@dataclass(frozen=True)
class Glyph:
    arch_center_y: float
    arch_radius: float
    arch_width: float
    bottom: float
    stem_top: float
    stem_width: float

    def __post_init__(self) -> None:
        if self.arch_width <= 0:
            message = f'An arch stroke width must be positive, not {self.arch_width}.'
            raise ValueError(message)

        if self.stem_width <= 0:
            message = f'A stem stroke width must be positive, not {self.stem_width}.'
            raise ValueError(message)

        if self.bottom <= self.arch_center_y:
            message = f'The glyph ends at y {self.bottom}, above its arch center.'
            raise ValueError(message)

        inner = self.arch_radius - self.arch_width / 2
        outer = self.arch_radius + self.arch_width / 2
        stem_half = self.stem_width / 2
        crown = self.arch_center_y - self.stem_top
        corner = math.hypot(self.arch_radius, self.bottom - DISC_CENTER) + self.arch_width / 2

        if stem_half >= inner:
            message = f'A {self.stem_width} wide stem does not fit an arch of inner radius {inner}.'
            raise ValueError(message)

        if crown + stem_half > outer:
            message = f'The stem cap at y {self.stem_top} pokes out above the arch.'
            raise ValueError(message)

        if math.hypot(stem_half, crown) < inner:
            message = f'The stem top at y {self.stem_top} stops short of the arch.'
            raise ValueError(message)

        if corner >= DISC_RADIUS:
            message = f'The leg ends reach {corner:.2f} from the center, past the disc.'
            raise ValueError(message)


@dataclass(frozen=True)
class Layout:
    disc_diameter: float
    disc_x: float
    disc_y: float
    height: float
    text_height: float
    text_width: float
    text_x: float
    text_y: float
    width: float

    def __post_init__(self) -> None:
        if self.disc_diameter <= 0:
            message = f'A disc diameter must be positive, not {self.disc_diameter}.'
            raise ValueError(message)

        boxes = (
            ('disc', self.disc_x, self.disc_y, self.disc_diameter, self.disc_diameter),
            ('wordmark', self.text_x, self.text_y, self.text_width, self.text_height),
        )

        for name, left, top, width, height in boxes:
            right = left + width
            bottom = top + height

            if left < 0:
                message = f'The {name} starts at x {left}, left of the layout.'
                raise ValueError(message)

            if top < 0:
                message = f'The {name} starts at y {top}, above the layout.'
                raise ValueError(message)

            if right > self.width:
                message = f'The {name} reaches x {right}, past the {self.width} wide layout.'
                raise ValueError(message)

            if bottom > self.height:
                message = f'The {name} reaches y {bottom}, past the {self.height} tall layout.'
                raise ValueError(message)

        gap_x = self.text_x - self.disc_x - self.disc_diameter
        gap_y = self.text_y - self.disc_y - self.disc_diameter

        if max(gap_x, gap_y) < 0:
            message = 'The disc overlaps the wordmark.'
            raise ValueError(message)


@dataclass(frozen=True)
class Paint:
    end: str
    start: str

    def __post_init__(self) -> None:
        if not COLOR_PATTERN.fullmatch(self.start):
            message = f'A paint starts at an uppercase hex color, not {self.start!r}.'
            raise ValueError(message)

        if not COLOR_PATTERN.fullmatch(self.end):
            message = f'A paint ends at an uppercase hex color, not {self.end!r}.'
            raise ValueError(message)


@dataclass(frozen=True)
class Raster:
    height: int
    markup: str
    target: Path
    width: int

    def __post_init__(self) -> None:
        if self.width <= 0:
            message = f'{self.target.name} needs a positive width, not {self.width}.'
            raise ValueError(message)

        if self.height <= 0:
            message = f'{self.target.name} needs a positive height, not {self.height}.'
            raise ValueError(message)

        if self.target.suffix not in {'.png', '.rgba'}:
            message = f'{self.target.name} is neither a PNG nor raw RGBA.'
            raise ValueError(message)


@dataclass(frozen=True)
class Wordmark:
    height: float
    path: str
    width: float

    def __post_init__(self) -> None:
        if self.width <= 0:
            message = f'A wordmark width must be positive, not {self.width}.'
            raise ValueError(message)

        if self.height <= 0:
            message = f'A wordmark height must be positive, not {self.height}.'
            raise ValueError(message)

        if not self.path.startswith('M'):
            message = f'A wordmark outline opens with a moveto, not {self.path[:16]!r}.'
            raise ValueError(message)


def main() -> None:
    magick = program_path(MAGICK)
    glyphs = glyph_levels()
    wordmark = wordmark_read()
    vectors = vector_plan(glyphs, wordmark)
    rasters = raster_plan(glyphs, vectors)

    with tempfile.TemporaryDirectory() as directory:
        browser = program_path(BROWSERS)
        scratch = Path(directory)
        assets = scratch / 'assets'
        references = scratch / 'references'

        assets.mkdir()
        references.mkdir()
        reference_check(glyphs, browser=browser, magick=magick, scratch=references)
        raster_render(rasters, browser=browser, magick=magick, scratch=assets)

    for path, markup in vectors.items():
        path.write_text(markup, encoding='utf-8')

    ladder_validate(glyphs, magick=magick)

    colors = ASSETS / 'solopass-colors.md'
    colors_text = colors_markdown()

    colors.write_text(colors_text, encoding='utf-8')

    pictures = [raster.target for raster in rasters if raster.target.suffix == '.png']
    members = [*vectors, WORDMARK_SOURCE, *pictures]

    pack_write(members)


def arc_command(*, end: tuple[float, float], radius: float, sweep: int) -> str:
    if not all(math.isfinite(coordinate) for coordinate in end):
        message = f'An arc ends at a finite point, not {end}.'
        raise ValueError(message)

    if radius <= 0:
        message = f'An arc radius must be positive, not {radius}.'
        raise ValueError(message)

    if sweep not in {0, 1}:
        message = f'An arc sweep flag is 0 or 1, not {sweep}.'
        raise ValueError(message)

    size = number_text(radius)

    return f'A{size} {size} 0 0 {sweep} {point_text(end)}'


def colors_markdown() -> str:
    logo = logo_paint()
    wordmarks = [f'| Wordmark on {ground} | `{ink}` |' for ground, ink in GROUNDS]
    states = [f'| {state.capitalize()} | `{color}` |' for state, color in TRAY]

    gradient = (
        'The gradient on the circle runs from its top left corner to its bottom right corner, '
        'and each stop is listed with its offset.'
    )

    tray = (
        'The tray draws the same symbol on a flat circle whose color follows the state of the '
        'connection.'
    )

    mono = (
        'A mono file without a ground fills each shape with `currentColor`, so an inline copy '
        'takes the color of the text around it. The mono mark cuts the symbol out of its '
        'circle, so the ground shows through the symbol.'
    )

    lines = [
        f'# {LABEL} colors',
        '',
        gradient,
        '',
        '| Use | Stops |',
        '|---|---|',
        f'| Circle | `{logo.start}` at 0, `{logo.end}` at 1 |',
        '',
        '| Use | Color |',
        '|---|---|',
        f'| Symbol | `{GLYPH_COLOR}` |',
        *wordmarks,
        '',
        '## Tray',
        '',
        tray,
        '',
        '| State | Color |',
        '|---|---|',
        *states,
        '',
        '## Mono',
        '',
        mono,
    ]

    return '\n'.join(lines) + '\n'


def color_channels(color: str) -> tuple[int, ...]:
    if not COLOR_PATTERN.fullmatch(color):
        message = f'A color is uppercase hex, not {color!r}.'
        raise ValueError(message)

    return tuple(int(color[index:index + 2], 16) for index in range(1, 7, 2))


def composition_markup(layout: Layout, *, ink: str, mark: list[str], wordmark: Wordmark) -> str:
    if not INK_PATTERN.fullmatch(ink):
        message = f'A wordmark ink is an uppercase hex color or currentColor, not {ink!r}.'
        raise ValueError(message)

    if not mark:
        message = 'A composition needs a mark with at least one element.'
        raise ValueError(message)

    scale = layout.disc_diameter / (2 * DISC_RADIUS)
    corner = DISC_CENTER - DISC_RADIUS
    shift_x = layout.disc_x - corner * scale
    shift_y = layout.disc_y - corner * scale
    placement = f'translate({number_text(shift_x)} {number_text(shift_y)})'
    transform = f'{placement} scale({number_text(scale, places=4)})'
    text = f'translate({number_text(layout.text_x)} {number_text(layout.text_y)})'
    view_box = f'0 0 {number_text(layout.width)} {number_text(layout.height)}'

    body = [
        f'<g transform="{transform}">',
        *(f'    {element}' for element in mark),
        '</g>',
        f'<path transform="{text}" fill="{ink}" d="{wordmark.path}"/>',
    ]

    return svg_markup(
        body=body,
        height=layout.height * NOMINAL_SCALE,
        view_box=view_box,
        width=layout.width * NOMINAL_SCALE,
    )


def disc_elements(paint: Paint) -> list[str]:
    center = number_text(DISC_CENTER)
    radius = number_text(DISC_RADIUS)
    circle = f'<circle cx="{center}" cy="{center}" r="{radius}"'

    if paint.start == paint.end:
        return [f'{circle} fill="{paint.start}"/>']

    return [*gradient_elements(paint), f'{circle} fill="url(#{GRADIENT_ID})"/>']


def disc_path() -> str:
    left = (DISC_CENTER - DISC_RADIUS, DISC_CENTER)
    right = (DISC_CENTER + DISC_RADIUS, DISC_CENTER)
    over = arc_command(end=right, radius=DISC_RADIUS, sweep=1)
    under = arc_command(end=left, radius=DISC_RADIUS, sweep=1)

    return f'M{point_text(left)}{over}{under}Z'


def glyph_levels() -> dict[str, Glyph]:
    compact = Glyph(
        arch_center_y=116,
        arch_radius=48,
        arch_width=32,
        bottom=184,
        stem_top=74,
        stem_width=32,
    )

    regular = Glyph(
        arch_center_y=115,
        arch_radius=54,
        arch_width=24,
        bottom=191,
        stem_top=68,
        stem_width=19.2,
    )

    small = Glyph(
        arch_center_y=116,
        arch_radius=48,
        arch_width=32,
        bottom=184,
        stem_top=74,
        stem_width=64 / 3,
    )

    levels = {'compact': compact, 'regular': regular, 'small': small}

    if levels.keys() != LEVELS:
        message = f'The glyph levels {sorted(levels)} differ from the ladder {sorted(LEVELS)}.'
        raise ValueError(message)

    return levels


def glyph_outline(glyph: Glyph) -> str:
    arch_half = glyph.arch_width / 2
    stem_half = glyph.stem_width / 2
    inner = glyph.arch_radius - arch_half
    outer = glyph.arch_radius + arch_half
    junction = glyph.arch_center_y - math.sqrt(inner**2 - stem_half**2)

    if glyph.bottom <= junction:
        message = f'The stem ends at y {glyph.bottom}, inside the arch.'
        raise ValueError(message)

    bottom = glyph.bottom
    center = glyph.arch_center_y
    inner_left = DISC_CENTER - inner
    inner_right = DISC_CENTER + inner
    outer_left = DISC_CENTER - outer
    outer_right = DISC_CENTER + outer
    stem_left = DISC_CENTER - stem_half
    stem_right = DISC_CENTER + stem_half

    commands = [
        f'M{point_text((outer_left, bottom))}',
        f'L{point_text((outer_left, center))}',
        arc_command(end=(outer_right, center), radius=outer, sweep=1),
        f'L{point_text((outer_right, bottom))}',
        arc_command(end=(inner_right, bottom), radius=arch_half, sweep=1),
        f'L{point_text((inner_right, center))}',
        arc_command(end=(stem_right, junction), radius=inner, sweep=0),
        f'L{point_text((stem_right, bottom))}',
        arc_command(end=(stem_left, bottom), radius=stem_half, sweep=1),
        f'L{point_text((stem_left, junction))}',
        arc_command(end=(inner_left, center), radius=inner, sweep=0),
        f'L{point_text((inner_left, bottom))}',
        arc_command(end=(outer_left, bottom), radius=arch_half, sweep=1),
    ]

    return ''.join(commands) + 'Z'


def gradient_elements(paint: Paint) -> list[str]:
    near = number_text(DISC_CENTER - DISC_RADIUS)
    far = number_text(DISC_CENTER + DISC_RADIUS)
    line = f'x1="{near}" y1="{near}" x2="{far}" y2="{far}"'
    opening = f'<linearGradient id="{GRADIENT_ID}" gradientUnits="userSpaceOnUse" {line}>'

    return [
        '<defs>',
        f'    {opening}',
        f'        <stop offset="0" stop-color="{paint.start}"/>',
        f'        <stop offset="1" stop-color="{paint.end}"/>',
        '    </linearGradient>',
        '</defs>',
    ]


def icon_markup(glyph: Glyph, *, paint: Paint) -> str:
    body = mark_elements(glyph, paint=paint)
    canvas = f'0 0 {CANVAS_SIZE} {CANVAS_SIZE}'

    return svg_markup(body=body, height=CANVAS_SIZE, view_box=canvas, width=CANVAS_SIZE)


def icon_validate(path: Path, *, glyph: Glyph, magick: str, paint: Paint, size: int) -> None:
    if not path.is_file():
        message = f'There is no icon at {path} to check.'
        raise FileNotFoundError(message)

    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if size not in LADDER_SIZES:
        message = f'The ladder draws the sizes {sorted(LADDER_SIZES)}, not {size}.'
        raise ValueError(message)

    if path.suffix == '.png':
        source = [str(path)]
    else:
        source = ['-size', f'{size}x{size}', '-depth', '8', f'rgba:{path}']

    glyph_top = glyph.arch_center_y - glyph.arch_radius - glyph.arch_width / 2
    probe_y = int((DISC_CENTER - DISC_RADIUS + glyph_top) / 2 * size / CANVAS_SIZE)
    middle = size // 2
    probe = f'%[fx:p{{0,0}}.a] %[fx:p{{{middle},{middle}}}.a] %[hex:p{{{middle},{probe_y}}}]'
    command = [magick, *source, '-format', probe, 'info:']
    fields = program_read(command).split()

    if len(fields) != 3:
        message = f'magick described {path.name} as {fields}, not two alphas and a color.'
        raise ValueError(message)

    corner, center, pixel = fields
    scale = CANVAS_SIZE / size
    expected = paint_at(paint, x=(middle + 0.5) * scale, y=(probe_y + 0.5) * scale)

    if float(corner) != 0:
        message = f'{path.name} has corner alpha {corner}, so its ground is not transparent.'
        raise ValueError(message)

    if float(center) != 1:
        message = f'{path.name} has center alpha {center}, so its disc did not render.'
        raise ValueError(message)

    if not pixel_matches(pixel, expected=expected):
        message = f'{path.name} paints its disc {pixel} where the paint gives {expected}.'
        raise ValueError(message)

    icon_validate_edges(source, magick=magick, name=path.name, size=size)


def icon_validate_edges(source: list[str], *, magick: str, name: str, size: int) -> None:
    if not source:
        message = 'An edge check needs an image to read.'
        raise ValueError(message)

    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if not name:
        message = 'An edge check names the image it reads.'
        raise ValueError(message)

    if size not in LADDER_SIZES:
        message = f'The ladder draws the sizes {sorted(LADDER_SIZES)}, not {size}.'
        raise ValueError(message)

    command = [magick, *source, '-alpha', 'extract', '-threshold', '50%', '-format', '%@', 'info:']
    output = program_read(command).strip()
    fields = output.split('+')

    if len(fields) != 3:
        message = f'magick trimmed {name} to {output!r}, not to a WxH+X+Y box.'
        raise ValueError(message)

    extent, left, top = fields
    width, height = extent.split('x')
    scale = size / CANVAS_SIZE
    near = (DISC_CENTER - DISC_RADIUS) * scale
    far = (DISC_CENTER + DISC_RADIUS) * scale

    edges = {
        'left': (int(left), near),
        'top': (int(top), near),
        'right': (int(left) + int(width), far),
        'bottom': (int(top) + int(height), far),
    }

    for edge, (measured, expected) in edges.items():
        if abs(measured - expected) > EDGE_TOLERANCE_PIXELS:
            message = f'{name} has its {edge} edge at {measured} px, not {expected:.2f} px.'
            raise ValueError(message)


def ladder_validate(glyphs: dict[str, Glyph], *, magick: str) -> None:
    if glyphs.keys() != LEVELS:
        message = f'The glyph levels {sorted(glyphs)} differ from the ladder {sorted(LEVELS)}.'
        raise ValueError(message)

    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    logo = logo_paint()

    for size, level in LADDER:
        icon = ASSETS / f'solopass-icon-{size}.png'
        icon_validate(icon, glyph=glyphs[level], magick=magick, paint=logo, size=size)

    for state, color in TRAY:
        pixmap = ASSETS / f'{state}.rgba'
        flat = Paint(end=color, start=color)

        icon_validate(pixmap, glyph=glyphs['regular'], magick=magick, paint=flat, size=TRAY_SIZE)


def layout_lockup(wordmark: Wordmark) -> Layout:
    if not 0 < WORDMARK_MEANLINE_Y < WORDMARK_BASELINE_Y < wordmark.height:
        message = (
            f'The wordmark lines at y {WORDMARK_MEANLINE_Y} and {WORDMARK_BASELINE_Y} '
            f'fall outside its {wordmark.height} tall box.'
        )

        raise ValueError(message)

    axis = (WORDMARK_MEANLINE_Y + WORDMARK_BASELINE_Y) / 2
    disc_top = axis - LOCKUP_DISC_DIAMETER / 2
    top = min(0, disc_top)
    bottom = max(wordmark.height, disc_top + LOCKUP_DISC_DIAMETER)

    return Layout(
        disc_diameter=LOCKUP_DISC_DIAMETER,
        disc_x=0,
        disc_y=disc_top - top,
        height=bottom - top,
        text_height=wordmark.height,
        text_width=wordmark.width,
        text_x=LOCKUP_DISC_DIAMETER + LOCKUP_GAP,
        text_y=-top,
        width=LOCKUP_DISC_DIAMETER + LOCKUP_GAP + wordmark.width,
    )


def layout_stack(wordmark: Wordmark) -> Layout:
    width = max(wordmark.width, STACK_DISC_DIAMETER)

    return Layout(
        disc_diameter=STACK_DISC_DIAMETER,
        disc_x=(width - STACK_DISC_DIAMETER) / 2,
        disc_y=0,
        height=STACK_DISC_DIAMETER + STACK_GAP + wordmark.height,
        text_height=wordmark.height,
        text_width=wordmark.width,
        text_x=(width - wordmark.width) / 2,
        text_y=STACK_DISC_DIAMETER + STACK_GAP,
        width=width,
    )


def logo_paint() -> Paint:
    return Paint(end=DISC_COLOR_END, start=DISC_COLOR_START)


def mark_elements(glyph: Glyph, *, paint: Paint) -> list[str]:
    symbol = f'<path fill="{GLYPH_COLOR}" d="{glyph_outline(glyph)}"/>'
    return [*disc_elements(paint), symbol]


def mark_mono_elements(glyph: Glyph) -> list[str]:
    shape = disc_path() + glyph_outline(glyph)

    return [f'<path fill="currentColor" fill-rule="evenodd" d="{shape}"/>']


def number_text(value: float, *, places: int = 2) -> str:
    if not math.isfinite(value):
        message = f'SVG markup carries finite numbers, not {value}.'
        raise ValueError(message)

    if places < 1:
        message = f'A number keeps at least one decimal place before trimming, not {places}.'
        raise ValueError(message)

    text = f'{value:.{places}f}'.rstrip('0').rstrip('.')

    return '0' if text == '-0' else text


def pack_validate(ordered: list[Path]) -> None:
    if not ordered:
        message = 'A pack holds at least one file.'
        raise ValueError(message)

    with zipfile.ZipFile(PACK) as archive:
        broken = archive.testzip()
        names = archive.namelist()
        contents = {name: archive.read(name) for name in names}

    expected = [path.name for path in ordered]

    if broken is not None:
        message = f'{PACK.name} fails its CRC check at {broken}.'
        raise ValueError(message)

    if names != expected:
        message = f'{PACK.name} holds {names}, not {expected}.'
        raise ValueError(message)

    for path in ordered:
        if contents[path.name] != path.read_bytes():
            message = f'{PACK.name} carries a {path.name} that differs from the file on disk.'
            raise ValueError(message)


def pack_write(members: list[Path]) -> None:
    if not members:
        message = 'A pack holds at least one file.'
        raise ValueError(message)

    pictures = sorted(path for path in members if path.suffix == '.png')
    vectors = sorted(path for path in members if path.suffix == '.svg')
    ordered = [*vectors, *pictures]
    names = {path.name for path in ordered}

    if len(ordered) != len(members):
        message = f'The pack carries only SVG and PNG files, not {sorted(members)}.'
        raise ValueError(message)

    if len(names) != len(ordered):
        message = f'The pack names a file more than once: {sorted(path.name for path in ordered)}.'
        raise ValueError(message)

    with zipfile.ZipFile(PACK, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in ordered:
            data = path.read_bytes()
            info = zipfile.ZipInfo(path.name, date_time=PACK_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16

            archive.writestr(info, data)

    pack_validate(ordered)


def paint_at(paint: Paint, *, x: float, y: float) -> tuple[int, ...]:
    if not 0 <= x <= CANVAS_SIZE:
        message = f'A paint is read inside the canvas, not at x {x}.'
        raise ValueError(message)

    if not 0 <= y <= CANVAS_SIZE:
        message = f'A paint is read inside the canvas, not at y {y}.'
        raise ValueError(message)

    near = DISC_CENTER - DISC_RADIUS
    amount = min(max(((x - near) + (y - near)) / (4 * DISC_RADIUS), 0), 1)
    start = color_channels(paint.start)
    end = color_channels(paint.end)

    return tuple(round(low + (high - low) * amount) for low, high in zip(start, end, strict=True))


def pixel_matches(pixel: str, *, expected: tuple[int, ...]) -> bool:
    if len(pixel) != 8:
        message = f'A pixel reads as eight hex digits of RGBA, not {pixel!r}.'
        raise ValueError(message)

    if len(expected) != 3:
        message = f'A paint gives three channels, not {expected}.'
        raise ValueError(message)

    channels = [int(pixel[index:index + 2], 16) for index in range(0, 8, 2)]
    pairs = zip(channels[:3], expected, strict=True)
    close = all(abs(seen - wanted) <= PROBE_TOLERANCE for seen, wanted in pairs)
    opaque = channels[3] == 255

    return opaque and close


def point_text(point: tuple[float, float]) -> str:
    if not all(math.isfinite(coordinate) for coordinate in point):
        message = f'SVG markup carries finite points, not {point}.'
        raise ValueError(message)

    return f'{number_text(point[0])} {number_text(point[1])}'


def program_check(result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode != 0:
        message = (
            f'{result.args[0]} exited with status {result.returncode}: '
            f'{result.stderr.strip()}'
        )

        raise RuntimeError(message)


def program_path(names: tuple[str, ...]) -> str:
    if not names:
        message = 'A program search needs at least one name.'
        raise ValueError(message)

    for name in names:
        path = shutil.which(name)

        if path is not None:
            return path

    message = f'None of {", ".join(names)} is on PATH.'
    raise FileNotFoundError(message)


def program_read(command: list[str]) -> str:
    if not command:
        message = 'A program command needs at least the program path.'
        raise ValueError(message)

    result = subprocess.run(
        command,
        capture_output=True,
        check=False,
        errors='replace',
        text=True,
        timeout=PROGRAM_TIMEOUT_SECONDS,
    )

    program_check(result)

    return result.stdout


def program_run(command: list[str]) -> None:
    if not command:
        message = 'A program command needs at least the program path.'
        raise ValueError(message)

    result = subprocess.run(
        command,
        check=False,
        errors='replace',
        stderr=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        text=True,
        timeout=PROGRAM_TIMEOUT_SECONDS,
    )

    program_check(result)


def raster_crop(raster: Raster, *, magick: str, offset: int, screenshot: Path) -> None:
    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if offset < 0:
        message = f'A crop starts at a row of zero or more, not {offset}.'
        raise ValueError(message)

    if not screenshot.is_file():
        message = f'There is no screenshot at {screenshot} to crop.'
        raise FileNotFoundError(message)

    if raster.target.suffix == '.png':
        output = f'PNG32:{raster.target}'
    else:
        output = f'rgba:{raster.target}'

    command = [
        magick,
        str(screenshot),
        '-crop',
        f'{raster.width}x{raster.height}+0+{offset}',
        '+repage',
        '-strip',
        '-depth',
        '8',
        '-define',
        'png:exclude-chunks=date,time',
        output,
    ]

    program_run(command)


def raster_page(rasters: list[Raster]) -> str:
    if not rasters:
        message = 'A page needs at least one raster.'
        raise ValueError(message)

    images = []
    offset = 0

    for raster in rasters:
        encoded = base64.b64encode(raster.markup.encode()).decode()
        size = f'width: {raster.width}px; height: {raster.height}px'
        style = f'position: absolute; left: 0; top: {offset}px; {size}'
        image = f'<img src="data:image/svg+xml;base64,{encoded}" style="{style}">'

        images.append(image)
        offset += raster.height

    body = ''.join(images)
    head = '<head><style>body { margin: 0; }</style></head>'

    return f'<!doctype html><html>{head}<body>{body}</body></html>\n'


def raster_plan(glyphs: dict[str, Glyph], vectors: dict[Path, str]) -> list[Raster]:
    if glyphs.keys() != LEVELS:
        message = f'The glyph levels {sorted(glyphs)} differ from the ladder {sorted(LEVELS)}.'
        raise ValueError(message)

    if not vectors:
        message = 'A raster plan needs the vector files it draws from.'
        raise ValueError(message)

    logo = logo_paint()
    rasters = []

    for size, level in LADDER:
        markup = icon_markup(glyphs[level], paint=logo)
        target = ASSETS / f'solopass-icon-{size}.png'
        raster = Raster(height=size, markup=markup, target=target, width=size)

        rasters.append(raster)

    for state, color in TRAY:
        flat = Paint(end=color, start=color)
        markup = icon_markup(glyphs['regular'], paint=flat)
        target = ASSETS / f'{state}.rgba'
        raster = Raster(height=TRAY_SIZE, markup=markup, target=target, width=TRAY_SIZE)

        rasters.append(raster)

    for form in ('lockup', 'stack'):
        for ground, _ in GROUNDS:
            markup = vectors[ASSETS / f'solopass-{form}-outline-on-{ground}.svg']
            target = ASSETS / f'solopass-{form}-on-{ground}.png'
            _, _, width, height = view_box_read(markup)

            raster = Raster(
                height=round(height * RASTER_SCALE),
                markup=markup,
                target=target,
                width=round(width * RASTER_SCALE),
            )

            rasters.append(raster)

    return rasters


def raster_render(rasters: list[Raster], *, browser: str, magick: str, scratch: Path) -> None:
    if not rasters:
        message = 'A render needs at least one raster.'
        raise ValueError(message)

    if shutil.which(browser) is None:
        message = f'{browser} is not an executable program.'
        raise FileNotFoundError(message)

    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if not scratch.is_dir():
        message = f'There is no scratch directory at {scratch} to render in.'
        raise FileNotFoundError(message)

    page = scratch / 'page.html'
    profile = scratch / 'profile'
    screenshot = scratch / 'page.png'
    width = max(raster.width for raster in rasters)
    height = sum(raster.height for raster in rasters)
    html = raster_page(rasters)

    page.write_text(html, encoding='utf-8')

    command = [
        browser,
        '--headless=new',
        '--disable-gpu',
        '--hide-scrollbars',
        '--force-device-scale-factor=1',
        '--default-background-color=00000000',
        f'--user-data-dir={profile}',
        f'--window-size={width},{height}',
        f'--screenshot={screenshot}',
        page.as_uri(),
    ]

    program_run(command)

    if not screenshot.is_file():
        message = f'{browser} exited cleanly but wrote no screenshot to {screenshot}.'
        raise RuntimeError(message)

    offset = 0

    for raster in rasters:
        raster_crop(raster, magick=magick, offset=offset, screenshot=screenshot)
        raster_validate(raster, magick=magick)
        offset += raster.height


def raster_validate(raster: Raster, *, magick: str) -> None:
    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if not raster.target.is_file():
        message = f'There is no rendered image at {raster.target} to check.'
        raise FileNotFoundError(message)

    if raster.target.suffix == '.rgba':
        expected = raster.width * raster.height * 4
        actual = raster.target.stat().st_size

        if actual != expected:
            message = f'{raster.target.name} holds {actual} bytes, not {expected}.'
            raise ValueError(message)

        return

    command = [magick, str(raster.target), '-format', '%w %h', 'info:']
    fields = program_read(command).split()
    expected_fields = [str(raster.width), str(raster.height)]

    if fields != expected_fields:
        measured = ' x '.join(fields)
        message = f'{raster.target.name} measures {measured}, not {raster.width} x {raster.height}.'
        raise ValueError(message)


def reference_check(
    glyphs: dict[str, Glyph],
    *,
    browser: str,
    magick: str,
    scratch: Path,
) -> None:
    if glyphs.keys() != LEVELS:
        message = f'The glyph levels {sorted(glyphs)} differ from the ladder {sorted(LEVELS)}.'
        raise ValueError(message)

    if shutil.which(browser) is None:
        message = f'{browser} is not an executable program.'
        raise FileNotFoundError(message)

    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if not scratch.is_dir():
        message = f'There is no scratch directory at {scratch} to render in.'
        raise FileNotFoundError(message)

    logo = logo_paint()
    jobs = []
    pairs = []

    for name, glyph in glyphs.items():
        outlined = scratch / f'{name}-outlined.png'
        stroked = scratch / f'{name}-stroked.png'
        outlined_markup = icon_markup(glyph, paint=logo)
        stroked_markup = reference_markup(glyph, paint=logo)
        size = REFERENCE_SIZE
        outlined_raster = Raster(height=size, markup=outlined_markup, target=outlined, width=size)
        stroked_raster = Raster(height=size, markup=stroked_markup, target=stroked, width=size)
        pair = (outlined, stroked)

        jobs.append(outlined_raster)
        jobs.append(stroked_raster)
        pairs.append(pair)

    raster_render(jobs, browser=browser, magick=magick, scratch=scratch)

    for outlined, stroked in pairs:
        reference_compare(magick=magick, outlined=outlined, stroked=stroked)


def reference_compare(*, magick: str, outlined: Path, stroked: Path) -> None:
    if shutil.which(magick) is None:
        message = f'{magick} is not an executable program.'
        raise FileNotFoundError(message)

    if not outlined.is_file():
        message = f'There is no outlined render at {outlined} to compare.'
        raise FileNotFoundError(message)

    if not stroked.is_file():
        message = f'There is no stroked render at {stroked} to compare.'
        raise FileNotFoundError(message)

    command = [magick, 'compare', '-metric', 'RMSE', str(stroked), str(outlined), 'null:']

    result = subprocess.run(
        command,
        capture_output=True,
        check=False,
        errors='replace',
        text=True,
        timeout=PROGRAM_TIMEOUT_SECONDS,
    )

    report = result.stderr.strip()

    if result.returncode not in {0, 1}:
        message = f'magick compare exited with status {result.returncode}: {report}'
        raise RuntimeError(message)

    opening = report.find('(')
    closing = report.find(')')

    if opening < 0:
        message = f'magick compare reported {report!r}, not an RMSE with its normalized value.'
        raise ValueError(message)

    if closing < opening:
        message = f'magick compare reported {report!r}, not an RMSE with its normalized value.'
        raise ValueError(message)

    error = float(report[opening + 1:closing])

    if error > REFERENCE_RMSE_MAX:
        message = (
            f'{outlined.name} differs from its stroked reference by {error} RMSE, '
            f'past the {REFERENCE_RMSE_MAX} limit.'
        )

        raise ValueError(message)


def reference_markup(glyph: Glyph, *, paint: Paint) -> str:
    left = DISC_CENTER - glyph.arch_radius
    right = DISC_CENTER + glyph.arch_radius
    over = arc_command(end=(right, glyph.arch_center_y), radius=glyph.arch_radius, sweep=1)
    legs = f'M{point_text((left, glyph.bottom))}L{point_text((left, glyph.arch_center_y))}'
    arch = f'{legs}{over}L{point_text((right, glyph.bottom))}'
    stem_top = point_text((DISC_CENTER, glyph.stem_top))
    stem_bottom = point_text((DISC_CENTER, glyph.bottom))
    stem = f'M{stem_top}L{stem_bottom}'
    arch_width = number_text(glyph.arch_width)
    stem_width = number_text(glyph.stem_width)
    rounding = 'fill="none" stroke-linecap="round" stroke-linejoin="round"'
    canvas = f'0 0 {CANVAS_SIZE} {CANVAS_SIZE}'

    body = [
        *disc_elements(paint),
        f'<path d="{arch}" stroke="{GLYPH_COLOR}" stroke-width="{arch_width}" {rounding}/>',
        f'<path d="{stem}" stroke="{GLYPH_COLOR}" stroke-width="{stem_width}" {rounding}/>',
    ]

    return svg_markup(body=body, height=CANVAS_SIZE, view_box=canvas, width=CANVAS_SIZE)


def svg_markup(*, body: list[str], height: float, view_box: str, width: float) -> str:
    if not body:
        message = 'An SVG document needs at least one element.'
        raise ValueError(message)

    if height <= 0:
        message = f'An SVG document has a positive height, not {height}.'
        raise ValueError(message)

    if len(view_box.split()) != 4:
        message = f'An SVG viewBox carries four numbers, not {view_box!r}.'
        raise ValueError(message)

    if width <= 0:
        message = f'An SVG document has a positive width, not {width}.'
        raise ValueError(message)

    size = f'width="{number_text(width)}" height="{number_text(height)}"'
    label = f'role="img" aria-label="{LABEL}"'
    root = f'<svg xmlns="{SVG_NAMESPACE}" {size} viewBox="{view_box}" {label}>'
    children = [f'    {line}' for line in body]
    lines = [root, f'    <title>{LABEL}</title>', *children, '</svg>']
    markup = '\n'.join(lines) + '\n'

    svg_validate(markup)

    return markup


def svg_validate(markup: str) -> None:
    if not markup.startswith('<svg '):
        message = f'An SVG document opens with an svg element, not {markup[:16]!r}.'
        raise ValueError(message)

    document = xml.dom.minidom.parseString(markup)
    root = document.documentElement
    namespace = root.getAttribute('xmlns')
    elements = document.getElementsByTagName('*')
    named = [element for element in elements if element.hasAttribute('id')]
    identifiers = [element.getAttribute('id') for element in named]
    references = set(re.findall(r'url\(#([^)]+)\)', markup))
    missing = references - set(identifiers)

    if root.tagName != 'svg':
        message = f'An SVG document opens with <{root.tagName}>, not <svg>.'
        raise ValueError(message)

    if namespace != SVG_NAMESPACE:
        message = f'An SVG document declares the namespace {namespace!r}, not {SVG_NAMESPACE}.'
        raise ValueError(message)

    if len(identifiers) != len(set(identifiers)):
        message = f'An SVG document defines an id more than once: {sorted(identifiers)}.'
        raise ValueError(message)

    if missing:
        message = f'An SVG document paints with ids it never defines: {sorted(missing)}.'
        raise ValueError(message)

    view_box_read(markup)


def vector_plan(glyphs: dict[str, Glyph], wordmark: Wordmark) -> dict[Path, str]:
    if glyphs.keys() != LEVELS:
        message = f'The glyph levels {sorted(glyphs)} differ from the ladder {sorted(LEVELS)}.'
        raise ValueError(message)

    logo = logo_paint()
    regular = glyphs['regular']
    diameter = 2 * DISC_RADIUS
    corner = number_text(DISC_CENTER - DISC_RADIUS)
    tight = f'{corner} {corner} {number_text(diameter)} {number_text(diameter)}'
    mark = mark_elements(regular, paint=logo)
    mono = mark_mono_elements(regular)
    icon = icon_markup(regular, paint=logo)
    icon_compact = icon_markup(glyphs['compact'], paint=logo)
    mark_color = svg_markup(body=mark, height=diameter, view_box=tight, width=diameter)
    mark_mono = svg_markup(body=mono, height=diameter, view_box=tight, width=diameter)
    compositions = (('lockup', layout_lockup(wordmark)), ('stack', layout_stack(wordmark)))

    plan = {
        ASSETS / 'solopass-icon-compact.svg': icon_compact,
        ASSETS / 'solopass-icon.svg': icon,
        ASSETS / 'solopass-mark-mono.svg': mark_mono,
        ASSETS / 'solopass-mark.svg': mark_color,
    }

    for form, layout in compositions:
        target = ASSETS / f'solopass-{form}-mono-outline.svg'
        plan[target] = composition_markup(layout, ink='currentColor', mark=mono, wordmark=wordmark)

        for ground, ink in GROUNDS:
            target = ASSETS / f'solopass-{form}-outline-on-{ground}.svg'
            plan[target] = composition_markup(layout, ink=ink, mark=mark, wordmark=wordmark)

    for ground, ink in GROUNDS:
        target = ASSETS / f'solopass-wordmark-mono-outline-on-{ground}.svg'
        plan[target] = wordmark_markup(wordmark, ink=ink)

    return plan


def view_box_read(markup: str) -> tuple[float, float, float, float]:
    if not markup.startswith('<svg '):
        message = f'An SVG document opens with an svg element, not {markup[:16]!r}.'
        raise ValueError(message)

    root = xml.dom.minidom.parseString(markup).documentElement
    fields = root.getAttribute('viewBox').split()

    if len(fields) != 4:
        message = f'An SVG viewBox carries four numbers, not {fields}.'
        raise ValueError(message)

    left, top, width, height = (float(field) for field in fields)

    if width <= 0:
        message = f'An SVG viewBox has a positive width, not {width}.'
        raise ValueError(message)

    if height <= 0:
        message = f'An SVG viewBox has a positive height, not {height}.'
        raise ValueError(message)

    return left, top, width, height


def wordmark_markup(wordmark: Wordmark, *, ink: str) -> str:
    if not INK_PATTERN.fullmatch(ink):
        message = f'A wordmark ink is an uppercase hex color or currentColor, not {ink!r}.'
        raise ValueError(message)

    body = [f'<path fill="{ink}" d="{wordmark.path}"/>']
    view_box = f'0 0 {number_text(wordmark.width)} {number_text(wordmark.height)}'

    return svg_markup(
        body=body,
        height=wordmark.height * NOMINAL_SCALE,
        view_box=view_box,
        width=wordmark.width * NOMINAL_SCALE,
    )


def wordmark_read() -> Wordmark:
    if not WORDMARK_SOURCE.is_file():
        message = f'There is no wordmark at {WORDMARK_SOURCE} to compose with.'
        raise FileNotFoundError(message)

    markup = WORDMARK_SOURCE.read_text(encoding='utf-8')
    paths = xml.dom.minidom.parseString(markup).getElementsByTagName('path')
    left, top, width, height = view_box_read(markup)

    if len(paths) != 1:
        message = f'{WORDMARK_SOURCE.name} carries {len(paths)} paths, not one.'
        raise ValueError(message)

    path = paths[0]
    fill = path.getAttribute('fill')

    if fill != 'currentColor':
        message = f'{WORDMARK_SOURCE.name} fills its outline with {fill!r}, not currentColor.'
        raise ValueError(message)

    if path.hasAttribute('transform'):
        message = f'{WORDMARK_SOURCE.name} moves its outline with a transform.'
        raise ValueError(message)

    if left != 0:
        message = f'{WORDMARK_SOURCE.name} starts its viewBox at x {left}, not 0.'
        raise ValueError(message)

    if top != 0:
        message = f'{WORDMARK_SOURCE.name} starts its viewBox at y {top}, not 0.'
        raise ValueError(message)

    return Wordmark(height=height, path=path.getAttribute('d'), width=width)


if __name__ == '__main__':
    main()
