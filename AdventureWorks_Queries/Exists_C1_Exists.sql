USE AdventureWorks;
GO

SELECT DISTINCT s.Name
FROM Sales.Store AS s
WHERE EXISTS (SELECT *
      FROM Purchasing.Vendor AS v
      WHERE s.Name = v.Name);
GO
