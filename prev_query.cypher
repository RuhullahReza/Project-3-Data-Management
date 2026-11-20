// Query Project 2 (PostgreSQL) yang diterjemahkan ke Cypher (Neo4j) - Project 3
// Sumber: dokumen Project 2, Table 1 (Writes Query) dan Table 2 (Read Queries).
//
// Catatan umum:
// - Setiap statement Cypher berjalan dalam satu transaksi, jadi query "atomic" di Project 2
//   (BEGIN ... COMMIT) cukup ditulis sebagai satu statement. Kalau ada yang gagal, semuanya batal.
// - Untuk uji coba tanpa menyimpan data (pengganti ROLLBACK di Project 2), jalankan di cypher-shell:
//   :begin  ->  query  ->  :rollback
// - Neo4j tidak punya IDENTITY / sequence, jadi id baru diambil dari id terbesar + 1.
//   Constraint unik (dibuat di scripts/seed.py) mencegah id dobel kalau ada dua transaksi bersamaan.
// - FOR UPDATE di PostgreSQL diganti apoc.lock.nodes (plugin APOC sudah aktif di docker-compose.yml).
// - Properti current_status dan total_fee disimpan langsung di node Transaction (lihat dokumen hal. 3),
//   jadi setiap write yang menambah status/fee juga memperbarui kedua properti ini.


// =====================================================================
// WRITE QUERIES
// =====================================================================

// Write 1: Insert new partner
// Menambahkan satu partner biller sektor telekomunikasi.
OPTIONAL MATCH (x:Partner) WHERE x.partner_id IS NOT NULL
WITH x ORDER BY x.partner_id DESC LIMIT 1
WITH coalesce(x.partner_id, 0) + 1 AS new_partner_id
CREATE (p:Partner {
    partner_id: new_partner_id,
    partner_name: 'PT Indosat Ooredoo Hutchison',
    partner_type: 'biller',
    partner_status: 'active',
    sector: 'telecommunication'
})
RETURN p.partner_id AS partner_id;


// Write 2: Insert customer, then account
// Customer dan Account dibuat dalam satu statement, lalu dihubungkan dengan relasi HOLDS
// (pengganti FK Account.customer_id).
OPTIONAL MATCH (x:Customer) WHERE x.customer_id IS NOT NULL
WITH x ORDER BY x.customer_id DESC LIMIT 1
WITH coalesce(x.customer_id, 0) + 1 AS new_customer_id
OPTIONAL MATCH (y:Account) WHERE y.account_id IS NOT NULL
WITH new_customer_id, y ORDER BY y.account_id DESC LIMIT 1
WITH new_customer_id, coalesce(y.account_id, 0) + 1 AS new_account_id
CREATE (c:Customer {
    customer_id: new_customer_id,
    customer_type: 'individual',
    customer_name: 'Budi Santoso',
    city: 'Jakarta',
    id_type: 'identity_card',
    id_no: '3175098765432109',
    kyc_status: 'verified',
    customer_status: 'active',
    registered_date: date()
})
CREATE (a:Account {
    account_id: new_account_id,
    account_no: '1122334455',
    account_name: 'Tabungan Budi',
    opened_date: date(),
    account_status: 'active',
    current_balance: 1500000
})
CREATE (c)-[:HOLDS]->(a)
RETURN a.account_id AS account_id;


// Write 3: Atomic INSERT - cash deposit
// Setoran tunai 250.000 ke account_id 1: buat transaksi, tambah saldo akun,
// dan catat status 'initiated' lalu 'success'.
// Di Project 2 query ini tidak mengisi tabel Account_Transaction; di sini node diberi label
// AccountTransaction dan movement_type 'deposit' supaya sesuai model graph.
MATCH (a:Account {account_id: 1})
CALL apoc.lock.nodes([a])
OPTIONAL MATCH (x:Transaction) WHERE x.transaction_id IS NOT NULL
WITH a, x ORDER BY x.transaction_id DESC LIMIT 1
WITH a, coalesce(x.transaction_id, 0) + 1 AS new_transaction_id, a.current_balance AS balance_before
CREATE (t:Transaction:AccountTransaction {
    transaction_id: new_transaction_id,
    transaction_type: 'account',
    transaction_datetime: localdatetime(),
    amount: 250000,
    currency_code: 'IDR',
    reference_no: 'REF-' + toString(timestamp() / 1000),
    balance_before: balance_before,
    balance_after: balance_before + 250000,
    movement_type: 'deposit',
    current_status: 'success',
    total_fee: 0
})
CREATE (t)-[:TRANSFERED_TO]->(a)
SET a.current_balance = balance_before + 250000
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 1, status: 'initiated', status_datetime: localdatetime()})
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 2, status: 'success', status_datetime: localdatetime()})
RETURN t.transaction_id AS transaction_id, a.account_id AS account_id, a.current_balance AS current_balance;


// Write 4: Update partner status
// Selalu pakai filter yang spesifik; tanpa filter, semua node Partner ikut berubah.
MATCH (p:Partner {partner_name: 'PT Indosat Ooredoo Hutchison'})
SET p.partner_status = 'suspended'
RETURN p.partner_id AS partner_id, p.partner_status AS partner_status;


// Write 5: Update bill status to paid
MATCH (b:Bill {bill_id: 8})
SET b.bill_status = 'paid'
RETURN b.bill_id AS bill_id, b.bill_status AS bill_status;


// Write 6: Delete sample customer with cascade effect
// Menghapus customer dari Write 2 beserta akunnya (seperti ON DELETE CASCADE).
// Neo4j tidak punya FK, jadi perlindungan data dibuat manual: customer hanya dihapus kalau
// belum punya transaksi dan akunnya belum dipakai transaksi (di PostgreSQL ini akan error FK).
MATCH (c:Customer {id_type: 'identity_card', id_no: '3175098765432109'})
OPTIONAL MATCH (c)-[:HOLDS]->(a:Account)
WITH c, collect(a) AS accounts
WHERE NOT EXISTS { (c)-[:PERFORMS]->(:Transaction) }
  AND none(acc IN accounts WHERE EXISTS { (acc)<-[:TRANSFERED_TO]-(:Transaction) })
FOREACH (acc IN accounts | DETACH DELETE acc)
DETACH DELETE c
RETURN size(accounts) AS deleted_accounts;


// Write 7: Complete INSERT + UPDATE - pay a bill
// Pembayaran tagihan listrik bill_id 8 (757.000) oleh customer 1 dari account 1:
// buat transaksi BillPayment, tandai tagihan 'paid', kurangi saldo akun, catat status.
// CHECK current_balance >= 0 di PostgreSQL diganti filter saldo: kalau saldo kurang, tidak ada yang dibuat.
// Relasi TRANSFERED_TO hanya untuk AccountTransaction (dokumen hal. 7), jadi akun yang dipakai
// tercatat lewat balance_before/balance_after saja.
MATCH (c:Customer {customer_id: 1})
MATCH (a:Account {account_id: 1})
MATCH (b:Bill {bill_id: 8})
CALL apoc.lock.nodes([a, b])
WITH c, a, b
WHERE a.current_balance >= 757000
OPTIONAL MATCH (x:Transaction) WHERE x.transaction_id IS NOT NULL
WITH c, a, b, x ORDER BY x.transaction_id DESC LIMIT 1
WITH c, a, b, coalesce(x.transaction_id, 0) + 1 AS new_transaction_id, a.current_balance AS balance_before
CREATE (t:Transaction:BillPayment {
    transaction_id: new_transaction_id,
    transaction_type: 'bill_payment',
    transaction_datetime: localdatetime(),
    amount: 757000,
    currency_code: 'IDR',
    reference_no: 'REF-BP-' + apoc.temporal.format(localdatetime(), 'yyMMddHHmmss'),
    balance_before: balance_before,
    balance_after: balance_before - 757000,
    payment_method: 'electronic_money',
    biller_reference_no: 'PLN-REF-7788',
    confirmed_datetime: localdatetime(),
    current_status: 'success',
    total_fee: 0
})
CREATE (c)-[:PERFORMS]->(t)
CREATE (t)-[:SETTLES]->(b)
SET b.bill_status = 'paid',
    a.current_balance = balance_before - 757000
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 1, status: 'initiated', status_datetime: localdatetime()})
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 2, status: 'success', status_datetime: localdatetime()})
RETURN t.transaction_id AS transaction_id, b.bill_status AS bill_status, a.current_balance AS current_balance;


// Write 8: Atomic INSERT - cash pickup remittance
// Satu statement mencatat remitansi domestik cash pickup oleh customer 1:
// Transaction + Remittance, MoneyOrder (beserta nomor HP penerima), 2 status, 1 fee, dan receipt.
// Di graph, 7 tabel PostgreSQL ini menjadi 1 node Transaction (receipt disimpan sebagai properti),
// 1 MoneyOrder, 2 StatusChange, dan 1 Fee.
MATCH (c:Customer {customer_id: 1})
OPTIONAL MATCH (x:Transaction) WHERE x.transaction_id IS NOT NULL
WITH c, x ORDER BY x.transaction_id DESC LIMIT 1
WITH c, coalesce(x.transaction_id, 0) + 1 AS new_transaction_id
OPTIONAL MATCH (y:Transaction) WHERE y.receipt_id IS NOT NULL
WITH c, new_transaction_id, y ORDER BY y.receipt_id DESC LIMIT 1
WITH c, new_transaction_id, coalesce(y.receipt_id, 0) + 1 AS new_receipt_id
OPTIONAL MATCH (z:MoneyOrder) WHERE z.money_order_id IS NOT NULL
WITH c, new_transaction_id, new_receipt_id, z ORDER BY z.money_order_id DESC LIMIT 1
WITH c, new_transaction_id, new_receipt_id, coalesce(z.money_order_id, 0) + 1 AS new_money_order_id
CREATE (t:Transaction:Remittance {
    transaction_id: new_transaction_id,
    transaction_type: 'remittance',
    transaction_datetime: localdatetime(),
    amount: 1500000,
    currency_code: 'IDR',
    reference_no: 'RMT-20261103-001',
    service_scope: 'domestic',
    destination_country_code: 'ID',
    delivery_method: 'cash_pickup',
    purpose: 'Kiriman Keluarga',
    current_status: 'success',
    total_fee: 2500,
    receipt_id: new_receipt_id,
    receipt_issued_datetime: localdatetime(),
    receipt_delivery_format: 'printed',
    receipt_reprint_count: 0
})
CREATE (c)-[:PERFORMS]->(t)
CREATE (t)-[:ISSUES]->(:MoneyOrder {
    money_order_id: new_money_order_id,
    collection_code: 'MO-20261103-001',
    receiver_name: 'Siti Aminah',
    receiver_phones: ['081234567890'],
    order_amount: 1500000,
    expiry_date: date() + duration({days: 30}),
    order_status: 'issued'
})
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 1, status: 'initiated', status_datetime: localdatetime()})
CREATE (t)-[:HAS_STATUS]->(:StatusChange {sequence_no: 2, status: 'success', status_datetime: localdatetime()})
CREATE (t)-[:HAS_FEE]->(:Fee {fee_no: 1, fee_type: 'admin', fee_amount: 2500, charged_to: 'customer'})
RETURN t.receipt_id AS receipt_id, t.transaction_id AS transaction_id;


// Write 9: Atomic INSERT + UPDATE - bill payment reversal
// Membatalkan pembayaran tagihan paling lama yang tagihannya 'paid' dan belum pernah di-reversal:
// catat Reversal 'completed', tambah status 'reversed', lalu kembalikan tagihan menjadi 'unpaid'
// dengan penalty 0.
MATCH (t:BillPayment)-[:SETTLES]->(b:Bill {bill_status: 'paid'})
WHERE NOT EXISTS { (t)-[:REVERSED_BY]->(:Reversal) }
WITH t, b ORDER BY t.transaction_id LIMIT 1
CALL apoc.lock.nodes([t, b])
OPTIONAL MATCH (x:Reversal) WHERE x.reversal_id IS NOT NULL
WITH t, b, x ORDER BY x.reversal_id DESC LIMIT 1
WITH t, b, coalesce(x.reversal_id, 0) + 1 AS new_reversal_id
CALL (t) {
    OPTIONAL MATCH (t)-[:HAS_STATUS]->(s:StatusChange)
    RETURN coalesce(max(s.sequence_no), 0) + 1 AS next_sequence_no
}
CREATE (t)-[:REVERSED_BY]->(:Reversal {
    reversal_id: new_reversal_id,
    reversal_datetime: localdatetime(),
    reason_code: 'wrong_input',
    reversed_amount: t.amount,
    reversal_status: 'completed'
})
CREATE (t)-[:HAS_STATUS]->(:StatusChange {
    sequence_no: next_sequence_no,
    status: 'reversed',
    status_datetime: localdatetime(),
    reason_code: 'wrong_input'
})
SET t.current_status = 'reversed',
    b.bill_status = 'unpaid',
    b.penalty_amount = 0
RETURN b.bill_id AS bill_id, b.bill_status AS bill_status, b.penalty_amount AS penalty_amount;


// Write 10: Bulk UPDATE - expire money orders
// Semua money order 'issued' yang kedaluwarsa sebelum 15 September 2026 diubah menjadi 'expired'.
// Tanggal dibuat tetap supaya hasilnya tidak bergantung pada kapan query dijalankan.
MATCH (mo:MoneyOrder {order_status: 'issued'})
WHERE mo.expiry_date < date('2026-09-15')
SET mo.order_status = 'expired'
RETURN count(mo) AS expired_money_orders;


// =====================================================================
// READ QUERIES
// =====================================================================

// Read 1: Profiling Customer by City
// Jumlah customer per kota, tipe customer, status KYC, dan status customer.
MATCH (c:Customer)
RETURN c.city AS city,
       c.customer_type AS customer_type,
       c.kyc_status AS kyc_status,
       c.customer_status AS customer_status,
       count(*) AS total_customers
ORDER BY city, customer_type, kyc_status, customer_status;


// Read 2: Customer Transaction History
// Riwayat transaksi satu customer. Set parameter dulu di Neo4j Browser: :param customer_id => 1
MATCH (c:Customer {customer_id: $customer_id})-[:PERFORMS]->(t:Transaction)
RETURN c.customer_id AS customer_id,
       t.transaction_id AS transaction_id,
       c.customer_name AS customer_name,
       t.transaction_type AS transaction_type,
       t.amount AS amount,
       t.currency_code AS currency_code,
       t.reference_no AS reference_no;


// Read 3: Single Customer Profile
// Profil lengkap customer 1: status, KYC, jumlah akun, total saldo, dan jumlah transaksi seumur hidup.
// Akun dan transaksi dihitung terpisah. Di SQL Project 2, LEFT JOIN Account dan Transaction sekaligus
// membuat SUM(current_balance) ikut terkali jumlah transaksi; di sini total_balance tidak terkali.
MATCH (c:Customer {customer_id: 1})
OPTIONAL MATCH (c)-[:HOLDS]->(a:Account)
WITH c, count(a) AS total_accounts, coalesce(sum(a.current_balance), 0) AS total_balance
OPTIONAL MATCH (c)-[:PERFORMS]->(t:Transaction)
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.customer_status AS customer_status,
       c.kyc_status AS kyc_status,
       total_accounts,
       total_balance,
       count(t) AS lifetime_transactions;


// Read 4: Partner Reversal Evaluation
// Jumlah pembayaran, jumlah reversal, dan persentase reversal untuk setiap partner biller.
MATCH (p:Partner {partner_type: 'biller'})<-[:ISSUED_BY]-(:Bill)<-[:SETTLES]-(bp:BillPayment)
OPTIONAL MATCH (bp)-[:REVERSED_BY]->(r:Reversal)
WITH p, count(bp) AS total_payments_attempted, count(r) AS total_reversals
WHERE total_payments_attempted > 0
RETURN p.partner_id AS partner_id,
       p.partner_name AS partner_name,
       p.sector AS sector,
       total_payments_attempted,
       total_reversals,
       total_reversals * 100.0 / total_payments_attempted AS reversal_percent
ORDER BY reversal_percent DESC;


// Read 5: User Clustering by Activity
// Customer aktif dikelompokkan berdasarkan aktivitas 90 hari terakhir:
// - Potential   : transaksi >= 10 ATAU nominal >= 1.000.000 ATAU saldo >= 5.000.000
// - Normal User : transaksi >= 3 ATAU nominal >= 500.000
// - Low Usage   : selain itu
// Saldo dan transaksi dihitung terpisah supaya saldo tidak terkali jumlah transaksi (lihat Read 3).
MATCH (c:Customer {customer_status: 'active'})
OPTIONAL MATCH (c)-[:HOLDS]->(a:Account)
WITH c, coalesce(sum(a.current_balance), 0) AS current_total_balance
OPTIONAL MATCH (c)-[:PERFORMS]->(t:Transaction)
WHERE t.transaction_datetime >= localdatetime() - duration({days: 90})
WITH c, current_total_balance,
     count(t) AS total_transactions_90d,
     coalesce(sum(t.amount), 0) AS total_amount_90d
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.customer_status AS customer_status,
       total_transactions_90d,
       total_amount_90d,
       current_total_balance,
       CASE
           WHEN total_amount_90d >= 1000000
             OR total_transactions_90d >= 10
             OR current_total_balance >= 5000000 THEN 'Potential'
           WHEN total_transactions_90d >= 3
             OR total_amount_90d >= 500000 THEN 'Normal User'
           ELSE 'Low Usage'
       END AS user_cluster
ORDER BY total_amount_90d DESC;


// Read 6: Dormant Tracking
// Akun dormant milik customer aktif, diurutkan dari saldo terbesar.
MATCH (c:Customer {customer_status: 'active'})-[:HOLDS]->(a:Account {account_status: 'dormant'})
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.city AS city,
       a.account_no AS account_no,
       a.account_status AS account_status,
       a.current_balance AS current_balance,
       a.opened_date AS opened_date
ORDER BY current_balance DESC;


// Read 7: Non Indexed Search (name and city) - stress test
// Pencarian bebas berdasarkan nama dan kota. toLower + CONTAINS tidak memakai index,
// sama seperti LOWER(...) LIKE '%...%' di PostgreSQL.
MATCH (c:Customer)-[:HOLDS]->(a:Account)<-[:TRANSFERED_TO]-(t:Transaction)
WHERE toLower(c.customer_name) CONTAINS 'budi'
  AND toLower(c.city) CONTAINS 'jakarta'
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.city AS city,
       a.account_no AS account_no,
       t.reference_no AS reference_no,
       t.amount AS amount,
       t.transaction_datetime AS transaction_datetime
ORDER BY transaction_datetime DESC;


// Read 8: Customer dengan remittance internasional DAN bill payment bernilai besar
// Batas nominal mengikuti SQL Project 2 (amount > 500.000), walaupun judul di dokumen
// menyebut 5.000.000,00.
MATCH (c:Customer)
WHERE EXISTS { (c)-[:PERFORMS]->(r:Remittance) WHERE r.service_scope = 'international' }
  AND EXISTS { (c)-[:PERFORMS]->(bp:BillPayment) WHERE bp.amount > 500000 }
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.city AS city
ORDER BY customer_id;


// Read 9: Customer aktif dan verified yang belum pernah bertransaksi
// Belum pernah melakukan bill payment / disbursement, dan tidak punya akun dormant.
MATCH (c:Customer {customer_status: 'active', kyc_status: 'verified'})
WHERE NOT EXISTS {
        (c)-[:PERFORMS]->(t:Transaction)
        WHERE t.transaction_type IN ['bill_payment', 'disbursement']
      }
  AND NOT EXISTS { (c)-[:HOLDS]->(:Account {account_status: 'dormant'}) }
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       c.city AS city,
       c.registered_date AS registered_date
ORDER BY registered_date ASC;


// Read 10: Find Customer with high daily transaction (> 5)
// Customer yang melakukan lebih dari 5 transaksi dalam satu hari.
MATCH (c:Customer)-[:PERFORMS]->(t:Transaction)
WITH c, date(t.transaction_datetime) AS transaction_date,
     count(t) AS daily_tx_count,
     sum(t.amount) AS total_daily_amount
WHERE daily_tx_count > 5
RETURN c.customer_id AS customer_id,
       c.customer_name AS customer_name,
       transaction_date,
       daily_tx_count,
       total_daily_amount
ORDER BY daily_tx_count DESC, transaction_date DESC;


// Read 11: Monthly Volume and Fee Revenue
// Jumlah transaksi, total nominal, dan total fee per bulan dan per jenis transaksi selama 2026.
// Fee per transaksi sudah dijumlahkan saat seed (properti total_fee), jadi tidak perlu subquery
// seperti di SQL dan tidak ada risiko fee terhitung dobel.
MATCH (t:Transaction)
WHERE t.transaction_datetime >= localdatetime('2026-01-01T00:00:00')
  AND t.transaction_datetime <  localdatetime('2027-01-01T00:00:00')
RETURN date.truncate('month', t.transaction_datetime) AS transaction_month,
       t.transaction_type AS transaction_type,
       count(*) AS total_transactions,
       sum(t.amount) AS total_amount,
       coalesce(sum(t.total_fee), 0) AS total_fee
ORDER BY transaction_month, transaction_type;


// Read 12: Current Status Distribution
// Jumlah transaksi, total nominal, dan persentase tiap status terakhir di dalam setiap jenis transaksi.
// Status terakhir sudah disimpan di properti current_status, jadi tidak perlu membaca semua StatusChange.
// Transaksi tanpa status dilewati, sama seperti JOIN ke latest_status di SQL.
MATCH (t:Transaction)
WHERE t.current_status IS NOT NULL
WITH t.transaction_type AS transaction_type,
     t.current_status AS current_status,
     count(*) AS total_transactions,
     sum(t.amount) AS total_amount
WITH transaction_type,
     sum(total_transactions) AS type_total,
     collect({current_status: current_status,
              total_transactions: total_transactions,
              total_amount: total_amount}) AS statuses
UNWIND statuses AS s
RETURN transaction_type,
       s.current_status AS current_status,
       s.total_transactions AS total_transactions,
       s.total_amount AS total_amount,
       round(s.total_transactions * 100.0 / type_total, 2) AS percent_of_type
ORDER BY transaction_type, total_transactions DESC;


// Read 13: Fund Distribution Program Realization
// Setiap program dengan partner, total anggaran, jumlah payout, total dana tersalur,
// sisa anggaran, dan persentase realisasi.
MATCH (pt:Partner)-[:RUNS]->(p:FundProgram)
OPTIONAL MATCH (p)-[:FUNDS]->(po:Payout)
WITH p, pt, count(po) AS total_payouts, coalesce(sum(po.payout_amount), 0) AS total_paid
RETURN p.program_name AS program_name,
       pt.partner_name AS partner_name,
       p.total_budget AS total_budget,
       total_payouts,
       total_paid,
       p.total_budget - total_paid AS remaining_budget,
       round(total_paid * 100.0 / p.total_budget, 2) AS realization_percent
ORDER BY realization_percent DESC;
