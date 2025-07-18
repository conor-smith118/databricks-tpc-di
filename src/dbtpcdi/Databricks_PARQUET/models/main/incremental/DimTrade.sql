{{
    config(
        materialized = 'table'
    )
}}
WITH tradeincremental AS (
    SELECT
        min(cdc_flag) cdc_flag,
        tradeid,
        min(t_dts) create_ts,
        max_by(
            struct(
                t_dts,
                status,
                t_tt_id,
                cashflag,
                t_s_symb,
                quantity,
                bidprice,
                t_ca_id,
                executedby,
                tradeprice,
                fee,
                commission,
                tax
            ),
            t_dts
        ) current_record,
        min(int(substring(_metadata.file_path FROM (position('/Batch', _metadata.file_path) + 6) FOR 1))) batchid
    FROM parquet.`{{var("rawfilelocation")}}/sf={{var("scalefactor")}}/Batch{2,3}/Trade.parquet` t
    GROUP BY tradeid
),
TradeIncrementalHistory AS (
    SELECT
        tradeid,
        current_record.t_dts ts,
        current_record.status
    FROM tradeincremental
    WHERE cdc_flag = "U"
    UNION ALL
    SELECT *
    FROM parquet.`{{var("rawfilelocation")}}/sf={{var("scalefactor")}}/Batch1/TradeHistory*.parquet`
),
Current_Trades as (
    SELECT
        tradeid,
        min(ts) create_ts,
        max_by(struct(ts, status), ts) current_status
    FROM TradeIncrementalHistory
    group by tradeid
),
Trades_Final (
    SELECT
        tradeid,
        create_ts,
        CASE
            WHEN current_status.status IN ("CMPT", "CNCL") THEN current_status.ts
            END close_ts,
        current_status.status,
        t_is_cash cashflag,
        t_st_id,
        t_tt_id,
        t_s_symb,
        quantity,
        bidprice,
        t_ca_id,
        executedby,
        tradeprice,
        fee,
        commission,
        tax,
        1 batchid
    FROM parquet.`{{var("rawfilelocation")}}/sf={{var("scalefactor")}}/Batch1/Trade_*.parquet` t
    JOIN Current_Trades ct
        ON t.t_id = ct.tradeid
    UNION ALL
    SELECT
        tradeid,
        create_ts,
        CASE
        WHEN current_record.status IN ("CMPT", "CNCL") THEN current_record.t_dts
        END close_ts,
        current_record.status,
        current_record.cashflag,
        current_record.status,
        current_record.t_tt_id,
        current_record.t_s_symb,
        current_record.quantity,
        current_record.bidprice,
        current_record.t_ca_id,
        current_record.executedby,
        current_record.tradeprice,
        current_record.fee,
        current_record.commission,
        current_record.tax,
        batchid
    FROM tradeincremental
    WHERE cdc_flag = "I"
)
SELECT
  trade.tradeid,
  sk_brokerid,
  bigint(date_format(create_ts, 'yyyyMMdd')) sk_createdateid,
  bigint(date_format(create_ts, 'HHmmss')) sk_createtimeid,
  bigint(date_format(close_ts, 'yyyyMMdd')) sk_closedateid,
  bigint(date_format(close_ts, 'HHmmss')) sk_closetimeid,
  decode(trade.status,
    'ACTV',	'Active',
    'CMPT','Completed',
    'CNCL','Canceled',
    'PNDG','Pending',
    'SBMT','Submitted',
    'INAC','Inactive') status,
  decode(t_tt_id,
    'TMB', 'Market Buy',
    'TMS', 'Market Sell',
    'TSL', 'Stop Loss',
    'TLS', 'Limit Sell',
    'TLB', 'Limit Buy'
  ) type,
  if(cashflag = 1, TRUE, FALSE) cashflag,
  sk_securityid,
  sk_companyid,
  trade.quantity,
  trade.bidprice,
  sk_customerid,
  sk_accountid,
  trade.executedby,
  trade.tradeprice,
  trade.fee,
  trade.commission,
  trade.tax,
  trade.batchid
FROM Trades_Final trade
JOIN {{ ref('DimSecurity') }}  ds
  ON
    ds.symbol = trade.t_s_symb
    AND date(create_ts) >= ds.effectivedate
    AND date(create_ts) < ds.enddate
JOIN {{ ref('DimAccount') }} da
  ON
    trade.t_ca_id = da.accountid
    AND date(create_ts) >= da.effectivedate
    AND date(create_ts) < da.enddate;