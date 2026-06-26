USE AdventureWorks;
GO

SELECT pp.FirstName,
    pp.LastName,
    e.NationalIDNumber
FROM HumanResources.Employee AS e WITH (INDEX (AK_Employee_NationalIDNumber))
INNER JOIN Person.Person AS pp
    ON e.BusinessEntityID = pp.BusinessEntityID
WHERE LastName = 'Johnson';
GO
