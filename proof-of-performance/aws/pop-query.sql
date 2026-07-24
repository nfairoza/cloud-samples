-- Proof of Performance - AWS Athena query (CUR 2.0 / Data Exports)
-- Emits the normalized "long" schema consumed by ../build_report.py:
--   cloud, year, month, region, arch, family, vcpu_hours, vcpus
--
-- vcpu_hours = SUM(instance-hours x vCPUs-per-instance)
--            = SUM(line_item_usage_amount * product_vcpu)              (usage/consumption)
-- vcpus      = provisioned vCPUs that month = SUM over DISTINCT instances
--              (line_item_resource_id) of each instance's product_vcpu.  A real
--              headcount of the vCPUs that existed that month, NOT a time-average.
--
-- Architecture is inferred from the EC2 instance family token:
--   * a 'g' in the attribute letters  -> ARM (Graviton)   e.g. m7g, c7gn, t4g
--   * an 'a' in the attribute letters -> AMD              e.g. m7a, r7a, hpc7a
--   * otherwise                       -> Intel            e.g. m7i, c6i, m5, r5n
--   * 'a1' family is special-cased to ARM (Graviton 1)
--
-- Window: the last 12 COMPLETED months (excludes the current partial month so
-- partial data never skews a trend).

-- Inner query: collapse to one row per (month, group, instance) so an instance
-- that appears on many usage rows is counted ONCE for the provisioned vCPU total.
WITH per_instance AS (
    SELECT
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
        line_item_resource_id AS resource_id,
        -- vCPUs are fixed per instance size; MAX picks it up regardless of row count
        MAX(TRY_CAST(product_vcpu AS DOUBLE)) AS inst_vcpus,
        SUM(line_item_usage_amount * TRY_CAST(product_vcpu AS DOUBLE)) AS inst_vcpu_hours
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
        1, 2, 3, 4, 5, 6
)
SELECT
    'AWS' AS cloud,
    year,
    month,
    region,
    arch,
    family,
    CAST(SUM(inst_vcpu_hours) AS DOUBLE) AS vcpu_hours,
    CAST(SUM(inst_vcpus) AS INTEGER) AS vcpus
FROM
    per_instance
GROUP BY
    year, month, region, arch, family
ORDER BY
    year, month, region, arch;
