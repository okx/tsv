WITH events AS (
 SELECT 'event' AS row_kind, block_time, block_number, "index" AS log_index,
 concat('0x',lower(to_hex(contract_address))) AS contract_address,
 concat('0x',lower(to_hex(topic0))) AS topic0,
 concat('0x',lower(to_hex(data))) AS data,
 concat('0x',lower(to_hex(tx_hash))) AS tx_hash,
 concat('0x',lower(to_hex(tx_from))) AS tx_from,
 concat('0x',lower(to_hex(tx_to))) AS tx_to
 FROM xlayer.logs
 WHERE block_date >= DATE '2024-01-01' AND block_date <= DATE '2026-11-02'
 AND contract_address IN (0x0ab2890fc2b921fe9ccd1ca58f64cef758acd1bb,0xa96982eeb325b9051cfbac970ede179a903d85df,0x3c946e6491707792592996c896ccca43b8353392,0x017d40856467f36b0b86775314f04ba8ed0d65b3)
 AND topic0 IN (0x81ffbfef319d8e018af37c91c880768a5e52e5aef2d52ed7d03d73a9c940a96c,0xd4288bbc89382857327f7cd94c27bef4d693c4a48b59f38bea82bfc33d522a3d,0xfa47a8dfcdc942a0a3741f1cb27d9204791c65abf5e0cbacae56a51f27de3376,0x9e8e6fefa02ab82a125e6b37b1c9d6615c955513136bce3372f9722da3f1dc6c)
), watermark AS (
 SELECT 'watermark' AS row_kind, block_time, block_number, CAST(NULL AS integer) AS log_index,
 CAST(NULL AS varchar) AS contract_address, CAST(NULL AS varchar) AS topic0, CAST(NULL AS varchar) AS data,
 CAST(NULL AS varchar) AS tx_hash, CAST(NULL AS varchar) AS tx_from, CAST(NULL AS varchar) AS tx_to
 FROM xlayer.transactions
 WHERE block_date >= DATE '2026-11-01' AND block_date <= DATE '2026-11-02'
 ORDER BY block_number DESC LIMIT 1
)
SELECT * FROM events UNION ALL SELECT * FROM watermark ORDER BY block_number, log_index
