#!/usr/bin/env python3
"""Validate and review an authorized retail TSV export; never fetches retailer data."""
import argparse
import csv
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

SCHEMA_VERSION = 3
FIELDS = ["catalog_version", "product_id", "id", "department", "brand", "name", "sku_eu", "sku_us",
          "product_ref_eu", "product_ref_us", "category",
          "description", "color", "variant", "kind", "slot", "eu_cents", "us_cents",
          "fx_usd_per_eur_x10000", "fx_as_of", "fx_source", "checked_at", "source_eu", "source_us",
          "price_note", "available"]
ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
RETAIL_DOMAINS = {
    "sephora": ("sephora.com", "sephora.fr", "sephora.de", "sephora.it", "sephora.es"),
    "lululemon": ("lululemon.com", "lululemon.de", "lululemon.fr", "lululemon.co.uk"),
    "pandora": ("pandora.net",),
}
ECB = "www.ecb.europa.eu"


class CatalogError(ValueError):
    pass


def read_catalog(path):
    path = Path(path)
    version = None
    rows = []
    seen = set()
    products = {}
    try:
        handle = path.open("r", encoding="utf-8", newline="")
    except OSError as exc:
        raise CatalogError(f"cannot read {path}: {exc}") from exc
    with handle:
        first = handle.readline().rstrip("\r\n")
        second = handle.readline().rstrip("\r\n")
        match = re.fullmatch(r"# catalog_version=(\d+)", first)
        if not match or int(match.group(1)) < 1:
            raise CatalogError("first line must be # catalog_version=<positive integer>")
        if second != f"# schema_version={SCHEMA_VERSION}":
            raise CatalogError(f"second line must be # schema_version={SCHEMA_VERSION}")
        version = int(match.group(1))
        for line_number, line in enumerate(handle, 3):
            if not line.strip() or line.startswith("#"):
                continue
            values = next(csv.reader([line], delimiter="\t"))
            if len(values) != len(FIELDS):
                raise CatalogError(f"line {line_number}: expected {len(FIELDS)} tab-separated columns")
            row = dict(zip(FIELDS, values))
            validate_row(row, line_number, version)
            if row["id"] in seen:
                raise CatalogError(f"line {line_number}: duplicate variant ID {row['id']}")
            seen.add(row["id"])
            signature = tuple(row[key] for key in ("department", "brand", "name", "category", "description", "color", "kind", "slot",
                                                   "product_ref_eu", "product_ref_us"))
            previous = products.setdefault(row["product_id"], signature)
            if previous != signature:
                raise CatalogError(f"line {line_number}: conflicting metadata for product {row['product_id']}")
            rows.append(row)
    if not rows:
        raise CatalogError("catalog contains no variant rows")
    return version, rows


def host_allowed(url, suffixes):
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        return False
    host = parsed.hostname.lower()
    return any(host == suffix or host.endswith("." + suffix) for suffix in suffixes)


def integer(text, minimum, maximum):
    if not re.fullmatch(r"[0-9]+", text or ""):
        return None
    value = int(text)
    return value if minimum <= value <= maximum else None


def validate_row(row, line, version):
    if integer(row["catalog_version"], 1, 2147483647) != version:
        raise CatalogError(f"line {line}: row catalog version differs from file version")
    for key, limit in (("id", 32), ("product_id", 64)):
        if not ID.fullmatch(row[key]) or len(row[key]) > limit:
            raise CatalogError(f"line {line}: invalid {key}")
    if row["department"] not in RETAIL_DOMAINS:
        raise CatalogError(f"line {line}: unsupported department")
    if any(not row[key] or len(row[key]) > maximum for key, maximum in
           (("brand", 80), ("name", 160), ("product_ref_eu", 100), ("product_ref_us", 100), ("category", 80),
            ("description", 500), ("variant", 100))):
        raise CatalogError(f"line {line}: missing or overlong product field")
    for key in ("sku_eu", "sku_us", "product_ref_eu", "product_ref_us"):
        if row[key] != "-" and not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", row[key]):
            raise CatalogError(f"line {line}: invalid regional SKU/reference")
    if row["product_ref_eu"] == "-" or row["product_ref_us"] == "-":
        raise CatalogError(f"line {line}: both regional product references are required")
    if any(any(char in row[key] for char in "\r\n\t\x00") for key in FIELDS):
        raise CatalogError(f"line {line}: control character in field")
    if (row["kind"] not in ("fashion", "collectible") or row["slot"] not in
            ("-", "outfit", "head", "accessory", "ring", "necklace", "bracelet")):
        raise CatalogError(f"line {line}: invalid kind or slot")
    if row["available"] not in ("true", "false"):
        raise CatalogError(f"line {line}: availability must be true or false")
    eu = integer(row["eu_cents"], 1, 100_000_000)
    us = integer(row["us_cents"], 1, 100_000_000)
    fx = integer(row["fx_usd_per_eur_x10000"], 5000, 20000)
    if None in (eu, us, fx):
        raise CatalogError(f"line {line}: invalid reference price or FX rate")
    for key in ("fx_as_of", "checked_at"):
        if not DATE.fullmatch(row[key]):
            raise CatalogError(f"line {line}: invalid {key} date")
    if not host_allowed(row["fx_source"], (ECB,)):
        raise CatalogError(f"line {line}: FX source must be ECB HTTPS")
    if not host_allowed(row["source_eu"], RETAIL_DOMAINS[row["department"]]) or not host_allowed(
            row["source_us"], RETAIL_DOMAINS[row["department"]]):
        raise CatalogError(f"line {line}: product source host does not match department")
    # Existing pricing implementation's half-up integer formula, using cent values.
    converted_us = (us * 10_000 * 2 + fx) // (2 * fx)
    coin_price = ((eu + converted_us) * 25 * 2 + 19) // (19 * 2)
    if not 1 <= coin_price <= 1_000_000_000:
        raise CatalogError(f"line {line}: calculated Coin amount overflows supported range")


def row_key(row):
    return row["id"]


def diff(base, incoming):
    old = {row_key(row): row for row in base}
    new = {row_key(row): row for row in incoming}
    added = sorted(new.keys() - old.keys())
    changed = sorted(key for key in new.keys() & old.keys()
                     if any(new[key][field] != old[key][field] for field in FIELDS if field != "catalog_version"))
    removed = sorted(old.keys() - new.keys())
    return added, changed, removed


def write_catalog_atomic(output, version, rows):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=str(output.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(f"# catalog_version={version}\n")
            handle.write(f"# schema_version={SCHEMA_VERSION}\n")
            handle.write(f"# Molly retail catalog. TSV schema={SCHEMA_VERSION}; one immutable variant snapshot per row.\n")
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            # Stable sort groups product rows while preserving curated variant order.
            for row in sorted(rows, key=lambda item: item["product_id"]):
                writer.writerow([row[field] for field in FIELDS])
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate", help="validate an authorized TSV snapshot")
    validate.add_argument("input")
    preview = sub.add_parser("preview", help="show changes without writing")
    preview.add_argument("--base", required=True)
    preview.add_argument("--input", required=True)
    apply = sub.add_parser("apply", help="merge a reviewed import atomically")
    apply.add_argument("--base", required=True)
    apply.add_argument("--input", required=True)
    apply.add_argument("--output", required=True)
    apply.add_argument("--complete-snapshot", action="store_true",
                       help="archive omitted old rows; only use for an authorized complete export")
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            version, rows = read_catalog(args.input)
            print(f"valid: catalog v{version}, {len(rows)} variants, {len({r['product_id'] for r in rows})} products")
            return 0
        base_version, base = read_catalog(args.base)
        import_version, incoming = read_catalog(args.input)
        added, changed, removed = diff(base, incoming)
        print(f"base v{base_version}; import v{import_version}; added={len(added)} changed={len(changed)} absent={len(removed)}")
        for title, values in (("added", added), ("changed", changed), ("absent", removed)):
            for value in values[:100]:
                print(f"{title}: {value}")
            if len(values) > 100:
                print(f"{title}: ... {len(values) - 100} more")
        if args.command == "preview":
            return 0
        merged = {row_key(row): dict(row) for row in base}
        for row in incoming:
            previous = merged.get(row_key(row))
            if previous and previous["product_id"] != row["product_id"]:
                raise CatalogError(f"variant ID {row['id']} cannot be reassigned to another product")
            merged[row_key(row)] = dict(row)
        if args.complete_snapshot:
            for key in removed:
                merged[key]["available"] = "false"
        # Bump once per accepted import and stamp every row for an internally consistent snapshot.
        version = max(base_version, import_version) + 1
        for row in merged.values():
            row["catalog_version"] = str(version)
        write_catalog_atomic(args.output, version, merged.values())
        print(f"wrote v{version}: {len(merged)} variants; absent rows {'archived' if args.complete_snapshot else 'retained unchanged'}")
        return 0
    except (CatalogError, OSError, csv.Error) as exc:
        print(f"catalog import rejected: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
