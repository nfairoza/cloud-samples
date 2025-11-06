SELECT
   'AWS' as Cloud,
   REGEXP_REPLACE(line_item_availability_zone, '[a-z]$', '') as Region,
   product_instance_type as Size,
   COUNT(DISTINCT line_item_resource_id) as Quantity,
   CAST(SUM(line_item_usage_amount) as INTEGER) as "Total number of hours per month",
   CASE
       WHEN pricing_purchase_option = 'Reserved' THEN 'Reserved'
       WHEN pricing_purchase_option = 'Spot' THEN 'Spot'
       ELSE 'On-Demand'
   END as "Pricing Model"
FROM
   ${DATABASE_NAME}.${TABLE_NAME}
WHERE
   line_item_line_item_type = 'Usage'
   AND line_item_product_code = 'AmazonEC2'
   AND line_item_usage_type LIKE '%BoxUsage%'
   AND year = CAST(YEAR(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR)
   AND month = LPAD(CAST(MONTH(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR), 2, '0')
GROUP BY
   line_item_availability_zone,
   product_instance_type,
   pricing_purchase_option
ORDER BY
   Size,
   Region,
   "Pricing Model";
