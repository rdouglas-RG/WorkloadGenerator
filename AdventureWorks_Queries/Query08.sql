SELECT TOP (120000)
    sod.SalesOrderID,
    sod.SalesOrderDetailID,
    sod.UnitPrice,
    -- Complex cascading math that hammers CPU floating-point units
    MathGrind = SIN(sod.UnitPrice) * COS(sod.OrderQty) / NULLIF(LOG10(sod.SalesOrderDetailID), 0),
    RandomWeight = ABS(CHECKSUM(NEWID())) % 1000
FROM Sales.SalesOrderDetail sod
CROSS JOIN Production.ProductCategory pc
WHERE 
    -- The WHERE clause math forces execution before any rows can be discarded
    (ABS(SIN(CAST(sod.SalesOrderID AS INT))) * 100) >= 0.00
ORDER BY 
    MathGrind ASC, 
    RandomWeight DESC;
