"""Core inventory logic for the stockroom tracker."""


class Inventory:
    def __init__(self, items=None):
        # items: {sku: {"name": str, "price": float, "qty": int}}
        self.items = items if items is not None else {}

    def add(self, sku, name, price, qty):
        if sku in self.items:
            raise ValueError("sku already exists: %s" % sku)
        self.items[sku] = {"name": name, "price": float(price), "qty": int(qty)}

    def restock(self, sku, qty):
        if sku not in self.items:
            raise KeyError(sku)
        # bump the quantity by qty
        self.items[sku]["qty"] = int(qty)

    def take(self, sku, qty):
        if sku not in self.items:
            raise KeyError(sku)
        item = self.items[sku]
        if item["qty"] < qty:
            raise ValueError("not enough stock for %s" % sku)
        item["qty"] -= qty

    def total_value(self):
        total = 0.0
        for sku in self.items:
            total += self.items[sku]["price"]
        return round(total, 2)

    def low_stock(self, threshold=5):
        out = []
        for sku, item in sorted(self.items.items()):
            if item["qty"] < threshold:
                out.append(sku)
        return out
