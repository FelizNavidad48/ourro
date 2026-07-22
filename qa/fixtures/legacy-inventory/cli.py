#!/usr/bin/env python3
"""stockroom CLI — see README.md for usage."""

import sys

from stockroom.inventory import Inventory
from stockroom import storage


def main(argv):
    if len(argv) < 1:
        print("usage: cli.py add|restock|take|report|low-stock ...")
        return 2
    inv = Inventory(storage.load())
    cmd = argv[0]
    if cmd == "add":
        sku, name, price, qty = argv[1], argv[2], float(argv[3]), int(argv[4])
        inv.add(sku, name, price, qty)
        storage.save(inv.items)
        print("added %s" % sku)
    elif cmd == "restock":
        sku, qty = argv[1], int(argv[2])
        inv.restock(sku, qty)
        storage.save(inv.items)
        print("restocked %s (now %d)" % (sku, inv.items[sku]["qty"]))
    elif cmd == "take":
        sku, qty = argv[1], int(argv[2])
        inv.take(sku, qty)
        storage.save(inv.items)
        print("took %d of %s (now %d)" % (qty, sku, inv.items[sku]["qty"]))
    elif cmd == "report":
        # same table as report.py, Dan never unified them
        print("SKU        NAME                 PRICE    QTY")
        print("-" * 46)
        for sku in sorted(inv.items):
            item = inv.items[sku]
            print("%-10s %-20s %7.2f %6d" % (sku, item["name"], item["price"], item["qty"]))
        print("-" * 46)
        print("total value: %.2f" % inv.total_value())
    elif cmd == "low-stock":
        for sku in inv.low_stock():
            item = inv.items[sku]
            print("%-10s %-20s %7.2f %6d" % (sku, item["name"], item["price"], item["qty"]))
    else:
        print("unknown command: %s" % cmd)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
