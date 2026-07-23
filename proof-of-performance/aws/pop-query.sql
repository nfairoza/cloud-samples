-- Proof of Performance - AWS Athena query (CUR 2.0 / Data Exports)
-- Emits the normalized "long" schema consumed by ../build_report.py:
--   cloud, year, month, region, arch, family, vcpu_hours
--
-- vcpu_hours = SUM(instance-hours x vCPUs-per-instance)
--            = SUM(line_item_usage_amount * product_vcpu)
--
-- Architecture is inferred from the EC2 instance family token:
--   * a 'g' in the attribute letters  -> ARM (Graviton)   e.g. m7g, c7gn, t4g
--   * an 'a' in the attribute letters -> AMD              e.g. m7a, r7a, hpc7a
--   * otherwise                       -> Intel            e.g. m7i, c6i, m5, r5n
--   * 'a1' family is special-cased to ARM (Graviton 1)
--
-- Window: the last 12 COMPLETED months (excludes the current partial month so
-- partial data never skews a trend).

SELECT
    'AWS' AS cloud,
    CAST(year AS INTEGER) AS year,
    CAST(month AS INTEGER) AS month,
    REGEXP_REPLACE(line_item_availability_zone, '[a-z]$', '') AS region,
    CASE
        WHEN split_part(product_instance_type, '.', 1) = 'a1' THEN 'ARM'
        WHEN regexp_like(split_part(product_instance_type, '.', 1), '[0-9][a-z]*g[a-z]*$') THEN 'ARM'
        WHEN regexp_like(split_part(product_instance_type, '.', 1), '[0-9][a-z]*a[a-z]*$') THEN 'AMD'
        ELSE 'Intel'
    END AS arch,
    split_part(product_instance_type, '.', 1) AS family,
    CAST(SUM(line_item_usage_amount * TRY_CAST(product_vcpu AS DOUBLE)) AS DOUBLE) AS vcpu_hours
FROM
    ${DATABASE_NAME}.${TABLE_NAME}
WHERE
    line_item_line_item_type = 'Usage'
    AND line_item_product_code = 'AmazonEC2'
    AND line_item_usage_type LIKE '%BoxUsage%'
    AND TRY_CAST(product_vcpu AS DOUBLE) > 0
    AND (CAST(year AS INTEGER) * 100 + CAST(month AS INTEGER))
        >= (YEAR(DATE_ADD('month', -12, CURRENT_DATE)) * 100 + MONTH(DATE_ADD('month', -12, CURRENT_DATE)))
    AND (CAST(year AS INTEGER) * 100 + CAST(month AS INTEGER))
        < (YEAR(CURRENT_DATE) * 100 + MONTH(CURRENT_DATE))
GROUP BY
    2, 3, 4, 5, 6
ORDER BY
    2, 3, 4, 5;
