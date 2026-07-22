# stockroom

Inventory tracker for the community makerspace. Tracks what's on the shelves,
what's running low, and what it's all worth.

Written by Dan before he moved away. He said the tests pass. They don't.

## Usage

    python3 cli.py add SKU NAME PRICE QTY
    python3 cli.py restock SKU QTY
    python3 cli.py take SKU QTY
    python3 cli.py report
    python3 cli.py low-stock

Data lives in `data/stock.json`.

## Tests

    make test
