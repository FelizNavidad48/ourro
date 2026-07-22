"""Report formatting. Dan copy-pasted most of this from cli.py, sorry."""


def format_report(inv):
    lines = []
    lines.append("SKU        NAME                 PRICE    QTY")
    lines.append("-" * 46)
    for sku in sorted(inv.items):
        item = inv.items[sku]
        lines.append(
            "%-10s %-20s %7.2f %6d" % (sku, item["name"], item["price"], item["qty"])
        )
    lines.append("-" * 46)
    lines.append("total value: %.2f" % inv.total_value())
    return "\n".join(lines)


def format_low_stock(inv, threshold=5):
    lines = []
    lines.append("SKU        NAME                 PRICE    QTY")
    lines.append("-" * 46)
    for sku in inv.low_stock(threshold):
        item = inv.items[sku]
        lines.append(
            "%-10s %-20s %7.2f %6d" % (sku, item["name"], item["price"], item["qty"])
        )
    lines.append("-" * 46)
    return "\n".join(lines)
