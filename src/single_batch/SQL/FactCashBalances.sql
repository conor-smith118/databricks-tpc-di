-- Databricks notebook source
USE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor);
CREATE OR REPLACE TABLE FactCashBalances (
  ${tgt_schema}
  ${constraints}
)
TBLPROPERTIES (${tbl_props});

-- COMMAND ----------

INSERT OVERWRITE IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.FactCashBalances')
with historical as (
  SELECT
    accountid,
    to_date(ct_dts) datevalue,
    sum(ct_amt) account_daily_total
  FROM read_files(
    "${tpcdi_directory}sf=${scale_factor}/Batch1",
    format => "csv",
    inferSchema => False,
    header => False,
    sep => "|",
    fileNamePattern => "CashTransaction.txt",
    schemaEvolutionMode => 'none',
    schema => "accountid BIGINT, ct_dts TIMESTAMP, ct_amt DOUBLE, ct_name STRING"
  )
  GROUP BY ALL
),
alltransactions as (
  SELECT *, 1 batchid FROM historical
  UNION ALL
  SELECT
    accountid,
    to_date(ct_dts) datevalue,
    sum(ct_amt) account_daily_total,
    int(substring(_metadata.file_path FROM (position('/Batch', _metadata.file_path) + 6) FOR 1)) batchid
  FROM read_files(
    "${tpcdi_directory}sf=${scale_factor}/Batch{2,3}",
    format => "csv",
    inferSchema => False,
    header => False,
    sep => "|",
    fileNamePattern => "CashTransaction.txt",
    schemaEvolutionMode => 'none',
    schema => "cdc_flag STRING, cdc_dsn BIGINT, accountid BIGINT, ct_dts TIMESTAMP, ct_amt DOUBLE, ct_name STRING"
  )
  GROUP BY ALL
)
SELECT 
  a.sk_customerid, 
  a.sk_accountid, 
  bigint(date_format(datevalue, 'yyyyMMdd')) sk_dateid,
  sum(account_daily_total) OVER (partition by c.accountid order by datevalue) cash,
  c.batchid
FROM alltransactions c
JOIN IDENTIFIER(:catalog || '.' || :wh_db || '_' || :scale_factor || '.DimAccount') a 
  ON 
    c.accountid = a.accountid
    AND c.datevalue >= a.effectivedate 
    AND c.datevalue < a.enddate
