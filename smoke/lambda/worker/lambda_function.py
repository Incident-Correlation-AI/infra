"""SMOKE placeholder - consumes SQS, writes ONLY clearly-labeled smoke items to DynamoDB.
Never creates incident-shaped items (the demo must never be seeded directly)."""
import json
import os
import time
import uuid

import boto3

TABLE = os.environ.get("INCIDENT_TABLE", "")


def handler(event, context):
    failures = []
    if not TABLE:
        return {"batchItemFailures": [{"itemIdentifier": "missing-table-name"}]}
    table = boto3.resource("dynamodb").Table(TABLE)
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            for evt in body.get("events", []):
                if isinstance(evt, dict) and evt.get("type") == "wiresmoke":
                    table.put_item(
                        Item={
                            "pk": "SMOKE",
                            "sk": f"WIRE#{time.time_ns()}",
                            "event_id": evt.get("event_id", "unknown"),
                            "ingest_wait_ms": evt.get("ingest_wait_ms", 0),
                            "note": "wiring smoke test item - safe to delete",
                        }
                    )
        except Exception:
            failures.append({"itemIdentifier": record.get("messageId")})
    return {"batchItemFailures": failures}
