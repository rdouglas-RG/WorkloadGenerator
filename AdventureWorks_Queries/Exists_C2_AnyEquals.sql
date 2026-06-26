USE AdventureWorks;
GO

SELECT DISTINCT s.Name
FROM Sales.Store AS s
WHERE s.Name = ANY (SELECT v.Name
      FROM Purchasing.Vendor AS v);
GO
