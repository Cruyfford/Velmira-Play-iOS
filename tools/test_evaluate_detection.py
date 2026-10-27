#!/usr/bin/env python3
"""Tests for offline detector metrics (no model or gameplay automation involved)."""
import unittest
from evaluate_detection import evaluate, iou


def obj(box, side="enemy"):
    return {"box": box, "side": side}


class EvaluationTests(unittest.TestCase):
    def test_iou_identical(self):
        self.assertEqual(iou([0.1, 0.1, 0.2, 0.2], [0.1, 0.1, 0.2, 0.2]), 1.0)

    def test_iou_disjoint(self):
        self.assertEqual(iou([0.1, 0.1, 0.1, 0.1], [0.7, 0.7, 0.1, 0.1]), 0.0)

    def test_true_positive(self):
        report = evaluate({"frames": [{"id": "1", "truth": [obj([0.1, 0.1, 0.2, 0.2])],
                                       "predictions": [obj([0.1, 0.1, 0.2, 0.2])]}]})
        self.assertEqual((report["TP"], report["FP"], report["FN"]), (1, 0, 0))
        self.assertEqual(report["precision"], 1.0)
        self.assertEqual(report["recall"], 1.0)

    def test_false_positive_and_false_negative(self):
        report = evaluate({"frames": [
            {"id": "1", "truth": [obj([0.1, 0.1, 0.2, 0.2])],
             "predictions": [obj([0.7, 0.7, 0.1, 0.1])]}]})
        self.assertEqual((report["TP"], report["FP"], report["FN"]), (0, 1, 1))

    def test_duplicate_predictions_not_double_counted(self):
        box = [0.1, 0.1, 0.2, 0.2]
        report = evaluate({"frames": [{"truth": [obj(box)], "predictions": [obj(box), obj(box)]}]})
        self.assertEqual((report["TP"], report["FP"], report["FN"]), (1, 1, 0))
        self.assertEqual(report["precision"], 0.5)

    def test_friendly_misidentified_as_enemy(self):
        box = [0.1, 0.1, 0.2, 0.2]
        report = evaluate({"frames": [{"truth": [obj(box, "friendly")],
                                       "predictions": [obj(box, "enemy")]}]}, "enemy")
        self.assertEqual((report["TP"], report["FP"], report["FN"]), (0, 1, 0))

    def test_unreturned_enemy_is_a_miss(self):
        box = [0.1, 0.1, 0.2, 0.2]
        report = evaluate({"frames": [{"truth": [obj(box)], "predictions": []}]})
        self.assertEqual((report["TP"], report["FP"], report["FN"]), (0, 0, 1))
        self.assertIsNone(report["precision"])
        self.assertEqual(report["recall"], 0.0)

    def test_empty_data_is_not_100_percent_precision(self):
        report = evaluate({"frames": []})
        self.assertIsNone(report["precision"])
        self.assertIsNone(report["recall"])

    def test_invalid_geometry(self):
        with self.assertRaises(ValueError):
            evaluate({"frames": [{"id": "bad", "truth": [obj([-0.1, 0, 0.3, 0.3])],
                                  "predictions": []}]})


if __name__ == "__main__":
    unittest.main()
