import os
from decimal import Decimal
from itertools import count

import psycopg
from dotenv import load_dotenv
from neo4j import GraphDatabase
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row

load_dotenv()
cursor_id = count()

BATCH_SIZE = 2500

def to_neo4j_value(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value

def stream(pg, graph_db, sql, cypher):
    # untuk execute query di postgres dan stream hasilnya ke neo4j
    total = 0
    
    with pg.cursor(name=f"cursor_{next(cursor_id)}", row_factory=dict_row) as cursor:
        cursor.execute(sql)
        while rows := cursor.fetchmany(BATCH_SIZE):
            rows = [row for row in rows]
            rows = [{k: to_neo4j_value(v) for k, v in row.items()} for row in rows]
            graph_db.execute_query(cypher, rows=rows)
            total += len(rows)

    print(f"Total rows processed: {total}")

# Index di Neo4J
Unique = [
    ("Customer", "customer_id"),
    ("Account", "account_id"),
    ("Account", "account_no"),
    ("Transaction", "transaction_id"),
    ("Transaction", "reference_no"),
    ("Transaction", "receipt_id"),
    ("Bill", "bill_id"),
    ("Partner", "partner_id"),
    ("MoneyOrder", "money_order_id"),
    ("MoneyOrder", "collection_code"),
    ("Payout", "payout_id"),
    ("FundProgram", "program_id"),
    ("Reversal", "reversal_id"),
]

RANGE = [
    ("Transaction", "transaction_type"), 
    ("Transaction", "transaction_datetime"),
    ("Bill", "biller_customer_no"), 
    ("MoneyOrder", "expiry_date"),
]

FULLTEXT = [
    ("Customer", "customer_name"), 
    ("Customer", "city")
]

sql_transaction = """
    SELECT t.*, {columns}, (
        SELECT s.status FROM Status_History s
        Where s.transaction_id = t.transaction_id
        ORDER BY s.sequence_no DESC LIMIT 1
    ) as current_status,
    (
        SELECT COALESCE(SUM(f.fee_amount), 0) FROM Transaction_Fee f
        WHERE f.transaction_id = t.transaction_id
    ) as total_fee,
    rc.receipt_id,
    rc.issued_datetime as receipt_issued_datetime,
    rc.delivery_format as receipt_delivery_format,
    rc.reprint_count as receipt_reprint_count
    FROM Transaction t
    JOIN {subtype} st ON t.transaction_id = st.transaction_id
    LEFT JOIN Receipt rc ON t.transaction_id = rc.transaction_id
    """

def create_neo4j_index(graph_db):
    for label, prop in Unique:
        graph_db.execute_query(f"CREATE CONSTRAINT IF NOT EXISTS FOR (n:{label}) REQUIRE n.{prop} IS UNIQUE")
    for label, prop in RANGE:
        graph_db.execute_query(f"CREATE INDEX IF NOT EXISTS FOR (n:{label}) ON (n.{prop})")
    for label, prop in FULLTEXT:
        graph_db.execute_query(f"CREATE FULLTEXT INDEX IF NOT EXISTS FOR (n:{label}) ON EACH [n.{prop}]")

def load_partner(pg, graph_db):
    # load data partner dari postgres
    sql = "SELECT * FROM partner"

    # insert data ke neo4j
    cypher = """
    UNWIND $rows AS row
    MERGE (p:Partner {partner_id: row.partner_id})
    SET p += row
    """

    stream(pg, graph_db, sql, cypher)

def load_customer_dan_account(pg, graph_db):
    # load data customer dari postgres
    sql = "SELECT * FROM customer"

    # insert data ke neo4j
    cypher = """
    UNWIND $rows AS row
    MERGE (c:Customer {customer_id: row.customer_id})
    SET c += row
    """

    stream(pg, graph_db, sql, cypher)

    # load data account dari postgres
    sql = "SELECT * FROM account"

    # insert data ke neo4j
    
    # unwinnd itu buat loop data dan row berbentuk key value
    # set dulu customer id ke null
    # match customer id dari row ke customer di neo4j
    # buat relasi has account antara customer ke account
    cypher = """
    UNWIND $rows AS row
    MERGE (a:Account {account_id: row.account_id})
    SET a += row{.*, customer_id: null}
    WITH a, row
    MATCH (c:Customer {customer_id: row.customer_id})
    MERGE (c)-[:HOLDS]->(a)
    """

    stream(pg, graph_db, sql, cypher)

def load_account_transactions(pg, graph_db):
    sql = sql_transaction.format(
        columns="st.movement_type, st.counterparty_account_no",
        subtype="Account_Transaction",
    )

    cypher = """
    UNWIND $rows AS row
    MERGE (t:Transaction {transaction_id: row.transaction_id})
    SET t:AccountTransaction, t += row{.*, customer_id: null, account_id: null}
    WITH t, row
    MATCH (c:Customer {customer_id: row.customer_id})
    MERGE (c)-[:PERFORMS]->(t)
    """

    stream(pg, graph_db, sql, cypher)

def load_bill_payment_dan_reversal(pg, graph_db):
    # load bill dan hubungkan ke partner
    sql = "SELECT * FROM Bill"

    cypher = """
    UNWIND $rows AS row
    MERGE (b:Bill {bill_id: row.bill_id})
    SET b += row{.*, partner_id: null}
    WITH b, row
    MATCH (p:Partner {partner_id: row.partner_id})
    MERGE (b)-[:ISSUED_BY]->(p)
    """

    stream(pg, graph_db, sql, cypher)

    ### load bill payment dan hubungkan ke customer dan bill
    sql = sql_transaction.format(
        columns="st.payment_method, st.biller_reference_no, st.confirmed_datetime, st.bill_id",
        subtype="Bill_Payment",
    )

    cypher = """
    UNWIND $rows AS row
    MERGE (t:Transaction {transaction_id: row.transaction_id})
    SET t:BillPayment, t += row{.*, customer_id: null, account_id: null, bill_id: null}
    with t, row
    MATCH (c:Customer {customer_id: row.customer_id})
    MATCH (b:Bill {bill_id: row.bill_id})
    MERGE (c)-[:PERFORMS]->(t)
    MERGE (t)-[:SETTLES]->(b)
    """

    stream(pg, graph_db, sql, cypher)

    ### load reversal dan hubungkan ke bill payment
    sql = "SELECT * FROM Reversal"

    cypher = """
    UNWIND $rows AS row
    MERGE (r:Reversal {reversal_id: row.reversal_id})
    SET r += row{.*, transaction_id: null}
    WITH r, row
    MATCH (t:Transaction:BillPayment {transaction_id: row.transaction_id})
    MERGE (t)-[:REVERSED_BY]->(r)
    """

    stream(pg, graph_db, sql, cypher)

def load_remittance_dan_money_order(pg, graph_db):
    # load remittance dan hubungkan ke customer
    sql = sql_transaction.format(
        columns="st.service_scope, st.destination_country_code, st.delivery_method, st.purpose",
        subtype="Remittance",
    )

    cypher = """
    UNWIND $rows AS row
    MERGE (t:Transaction {transaction_id: row.transaction_id})
    SET t:Remittance, t += row{.*, customer_id: null, account_id: null}
    WITH t, row
    MATCH (c:Customer {customer_id: row.customer_id})
    MERGE (c)-[:PERFORMS]->(t)
    """

    stream(pg, graph_db, sql, cypher)

    # load money order dan hubungkan ke remittance
    sql = """
    SELECT m.*, ARRAY(
        SELECT p.receiver_phone FROM Money_Order_Receiver_Phone p
        WHERE p.money_order_id = m.money_order_id
        ORDER BY p.receiver_phone
    ) AS receiver_phones
    FROM money_order m
    """

    cypher = """
    UNWIND $rows AS row
    MERGE (mo:MoneyOrder {money_order_id: row.money_order_id})
    SET mo += row{.*, transaction_id: null}
    WITH mo, row
    MATCH (t:Transaction:Remittance {transaction_id: row.transaction_id})
    MERGE (t)-[:ISSUES]->(mo)
    """
    
    stream(pg, graph_db, sql, cypher)

def load_disbursement_dan_payout(pg, graph_db):
    # load fund distribution program dan hubungkan ke partner
    sql = "SELECT * FROM Fund_Distribution_Program"

    cypher = """
    UNWIND $rows AS row
    MERGE (f:FundProgram {program_id: row.program_id})
    SET f += row{.*, partner_id: null}
    WITH f, row
    MATCH (p:Partner {partner_id: row.partner_id})
    MERGE (p)-[:RUNS]->(f)
    """

    stream(pg, graph_db, sql, cypher)

    # load disbursement
    sql = sql_transaction.format(
        columns="st.disbursement_method, st.verification_method, st.verified_id_no",
        subtype="Disbursement",
    )

    cypher = """
    UNWIND $rows AS row
    MERGE (t:Transaction {transaction_id: row.transaction_id})
    SET t:Disbursement, t += row{.*, customer_id: null, account_id: null}
    """

    stream(pg, graph_db, sql, cypher)

    # hubungkan customer ke disbursement
    sql = """
    SELECT transaction_id, customer_id from Transaction
    WHERE transaction_type = 'disbursement' AND customer_id IS NOT NULL
    """

    cypher = """
    UNWIND $rows AS row
    MATCH (t:Transaction:Disbursement {transaction_id: row.transaction_id})
    MATCH (c:Customer {customer_id: row.customer_id})
    MERGE (c)-[:PERFORMS]->(t)
    """

    stream(pg, graph_db, sql, cypher)

    # load payout dan hubungkan ke disbursement
    sql = "SELECT * FROM Payout"

    cypher = """
    UNWIND $rows AS row
    MERGE (p:Payout {payout_id: row.payout_id})
    SET p += row{.*, transaction_id: null, money_order_id: null, program_id: null}
    WITH p, row
    MATCH (t:Transaction:Disbursement {transaction_id: row.transaction_id})
    MERGE (t)-[:EXECUTES]->(p)
    """

    stream(pg, graph_db, sql, cypher)

    # payout dari money order
    sql = "SELECT payout_id, money_order_id FROM Payout WHERE money_order_id IS NOT NULL"

    cypher = """
    UNWIND $rows AS row
    MATCH (mo:MoneyOrder {money_order_id: row.money_order_id})
    MATCH (p:Payout {payout_id: row.payout_id})
    MERGE (mo)-[:PAID_OUT_AS]->(p)
    """

    stream(pg, graph_db, sql, cypher)

    # payout dari fund distribution program
    sql = "SELECT payout_id, program_id FROM Payout WHERE program_id IS NOT NULL"

    cypher = """
    UNWIND $rows AS row
    MATCH (f:FundProgram {program_id: row.program_id})
    MATCH (p:Payout {payout_id: row.payout_id})
    MERGE (f)-[:FUNDS]->(p)
    """

    stream(pg, graph_db, sql, cypher)

def load_status_dan_fee(pg, graph_db):
    # load status history dan hubungkan ke transaction
    sql = "SELECT * FROM Status_History"

    cypher = """
    UNWIND $rows AS row
    MATCH (t:Transaction {transaction_id: row.transaction_id})
    MERGE (t)-[:HAS_STATUS]->(s:StatusChange {sequence_no: row.sequence_no})
    SET s += row{.*, transaction_id: null}
    """

    stream(pg, graph_db, sql, cypher)

    # load fee dan hubungkan ke transaction
    sql = "SELECT * FROM Transaction_Fee"

    cypher = """
    UNWIND $rows AS row
    MATCH (t:Transaction {transaction_id: row.transaction_id})
    MERGE (t)-[:HAS_FEE]->(f:Fee {fee_no: row.fee_no})
    SET f += row{.*, transaction_id: null}
    """

    stream(pg, graph_db, sql, cypher)

def main():
    # koneksi ke postgres
    pg_conninfo = make_conninfo(
        host=os.getenv("POSTGRES_HOST"),
        port=os.getenv("POSTGRES_PORT"),
        dbname=os.getenv("POSTGRES_DB"),
        user=os.getenv("POSTGRES_USER"),
        password=os.getenv("POSTGRES_PASSWORD"),
    )

    graph_db = GraphDatabase.driver(
        os.getenv("NEO4J_URI"),
        auth=(os.getenv("NEO4J_USER"), os.getenv("NEO4J_PASSWORD")),
    )

    with psycopg.connect(pg_conninfo) as pg, graph_db as graph_db:
        pg.read_only = True

        graph_db.verify_connectivity()

        create_neo4j_index(graph_db)
  
        load_partner(pg, graph_db)
        load_customer_dan_account(pg, graph_db)
        load_account_transactions(pg, graph_db)
        load_bill_payment_dan_reversal(pg, graph_db)
        load_remittance_dan_money_order(pg, graph_db)
        load_disbursement_dan_payout(pg, graph_db)
        load_status_dan_fee(pg, graph_db)

if __name__ == "__main__":
    main()
