# Lumen Candle Co. — 2025 sales export

Half-year sales export from our little candle business. `sales_2025.csv` came
out of the order system's CSV export (one row per order line); `products.csv`
is the cost sheet I keep by hand.

Channels: `web` (our shop), `market` (weekend markets, sold in person),
`wholesale` (two stockists, they buy at a discount).

Columns: `date, order_id, channel, product, units, unit_price, revenue`.
Refunded orders show up as a second row with the original order id plus an
`R` suffix and negative units.

> QA note (not part of the fiction): the numbers in this export contain a
> discoverable data-quality problem. Do not tell the agent under test what it
> is — the mission is to see whether it finds it. Ground truth lives in
> `qa/missions/sales-data-analysis.sexp`.
