# Target contract: canonical order lines (JSON)

Output a JSON array with ONE object per data row of the partner file, in file order:

```json
[
  {
    "orderId": "4711",
    "customer": "Contoso Retail",
    "orderDate": "2026-09-03",
    "sku": "SKU-100",
    "quantity": 5,
    "unitPrice": 12.5,
    "lineTotal": 62.5
  }
]
```

Rules:
- `orderDate` is ISO 8601 (`yyyy-MM-dd`).
- `quantity` is an integer; `unitPrice` and `lineTotal` are JSON numbers.
- `lineTotal` = `quantity` x `unitPrice`, rounded to 2 decimals.
- Values must match the partner file exactly (same order, same prices).
