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
        self.assertEqual(len(rows), 30)
        self.assertEqual(len({item["product_id"] for item in rows}), 10)
        original_ids = {
            "bhydra50", "blushhope", "blushjoy", "blushhappy", "blushgrateful", "blushgrace", "blushlove",
            "define0", "define2", "define4", "define6", "define8", "define10", "define12", "define14",
            "heartneck", "ring48", "ring50", "ring52", "ring54", "ring56", "ring58", "ring60",
            "rainbowneck", "bracelet16", "bracelet21", "bracelet23",
        }
        by_id = {item["id"]: item for item in rows}
        self.assertTrue(original_ids.issubset(by_id))
        self.assertEqual(len(original_ids), 27)
        expected_prices = {
            "de_bhydra": ("5200", "5600"), "rare_softpinch": ("2900", "2500"),
            "lulu_define": ("12800", "12800"), "pandora_heart": ("7500", "9800"),
            "pandora_elevated_heart_ring": ("6900", "9800"), "pandora_rainbow": ("13900", "19000"),
            "pandora_moments": ("11900", "20000"),
        }
        for item in rows:
            if item["product_id"] in expected_prices:
                self.assertEqual((item["eu_cents"], item["us_cents"]), expected_prices[item["product_id"]])
        additions = {item["product_id"]: item for item in rows if item["product_id"] in {
            "rare_positive_light_gloss", "lulu_align25", "pandora_snowflake_charm"}}
        self.assertEqual(set(additions), {"rare_positive_light_gloss", "lulu_align25", "pandora_snowflake_charm"})
        self.assertEqual((additions["rare_positive_light_gloss"]["eu_cents"],
                          additions["rare_positive_light_gloss"]["us_cents"]), ("2200", "2000"))
        self.assertEqual(additions["rare_positive_light_gloss"]["source_eu"].split("/")[2], "www.sephora.fr")
        self.assertEqual(additions["lulu_align25"]["name"], 'lululemon Align™ High-Rise Pant 25"')
        self.assertEqual(additions["pandora_snowflake_charm"]["product_ref_eu"], "764249C01")

    def test_importer_round_trips_exact_product_names_with_quotes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "quoted.tsv"
            value = row()
            value["name"] = 'Official product name, 25"'
            write(path, [value])
            _, rows = read_catalog(path)
            self.assertEqual(rows[0]["name"], 'Official product name, 25"')

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
