
import os
import re
from neo4j import GraphDatabase
from dotenv import load_dotenv

load_dotenv()
print("URI:", repr(os.getenv("NEO4J_URI")))
print("USER:", repr(os.getenv("NEO4J_USER")))
print("PASSWORD EXISTS:", bool(os.getenv("NEO4J_PASSWORD")))

driver =GraphDatabase.driver(
        os.getenv("NEO4J_URI"),
        auth=(os.getenv("NEO4J_USER"), os.getenv("NEO4J_PASSWORD")),)

DATABASE = os.getenv("NEO4J_DATABASE", "neo4j")


def load_queries(filepath="prev_query.cypher"):
    with open(filepath, "r", encoding="utf-8") as file:
        content = file.read()

    sections = re.split(
        r"(?m)^//\s*(Read|Write)\s+(\d+):[^\n]*\n",
        content
    )

    queries = {
        "Read": {},
        "Write": {}
    }

    for i in range(1, len(sections), 3):
        query_type = sections[i]
        query_id = int(sections[i + 1])
        query_text = sections[i + 2]

        query_text = "\n".join(
            line for line in query_text.splitlines()
            if not line.strip().startswith("//")
        )

        query_text = query_text.strip().rstrip(";").strip()

        if query_text:
            queries[query_type][query_id] = query_text

    return queries


def execute_query(query, params=None):
    result = driver.execute_query(
        query,
        parameters_=params or {},
        database_=DATABASE
    )

    return [record.data() for record in result.records]

if __name__ == "__main__": #testing parser is working
    queries = load_queries()

    print("READ QUERIES:")
    print(list(queries["Read"].keys()))

    print("\nWRITE QUERIES:")
    print(list(queries["Write"].keys()))