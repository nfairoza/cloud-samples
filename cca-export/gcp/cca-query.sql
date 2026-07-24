-- GCP CCA Export - BigQuery billing query (standalone / portal copy)
-- ---------------------------------------------------------------------------
-- Emits the CCA Portfolio Template columns for the last full calendar month:
--   Cloud, Region, Size, Quantity, Total number of hours per month, Pricing Model
--
-- This is the same query embedded in get-cca-export.sh, provided as a plain .sql
-- file so you can paste it straight into BigQuery Studio (Console -> BigQuery ->
-- Studio) with no CLI or Bash. Save the result as CSV and paste into
-- AWS_AZURE_GCP.xlsx.
--
-- BEFORE RUNNING: replace the three placeholders below with your billing export:
--   PROJECT_ID  - project that owns the billing dataset
--   DATASET     - BigQuery dataset holding the export (e.g. billing_data)
--   TABLE       - the DETAILED / resource-level export table, e.g.
--                 gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX
--
-- IMPORTANT: you must use the resource-level export table (..._resource_v1_...).
-- "Size" comes from system_labels 'compute.googleapis.com/machine_spec', which
-- only exists in the detailed export - not the standard (..._v1_...) one.
--
-- NOTES:
-- * "Total number of hours per month" = instance count x 730 (a full-month
--   estimate). GCP bills per vCPU/GB rather than per instance-hour, so a true
--   instance-hour figure is not directly available; 730 keeps parity with the
--   CCA template. Edit the two "* 730" occurrences to change the estimate.
-- * Pricing detects Spot/Preemptible from the SKU description. Committed Use
--   Discounts (Reserved) are billing credits, hard to attribute per instance,
--   so committed VMs are reported as On-Demand here.
-- ---------------------------------------------------------------------------

WITH vms AS (
  SELECT
    location.region AS region,
    (SELECT value FROM UNNEST(system_labels)
       WHERE key = 'compute.googleapis.com/machine_spec') AS size,
    resource.name AS resource_name,
    CASE
      WHEN LOWER(sku.description) LIKE '%spot%'
        OR LOWER(sku.description) LIKE '%preemptible%' THEN 'Spot'
      ELSE 'On-Demand'
    END AS pricing_model
  FROM `PROJECT_ID.DATASET.TABLE`
  WHERE service.description = 'Compute Engine'
    AND DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)
    AND DATE(usage_start_time) <  DATE_TRUNC(CURRENT_DATE(), MONTH)
    AND (SELECT value FROM UNNEST(system_labels)
           WHERE key = 'compute.googleapis.com/machine_spec') IS NOT NULL
)
SELECT
  'GCP' AS Cloud,
  region AS Region,
  size AS Size,
  COUNT(DISTINCT resource_name) AS Quantity,
  COUNT(DISTINCT resource_name) * 730 AS `Total number of hours per month`,
  pricing_model AS `Pricing Model`
FROM vms
GROUP BY region, size, pricing_model
ORDER BY size, region, pricing_model;
