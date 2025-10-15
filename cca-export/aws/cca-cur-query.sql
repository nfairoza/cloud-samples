-- The Athena SQL query below is intended for environments where the AWS Cost and Usage Report (CUR)
-- is already configured with Athena and a Glue crawler is set up to keep the schema up to date.
-- This setup is fairly common among customers with FinOps practices in place,
--  making this one of the easiest ways to extract clean, actionable usage data.

SELECT
   'AWS' as Cloud,
   REGEXP_REPLACE(line_item_availability_zone, '[a-z]$', '') as Region,
   product_instance_type as Size,
   COUNT(DISTINCT line_item_resource_id) as Quantity,
   CAST(SUM(line_item_usage_amount) as INTEGER) as "Total number of hours per month",
   CASE
       WHEN pricing_purchase_option = 'Reserved' THEN 'Reserved'
       WHEN pricing_purchase_option = 'Spot' THEN 'Spot'
       WHEN pricing_purchase_option = 'On-Demand' THEN 'On-Demand'
       ELSE 'not supported'
   END as "Pricing Model"
FROM
   your_database.your_cur_table
WHERE
   line_item_line_item_type = 'Usage'
   AND line_item_product_code = 'AmazonEC2'
   AND line_item_usage_type LIKE '%BoxUsage%'
   AND product_instance_type LIKE '%a.%'
GROUP BY
   line_item_availability_zone,
   product_instance_type,
   pricing_purchase_option
ORDER BY
   Size,
   Region,
   "Pricing Model"
