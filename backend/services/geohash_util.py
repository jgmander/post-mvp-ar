"""Pure-Python standard Geohash encoder and 8-neighbor calculator (zero C++/Rust build deps)."""

_BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"
_DECODE_MAP = {ch: idx for idx, ch in enumerate(_BASE32)}


def encode(latitude: float, longitude: float, precision: int = 7) -> str:
    lat_min, lat_max = -90.0, 90.0
    lon_min, lon_max = -180.0, 180.0
    is_even = True
    bit = 0
    ch = 0
    chars: list[str] = []

    while len(chars) < precision:
        if is_even:
            mid = (lon_min + lon_max) / 2.0
            if longitude > mid:
                ch = (ch << 1) | 1
                lon_min = mid
            else:
                ch = ch << 1
                lon_max = mid
        else:
            mid = (lat_min + lat_max) / 2.0
            if latitude > mid:
                ch = (ch << 1) | 1
                lat_min = mid
            else:
                ch = ch << 1
                lat_max = mid

        is_even = not is_even
        if bit < 4:
            bit += 1
        else:
            chars.append(_BASE32[ch])
            bit = 0
            ch = 0

    return "".join(chars)


def decode_bbox(hashcode: str) -> tuple[float, float, float, float]:
    """Returns (lat_min, lat_max, lon_min, lon_max) for a geohash."""
    lat_min, lat_max = -90.0, 90.0
    lon_min, lon_max = -180.0, 180.0
    is_even = True

    for char in hashcode.lower():
        val = _DECODE_MAP[char]
        for mask in (16, 8, 4, 2, 1):
            if is_even:
                mid = (lon_min + lon_max) / 2.0
                if val & mask:
                    lon_min = mid
                else:
                    lon_max = mid
            else:
                mid = (lat_min + lat_max) / 2.0
                if val & mask:
                    lat_min = mid
                else:
                    lat_max = mid
            is_even = not is_even

    return lat_min, lat_max, lon_min, lon_max


def _wrap_lon(lon: float) -> float:
    if lon > 180.0:
        return lon - 360.0
    if lon < -180.0:
        return lon + 360.0
    return lon


def neighbors(hashcode: str) -> list[str]:
    """Returns the 8 surrounding geohash cells at the same precision."""
    precision = len(hashcode)
    lat_min, lat_max, lon_min, lon_max = decode_bbox(hashcode)
    d_lat = lat_max - lat_min
    d_lon = lon_max - lon_min
    c_lat = (lat_min + lat_max) / 2.0
    c_lon = (lon_min + lon_max) / 2.0

    out: list[str] = []
    for lat_step in (-1, 0, 1):
        for lon_step in (-1, 0, 1):
            if lat_step == 0 and lon_step == 0:
                continue
            n_lat = max(-89.999999, min(89.999999, c_lat + lat_step * d_lat))
            n_lon = _wrap_lon(c_lon + lon_step * d_lon)
            out.append(encode(n_lat, n_lon, precision=precision))
    return out
