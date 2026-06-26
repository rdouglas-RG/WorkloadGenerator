SELECT 
    th.TransactionID,
    p.[Name] AS ProductName,
    LengthCheck = LEN(p.[Name]) + LEN(p.ProductNumber),
    ScrambledID = REPLACE(CAST(th.TransactionID AS VARCHAR(50)), '1', 'A')
FROM Production.TransactionHistory th
INNER JOIN Production.Product p 
    -- The join key matches, but the floor/exponent math forces an implicit expression evaluation for every single comparison
    ON th.ProductID = p.ProductID 
   AND FLOOR(LOG10(th.ProductID) * 100) = FLOOR(LOG10(p.ProductID) * 100)
WHERE 
    -- Complex non-SARGable string & math operations over the tables
    REPLACE(p.[Name], ' ', '') LIKE '%[0-9]%' 
    OR (th.Quantity * 1.075 / 3.14) > 0.5
ORDER BY 
    LengthCheck DESC, 
    th.TransactionDate ASC;
