SELECT
   'AWS' as Cloud,
   REGEXP_REPLACE(availability_zone, '[a-z]$', '') as Region,
   product_instance_type as Size,
   COUNT(DISTINCT resource_id) as Quantity,
   CAST(SUM(usage_amount) as INTEGER) as "Total number of hours per month",
   CASE
       WHEN purchase_option = 'Reserved' THEN 'Reserved'
       WHEN purchase_option = 'Spot' THEN 'Spot'
       WHEN purchase_option = 'On-Demand' THEN 'On-Demand'
       ELSE 'not supported'
   END as "Pricing Model"
FROM
   your_database.your_cur_table
WHERE
   record_type = 'LineItem'
   AND product_code = 'AmazonEC2'
   AND usage_type LIKE '%BoxUsage%'
   AND product_instance_type LIKE '%a.%'
   AND year = CAST(YEAR(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR)
   AND month = LPAD(CAST(MONTH(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR), 2, '0')
GROUP BY
   availability_zone,
   product_instance_type,
   purchase_option
ORDER BY
   Size,
   Region,
   "Pricing Model"
