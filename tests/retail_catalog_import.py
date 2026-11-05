import csv
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.retail_catalog import CatalogError, FIELDS, main, read_catalog


def row(variant_id="sample1", available="true"):
    values = {
        "catalog_version": "2", "product_id": "sample_product", "id": variant_id,
        "department": "sephora", "brand": "Example Brand", "name": "Example serum",
        "sku_eu": "-", "sku_us": "-", "product_ref_eu": "P10017094", "product_ref_us": "P97989778",
        "category": "skincare/serum", "description": "Short original summary.",
        "color": "-", "variant": "30 ml", "kind": "collectible", "slot": "-",
        "eu_cents": "5000", "us_cents": "5500", "fx_usd_per_eur_x10000": "11000",
        "fx_as_of": "2026-11-05",
        "fx_source": "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html",
        "checked_at": "2026-11-05", "source_eu": "https://www.sephora.fr/p/example.html",
        "source_us": "https://www.sephora.com/product/example.html", "price_note": "-", "available": available,
    }
    return values


def write(path, rows, version=2):
    path = Path(path)
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(f"# catalog_version={version}\n# schema_version=3\n# test snapshot\n")
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        for value in rows:
            value["catalog_version"] = str(version)
            writer.writerow([value[field] for field in FIELDS])


class RetailCatalogImportTests(unittest.TestCase):
    def test_shipped_catalog_is_a_valid_snapshot_with_existing_product_count(self):
        _, rows = read_catalog(Path("data/retail/catalog.tsv"))
        self.assertEqual(len(rows), 27)
        self.assertEqual(len({item["product_id"] for item in rows}), 7)

    def test_validates_realistic_export_shape_and_prices(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.tsv"
            write(path, [row()])
            version, rows = read_catalog(path)
            self.assertEqual((version, rows[0]["id"]), (2, "sample1"))

    def test_rejects_duplicate_ids_invalid_sources_and_bad_prices(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.tsv"
            write(path, [row(), row()])
            with self.assertRaisesRegex(CatalogError, "duplicate variant"):
                read_catalog(path)
            changed = row(); changed["source_us"] = "https://unauthorized.example/product"
            write(path, [changed])
            with self.assertRaisesRegex(CatalogError, "source host"):
                read_catalog(path)
            changed = row(); changed["eu_cents"] = "-1"
            write(path, [changed])
            with self.assertRaisesRegex(CatalogError, "reference price"):
                read_catalog(path)
            changed = row(); changed["product_ref_us"] = "-"
            write(path, [changed])
            with self.assertRaisesRegex(CatalogError, "both regional product references"):
                read_catalog(path)

    def test_apply_merge_keeps_omitted_records_and_archives_only_complete_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "base.tsv"
            incoming = Path(directory) / "incoming.tsv"
            output = Path(directory) / "output.tsv"
            first, second = row("first"), row("second")
            second["product_id"] = "sample_second"
            write(base, [first, second])
            write(incoming, [first])
            preview_output = io.StringIO()
            with contextlib.redirect_stdout(preview_output):
                self.assertEqual(main(["preview", "--base", str(base), "--input", str(incoming)]), 0)
            self.assertIn("absent=1", preview_output.getvalue())
            self.assertFalse(output.exists(), "preview must not write output")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["apply", "--base", str(base), "--input", str(incoming), "--output", str(output)]), 0)
            out_version, out_rows = read_catalog(output)
            self.assertEqual(out_version, 3)
            self.assertEqual({item["id"] for item in out_rows}, {"first", "second"})
            self.assertEqual(next(item for item in out_rows if item["id"] == "second")["available"], "true")
            archived = Path(directory) / "archived.tsv"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["apply", "--base", str(base), "--input", str(incoming), "--output", str(archived), "--complete-snapshot"]), 0)
            _, archived_rows = read_catalog(archived)
            self.assertEqual(next(item for item in archived_rows if item["id"] == "second")["available"], "false")

    def test_failed_update_does_not_replace_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing.tsv"
            output.write_text("keep me", encoding="utf-8")
            with self.assertRaises(CatalogError):
                read_catalog(Path(directory) / "missing.tsv")
            self.assertEqual(output.read_text(encoding="utf-8"), "keep me")

    def test_existing_variant_id_cannot_be_reassigned_to_another_product(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "base.tsv"
            incoming = Path(directory) / "incoming.tsv"
            output = Path(directory) / "out.tsv"
            original, reassigned = row("stable"), row("stable")
            reassigned["product_id"] = "different_product"
            write(base, [original])
            write(incoming, [reassigned])
            with contextlib.redirect_stderr(io.StringIO()):
                result = main(["apply", "--base", str(base), "--input", str(incoming), "--output", str(output)])
            self.assertEqual(result, 2)
            self.assertFalse(output.exists())

    def test_product_references_must_be_consistent_across_variants(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "conflict.tsv"
            first, second = row("first"), row("second")
            second["product_ref_us"] = "P97989779"
            write(path, [first, second])
            with self.assertRaisesRegex(CatalogError, "conflicting metadata"):
                read_catalog(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
