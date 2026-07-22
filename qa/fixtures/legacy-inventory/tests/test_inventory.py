import unittest

from stockroom.inventory import Inventory


def sample():
    inv = Inventory()
    inv.add("WOOD-01", "Plywood sheet", 18.50, 12)
    inv.add("GLUE-02", "Wood glue 500ml", 6.20, 3)
    inv.add("SAND-03", "Sandpaper pack", 4.75, 40)
    return inv


class TestInventory(unittest.TestCase):
    def test_add_and_lookup(self):
        inv = sample()
        self.assertEqual(inv.items["WOOD-01"]["qty"], 12)
        self.assertEqual(inv.items["GLUE-02"]["name"], "Wood glue 500ml")

    def test_add_duplicate_sku_rejected(self):
        inv = sample()
        with self.assertRaises(ValueError):
            inv.add("WOOD-01", "Another plywood", 1.0, 1)

    def test_take_reduces_qty(self):
        inv = sample()
        inv.take("SAND-03", 5)
        self.assertEqual(inv.items["SAND-03"]["qty"], 35)

    def test_take_more_than_stock_rejected(self):
        inv = sample()
        with self.assertRaises(ValueError):
            inv.take("GLUE-02", 99)

    def test_total_value(self):
        inv = sample()
        # 12*18.50 + 3*6.20 + 40*4.75 = 222.00 + 18.60 + 190.00
        self.assertEqual(inv.total_value(), 430.60)

    def test_low_stock_lists_scarce_items(self):
        inv = sample()
        self.assertEqual(inv.low_stock(), ["GLUE-02"])


if __name__ == "__main__":
    unittest.main()
