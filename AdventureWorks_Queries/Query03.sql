-- Target Execution: ~2 to 4 seconds
SELECT 
    th.TransactionID,
    th.ProductID,
    th.TransactionDate,
    th.Quantity,
    th.ActualCost,
    SUM(th.Quantity) OVER(PARTITION BY th.ProductID ORDER BY th.TransactionDate) AS RunningQty,
    AVG(th.ActualCost) OVER(PARTITION BY DATEPART(month, th.TransactionDate)) AS MonthlyAvgCost,
    RANK() OVER(PARTITION BY th.ProductID ORDER BY th.ActualCost DESC) AS CostRank,
    LEAD(th.ActualCost, 1) OVER(PARTITION BY th.ProductID ORDER BY th.TransactionDate) AS NextCost
FROM Production.TransactionHistory th
ORDER BY CostRank DESC, th.TransactionDate ASC;
