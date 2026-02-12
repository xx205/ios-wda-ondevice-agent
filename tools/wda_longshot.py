import argparse, base64, hashlib, io, json, os, time
from dataclasses import dataclass
from urllib.request import urlopen, Request

try:
    from PIL import Image
except Exception as e:
    raise SystemExit('Pillow required: pip install pillow')

try:
    import numpy as np
except Exception as e:
    raise SystemExit("numpy required: pip install numpy")


def jget(url: str, timeout=10):
    with urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def post(url: str, payload: dict, timeout=10):
    req = Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    with urlopen(req, timeout=timeout) as r:
        data = r.read().decode('utf-8')
    return json.loads(data)


@dataclass
class Capture:
    path: str
    sha256: str
    crop_sha256: str
    size: tuple[int, int]


def w3c_actions_tap(base: str, sid: str, x: int, y: int):
    payload = {
        'actions': [
            {
                'type': 'pointer',
                'id': 'finger1',
                'parameters': {'pointerType': 'touch'},
                'actions': [
                    {'type': 'pointerMove', 'duration': 0, 'x': int(x), 'y': int(y)},
                    {'type': 'pointerDown', 'button': 0},
                    {'type': 'pause', 'duration': 40},
                    {'type': 'pointerUp', 'button': 0},
                ],
            }
        ]
    }
    post(f'{base}/session/{sid}/actions', payload, timeout=10)


def w3c_actions_swipe(base: str, sid: str, x: int, y1: int, y2: int, duration_ms: int):
    payload = {
        'actions': [
            {
                'type': 'pointer',
                'id': 'finger1',
                'parameters': {'pointerType': 'touch'},
                'actions': [
                    {'type': 'pointerMove', 'duration': 0, 'x': int(x), 'y': int(y1)},
                    {'type': 'pointerDown', 'button': 0},
                    {'type': 'pause', 'duration': 60},
                    {'type': 'pointerMove', 'duration': int(duration_ms), 'x': int(x), 'y': int(y2)},
                    {'type': 'pointerUp', 'button': 0},
                ],
            }
        ]
    }
    post(f'{base}/session/{sid}/actions', payload, timeout=15)


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def crop_for_compare(im: Image.Image, top_trim: int, bottom_trim: int) -> Image.Image:
    w, h = im.size
    left = int(w * 0.12)
    right = int(w * 0.88)
    top = top_trim
    bottom = max(top + 1, h - bottom_trim)
    return im.crop((left, top, right, bottom)).convert('L')


def take_screenshot_png(base: str) -> bytes:
    obj = jget(f'{base}/screenshot', timeout=30)
    b64 = obj.get('value') or ''
    return base64.b64decode(b64)


def capture_one(base: str, outdir: str, idx: int, top_trim: int, bottom_trim: int) -> Capture:
    png = take_screenshot_png(base)
    path = os.path.join(outdir, f'{idx:02d}.png')
    with open(path, 'wb') as f:
        f.write(png)
    im = Image.open(io.BytesIO(png)).convert('RGB')
    crop = crop_for_compare(im, top_trim=top_trim, bottom_trim=bottom_trim)
    crop_bytes = crop.tobytes()
    return Capture(path=path, sha256=sha256_bytes(png), crop_sha256=sha256_bytes(crop_bytes), size=im.size)


def best_overlap(prev: Image.Image, nxt: Image.Image, *, top_trim: int, bottom_trim: int) -> int:
    # Find overlap height (pixels) by matching bottom of prev to top of nxt on a central band.
    pw, ph = prev.size
    nw, nh = nxt.size
    if pw != nw:
        raise ValueError('width mismatch')

    band_left = int(pw * 0.12)
    band_right = int(pw * 0.88)

    prev_gray = prev.convert('L')
    nxt_gray = nxt.convert('L')

    prev_use = prev_gray.crop((band_left, top_trim, band_right, ph - bottom_trim))
    nxt_use = nxt_gray.crop((band_left, top_trim, band_right, nh - bottom_trim))

    # Candidate overlap range
    max_o = min(prev_use.size[1], nxt_use.size[1], 1200)
    min_o = min(250, max_o)

    prev_arr = prev_use.tobytes()
    nxt_bytes = nxt_use.tobytes()

    pa = np.frombuffer(prev_arr, dtype=np.uint8).reshape(prev_use.size[1], prev_use.size[0])
    na = np.frombuffer(nxt_bytes, dtype=np.uint8).reshape(nxt_use.size[1], nxt_use.size[0])

    best_o = min_o
    best_score = None
    # coarse-to-fine search
    for step in (16, 4, 1):
        start = max(min_o, best_o - 80)
        end = min(max_o, best_o + 80)
        if best_score is None:
            start, end = min_o, max_o
        for o in range(start, end + 1, step):
            ps = pa[-o:, :]
            ns = na[:o, :]
            score = float(np.mean(np.abs(ps.astype(np.int16) - ns.astype(np.int16))))
            if best_score is None or score < best_score:
                best_score = score
                best_o = o
    return int(best_o)


def stitch(paths: list[str], out_path: str, *, top_trim: int, bottom_trim: int):
    ims = [Image.open(p).convert('RGB') for p in paths]
    w, h = ims[0].size

    overlaps = []
    for i in range(1, len(ims)):
        o = best_overlap(ims[i-1], ims[i], top_trim=top_trim, bottom_trim=bottom_trim)
        overlaps.append(o)

    # Assemble
    pieces = []
    # first: drop bottom tab area unless it's also last
    first = ims[0]
    if len(ims) > 1:
        first = first.crop((0, 0, w, h - bottom_trim))
    pieces.append(first)

    for i in range(1, len(ims)):
        im = ims[i]
        # drop bottom trim for intermediates
        if i < len(ims) - 1:
            im = im.crop((0, 0, w, h - bottom_trim))
        cut_top = top_trim + overlaps[i-1]
        if cut_top >= im.size[1]:
            continue
        pieces.append(im.crop((0, cut_top, w, im.size[1])))

    total_h = sum(p.size[1] for p in pieces)
    out = Image.new('RGB', (w, total_h), (0, 0, 0))
    y = 0
    for p in pieces:
        out.paste(p, (0, y))
        y += p.size[1]

    out.save(out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='http://127.0.0.1:8100')
    ap.add_argument('--outdir', default=None)
    ap.add_argument('--max', type=int, default=30)
    ap.add_argument('--scroll_fraction', type=float, default=0.33)
    ap.add_argument('--top_trim', type=int, default=220)
    ap.add_argument('--bottom_trim', type=int, default=260)
    args = ap.parse_args()

    base = args.base.rstrip('/')

    locked = jget(f'{base}/wda/locked', timeout=5).get('value')
    if locked:
        raise SystemExit('device is locked')

    sess = post(f'{base}/session', {'capabilities': {'alwaysMatch': {'platformName': 'iOS'}}}, timeout=10)
    sid = sess['value']['sessionId']
    size = jget(f'{base}/session/{sid}/window/size', timeout=10)['value']
    sw, sh = size['width'], size['height']

    outdir = args.outdir or f"/tmp/runpage_longshot_{time.strftime('%Y%m%d_%H%M%S')}"
    os.makedirs(outdir, exist_ok=True)

    # scroll to top (drag down)
    for _ in range(6):
        w3c_actions_swipe(base, sid, x=sw//2, y1=int(sh*0.25), y2=int(sh*0.86), duration_ms=280)
        time.sleep(0.15)

    caps: list[Capture] = []
    caps.append(capture_one(base, outdir, 0, top_trim=args.top_trim, bottom_trim=args.bottom_trim))

    same_count = 0
    for i in range(1, args.max):
        # scroll down (drag up)
        y1 = int(sh * (0.72))
        y2 = int(sh * (0.72 - args.scroll_fraction))
        y2 = max(int(sh*0.18), y2)
        w3c_actions_swipe(base, sid, x=sw//2, y1=y1, y2=y2, duration_ms=420)
        time.sleep(0.25)
        cap = capture_one(base, outdir, i, top_trim=args.top_trim, bottom_trim=args.bottom_trim)
        if cap.crop_sha256 == caps[-1].crop_sha256:
            same_count += 1
        else:
            same_count = 0
        caps.append(cap)
        if same_count >= 2:
            break

    paths = [c.path for c in caps]
    out_path = os.path.join(outdir, 'runpage_long.png')
    stitch(paths, out_path, top_trim=args.top_trim, bottom_trim=args.bottom_trim)

    print(outdir)
    print(out_path)
    print('frames', len(paths))


if __name__ == '__main__':
    main()
