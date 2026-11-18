// Sample insert Cypher (Project 3 - Data Management)
// Catatan: ini data dummy yang saya buat untuk coba-coba skema graph di Neo4j.
// Pakai MERGE + constraint unik (dari seed.py) biar kalau scriptnya ke-run ulang, datanya nggak dobel.
// Urutannya sengaja dibuat begini karena ada node yang jadi "prasyarat" relasi node berikutnya.

// 1. Insert partner dulu (contoh kasus: PLN sebagai biller)
MERGE (p:Partner {partner_id: 10})
SET p.partner_name = 'PLN (Persero)',
    p.partner_type = 'BILLER',
    p.status = 'ACTIVE';

// 2. Data nasabah (customer) - contoh 1 orang dulu biar gampang ditrace
MERGE (c:Customer {customer_id: 1001})
SET c.customer_name = 'Andi Pratama',
    c.city = 'Bandung',
    c.phone = '081320001234',
    c.email = 'andi.pratama@mail.test';

// 3. Bikin akun/rekening untuk nasabah tadi, sekalian hubungkan relasi HOLDS
MATCH (c:Customer {customer_id: 1001})
MERGE (a:Account {account_id: 2001})
SET a.account_no = 'TAB-2001-001',
    a.account_type = 'SAVINGS',
    a.balance = 7500000,
    a.status = 'ACTIVE'
MERGE (c)-[:HOLDS]->(a);

// 4. Contoh transaksi rekening (AccountTransaction) - simulasi transfer keluar/debit
MATCH (c:Customer {customer_id: 1001})
MERGE (t:Transaction {transaction_id: 5001})
SET t:AccountTransaction,
    t.transaction_type = 'account_transaction',
    t.reference_no = 'TRX-ACC-5001',
    t.transaction_datetime = datetime('2026-11-10T08:30:00'),
    t.amount = 300000,
    t.current_status = 'SUCCESS',
    t.total_fee = 2500,
    t.movement_type = 'DEBIT',
    t.counterparty_account_no = 'TAB-9999-002',
    t.receipt_id = 'RCPT-5001',
    t.receipt_issued_datetime = datetime('2026-11-10T08:30:12'),
    t.receipt_delivery_format = 'DIGITAL',
    t.receipt_reprint_count = 0
MERGE (c)-[:PERFORMS]->(t);

// 5. Tagihan (Bill) yang diterbitkan partner - misalnya tagihan listrik bulan ini
MATCH (p:Partner {partner_id: 10})
MERGE (b:Bill {bill_id: 3001})
SET b.biller_customer_no = 'IDPEL-55112233',
    b.bill_amount = 425000,
    b.due_date = date('2026-11-20'),
    b.bill_status = 'UNPAID'
MERGE (b)-[:ISSUED_BY]->(p);

// 6. Pembayaran tagihan (BillPayment), diasumsikan Andi bayar tunai di loket
MATCH (c:Customer {customer_id: 1001}), (b:Bill {bill_id: 3001})
MERGE (t:Transaction {transaction_id: 5002})
SET t:BillPayment,
    t.transaction_type = 'bill_payment',
    t.reference_no = 'TRX-BILL-5002',
    t.transaction_datetime = datetime('2026-11-12T14:05:00'),
    t.amount = 425000,
    t.current_status = 'SUCCESS',
    t.total_fee = 3000,
    t.payment_method = 'CASH',
    t.biller_reference_no = 'PLN-INV-77881',
    t.confirmed_datetime = datetime('2026-11-12T14:05:40'),
    t.receipt_id = 'RCPT-5002'
MERGE (c)-[:PERFORMS]->(t)
MERGE (t)-[:SETTLES]->(b);

// 7. Remitansi + Money Order (contoh kirim uang domestik, diambil tunai oleh penerima)
MATCH (c:Customer {customer_id: 1001})
MERGE (t:Transaction {transaction_id: 5003})
SET t:Remittance,
    t.transaction_type = 'remittance',
    t.reference_no = 'TRX-RMT-5003',
    t.transaction_datetime = datetime('2026-11-13T10:15:00'),
    t.amount = 1500000,
    t.current_status = 'PENDING',
    t.total_fee = 20000,
    t.service_scope = 'DOMESTIC',
    t.destination_country_code = 'ID',
    t.delivery_method = 'CASH_PICKUP',
    t.purpose = 'Biaya pendidikan'
MERGE (mo:MoneyOrder {money_order_id: 4001})
SET mo.collection_code = 'MO-2026-4001',
    mo.expiry_date = date('2026-11-27'),
    mo.receiver_name = 'Rina Wulandari',
    mo.receiver_phones = ['081355667788']
MERGE (c)-[:PERFORMS]->(t)
MERGE (t)-[:ISSUES]->(mo);

// 8. Program distribusi dana (FundProgram) yang dijalankan oleh partner
MATCH (p:Partner {partner_id: 10})
MERGE (f:FundProgram {program_id: 9001})
SET f.program_name = 'Bantuan Kompensasi Listrik 2026',
    f.start_date = date('2026-01-01'),
    f.end_date = date('2026-12-31'),
    f.status = 'ACTIVE'
MERGE (p)-[:RUNS]->(f);

// 9. Disbursement + Payout (pencairan dana program ke penerima manfaat)
MATCH (c:Customer {customer_id: 1001}), (f:FundProgram {program_id: 9001})
MERGE (t:Transaction {transaction_id: 5004})
SET t:Disbursement,
    t.transaction_type = 'disbursement',
    t.reference_no = 'TRX-DSB-5004',
    t.transaction_datetime = datetime('2026-11-15T09:00:00'),
    t.amount = 600000,
    t.current_status = 'SUCCESS',
    t.total_fee = 0,
    t.disbursement_method = 'CASH',
    t.verification_method = 'KTP',
    t.verified_id_no = '3273XXXXXXXXXXXX'
MERGE (payout:Payout {payout_id: 7001})
SET payout.amount = 600000,
    payout.payout_datetime = datetime('2026-11-15T09:03:00'),
    payout.status = 'PAID'
MERGE (c)-[:PERFORMS]->(t)
MERGE (t)-[:EXECUTES]->(payout)
MERGE (f)-[:FUNDS]->(payout);

// 10. Koreksi transaksi: reversal + status history + fee (misal bill payment tadi keinput ganda)
MATCH (t:Transaction {transaction_id: 5002})
MERGE (r:Reversal {reversal_id: 8001})
SET r.reason = 'Input ganda oleh teller',
    r.reversal_datetime = datetime('2026-11-12T16:20:00')
MERGE (t)-[:REVERSED_BY]->(r)
MERGE (t)-[:HAS_STATUS]->(s:StatusChange {sequence_no: 2})
SET s.status = 'REVERSED',
    s.changed_at = datetime('2026-11-12T16:20:00')
MERGE (t)-[:HAS_FEE]->(fee:Fee {fee_no: 1})
SET fee.fee_type = 'ADMIN_REVERSAL',
    fee.fee_amount = 0;
