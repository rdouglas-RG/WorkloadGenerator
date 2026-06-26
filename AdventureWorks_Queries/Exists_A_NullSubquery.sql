USE AdventureWorks;
GO

SELECT DepartmentID, Name
FROM HumanResources.Department
WHERE EXISTS (SELECT NULL)
ORDER BY Name ASC;
