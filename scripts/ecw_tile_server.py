"""
HTTP tile server: reads tiles directly from an ECW source via GDAL.

Serves XYZ Web Mercator PNG tiles at:
    http://127.0.0.1:PORT/{z}/{x}/{y}.png

flutter_map / MapLibre / any standard tile client can consume this directly.

Run:
    C:\\OSGeo4W\\OSGeo4W.bat python ecw_tile_server.py --src israel_tza.ecw

Performance optimizations:
  - LRU cache (in-memory PNG bytes) for repeat tiles
  - Pool of N warped VRTs → N parallel reads (GDAL datasets are NOT thread-safe
    on the same handle, but separate handles in different threads are fine)
  - Single ReadAsArray call for all bands (vs 3 separate per-band reads)
  - PIL/Pillow for PNG encoding (faster than GDAL for 256x256 tiles), with
    fallback to GDAL if Pillow is unavailable
"""
from __future__ import annotations

import argparse
import faulthandler
import hashlib
import io
import json
import math
import multiprocessing as mp
import os
import random
import sys
import tempfile
import threading
import time
import traceback
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Queue

import numpy as np

# C-level fault handler — catches segfaults inside GDAL / ECW SDK and prints
# a Python+C stack trace to stderr before the process dies. Without this,
# native crashes look like a silent process death (exit code -1 on Windows)
# with no Python traceback.
faulthandler.enable(file=sys.stderr, all_threads=True)

os.environ.setdefault("GDAL_DRIVER_PATH", r"C:\OSGeo4W\apps\gdal\lib\gdalplugins")
os.environ.setdefault("GDAL_CACHEMAX", "1024")

from osgeo import gdal
gdal.UseExceptions()
# Silence GDAL's own stderr chatter (e.g. "May be caused by..." secondary
# messages on ECW IReadBlock failures). With UseExceptions() the actual
# errors still raise as RuntimeError; we just don't want the noise.
gdal.PushErrorHandler("CPLQuietErrorHandler")

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

R = 6378137.0
ORIG_SHIFT = math.pi * R
TILE_SIZE = 256


def tile_bounds_merc(z, x, y):
    n = 2 ** z
    res = 2 * ORIG_SHIFT / n
    minx = -ORIG_SHIFT + x * res
    maxx = minx + res
    maxy = ORIG_SHIFT - y * res
    miny = maxy - res
    return minx, miny, maxx, maxy


# ---- multiprocessing worker (own GDAL state per process) -------------------

# Per-process globals (set by `_worker_init`)
_WPROC_HANDLE = None
_WPROC_STRETCH = None


def _worker_init(src_path: str, stretch_low, stretch_high) -> None:
    """Initializer for each Pool worker process — opens its own ECW handle."""
    global _WPROC_HANDLE, _WPROC_STRETCH
    # Same C-level fault handler as parent — without this, a segfault inside
    # the GDAL/ECW SDK in this worker would terminate it silently and the
    # parent's apply_async().get() would just see a BrokenPipeError with no
    # clue where in the C code we crashed.
    faulthandler.enable(file=sys.stderr, all_threads=True)
    os.environ.setdefault(
        "GDAL_DRIVER_PATH", r"C:\OSGeo4W\apps\gdal\lib\gdalplugins")
    # 1GB block cache per worker — ECW decode is the bottleneck; bigger cache
    # = fewer re-reads of overlapping windows during pan/zoom.
    os.environ["GDAL_CACHEMAX"] = "1024"
    # Internal multi-threaded decode within each worker — speeds up cold
    # tiles (zoom-in to fresh area) by parallelising a single ReadAsArray
    # across CPU cores. Workers themselves stay process-isolated.
    os.environ["GDAL_NUM_THREADS"] = "ALL_CPUS"
    from osgeo import gdal as _gdal
    _gdal.UseExceptions()
    _WPROC_HANDLE = _Handle(src_path)
    _WPROC_STRETCH = (stretch_low, stretch_high) if stretch_low is not None else None


def _worker_render(args) -> bytes | None:
    z, x, y = args
    try:
        return _render_with_handle(_WPROC_HANDLE, _WPROC_STRETCH, z, x, y)
    except BaseException:
        # Print traceback to stderr so the parent can see *why* a worker died
        # before multiprocessing pickles the exception and tears it down.
        sys.stderr.write(f"[worker] render z={z} x={x} y={y} crashed:\n")
        sys.stderr.write(traceback.format_exc())
        sys.stderr.flush()
        raise


def _render_with_handle(h, stretch, z: int, x: int, y: int) -> bytes | None:
    mnx, mny, mxx, mxy = tile_bounds_merc(z, x, y)
    px0, py0 = gdal.ApplyGeoTransform(h.inv_gt, mnx, mxy)
    px1, py1 = gdal.ApplyGeoTransform(h.inv_gt, mxx, mny)
    x_off = int(math.floor(min(px0, px1)))
    y_off = int(math.floor(min(py0, py1)))
    x_sz = int(math.ceil(abs(px1 - px0)))
    y_sz = int(math.ceil(abs(py1 - py0)))
    if x_off < 0: x_sz += x_off; x_off = 0
    if y_off < 0: y_sz += y_off; y_off = 0
    if x_off + x_sz > h.W: x_sz = h.W - x_off
    if y_off + y_sz > h.H: y_sz = h.H - y_off
    if x_sz <= 0 or y_sz <= 0:
        return None
    try:
        arr = h.warped.ReadAsArray(
            x_off, y_off, x_sz, y_sz,
            buf_xsize=TILE_SIZE, buf_ysize=TILE_SIZE,
            resample_alg=gdal.GRIORA_Bilinear)
    except RuntimeError:
        try:
            arr = h.warped.ReadAsArray(
                x_off, y_off, x_sz, y_sz,
                buf_xsize=TILE_SIZE, buf_ysize=TILE_SIZE,
                resample_alg=gdal.GRIORA_Average)
        except RuntimeError:
            return None
    if arr is None:
        return None
    if arr.ndim == 2:
        arr = arr[np.newaxis, :, :]
    if h.has_alpha and arr.shape[0] >= 4:
        if not arr[3].any():
            return None
    rgb = np.transpose(arr[:3], (1, 2, 0))
    if not rgb.flags["C_CONTIGUOUS"]:
        rgb = np.ascontiguousarray(rgb)
    if stretch is not None:
        rgb = _apply_stretch(rgb, *stretch)
    return _to_png(rgb)


# ---- per-handle (in-process, used when --workers=0) ------------------------

class _Handle:
    """One opened source + warped VRT, owned by exactly one worker at a time."""
    __slots__ = ("src_path", "src", "warped", "gt", "inv_gt", "W", "H",
                 "total_bands", "nbands", "has_alpha")

    def __init__(self, src_path: str):
        self.src_path = src_path
        self._open()

    def _open(self) -> None:
        self.src = gdal.Open(self.src_path, gdal.GA_ReadOnly)
        if self.src is None:
            raise RuntimeError(f"cannot open {self.src_path}")
        # multithread=False on purpose: GDAL docs say "any given GDALDataset
        # is used only from one thread" — multithread=True causes silent
        # segfaults on ECW source (GDAL #3372) — exactly the no-traceback
        # process exits we chased.
        self.warped = gdal.Warp(
            "", self.src, format="VRT", dstSRS="EPSG:3857",
            resampleAlg=gdal.GRA_Bilinear, multithread=False,
        )
        self.gt = self.warped.GetGeoTransform()
        self.inv_gt = gdal.InvGeoTransform(self.gt)
        self.W = self.warped.RasterXSize
        self.H = self.warped.RasterYSize
        self.total_bands = self.warped.RasterCount
        self.nbands = min(self.total_bands, 3)
        self.has_alpha = self.total_bands >= 4

    def reopen(self) -> None:
        """Close and reopen the GDAL datasets to flush ECW SDK internal state.
        ECW SDK accumulates state per-handle that eventually starts failing
        IReadBlock with 'Could not perform Read/Write on file' — reopening
        clears it. Also flushes GDAL block cache for this handle."""
        self.warped = None
        self.src = None
        gdal.SetCacheMax(0)               # drop all cached blocks
        gdal.SetCacheMax(1024 * 1024 * 1024)  # restore 1GB cache
        self._open()


# ---- LRU cache --------------------------------------------------------------

class _TileCache:
    """Thread-safe LRU cache of (z,x,y) → PNG bytes (or None for blank tile)."""
    __slots__ = ("_data", "_max", "_lock")

    def __init__(self, max_entries: int = 256):
        self._data: OrderedDict = OrderedDict()
        self._max = max_entries
        self._lock = threading.Lock()

    def get(self, key):
        with self._lock:
            v = self._data.get(key, _MISSING)
            if v is not _MISSING:
                self._data.move_to_end(key)
            return v if v is not _MISSING else None

    def has(self, key) -> bool:
        with self._lock:
            return key in self._data

    def put(self, key, value) -> None:
        with self._lock:
            self._data[key] = value
            self._data.move_to_end(key)
            while len(self._data) > self._max:
                self._data.popitem(last=False)

_MISSING = object()


# Pre-built transparent 1x1 PNG — served instead of HTTP 204 for tiles that
# can't be rendered (corrupt blocks, out-of-bounds, blank alpha). Most tile
# clients (incl. flutter_map) try to decode the body as PNG regardless of
# status, and an empty 204 body raises "Invalid image data" exceptions
# which spam the client log and abort layer rendering. A 200 with a real
# (transparent) PNG is decoded successfully and shown as nothing.
_TRANSPARENT_PNG: bytes
if HAS_PIL:
    _buf = io.BytesIO()
    Image.new("RGBA", (1, 1), (0, 0, 0, 0)).save(_buf, format="PNG")
    _TRANSPARENT_PNG = _buf.getvalue()
else:
    # Hard-coded smallest valid 1x1 transparent PNG (67 bytes).
    _TRANSPARENT_PNG = bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15"
        "c4890000000d49444154789c6300010000000005000178d72c0c0000000049"
        "454e44ae426082"
    )


# ---- main state -------------------------------------------------------------

class TileServerState:
    def __init__(self, src_path: str, stretch: tuple | None,
                 pool_size: int = 1, cache_size: int = 1024,
                 disk_cache_dir: str | None = None,
                 workers: int = 0):
        self.src_path = src_path
        self.stretch = stretch
        self.pool: Queue = Queue()
        self.first: _Handle = _Handle(src_path)
        self.pool.put(self.first)
        for _ in range(pool_size - 1):
            self.pool.put(_Handle(src_path))
        h = self.first
        # multiprocessing pool — N independent processes, each with its own
        # GDAL+ECW handle. Cold-tile parallelism scales linearly with N.
        self.mp_pool: mp.pool.Pool | None = None
        self._workers = workers
        # serializes pool re-creation across HTTP threads (only one rebuild
        # per pool death — others retry on the fresh pool).
        self._pool_lock = threading.Lock()
        if workers > 0:
            self.mp_pool = self._build_pool()
            print(f"[ecw] mp pool: {workers} workers", flush=True)
        # disk cache: keyed by hash of (src_path, file_mtime, file_size, stretch)
        # so a different ECW or modified file gets its own subtree.
        if disk_cache_dir is None:
            disk_cache_dir = os.path.join(tempfile.gettempdir(), "ecw_tile_cache")
        st = os.stat(src_path)
        sig = f"{src_path}|{st.st_mtime_ns}|{st.st_size}|{stretch}"
        sigh = hashlib.sha1(sig.encode()).hexdigest()[:16]
        self.disk_cache_root = Path(disk_cache_dir) / sigh
        self.disk_cache_root.mkdir(parents=True, exist_ok=True)
        print(f"[ecw] opened {src_path} pool={pool_size}", flush=True)
        print(f"[ecw] warped {h.W}x{h.H} bands={h.total_bands} "
              f"png={'PIL' if HAS_PIL else 'GDAL'} mem-cache={cache_size}",
              flush=True)
        print(f"[ecw] disk cache: {self.disk_cache_root}", flush=True)
        self.cache = _TileCache(cache_size)
        # Periodic ECW handle reopen — ECW SDK accumulates state per-handle
        # that eventually starts failing IReadBlock with "Could not perform
        # Read/Write on file". Counting actual GDAL reads (cache misses) and
        # reopening every N keeps the SDK healthy. Lock guards the reopen
        # against concurrent renderers in inline mode.
        self._read_count = 0
        self._read_lock = threading.Lock()
        self._reopen_every = 500

    def _build_pool(self) -> mp.pool.Pool:
        ctx = mp.get_context("spawn")
        sl = self.stretch[0] if self.stretch else None
        sh = self.stretch[1] if self.stretch else None
        return ctx.Pool(
            self._workers, initializer=_worker_init,
            initargs=(self.src_path, sl, sh),
        )

    def _recreate_pool(self, dead_pool) -> None:
        """Replace the worker pool after a fatal failure.

        Idempotent: if another thread already replaced ``dead_pool`` we
        skip rebuilding. Caller holds ``_pool_lock``.
        """
        if self.mp_pool is not dead_pool:
            return  # someone else already rebuilt
        try:
            dead_pool.terminate()
            dead_pool.join()
        except Exception:
            pass
        self.mp_pool = self._build_pool()
        sys.stderr.write(
            f"[pool] recreated with {self._workers} workers\n")
        sys.stderr.flush()

    @property
    def W(self): return self.first.W
    @property
    def H(self): return self.first.H
    @property
    def total_bands(self): return self.first.total_bands
    @property
    def nbands(self): return self.first.nbands
    @property
    def has_alpha(self): return self.first.has_alpha
    @property
    def warped(self): return self.first.warped  # for stretch sampling only

    def render_tile(self, z: int, x: int, y: int) -> bytes | None:
        key = (z, x, y)
        # 1. memory LRU
        cached = self.cache.get(key)
        if cached is not None or self.cache.has(key):
            return cached
        # 2. disk cache (positive only — blank markers were removed because
        # they cached transient SDK errors as permanent failures).
        disk_path = self.disk_cache_root / str(z) / str(x) / f"{y}.png"
        if disk_path.is_file():
            try:
                png = disk_path.read_bytes()
                self.cache.put(key, png)
                return png
            except OSError:
                pass
        # 3. render — prefer worker pool for parallelism
        if self.mp_pool is not None:
            png = self._apply_pool(z, x, y)
        else:
            h = self.pool.get()
            try:
                png = self._render_with(h, z, x, y)
            finally:
                self.pool.put(h)
            # periodic handle reopen to flush ECW SDK state (inline mode only —
            # workers are isolated processes, less prone to leak accumulation)
            with self._read_lock:
                self._read_count += 1
                if self._read_count >= self._reopen_every:
                    self._read_count = 0
                    sys.stderr.write(
                        f"[ecw] reopening handle after "
                        f"{self._reopen_every} reads\n")
                    sys.stderr.flush()
                    # drain pool, reopen each handle, refill
                    handles = []
                    while not self.pool.empty():
                        handles.append(self.pool.get_nowait())
                    for h in handles:
                        try:
                            h.reopen()
                        except Exception as e:
                            sys.stderr.write(
                                f"[ecw] reopen failed: {e}\n")
                            sys.stderr.flush()
                    for h in handles:
                        self.pool.put(h)
        # 4. persist — only write actual PNG bytes. None results are NOT
        # cached on disk (intentional regression of the older blank-marker
        # logic, which caused tiles to be permanently marked as failed when
        # they hit a transient ECW SDK error).
        if png is not None:
            try:
                disk_path.parent.mkdir(parents=True, exist_ok=True)
                tmp = disk_path.with_suffix(".png.tmp")
                tmp.write_bytes(png)
                os.replace(tmp, disk_path)
            except OSError:
                pass
        self.cache.put(key, png)
        return png

    # Errors that signal the pool itself is dead (vs. one bad tile). Single-
    # tile errors (RuntimeError from GDAL etc.) propagate as-is so the HTTP
    # handler returns 500 for that one tile only.
    _POOL_DEAD_ERRORS = (BrokenPipeError, EOFError, ConnectionResetError,
                          ConnectionAbortedError)

    def _apply_pool(self, z: int, x: int, y: int) -> bytes | None:
        """Submit one tile render to the worker pool, with one rebuild+retry
        on pool death. Per-tile errors propagate to the caller."""
        # Periodic proactive pool recreation to flush ECW SDK state in
        # workers (mirrors the inline-mode handle reopen). Without this,
        # workers accumulate SDK state until tiles silently start returning
        # transient errors that flutter renders as gray. Pool-recreate cost
        # is ~3-5s on Windows (spawn workers re-import everything) so we
        # don't do it too often.
        with self._read_lock:
            self._read_count += 1
            if self._read_count >= self._reopen_every:
                self._read_count = 0
                pool = self.mp_pool
                sys.stderr.write(
                    f"[pool] proactive recreate after "
                    f"{self._reopen_every} reads\n")
                sys.stderr.flush()
                with self._pool_lock:
                    self._recreate_pool(pool)
        for attempt in (0, 1):
            pool = self.mp_pool
            try:
                # apply_async + get with timeout so a hung worker doesn't
                # block the HTTP thread forever; on timeout we treat the
                # pool as broken and rebuild.
                return pool.apply_async(_worker_render, ((z, x, y),)).get(timeout=20)
            except self._POOL_DEAD_ERRORS as e:
                sys.stderr.write(
                    f"[pool] {type(e).__name__} on z={z} x={x} y={y}: {e} — "
                    f"rebuilding (attempt {attempt})\n")
                sys.stderr.flush()
            except mp.TimeoutError:
                sys.stderr.write(
                    f"[pool] timeout on z={z} x={x} y={y} — rebuilding "
                    f"(attempt {attempt})\n")
                sys.stderr.flush()
            except OSError as e:
                # OSError in apply_async/get usually means the queue/pipe
                # backing the pool is gone — treat as pool death.
                sys.stderr.write(
                    f"[pool] OSError on z={z} x={x} y={y}: {e} — "
                    f"rebuilding (attempt {attempt})\n")
                sys.stderr.flush()
            if attempt == 0:
                with self._pool_lock:
                    self._recreate_pool(pool)
            else:
                # Both attempts failed — give up on this tile.
                raise RuntimeError(
                    f"worker pool unstable for z={z} x={x} y={y}")
        return None

    def _render_with(self, h: _Handle, z: int, x: int, y: int) -> bytes | None:
        mnx, mny, mxx, mxy = tile_bounds_merc(z, x, y)
        px0, py0 = gdal.ApplyGeoTransform(h.inv_gt, mnx, mxy)
        px1, py1 = gdal.ApplyGeoTransform(h.inv_gt, mxx, mny)
        x_off = int(math.floor(min(px0, px1)))
        y_off = int(math.floor(min(py0, py1)))
        x_sz = int(math.ceil(abs(px1 - px0)))
        y_sz = int(math.ceil(abs(py1 - py0)))
        if x_off < 0: x_sz += x_off; x_off = 0
        if y_off < 0: y_sz += y_off; y_off = 0
        if x_off + x_sz > h.W: x_sz = h.W - x_off
        if y_off + y_sz > h.H: y_sz = h.H - y_off
        if x_sz <= 0 or y_sz <= 0:
            return None

        # single multi-band read (all bands incl. alpha if present); fall back
        # to Average on Bilinear failure (corrupt-block tolerant).
        # NOTE: errors are intentionally NOT printed here. ECW files commonly
        # have many bad blocks; printing per-tile floods the captured pipe
        # which back-pressures the HTTP thread → connection RSTs / "fills up".
        try:
            arr = h.warped.ReadAsArray(
                x_off, y_off, x_sz, y_sz,
                buf_xsize=TILE_SIZE, buf_ysize=TILE_SIZE,
                resample_alg=gdal.GRIORA_Bilinear)
        except RuntimeError:
            try:
                arr = h.warped.ReadAsArray(
                    x_off, y_off, x_sz, y_sz,
                    buf_xsize=TILE_SIZE, buf_ysize=TILE_SIZE,
                    resample_alg=gdal.GRIORA_Average)
            except RuntimeError:
                return None
        if arr is None:
            return None
        if arr.ndim == 2:
            arr = arr[np.newaxis, :, :]
        # blank-check via alpha band (if present in warped output)
        if h.has_alpha and arr.shape[0] >= 4:
            if not arr[3].any():
                return None
        rgb = np.transpose(arr[:3], (1, 2, 0))
        if not rgb.flags["C_CONTIGUOUS"]:
            rgb = np.ascontiguousarray(rgb)

        if self.stretch is not None:
            rgb = _apply_stretch(rgb, *self.stretch)

        return _to_png(rgb)


def _apply_stretch(arr: np.ndarray, low, high) -> np.ndarray:
    out = np.empty_like(arr)
    for c in range(3):
        lo, hi = low[c], high[c]
        if hi <= lo:
            out[..., c] = arr[..., c]; continue
        s = (arr[..., c].astype(np.float32) - lo) * (255.0 / (hi - lo))
        out[..., c] = np.clip(s, 0, 255).astype(np.uint8)
    return out


def _to_png(arr: np.ndarray) -> bytes:
    if HAS_PIL:
        img = Image.fromarray(arr, mode="RGB")
        buf = io.BytesIO()
        img.save(buf, format="PNG", compress_level=1)  # speed over size
        return buf.getvalue()
    # GDAL fallback
    h, w, _ = arr.shape
    MEM = gdal.GetDriverByName("MEM")
    PNG = gdal.GetDriverByName("PNG")
    mem = MEM.Create("", w, h, 3, gdal.GDT_Byte)
    for i in range(3):
        mem.GetRasterBand(i + 1).WriteRaster(0, 0, w, h, arr[..., i].tobytes())
    vsi = f"/vsimem/tile_{id(arr)}.png"
    ds = PNG.CreateCopy(vsi, mem); ds = None; mem = None
    f = gdal.VSIFOpenL(vsi, "rb")
    gdal.VSIFSeekL(f, 0, 2); sz = gdal.VSIFTellL(f); gdal.VSIFSeekL(f, 0, 0)
    data = bytes(gdal.VSIFReadL(1, sz, f))
    gdal.VSIFCloseL(f)
    gdal.Unlink(vsi)
    return data


# ---- compute global percentiles (one-time, on startup) ---------------------

def compute_stretch(state: TileServerState, n_samples: int = 80,
                    pct_low: float = 2.0, pct_high: float = 98.0) -> tuple:
    print(f"[stretch] sampling {n_samples} windows for percentiles ...", flush=True)
    h = state.first
    rng = random.Random(42)
    pixels = [[], [], []]
    n = 0
    fails = 0
    max_attempts = n_samples * 10
    attempts = 0
    while n < n_samples and attempts < max_attempts:
        attempts += 1
        x = rng.randint(0, h.W - TILE_SIZE)
        y = rng.randint(0, h.H - TILE_SIZE)
        try:
            if h.has_alpha:
                ab = h.warped.GetRasterBand(h.total_bands).ReadRaster(
                    x, y, TILE_SIZE, TILE_SIZE, 16, 16,
                    buf_type=gdal.GDT_Byte, resample_alg=gdal.GRIORA_NearestNeighbour)
                if ab is None or max(ab) == 0:
                    continue
            arr = h.warped.ReadAsArray(x, y, TILE_SIZE, TILE_SIZE,
                                       buf_xsize=TILE_SIZE, buf_ysize=TILE_SIZE)
        except RuntimeError as e:
            fails += 1
            if fails <= 5:
                print(f"[stretch] skipping bad window x={x} y={y}: {e}", flush=True)
            continue
        if arr is None:
            continue
        if arr.ndim == 2:
            arr = arr[np.newaxis, :, :]
        for b in range(min(arr.shape[0], 3)):
            ch = arr[b].ravel()
            ch = ch[ch > 0]
            if ch.size > 0:
                pixels[b].append(ch)
        n += 1
    if n == 0:
        print("[stretch] WARNING: no usable samples — disabling stretch", flush=True)
        return [0.0, 0.0, 0.0], [255.0, 255.0, 255.0]
    if fails > 0:
        print(f"[stretch] tolerated {fails} bad windows", flush=True)
    low, high = [], []
    for b in range(state.nbands):
        all_px = np.concatenate(pixels[b]) if pixels[b] else np.array([0, 255], dtype=np.uint8)
        lo, hi = np.percentile(all_px, [pct_low, pct_high])
        low.append(float(lo)); high.append(float(hi))
    print(f"[stretch] low={low}  high={high}", flush=True)
    return low, high


# ---- HTTP handler -----------------------------------------------------------

class TileHandler(BaseHTTPRequestHandler):
    state: TileServerState  # set by main()
    # HTTP/1.1 → keep-alive by default → flutter_map can reuse a connection
    # for many tiles, drastically reducing TIME_WAIT socket pressure on
    # Windows (the default ephemeral port range is ~16K and can exhaust
    # under heavy parallel tile loading).
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        path = self.path
        if path == "/" or path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        parts = path.strip("/").split("/")
        if len(parts) != 3 or not parts[2].endswith(".png"):
            self.send_error(404, "expected /{z}/{x}/{y}.png")
            return
        try:
            z = int(parts[0]); x = int(parts[1]); y = int(parts[2][:-4])
        except ValueError:
            self.send_error(400, "bad coords")
            return
        try:
            t0 = time.time()
            png = self.state.render_tile(z, x, y)
            dt = (time.time() - t0) * 1000
        except Exception as e:
            self.send_error(500, str(e)); return
        if png is None:
            # 404 with empty body (Content-Length 0) — flutter_map caches
            # the negative result and won't keep retrying. Better than 200
            # with empty body (decode failure → "Invalid image data") or
            # 200 with transparent PNG (gray on top of base, no caching).
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Render-Ms", f"{dt:.0f}")
        self.send_header("Content-Length", str(len(png)))
        self.end_headers()
        self.wfile.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="path to source ECW")
    ap.add_argument("--port", type=int, default=0, help="0 = random free port")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--no-stretch", action="store_true",
                    help="disable percentile color stretch")
    ap.add_argument("--pool-size", type=int, default=1,
                    help="number of warped-VRT handles. ECW SDK doesn't allow "
                         "multiple handles on the same file → keep at 1; "
                         "speedup comes from LRU cache + GDAL block cache.")
    ap.add_argument("--cache-size", type=int, default=1024,
                    help="LRU memory cache entries (PNG bytes)")
    ap.add_argument("--disk-cache-dir", default=None,
                    help="root for persistent on-disk PNG cache "
                         "(default: %TEMP%\\ecw_tile_cache)")
    ap.add_argument("--workers", type=int, default=0,
                    help="multiprocessing render workers (0 = inline, no MP). "
                         "Recommended: 4 for parallel cold-tile rendering "
                         "during zoom-in.")
    args = ap.parse_args()

    state = TileServerState(args.src, None,
                            pool_size=args.pool_size,
                            cache_size=args.cache_size,
                            disk_cache_dir=args.disk_cache_dir,
                            workers=0)  # build pool AFTER stretch computed
    if not args.no_stretch:
        state.stretch = compute_stretch(state)
    # spin up MP pool now (after stretch params are known)
    if args.workers > 0:
        state._workers = args.workers
        state.mp_pool = state._build_pool()
        print(f"[ecw] mp pool: {args.workers} workers", flush=True)

    TileHandler.state = state
    # Default request_queue_size=5 in stdlib's TCPServer is way too small —
    # flutter_map fires 30-60 parallel tile requests on a viewport, anything
    # past 5 the OS RSTs with errno 10054 ("forcibly closed"). Bump to 512
    # for headroom with 3+ workers and aggressive panning.
    ThreadingHTTPServer.request_queue_size = 512
    # daemon_threads so the per-request handler threads don't block shutdown.
    ThreadingHTTPServer.daemon_threads = True
    httpd = ThreadingHTTPServer((args.host, args.port), TileHandler)
    actual_port = httpd.server_address[1]
    print(f"\nserving at http://{args.host}:{actual_port}/{{z}}/{{x}}/{{y}}.png", flush=True)
    print(f"health:    http://{args.host}:{actual_port}/health", flush=True)
    print(f"\nctrl-c to stop", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")


if __name__ == "__main__":
    main()
