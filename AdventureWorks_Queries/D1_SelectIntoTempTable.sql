USE AdventureWorks;
GO

IF OBJECT_ID(N'#Bicycles', N'U') IS NOT NULL
DROP TABLE #Bicycles;
GO

SELECT *
INTO #Bicycles
FROM AdventureWorks.Production.Product
WHERE ProductNumber LIKE 'BK%';
GO
